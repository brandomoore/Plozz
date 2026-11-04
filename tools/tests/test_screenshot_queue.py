"""Offline tests for one-time App Store screenshot placement; never contact Apple."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUBY = shutil.which("ruby")
HARNESS = r'''
require "json"
require "uri"
require ARGV.fetch(0)
manifest = JSON.parse(File.read(ENV.fetch("MANIFEST")))
scenario = ENV.fetch("SCENARIO")
class Fake
  attr_reader :rows, :writes, :assets
  def initialize(manifest, scenario)
    @manifest = manifest; @scenario = scenario; @writes = []; @serial = 0; @failed = false
    @rows = manifest.fetch("groups").to_h do |g|
      [g["device"], Array.new(scenario == "full" ? 10 : 4) { |n| {"id"=>"old-#{g['device']}-#{n}", "image"=>"old-image-#{n}"} }]
    end
    @rows["duo"] = [{"id"=>"separate-duo-placement", "image"=>"separate-duo-image"}]
    @assets = {}
    manifest["groups"].each { |g| g["assets"].each { |a| @assets[a["id"]] = [a, g] } }
    @versions = manifest["after_versions"].map do |platform, baseline|
      {"id"=>baseline["id"], "attributes"=>{"platform"=>platform, "versionString"=>baseline["version"],
        "appStoreState"=>"READY_FOR_SALE", "createdDate"=>"2026-11-02T00:00:00Z"}}
    end
    unless scenario == "baseline"
      @versions += %w[IOS TV_OS].map do |platform|
        {"id"=>"next-#{platform}", "attributes"=>{"platform"=>platform, "versionString"=>"2026.11.5",
          "appStoreState"=>scenario == "in_review" ? "IN_REVIEW" : "PREPARE_FOR_SUBMISSION",
          "createdDate"=>"2026-11-05T00:00:00Z"}}
      end
    end
  end
  def get(path)
    if path.start_with?("v1/apps/")
      return {"data"=>@versions}
    elsif path.include?("/appStoreVersionLocalizations?")
      platform = path.include?("next-TV_OS") ? "TV_OS" : "IOS"
      return {"data"=>[{"id"=>"locale-#{platform}", "attributes"=>{"locale"=>"en-US"}}]}
    elsif path.start_with?("v1/appStoreVersions/")
      value = @versions.find { |v| v["id"] == path.split("/").last }
      if @scenario == "state_flip" && !@writes.empty?
        value["attributes"]["appStoreState"] = "IN_REVIEW"
      end
      return {"data"=>value}
    elsif path.start_with?("v1/appAssetLibraryImages/")
      asset, group = @assets.fetch(path.split("/").last)
      return {"data"=>{"attributes"=>{"state"=>"PREPARE_FOR_SUBMISSION", "fileName"=>asset["file"],
        "referenceName"=>"sha256:#{@scenario == 'wrong_asset' ? 'wrong' : asset['sha256']}",
        "specId"=>group["spec_id"], "imageAsset"=>{"width"=>group["dimensions"][0], "height"=>group["dimensions"][1]}}}}
    elsif path.include?("/placements?")
      query = URI.decode_www_form(path.split("?", 2).last).to_h
      raise "Image linkage must be explicitly included" unless query["include"] == "image"
      group = @manifest["groups"].find { |g| g["placement_group"] == query["filter[placementGroup]"] }
      return {"data"=>@rows[group["device"]].map { |r| {"id"=>r["id"], "relationships"=>{"image"=>{"data"=>{"id"=>r["image"]}}}} }}
    end
    raise "Unexpected GET #{path}"
  end
  def post(path, body)
    data = body.fetch("data")
    group = @manifest["groups"].find { |g| g["placement_group"] == data.fetch("attributes").fetch("placementGroup") }
    rows = @rows.fetch(group.fetch("device"))
    if @scenario == "partial" && group["device"] == "tv" && !@failed
      @failed = true
      raise "Definite pre-write failure"
    end
    @writes << path
    if path == "v1/appAssetLibraryPlacements"
      raise "Group capacity exceeded" if rows.length >= 10
      @serial += 1
      row = {"id"=>"new-#{@serial}", "image"=>data["relationships"]["image"]["data"]["id"]}
      rows << row
      rows << {"id"=>"foreign", "image"=>"foreign"} if @scenario == "concurrent"
      raise "Uncertain response after write" if @scenario == "uncertain"
      return {"data"=>{"id"=>row["id"]}}
    elsif path == "v1/appAssetLibraryPlacementOrderingRequests"
      order = data["relationships"]["orderedPlacements"]["data"].map { |x| x["id"] }
      rows.sort_by! { |r| order.index(r["id"]) }
      return {}
    end
    raise "Unexpected POST #{path}"
  end
  def delete(path)
    raise "Unexpected DELETE #{path}" unless path.start_with?("v1/appAssetLibraryPlacements/")
    @writes << path
    @rows.each_value { |rows| rows.reject! { |r| r["id"] == path.split("/").last } }
  end
end
client = Fake.new(manifest, scenario)
queue = -> { PlozzScreenshotQueue::Queue.new(client: client, manifest_path: ENV.fetch("MANIFEST"), state_directory: ENV.fetch("STATE")) }
errors = []
begin
  queue.call.apply(scenario == "wrong_version" ? "2026.11.6" : "2026.11.5")
rescue StandardError => e
  errors << e.message
end
first_writes = client.writes.length
if %w[success full partial uncertain lost_receipt].include?(scenario)
  File.delete(File.join(ENV.fetch("STATE"), "#{manifest['id']}.json")) if scenario == "lost_receipt"
  begin
    queue.call.apply(%w[success full lost_receipt].include?(scenario) ? "2026.11.6" : "2026.11.5")
  rescue StandardError => e
    errors << e.message
  end
end
state_path = File.join(ENV.fetch("STATE"), "#{manifest['id']}.json")
puts JSON.generate({errors: errors, writes: client.writes, first_writes: first_writes, rows: client.rows,
  state: File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}})
'''


@unittest.skipUnless(RUBY, "Ruby is required")
class ScreenshotQueueTests(unittest.TestCase):
    def run_case(self, scenario):
        manifest = json.loads((ROOT / "fastlane/pending-store-screenshots.json").read_text())
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "manifest.json"
            path.write_text(json.dumps(manifest))
            result = subprocess.run(
                [RUBY, "-e", HARNESS, str(ROOT / "fastlane/screenshot_queue.rb")],
                env={**os.environ, "SCENARIO": scenario, "MANIFEST": str(path),
                     "STATE": str(Path(temporary) / "state")},
                text=True, capture_output=True, timeout=30, check=True,
            )
        return manifest, json.loads(result.stdout)

    def test_exact_assets_order_and_one_time_consumption(self):
        for scenario in ("success", "full", "lost_receipt"):
            with self.subTest(scenario=scenario):
                manifest, result = self.run_case(scenario)
                self.assertEqual(result["errors"], [])
                self.assertEqual(len(result["writes"]), result["first_writes"])
                for group in manifest["groups"]:
                    self.assertEqual(
                        [row["image"] for row in result["rows"][group["device"]]],
                        [asset["id"] for asset in group["assets"]],
                    )
                self.assertTrue(all(p["complete"] for p in result["state"]["platforms"].values()))
                self.assertTrue(all(path.startswith("v1/appAssetLibraryPlacement") for path in result["writes"]))
                self.assertEqual(result["rows"]["duo"], [{"id": "separate-duo-placement", "image": "separate-duo-image"}])

    def test_partial_platform_failure_resumes(self):
        _, result = self.run_case("partial")
        self.assertEqual(result["errors"], ["Definite pre-write failure"])
        self.assertTrue(all(p["complete"] for p in result["state"]["platforms"].values()))
        self.assertEqual(len(result["rows"]["iphone"]), 6)
        self.assertEqual(len(result["rows"]["tv"]), 5)

    def test_locked_old_wrong_version_and_changed_assets_refuse_writes(self):
        for scenario in ("baseline", "in_review", "wrong_version", "wrong_asset"):
            with self.subTest(scenario=scenario):
                _, result = self.run_case(scenario)
                self.assertTrue(result["errors"])
                self.assertEqual(result["writes"], [])

    def test_concurrent_change_is_not_overwritten(self):
        _, result = self.run_case("concurrent")
        self.assertIn("Unexpected screenshot", result["errors"][0])
        self.assertEqual(len(result["writes"]), 1)
        self.assertTrue(any(row["id"] == "foreign" for row in result["rows"]["iphone"]))

    def test_review_transition_stops_before_next_write(self):
        _, result = self.run_case("state_flip")
        self.assertIn("editable draft", result["errors"][0])
        self.assertEqual(len(result["writes"]), 1)

    def test_uncertain_write_is_not_blindly_retried(self):
        _, result = self.run_case("uncertain")
        self.assertEqual(len(result["writes"]), 1)
        self.assertIn("unconfirmed", result["errors"][1])

    def test_release_hook_runs_after_uploads_before_tagging(self):
        fastfile = (ROOT / "fastlane/Fastfile").read_text()
        release = fastfile.split("lane :release do", 1)[1]
        self.assertLess(release.index("upload_to_app_store("), release.index("apply_queued_store_screenshots"))
        self.assertLess(release.index("apply_queued_store_screenshots"), release.index("tag_github_release("))
        beta = fastfile.split("lane :beta do", 1)[1].split('desc "Build and upload tvOS plus', 1)[0]
        self.assertNotIn("apply_queued_store_screenshots", beta)


if __name__ == "__main__":
    unittest.main()
