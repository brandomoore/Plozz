# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "securerandom"

# Separate Ruby interpreters isolate Pilot configuration and Spaceship tokens.
# Credentials travel over anonymous stdin pipes, never argv or a job file.
module PlozzTestflightPipeline
  class ValidationFailure < StandardError
    REASONS = {
      "external_group_missing" => "Required external TestFlight group is missing.",
      "uploaded_build_mismatch" => "Apple returned a different version or build; distribution was refused."
    }.freeze

    attr_reader :code

    def initialize(code)
      @code = code
      super(reason)
    end

    def reason
      REASONS.fetch(code)
    end
  end

  class Failure < StandardError
    attr_reader :outcomes

    def initialize(outcomes)
      @outcomes = outcomes
      super(
        outcomes.map { |outcome| PlozzTestflightPipeline.describe(outcome) }.join("\n") +
        "\nNo release tag created. Inspect these exact builds in App Store Connect before recovery; " \
        "do not rerun beta, rebuild, increment, or blindly retry an upload."
      )
    end
  end

  class << self
    def job(name:, app_identifier:, platform:, ipa:, version:, build_number:, notes:, group:)
      {
        name: name,
        options: {
          app_identifier: app_identifier, app_platform: platform, ipa: ipa,
          app_version: version, build_number: build_number.to_s, changelog: notes,
          distribute_external: true, groups: [group], notify_external_testers: true,
          submit_beta_review: true, skip_waiting_for_build_processing: false,
          wait_for_uploaded_build: true,
          skip_submission: false, distribute_only: false, expire_previous_builds: false,
          reject_build_waiting_for_review: false
        }
      }
    end

    def validate_jobs!(jobs, analyser: nil)
      require "fastlane_core/ipa_file_analyser" unless analyser
      analyser ||= FastlaneCore::IpaFileAnalyser
      jobs.each do |job|
        options = job.fetch(:options)
        ipa = options.fetch(:ipa)
        raise "#{job.fetch(:name)}: missing signed IPA #{ipa}" unless File.file?(ipa)

        {
          fetch_app_identifier: :app_identifier, fetch_app_platform: :app_platform,
          fetch_app_version: :app_version, fetch_app_build: :build_number
        }.each do |method, key|
          actual = analyser.public_send(method, ipa).to_s
          expected = options.fetch(key).to_s
          raise "#{job.fetch(:name)}: IPA #{key} #{actual.inspect} != approved #{expected.inspect}" unless actual == expected
        end
      end
    end

    def describe(outcome)
      state = outcome.fetch("state", {})
      details = %w[phase processing_state internal_state external_state error_class error_code reason].filter_map do |key|
        "#{key}=#{state[key]}" if state[key]
      end
      details << "process cleanup incomplete" if outcome["cleanup_failed"]
      "#{outcome.fetch('name')} #{outcome.fetch('version')} (#{outcome.fetch('build_number')}): " \
        "#{outcome.fetch('outcome')}; #{details.join(', ')}; " \
        "exit=#{outcome['exit_status'].inspect}, signal=#{outcome['signal'].inspect}; log=#{outcome.fetch('log')}"
    end

    def write_state(path, state)
      staging = "#{path}.next"
      File.write(staging, JSON.pretty_generate(state), mode: "w", perm: 0o600)
      File.rename(staging, path)
    end

    def lease_descriptors
      unless ENV["APPLE_BUILD_LEASE_PROTOCOL"] == "1" && ENV["APPLE_BUILD_LEASE_MODE"] == "shared"
        raise "TestFlight workers require the enclosing release's shared build lease"
      end
      %w[APPLE_BUILD_LEASE_PROOF_FD APPLE_BUILD_LEASE_LOCK_FD].to_h do |key|
        value = ENV.fetch(key)
        raise "Invalid inherited release lease descriptor" unless value.match?(/\A(?:[3-9]|[1-9][0-9]+)\z/)

        fd = Integer(value)
        [fd, IO.for_fd(fd, autoclose: false)]
      end
    end

    def upload_all(jobs:, api_key:, output_root:, command: [RbConfig.ruby, __FILE__, "--worker"],
                   grace: 10, poll: 0.1)
      descriptors = lease_descriptors
      directory = File.join(output_root, "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(8)}")
      FileUtils.mkdir_p(directory, mode: 0o700)
      children = jobs.map.with_index do |job, index|
        options = job.fetch(:options)
        {
          "name" => job.fetch(:name), "version" => options.fetch(:app_version),
          "build_number" => options.fetch(:build_number),
          "log" => File.join(directory, "#{index}.log"),
          "result" => File.join(directory, "#{index}.json"), "outcome" => "not started"
        }
      end
      cancelled = nil
      traps = {}
      %w[INT TERM].each { |signal| traps[signal] = Signal.trap(signal) { cancelled ||= signal } }
      begin
        jobs.zip(children).each do |job, child|
          break if cancelled

          reader, writer = IO.pipe
          begin
            File.open(child.fetch("log"), "w", 0o600) do |log|
              child["pid"] = Process.spawn(
                # The shell transporter writes/deletes shared ~/.appstoreconnect
                # keys. Use the normal altool/Java executor's private key storage.
                { "FASTLANE_ITUNES_TRANSPORTER_USE_SHELL_SCRIPT" => "false" },
                *command, child.fetch("result"),
                descriptors.merge(in: reader, out: log, err: log, pgroup: true, close_others: true)
              )
            end
            child["outcome"] = "running"
            puts("#{child.fetch('name')}: TestFlight worker #{child.fetch('pid')}; log=#{child.fetch('log')}")
            reader.close
            writer.write(JSON.generate(job.merge(
              api_key: api_key, fastlane_version: Gem.loaded_specs["fastlane"]&.version&.to_s
            )))
          rescue StandardError => e
            child["state"] = { "phase" => "starting", "error_class" => e.class.name }
            child["outcome"] = "failed to start"
          ensure
            reader.close unless reader.closed?
            writer.close
          end
        end

        deadline = nil
        loop do
          children.each do |child|
            reap(child)
            group_alive?(child) if child["reaped"]
          end
          if cancelled && deadline.nil?
            children.each { |child| signal_group(child, "TERM") }
            deadline = monotonic + grace
          end
          break if children.none? { |child| child["pid"] && !child["reaped"] }

          if deadline && monotonic >= deadline
            children.each { |child| signal_group(child, "KILL") }
          end
          sleep(poll)
        end
      ensure
        # A failed worker may leave its transporter alive. Own process groups
        # include those descendants; never signal unrelated builds or workers.
        children.each { |child| signal_group(child, "TERM") }
        cleanup_deadline = monotonic + grace
        while children.count { |child| group_alive?(child) } > 0 && monotonic < cleanup_deadline
          children.each { |child| reap(child) }
          sleep(poll)
        end
        children.each { |child| signal_group(child, "KILL") if group_alive?(child) }
        children.each do |child|
          if child["pid"] && !child["reaped"]
            _, status = Process.wait2(child.fetch("pid"))
            record_exit(child, status)
          end
        end
        cleanup_deadline = monotonic + grace
        while children.count { |child| group_alive?(child) } > 0 && monotonic < cleanup_deadline
          sleep(poll)
        end
        children.each do |child|
          if group_alive?(child)
            child["cleanup_failed"] = true
            child["outcome"] = "process cleanup incomplete"
          end
          child["cancelled_by"] = cancelled if cancelled
          child["outcome"] = "cancelled" if cancelled && child["outcome"] != "succeeded"
        end
        traps.each { |signal, previous| Signal.trap(signal, previous) }
        write_state(File.join(directory, "summary.json"), children)
      end
      raise Failure, children if cancelled || children.any? { |child| child["outcome"] != "succeeded" }

      children
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def signal_group(child, signal)
      return if !child["pid"] || child["group_gone"]

      Process.kill(signal, -child.fetch("pid"))
    rescue Errno::ESRCH
      child["group_gone"] = true
    end

    def group_alive?(child)
      return false if !child["pid"] || child["group_gone"]

      Process.kill(0, -child.fetch("pid"))
      true
    rescue Errno::ESRCH
      # Never revisit this numeric PGID, even if a later process reuses it.
      child["group_gone"] = true
      false
    end

    def reap(child)
      return unless child["pid"] && !child["reaped"]

      result = Process.wait2(child.fetch("pid"), Process::WNOHANG)
      record_exit(child, result.last) if result
    end

    def record_exit(child, status)
      child["reaped"] = true
      child["exit_status"] = status.exitstatus
      child["signal"] = status.termsig
      if File.file?(child.fetch("result"))
        begin
          state = JSON.parse(File.read(child.fetch("result")))
          child["state"] = valid_worker_state?(state) ? state : invalid_worker_state
        rescue JSON::ParserError, SystemCallError, IOError
          child["state"] = invalid_worker_state
        end
      end
      state = child.fetch("state", {})
      child["outcome"] =
        status.success? && state["phase"] == "complete" && !state["error_class"] && !state["error_code"] ? "succeeded" : "failed"
      signal_group(child, "TERM")
    end

    def valid_worker_state?(state)
      state.is_a?(Hash) && state["phase"].is_a?(String) && !state["phase"].strip.empty? &&
        %w[processing_state internal_state external_state error_class error_code reason].all? do |key|
          state[key].nil? || state[key].is_a?(String)
        end
    end

    def invalid_worker_state
      {
        "phase" => "unknown", "error_class" => "InvalidWorkerResult",
        "error_code" => "invalid_worker_result", "reason" => "Worker result was not a valid status object."
      }
    end

    def run_worker(result_path)
      $stdout.sync = $stderr.sync = true
      state = { "phase" => "starting" }
      update = lambda do |phase, details = {}|
        state.merge!(details).merge!("phase" => phase)
        write_state(result_path, state)
      end
      update.call("starting")
      Signal.trap("TERM") { raise Interrupt }
      Signal.trap("INT") { raise Interrupt }
      begin
        payload = JSON.parse($stdin.read, symbolize_names: true)
        $stdin.reopen(File::NULL)
        lease_descriptors
        require_relative "../tools/lib/apple_build_lease"
        AppleBuildLease.with_shared("plozz/fastlane/testflight-worker") do
          gem("fastlane", payload[:fastlane_version]) if payload[:fastlane_version]
          require "fastlane"
          require "pilot"
          require "pilot/options"
          options = payload.fetch(:options).merge(api_key: payload.fetch(:api_key))
          configuration = FastlaneCore::Configuration.create(Pilot::Options.available_options, options)
          manager_class = Class.new(Pilot::BuildManager) do
            define_method(:wait_for_build_processing_to_be_complete) do |*arguments|
              update.call("uploaded")
              build = super(*arguments)
              unless build.app_version == options.fetch(:app_version) && build.version == options.fetch(:build_number)
                raise ValidationFailure, "uploaded_build_mismatch"
              end
              update.call("processed", "build_id" => build.id, "processing_state" => build.processing_state)
              build
            end
            define_method(:distribute) do |values, build: nil|
              update.call("distributing")
              super(values, build: build)
              current = Spaceship::ConnectAPI::Build.get(build_id: build.id)
              update.call(
                "complete",
                "processing_state" => current.processing_state,
                "internal_state" => current.build_beta_detail.internal_build_state,
                "external_state" => current.build_beta_detail.external_build_state
              )
            end
          end
          manager = manager_class.new
          manager.start(configuration)
          groups = manager.app.get_beta_groups
          unless options.fetch(:groups).all? { |name| groups.any? { |group| group.name == name && group.is_internal_group == false } }
            raise ValidationFailure, "external_group_missing"
          end
          update.call("uploading")
          manager.upload(configuration)
        end
        0
      rescue Interrupt
        update.call(state.fetch("phase"), "error_class" => "Interrupted")
        130
      rescue ValidationFailure => e
        update.call(state.fetch("phase"), "error_class" => e.class.name, "error_code" => e.code, "reason" => e.reason)
        warn("TestFlight validation failed: #{e.code}: #{e.reason}")
        1
      rescue StandardError => e
        # Do not serialize exceptions/configuration: they may contain API keys.
        update.call(state.fetch("phase"), "error_class" => e.class.name)
        warn("TestFlight worker failed during #{state.fetch('phase')} (#{e.class.name})")
        1
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort("Internal worker only") unless ARGV.length == 2 && ARGV.first == "--worker"
  exit(PlozzTestflightPipeline.run_worker(ARGV.last))
end
