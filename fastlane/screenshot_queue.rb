require "json"
require "digest"
require "fileutils"
require "uri"
require "time"

module PlozzScreenshotQueue
  class Failure < StandardError; end
  EDITABLE = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].freeze

  class Client
    def initialize(client)
      @client = client
    end

    def get(path)
      @client.get(path).body
    end

    def post(path, data)
      # A timed-out POST may have succeeded. Preserve the journal instead of
      # retrying a non-idempotent placement creation.
      @client.post(path, data, tries: 1)&.body
    end

    def delete(path)
      @client.delete(path)
    end
  end

  class Queue
    def initialize(client:, manifest_path:, state_directory:)
      @client = client
      @manifest_bytes = File.read(manifest_path)
      @manifest = JSON.parse(@manifest_bytes)
      @directory = state_directory
      @id = @manifest.fetch("id")
      raise Failure, "Invalid screenshot queue ID" unless @id.match?(/\A[a-z0-9-]+\z/)
      @path = File.join(@directory, "#{@id}.json")
      @groups = @manifest.fetch("groups")
      raise Failure, "Expected the three approved screenshot groups" unless @groups.map { |g| g.fetch("device") }.sort == %w[ipad iphone tv]
      @groups.each do |group|
        assets = group.fetch("assets")
        raise Failure, "Invalid screenshot count" unless assets.length == (group["device"] == "tv" ? 5 : 6)
        raise Failure, "Duplicate screenshot assets" unless assets.map { |a| a.fetch("id") }.uniq.length == assets.length
        assets.each do |asset|
          raise Failure, "Missing screenshot fingerprint" unless asset.fetch("sha256").match?(/\A[0-9a-f]{64}\z/)
        end
      end
    end

    def apply(version)
      FileUtils.mkdir_p(@directory, mode: 0o700)
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        raise Failure, "Another screenshot queue application is running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        fingerprint = Digest::SHA256.hexdigest(@manifest_bytes)
        @state = File.exist?(@path) ? JSON.parse(File.read(@path)) :
          { "manifest_sha256" => fingerprint, "platforms" => {} }
        raise Failure, "Screenshot queue changed; use a new queue ID" unless @state["manifest_sha256"] == fingerprint
        pending = @groups.group_by { |g| g.fetch("platform") }.reject { |platform, _| @state["platforms"].dig(platform, "complete") }
        return "Screenshot queue already consumed" if pending.empty?
        versions = all("v1/apps/#{@manifest.fetch('app_id')}/appStoreVersions?limit=200")
        plans = pending.map do |platform, groups|
          baseline = @manifest.fetch("after_versions").fetch(platform)
          candidates = versions.select do |item|
            attrs = item.fetch("attributes")
            attrs["platform"] == platform && item["id"] != baseline.fetch("id") &&
              (components(attrs.fetch("versionString")) <=> components(baseline.fetch("version"))) == 1
          end
          target = candidates.min_by { |item| Time.iso8601(item.fetch("attributes").fetch("createdDate")) }
          raise Failure, "#{platform}: no next App Store draft exists" unless target
          locales = all("v1/appStoreVersions/#{target.fetch('id')}/appStoreVersionLocalizations?limit=200")
          locale = locales.find { |item| item.fetch("attributes")["locale"] == @manifest.fetch("locale") }
          raise Failure, "#{platform}: missing screenshot localization" unless locale
          if target.fetch("attributes").fetch("versionString") != version
            # Server placements make consumption recoverable on another machine.
            if groups.all? { |group| images(placements(locale["id"], group)) == desired(group) }
              @state["platforms"][platform] = { "version_id" => target["id"], "complete" => true }
              save
              next
            end
            raise Failure, "#{platform}: queue belongs to the first next version, not #{version}"
          end
          guard(target)
          previous = @state["platforms"][platform]
          if previous && previous["version_id"] != target["id"]
            raise Failure, "#{platform}: refusing to retarget a partially applied queue"
          end
          [platform, target, locale["id"], groups]
        end.compact
        plans.each { |_, _, _, groups| groups.each { |group| verify_assets(group) } }
        plans.each do |platform, target, locale, groups|
          platform_state = @state["platforms"][platform] ||= {
            "version_id" => target["id"], "version" => version, "groups" => {}, "complete" => false
          }
          save
          groups.each { |group| apply_group(target, locale, group, platform_state) }
          platform_state["complete"] = true
          save
        end
        "Screenshot queue applied and verified"
      end
    end

    private

    def components(value)
      raise Failure, "Invalid App Store version" unless value.match?(/\A\d+\.\d+\.\d+\z/)
      value.split(".").map(&:to_i)
    end

    def save
      temporary = "#{@path}.tmp"
      File.write(temporary, JSON.pretty_generate(@state) + "\n", perm: 0o600)
      File.rename(temporary, @path)
    end

    def all(path)
      result = []
      while path
        response = @client.get(path)
        result.concat(response.fetch("data"))
        link = response.dig("links", "next")
        path = nil
        if link
          uri = URI(link)
          unless uri.scheme == "https" && uri.host == "api.appstoreconnect.apple.com" && uri.userinfo.nil?
            raise Failure, "Unexpected App Store pagination destination"
          end
          path = uri.request_uri.delete_prefix("/")
        end
      end
      result
    end

    def guard(target)
      current = @client.get("v1/appStoreVersions/#{target.fetch('id')}").fetch("data")
      before = target.fetch("attributes")
      attrs = current.fetch("attributes")
      unless current["id"] == target["id"] && attrs["platform"] == before["platform"] &&
             attrs["versionString"] == before["versionString"] && EDITABLE.include?(attrs["appStoreState"])
        raise Failure, "Screenshot target is no longer the same editable draft"
      end
    end

    def verify_assets(group)
      group.fetch("assets").each do |asset|
        attrs = @client.get("v1/appAssetLibraryImages/#{asset.fetch('id')}").fetch("data").fetch("attributes")
        unless %w[PREPARE_FOR_SUBMISSION APPROVED ACCEPTED].include?(attrs["state"]) &&
               attrs["fileName"] == asset.fetch("file") &&
               attrs["referenceName"].to_s.end_with?("sha256:#{asset.fetch('sha256')}") &&
               attrs["specId"] == group.fetch("spec_id") &&
               [attrs.dig("imageAsset", "width"), attrs.dig("imageAsset", "height")] == group.fetch("dimensions")
          raise Failure, "Queued screenshot is unavailable or changed: #{asset.fetch('file')}"
        end
      end
    end

    def placements(locale, group)
      query = URI.encode_www_form(
        "filter[placementType]" => "APP_SCREENSHOT", "filter[placementGroup]" => group.fetch("placement_group"),
        "sort" => "placementGroupPosition", "include" => "image", "limit" => 50
      )
      all("v1/appStoreVersionLocalizations/#{locale}/placements?#{query}").map do |item|
        { "id" => item.fetch("id"), "image" => item.fetch("relationships").fetch("image").fetch("data").fetch("id") }
      end
    end

    def images(rows)
      rows.map { |row| row.fetch("image") }
    end

    def desired(group)
      group.fetch("assets").map { |asset| asset.fetch("id") }
    end

    def relationship(type, id)
      { "data" => { "type" => type, "id" => id } }
    end

    def check(target, locale, group, journal)
      guard(target)
      current = placements(locale, group)
      unless current == journal.fetch("expected")
        raise Failure, "Concurrent or unconfirmed screenshot change; inspect #{@path} before resuming"
      end
      current
    end

    def record(locale, group, journal, expected)
      current = placements(locale, group)
      unless current.sort_by { |row| row["id"] } == expected.sort_by { |row| row["id"] }
        raise Failure, "Unexpected screenshot placement readback; preserved journal at #{@path}"
      end
      journal["expected"] = current
      journal.delete("operation")
      save
    end

    def remove(target, locale, group, journal, row)
      current = check(target, locale, group, journal)
      journal["operation"] = { "delete_placement" => row.fetch("id") }
      save
      @client.delete("v1/appAssetLibraryPlacements/#{row.fetch('id')}")
      record(locale, group, journal, current.reject { |item| item["id"] == row["id"] })
    end

    def apply_group(target, locale, group, platform_state)
      key = group.fetch("device")
      journal = platform_state.fetch("groups")[key]
      unless journal
        original = placements(locale, group)
        journal = { "original" => original, "expected" => original, "complete" => false }
        platform_state["groups"][key] = journal
        save
      end
      current = check(target, locale, group, journal)
      wanted = desired(group)
      return if journal["complete"] && images(current) == wanted
      (wanted - images(current)).each do |image|
        current = check(target, locale, group, journal)
        obsolete = current.find { |row| !wanted.include?(row["image"]) }
        if current.length >= 10
          raise Failure, "Screenshot group is full without a replaceable placement" unless obsolete
          remove(target, locale, group, journal, obsolete)
          obsolete = nil
        end
        current = check(target, locale, group, journal)
        journal["operation"] = { "create_image" => image }
        save
        created = @client.post("v1/appAssetLibraryPlacements", "data" => {
          "type" => "appAssetLibraryPlacements",
          "attributes" => { "placementType" => "APP_SCREENSHOT", "placementGroup" => group.fetch("placement_group") },
          "relationships" => {
            "image" => relationship("appAssetLibraryImages", image),
            "appStoreVersionLocalization" => relationship("appStoreVersionLocalizations", locale)
          }
        }).fetch("data")
        record(locale, group, journal, current + [{ "id" => created.fetch("id"), "image" => image }])
        remove(target, locale, group, journal, obsolete) if obsolete
      end
      check(target, locale, group, journal).each do |row|
        remove(target, locale, group, journal, row) unless wanted.include?(row["image"])
      end
      current = check(target, locale, group, journal)
      raise Failure, "Duplicate or missing screenshot placement" unless images(current).sort == wanted.sort
      ordered = wanted.map { |image| current.find { |row| row["image"] == image } }
      journal["operation"] = { "order" => ordered }
      save
      @client.post("v1/appAssetLibraryPlacementOrderingRequests", "data" => {
        "type" => "appAssetLibraryPlacementOrderingRequests",
        "attributes" => { "placementGroup" => group.fetch("placement_group") },
        "relationships" => {
          "appStoreVersionLocalization" => relationship("appStoreVersionLocalizations", locale),
          "orderedPlacements" => { "data" => ordered.map { |row| { "type" => "appAssetLibraryPlacements", "id" => row["id"] } } }
        }
      })
      record(locale, group, journal, ordered)
      raise Failure, "Screenshot order was not applied" unless journal["expected"] == ordered
      journal["complete"] = true
      save
    end
  end
end
