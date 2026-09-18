#!/usr/bin/env python3
"""Offline release orchestration tests. Never archive or contact Apple."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "fastlane/testflight_pipeline.rb"
RUBY = shutil.which("ruby")
SECRET = "test-only-key-never-log-this"

FASTFILE_HARNESS = r"""
require "json"
module UI
  def self.method_missing(name, *args)
    raise args.first if name == :user_error!
  end
end
class LaneHarness
  attr_reader :lanes, :events, :build_options
  def initialize
    @lanes = {}; @events = []; @build_options = []
  end
  def desc(*); end
  def lane(name, &body); @lanes[name] = body; end
  def method_missing(name, *args)
    return @lanes.fetch(name).call(*args) if @lanes.key?(name)
    super
  end
  def respond_to_missing?(name, include_private = false)
    @lanes.key?(name) || super
  end
  def sh(*); ""; end
end
harness = LaneHarness.new
harness.instance_eval(File.read("fastlane/Fastfile"), File.expand_path("fastlane/Fastfile"))
module AppleBuildLease
  def self.with_shared(*); yield; end
end
def harness.asc_api_key; { key: "fixture" }; end
def harness.select_release_xcode; end
def harness.require_crash_reporting_dsn; end
def harness.next_build_number; @events << "number"; 39; end
def harness.marketing_version; "2026.9.17"; end
def harness.release_notes_entry
  { "id" => "release/039", "sections" => [
    { "category" => "Updated", "items" => ["Shared", { "text" => "TV only", "platforms" => ["tvOS"] }] },
    { "category" => "Fixed", "items" => [{ "text" => "iOS only", "platforms" => ["iOS"] }] }
  ] }
end
def harness.validate_release_notes_build(entry, number)
  @events << "gate"
  raise "gate failed" if ENV["SCENARIO"] == "gate_failure"
end
def harness.build_app(**options)
  @events << options.fetch(:scheme)
  @build_options << options
  raise "archive failed" if ENV["SCENARIO"] == "archive_failure" && options[:scheme] == "PlozziOS"
end
def harness.tag_github_release(*); @events << "tag"; end
PlozzTestflightPipeline.define_singleton_method(:validate_jobs!) do |jobs|
  harness.events << "validate IPAs"
end
PlozzTestflightPipeline.define_singleton_method(:upload_all) do |**arguments|
  harness.events << "upload both"
  harness.instance_variable_set(:@jobs, arguments[:jobs])
  raise PlozzTestflightPipeline::Failure.new([]) if ENV["SCENARIO"] == "upload_failure"
  []
end
begin
  harness.beta
rescue => e
  error = e.message
end
puts JSON.generate(events: harness.events, options: harness.build_options,
                   jobs: harness.instance_variable_get(:@jobs), error: error,
                   git_parameters: ENV["GIT_CONFIG_PARAMETERS"])
"""

SUPERVISOR = r"""
require ENV.fetch("PIPELINE_HELPER")
proof = File.open(File.join(ENV.fetch("SCRATCH"), "proof"), "w+")
lock = File.open(File.join(ENV.fetch("SCRATCH"), "lock"), "w+")
ENV["APPLE_BUILD_LEASE_PROTOCOL"] = "1"
ENV["APPLE_BUILD_LEASE_MODE"] = "shared"
ENV["APPLE_BUILD_LEASE_PROOF_FD"] = proof.fileno.to_s
ENV["APPLE_BUILD_LEASE_LOCK_FD"] = lock.fileno.to_s
jobs = JSON.parse(ENV.fetch("JOBS"), symbolize_names: true)
begin
  results = PlozzTestflightPipeline.upload_all(
    jobs: jobs, api_key: { key: ENV.fetch("SENTINEL") },
    output_root: File.join(ENV.fetch("SCRATCH"), "runs"),
    command: [RbConfig.ruby, ENV.fetch("WORKER")], grace: 0.2, poll: 0.01
  )
  puts JSON.generate(success: true, results: results)
rescue PlozzTestflightPipeline::Failure => e
  puts JSON.generate(success: false, results: e.outcomes, message: e.message)
end
"""

FAKE_WORKER = r"""
require ENV.fetch("PIPELINE_HELPER")
payload = JSON.parse($stdin.read, symbolize_names: true)
raise "missing key" unless payload.fetch(:api_key).fetch(:key) == ENV.fetch("SENTINEL")
PlozzTestflightPipeline.lease_descriptors.each_value(&:stat)
result = ARGV.last
options = payload.fetch(:options)
state = {
  "phase" => "uploading", "pid" => Process.pid,
  "started" => Process.clock_gettime(Process::CLOCK_MONOTONIC),
  "version" => options.fetch(:app_version), "build" => options.fetch(:build_number),
  "notes" => options.fetch(:changelog), "platform" => options.fetch(:app_platform)
}
scenario = payload.fetch(:scenario, "success")
if scenario == "hang"
  Signal.trap("TERM", "IGNORE")
  state["descendant"] = Process.spawn(
    RbConfig.ruby, "-e", "Signal.trap('TERM', 'IGNORE'); loop { sleep 1 }",
    in: File::NULL, out: File::NULL, err: File::NULL
  )
end
PlozzTestflightPipeline.write_state(result, state)
case scenario
when "hang"
  loop { sleep 1 }
when "failure"
  sleep 0.02
  state["phase"] = "uploaded"
  PlozzTestflightPipeline.write_state(result, state)
  exit 9
when "missing_result"
  File.unlink(result)
  exit 0
when "malformed_result"
  File.write(result, JSON.generate(payload.fetch(:result_value)))
  exit 0
else
  sleep 0.25
  state["phase"] = "complete"
  state["finished"] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  PlozzTestflightPipeline.write_state(result, state)
end
"""

MOCK_PILOT_WORKER = r"""
require ENV.fetch("PIPELINE_HELPER")
$LOADED_FEATURES.concat(["fastlane.rb", "pilot.rb", "pilot/options.rb",
  File.expand_path("tools/lib/apple_build_lease.rb")])
module AppleBuildLease
  def self.with_shared(*)
    raise "missing inherited lease" unless ENV["APPLE_BUILD_LEASE_MODE"] == "shared"
    yield
  end
end
module FastlaneCore
  module Configuration
    def self.create(_, options)
      raise "missing key" unless options[:api_key][:key] == ENV.fetch("SENTINEL")
      options
    end
  end
end
module Pilot
  module Options
    def self.available_options; []; end
  end
  class BuildManager
    Group = Struct.new(:name, :is_internal_group)
    App = Struct.new(:get_beta_groups)
    Build = Struct.new(:id, :app_version, :version, :processing_state, :build_beta_detail)
    Detail = Struct.new(:internal_build_state, :external_build_state)
    def start(options); @options = options; end
    def app
      groups = ENV["WORKER_SCENARIO"] == "missing_group" ? [] : [Group.new("Plozz External", false)]
      App.new(groups)
    end
    def upload(options)
      raise "sentinel upload failure #{ENV.fetch('SENTINEL')}" if ENV["WORKER_SCENARIO"] == "upload_failure"
      build = wait_for_build_processing_to_be_complete(false)
      distribute(options, build: build)
    end
    def wait_for_build_processing_to_be_complete(*)
      raise "sentinel processing failure" if ENV["WORKER_SCENARIO"] == "processing_failure"
      version = ENV["WORKER_SCENARIO"] == "wrong_build" ? "wrong" : @options[:app_version]
      Build.new("build-id", version, @options[:build_number], "VALID", nil)
    end
    def distribute(options, build: nil)
      raise "sentinel distribution failure" if ENV["WORKER_SCENARIO"] == "distribution_failure"
      raise "wrong notes" unless options[:changelog] == "TV only"
    end
  end
end
module Spaceship
  module ConnectAPI
    module Build
      def self.get(build_id:)
        detail = Pilot::BuildManager::Detail.new("IN_BETA_TESTING", "WAITING_FOR_BETA_REVIEW")
        Pilot::BuildManager::Build.new(build_id, "2026.9.17", "39", "VALID", detail)
      end
    end
  end
end
exit(PlozzTestflightPipeline.run_worker(ARGV.last))
"""

REAL_LEASE_COORDINATOR = r"""
require ENV.fetch("PIPELINE_HELPER")
require File.join(ENV.fetch("REPO_ROOT"), "tools/lib/apple_build_lease")
directory = ENV.fetch("SCRATCH")
report = { "coordinator_pid" => Process.pid }
begin
  AppleBuildLease.with_shared("test/fastlane-coordinator") do
    report.merge!(
      "lease_id" => ENV.fetch("APPLE_BUILD_LEASE_ID"),
      "proof_fd" => ENV.fetch("APPLE_BUILD_LEASE_PROOF_FD").to_i,
      "lock_fd" => ENV.fetch("APPLE_BUILD_LEASE_LOCK_FD").to_i
    )
    PlozzTestflightPipeline.write_state(File.join(directory, "coordinator.json"), report)
    failure = nil
    begin
      outcomes = PlozzTestflightPipeline.upload_all(
        jobs: JSON.parse(ENV.fetch("JOBS"), symbolize_names: true), api_key: {},
        output_root: File.join(directory, "runs"),
        command: [RbConfig.ruby, ENV.fetch("WORKER")], grace: 0.3, poll: 0.02
      )
    rescue PlozzTestflightPipeline::Failure => error
      failure = error
      outcomes = error.outcomes
    end
    report["results"] = outcomes
    report["children_reaped"] = outcomes.all? do |child|
      begin
        Process.waitpid(child.fetch("pid"), Process::WNOHANG)
        false
      rescue Errno::ECHILD
        true
      end
    end
    report["record_before_release"] = JSON.parse(File.read(
      File.join(ENV.fetch("APPLE_BUILD_INTERLOCK_TEST_ROOT"), "leases", "#{report.fetch('lease_id')}.json")
    ))
    PlozzTestflightPipeline.write_state(File.join(directory, "before-release.json"), report)
    sleep 0.02 until File.exist?(File.join(directory, "allow-coordinator-exit"))
    raise failure if failure
  end
  puts JSON.generate(success: true)
rescue PlozzTestflightPipeline::Failure
  puts JSON.generate(success: false)
  exit 1
end
"""

REAL_LEASE_WORKER = r"""
require ENV.fetch("PIPELINE_HELPER")
require File.join(ENV.fetch("REPO_ROOT"), "tools/lib/apple_build_lease")
payload = JSON.parse($stdin.read, symbolize_names: true)
platform = payload.fetch(:options).fetch(:app_platform)
state = { "phase" => "starting", "pid" => Process.pid }
Signal.trap("TERM") { raise Interrupt }
begin
  AppleBuildLease.with_shared("test/fastlane-dummy-worker") do
    descriptors = PlozzTestflightPipeline.lease_descriptors
    state.merge!(
      "phase" => "uploading", "lease_id" => ENV.fetch("APPLE_BUILD_LEASE_ID"),
      "proof_fd" => ENV.fetch("APPLE_BUILD_LEASE_PROOF_FD").to_i,
      "lock_fd" => ENV.fetch("APPLE_BUILD_LEASE_LOCK_FD").to_i,
      "descriptors" => descriptors.transform_values { |io| { "device" => io.stat.dev, "inode" => io.stat.ino } }
    )
    PlozzTestflightPipeline.write_state(ARGV.last, state)
    sleep 0.02 until File.exist?(File.join(ENV.fetch("SCRATCH"), "finish-#{platform}"))
    raise "fixture failure" if payload[:scenario] == "failure"
    state["phase"] = "complete"
    PlozzTestflightPipeline.write_state(ARGV.last, state)
  end
rescue Interrupt
  state["phase"] = "cancelled"
  PlozzTestflightPipeline.write_state(ARGV.last, state)
  exit 130
rescue StandardError
  state["phase"] = "failed"
  PlozzTestflightPipeline.write_state(ARGV.last, state)
  exit 9
end
"""


@unittest.skipUnless(RUBY, "Ruby is required for Fastlane pipeline tests")
class FastlanePipelineTests(unittest.TestCase):
    def setUp(self) -> None:
        (ROOT / ".build").mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="pipeline-tests-", dir=ROOT / ".build")
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.env = dict(
            os.environ,
            GIT_CONFIG_PARAMETERS="'safe.bareRepository=explicit' 'test.preserve=value'",
            PIPELINE_HELPER=str(HELPER),
            SCRATCH=str(self.directory),
            SENTINEL=SECRET,
        )
        for key in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"):
            self.env.pop(key, None)

    def ruby(self, source: str, **env: str) -> dict:
        result = subprocess.run(
            [RUBY, "-e", source], cwd=ROOT, env=dict(self.env, **env),
            capture_output=True, text=True, timeout=30, check=True,
        )
        return json.loads(result.stdout.splitlines()[-1])

    def jobs(self, scenarios: tuple[str, str] = ("success", "success")) -> list[dict]:
        return [
            {
                "name": name,
                "scenario": scenario,
                "options": {
                    "app_version": "2026.9.17", "build_number": "39",
                    "app_platform": platform, "changelog": notes,
                },
            }
            for name, platform, notes, scenario in zip(
                ["tvOS", "iOS/iPadOS"], ["appletvos", "ios"],
                ["TV only", "iOS only"], scenarios,
            )
        ]

    def run_supervisor(self, scenarios=("success", "success"), worker=FAKE_WORKER) -> dict:
        path = self.directory / "worker.rb"
        path.write_text(worker)
        return self.ruby(SUPERVISOR, WORKER=str(path), JOBS=json.dumps(self.jobs(scenarios)))

    def test_lanes_keep_archive_gate_and_platform_notes(self) -> None:
        result = self.ruby(FASTFILE_HARNESS)
        self.assertEqual(
            result["events"], ["number", "gate", "Plozz", "PlozziOS", "validate IPAs", "upload both", "tag"]
        )
        tv, ios = [job["options"] for job in result["jobs"]]
        self.assertEqual(tv["changelog"], "Updated\n• Shared\n• TV only")
        self.assertEqual(ios["changelog"], "Updated\n• Shared\n\nFixed\n• iOS only")
        for options in (tv, ios):
            self.assertEqual(options["app_version"], "2026.9.17")
            self.assertEqual(options["build_number"], "39")
            self.assertEqual(options["groups"], ["Plozz External"])
            for key in (
                "distribute_external", "notify_external_testers",
                "submit_beta_review", "wait_for_uploaded_build",
            ):
                self.assertTrue(options[key])
            for key in (
                "expire_previous_builds", "reject_build_waiting_for_review",
                "skip_waiting_for_build_processing", "skip_submission", "distribute_only",
            ):
                self.assertFalse(options[key])
        self.assertTrue(result["git_parameters"].endswith("'safe.bareRepository=all'"))
        self.assertIn("'test.preserve=value'", result["git_parameters"])

    def test_failure_never_tags_or_blindly_retries(self) -> None:
        for scenario in ("gate_failure", "archive_failure", "upload_failure"):
            with self.subTest(scenario=scenario):
                result = self.ruby(FASTFILE_HARNESS, SCENARIO=scenario)
                self.assertNotIn("tag", result["events"])
                self.assertEqual(result["events"].count("number"), 1)
                expected_uploads = 1 if scenario == "upload_failure" else 0
                self.assertEqual(result["events"].count("upload both"), expected_uploads)

    def test_package_options_are_private_and_not_xcargs(self) -> None:
        env = {
            "PLOZZ_FASTLANE_CLONED_SOURCE_PACKAGES": str(self.directory / "packages with spaces"),
            "PLOZZ_PACKAGE_CACHE_PATH": str(self.directory / "cache with spaces"),
            "GYM_CLONED_SOURCE_PACKAGES_PATH": "old-recovery-setting",
        }
        first = self.ruby(FASTFILE_HARNESS, **env)["options"]
        second = self.ruby(FASTFILE_HARNESS, **env)["options"]
        paths = [options["cloned_source_packages_path"] for options in first + second]
        self.assertEqual(len(set(paths)), 4)
        for options in first:
            self.assertTrue(options["cloned_source_packages_path"].startswith(env["PLOZZ_FASTLANE_CLONED_SOURCE_PACKAGES"] + "/"))
            self.assertEqual(options["package_cache_path"], env["PLOZZ_PACKAGE_CACHE_PATH"])
            self.assertTrue(options["disable_package_automatic_updates"])
            self.assertTrue(options["skip_package_repository_fetches"])
            self.assertFalse(options["skip_package_dependencies_resolution"])
            self.assertNotIn("Package", options["xcargs"])
            self.assertNotIn("packageCachePath", options["xcargs"])

    def test_real_gym_constructs_each_package_flag_once_in_every_phase(self) -> None:
        fastlane = shutil.which("fastlane")
        if not fastlane:
            self.skipTest("Fastlane is not installed")
        libexec = Path(fastlane).resolve().parent.parent / "libexec"
        if not (libexec / "gems").is_dir():
            self.skipTest("Non-Homebrew install: run command-construction test in its Ruby gem environment")
        options = self.ruby(
            FASTFILE_HARNESS,
            PLOZZ_FASTLANE_CLONED_SOURCE_PACKAGES=str(self.directory / "packages with spaces"),
            PLOZZ_PACKAGE_CACHE_PATH=str(self.directory / "cache with spaces"),
        )["options"][0]
        source = r"""
require "json"
require "gym"
require "pilot"
require "pilot/options"
require ENV.fetch("PIPELINE_HELPER")
require "shellwords"
FastlaneCore::Helper.define_singleton_method(:xcode_at_least?) { |_| true }
options = JSON.parse(ENV.fetch("BUILD_OPTIONS"), symbolize_names: true)
available = Gym::Options.available_options.map(&:key)
raise "unsupported option" unless (options.keys - available).empty?
options.delete(:project) # No generated Xcode project is required for this test.
options = FastlaneCore::Configuration.create(Gym::Options.available_options, options)
project = FastlaneCore::Project.allocate
project.instance_variable_set(:@options, options)
Gym.project = project
# Avoid Gym.config='s build-settings probes; exercise command construction only.
Gym.instance_variable_set(:@config, options)
Gym.cache = {}
commands = [
  project.build_xcodebuild_resolvepackagedependencies_command,
  project.build_xcodebuild_showbuildsettings_command,
  (["xcodebuild"] + Gym::BuildCommandGenerator.options + ["archive"]).join(" ")
]
job = PlozzTestflightPipeline.job(
  name: "tvOS", app_identifier: "com.thatcube.Plozz", platform: "appletvos",
  ipa: ENV.fetch("IPA"), version: "2026.9.17", build_number: "39",
  notes: "TV only", group: "Plozz External"
)
pilot = FastlaneCore::Configuration.create(
  Pilot::Options.available_options, job[:options].merge(api_key: { key: "fixture" })
)
raise "Pilot option changed" unless pilot[:groups] == ["Plozz External"] && pilot[:expire_previous_builds] == false
puts JSON.generate(commands: commands.map { |command| Shellwords.split(command) })
"""
        ipa = self.directory / "configuration-fixture.ipa"
        ipa.write_bytes(b"fixture")
        result = self.ruby(
            source, GEM_PATH=str(libexec), BUILD_OPTIONS=json.dumps(options),
            GYM_CLONED_SOURCE_PACKAGES_PATH="must-not-be-appended", IPA=str(ipa),
            PILOT_EXPIRE_PREVIOUS_BUILDS="true", PILOT_DISTRIBUTE_ONLY="true",
            PILOT_SKIP_SUBMISSION="true",
        )
        for tokens in result["commands"]:
            for flag in (
                "-clonedSourcePackagesDirPath", "-packageCachePath",
                "-disableAutomaticPackageResolution", "-skipPackageUpdates",
            ):
                self.assertEqual(tokens.count(flag), 1)
            self.assertEqual(tokens[tokens.index("-clonedSourcePackagesDirPath") + 1], options["cloned_source_packages_path"])
            self.assertEqual(tokens[tokens.index("-packageCachePath") + 1], options["package_cache_path"])

    def test_missing_release_lease_fails_before_launching(self) -> None:
        source = r"""
require ENV.fetch("PIPELINE_HELPER")
ENV.delete("APPLE_BUILD_LEASE_PROTOCOL")
Process.define_singleton_method(:spawn) { |*| raise "unexpected spawn" }
begin
  PlozzTestflightPipeline.upload_all(jobs: [], api_key: {}, output_root: ENV.fetch("SCRATCH"))
rescue => e
  puts JSON.generate(error: e.message)
end
"""
        result = self.ruby(source)
        self.assertIn("require the enclosing release's shared build lease", result["error"])

    def test_both_workers_overlap_and_keep_separate_state(self) -> None:
        result = self.run_supervisor()
        self.assertTrue(result["success"])
        tv, ios = result["results"]
        self.assertLess(max(tv["state"]["started"], ios["state"]["started"]), min(tv["state"]["finished"], ios["state"]["finished"]))
        self.assertEqual(tv["state"]["notes"], "TV only")
        self.assertEqual(ios["state"]["notes"], "iOS only")
        for child in result["results"]:
            self.assertTrue(child["reaped"])
            self.assertEqual(child["exit_status"], 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(child["pid"], 0)
        for path in self.directory.rglob("*"):
            if path.is_file():
                self.assertNotIn(SECRET, path.read_text())

    def test_failed_worker_does_not_cancel_successful_sibling(self) -> None:
        result = self.run_supervisor(("failure", "success"))
        self.assertFalse(result["success"])
        self.assertEqual([child["outcome"] for child in result["results"]], ["failed", "succeeded"])
        self.assertEqual(result["results"][0]["exit_status"], 9)
        self.assertEqual(result["results"][0]["state"]["phase"], "uploaded")
        self.assertTrue(all(child["reaped"] for child in result["results"]))
        self.assertIn("do not rerun beta", result["message"])
        self.assertIn("iOS/iPadOS 2026.9.17 (39): succeeded", result["message"])

    def test_exit_zero_without_completion_is_not_success(self) -> None:
        result = self.run_supervisor(("missing_result", "success"))
        self.assertFalse(result["success"])
        self.assertEqual(result["results"][0]["outcome"], "failed")

    def test_gone_groups_are_retired_even_if_numeric_id_is_reused(self) -> None:
        source = r"""
require ENV.fetch("PIPELINE_HELPER")
results = %w[probe signal].map do |first|
  calls = []
  Process.define_singleton_method(:kill) do |signal, pid|
    calls << [signal, pid]
    raise Errno::ESRCH if calls.length == 1
    1 # This numeric PGID has now been reused by an unrelated process.
  end
  child = { "pid" => 12345, "reaped" => true }
  if first == "probe"
    PlozzTestflightPipeline.group_alive?(child)
  else
    PlozzTestflightPipeline.signal_group(child, "TERM")
  end
  PlozzTestflightPipeline.signal_group(child, "TERM")
  PlozzTestflightPipeline.signal_group(child, "KILL")
  PlozzTestflightPipeline.group_alive?(child)
  { calls: calls, child: child }
end
puts JSON.generate(results: results)
"""
        result = self.ruby(source)
        for case in result["results"]:
            self.assertEqual(len(case["calls"]), 1)
            self.assertTrue(case["child"]["group_gone"])

    def test_finished_group_is_not_signalled_again_after_sibling_finishes(self) -> None:
        source = SUPERVISOR.replace(
            "begin\n  results",
            """retired = {}
original_kill = Process.method(:kill)
Process.define_singleton_method(:kill) do |signal, pid|
  raise "retired group was revisited" if retired[pid]
  begin
    original_kill.call(signal, pid)
  rescue Errno::ESRCH
    retired[pid] = true
    raise
  end
end
begin
  results""",
        )
        worker = self.directory / "worker.rb"
        worker.write_text(FAKE_WORKER)
        result = self.ruby(
            source, WORKER=str(worker), JOBS=json.dumps(self.jobs(("failure", "success"))),
        )
        self.assertEqual([child["outcome"] for child in result["results"]], ["failed", "succeeded"])
        self.assertTrue(all(child["group_gone"] for child in result["results"]))
        self.assertTrue(all(child["reaped"] for child in result["results"]))

    def test_malformed_result_schema_fails_without_interrupting_other_reaping(self) -> None:
        worker = self.directory / "worker.rb"
        worker.write_text(FAKE_WORKER)
        malformed = [
            [], ["complete"], "complete", 1, True, None, {},
            {"phase": 1}, {"phase": "complete", "error_class": []},
        ]
        for value in malformed:
            with self.subTest(value=value):
                jobs = self.jobs(("malformed_result", "success"))
                jobs[0]["result_value"] = value
                result = self.ruby(SUPERVISOR, WORKER=str(worker), JOBS=json.dumps(jobs))
                self.assertFalse(result["success"])
                self.assertEqual([child["outcome"] for child in result["results"]], ["failed", "succeeded"])
                self.assertTrue(all(child["reaped"] for child in result["results"]))
                self.assertEqual(result["results"][0]["state"]["error_code"], "invalid_worker_result")
                self.assertIn("Worker result was not a valid status object.", result["message"])

    def test_second_spawn_failure_still_reaps_first_child(self) -> None:
        source = SUPERVISOR.replace(
            "begin\n  results",
            """spawn_count = 0
original_spawn = Process.method(:spawn)
Process.define_singleton_method(:spawn) do |*args|
  spawn_count += 1
  raise Errno::EAGAIN if spawn_count == 2
  original_spawn.call(*args)
end
begin
  results""",
        )
        worker = self.directory / "worker.rb"
        worker.write_text(FAKE_WORKER)
        result = self.ruby(source, WORKER=str(worker), JOBS=json.dumps(self.jobs()))
        self.assertFalse(result["success"])
        self.assertEqual(result["results"][0]["outcome"], "succeeded")
        self.assertTrue(result["results"][0]["reaped"])
        self.assertEqual(result["results"][1]["outcome"], "failed to start")

    def test_cancel_terminates_groups_and_reaps_both_workers(self) -> None:
        worker = self.directory / "worker.rb"
        worker.write_text(FAKE_WORKER)
        env = dict(self.env, WORKER=str(worker), JOBS=json.dumps(self.jobs(("hang", "hang"))))
        process = subprocess.Popen(
            [RUBY, "-e", SUPERVISOR], cwd=ROOT, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            deadline = time.monotonic() + 10
            while len(list(self.directory.glob("runs/*/[01].json"))) < 2:
                if time.monotonic() >= deadline or process.poll() is not None:
                    self.fail("workers did not start")
                time.sleep(0.02)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            result = json.loads(stdout.splitlines()[-1])
            self.assertFalse(result["success"])
            for child in result["results"]:
                self.assertTrue(child["reaped"])
                self.assertEqual(child["outcome"], "cancelled")
                self.assertEqual(child["signal"], signal.SIGKILL)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child["pid"], 0)
                descendant = child["state"]["descendant"]
                state = subprocess.run(
                    ["ps", "-p", str(descendant), "-o", "stat="],
                    text=True, capture_output=True, check=False,
                ).stdout.strip()
                self.assertTrue(not state or state.startswith("Z"), state)
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=10)

    def test_ipa_identity_validation_rejects_stale_platform_artifact(self) -> None:
        ipa = self.directory / "fake.ipa"
        ipa.write_bytes(b"fixture")
        source = r"""
require ENV.fetch("PIPELINE_HELPER")
analyser = Object.new
def analyser.fetch_app_identifier(_); "com.thatcube.Plozz"; end
def analyser.fetch_app_platform(_); "appletvos"; end
def analyser.fetch_app_version(_); "2026.9.17"; end
def analyser.fetch_app_build(_); "38"; end
job = PlozzTestflightPipeline.job(
  name: "tvOS", app_identifier: "com.thatcube.Plozz", platform: "appletvos",
  ipa: ENV.fetch("IPA"), version: "2026.9.17", build_number: "39",
  notes: "TV only", group: "Plozz External"
)
begin
  PlozzTestflightPipeline.validate_jobs!([job], analyser: analyser)
rescue => e
  puts JSON.generate(error: e.message)
end
"""
        result = self.ruby(source, IPA=str(ipa))
        self.assertIn('IPA build_number "38" != approved "39"', result["error"])

    def test_worker_reports_exact_stages_and_observed_external_state(self) -> None:
        worker = self.directory / "pilot-worker.rb"
        worker.write_text(MOCK_PILOT_WORKER)
        job = {
            "name": "tvOS",
            "options": {
                "app_version": "2026.9.17", "build_number": "39", "changelog": "TV only",
                "groups": ["Plozz External"],
            },
        }
        for scenario, expected in (
            ("success", "complete"), ("missing_group", "starting"),
            ("upload_failure", "uploading"), ("processing_failure", "uploaded"),
            ("wrong_build", "uploaded"), ("distribution_failure", "distributing"),
        ):
            with self.subTest(scenario=scenario):
                result = self.ruby(
                    SUPERVISOR, WORKER=str(worker), JOBS=json.dumps([job]),
                    WORKER_SCENARIO=scenario,
                )
                state = result["results"][0]["state"]
                self.assertEqual(state["phase"], expected)
                self.assertEqual(result["success"], scenario == "success")
                if scenario in ("missing_group", "wrong_build"):
                    expected_code, expected_reason = {
                        "missing_group": ("external_group_missing", "Required external TestFlight group is missing."),
                        "wrong_build": (
                            "uploaded_build_mismatch",
                            "Apple returned a different version or build; distribution was refused.",
                        ),
                    }[scenario]
                    self.assertEqual(state["error_code"], expected_code)
                    self.assertEqual(state["reason"], expected_reason)
                    self.assertIn(expected_code, result["message"])
                    self.assertIn(expected_reason, result["message"])
                elif scenario != "success":
                    self.assertNotIn("reason", state)
                    self.assertNotIn("error_code", state)
                self.assertNotIn(SECRET, json.dumps(result))
                self.assertNotIn(SECRET, Path(result["results"][0]["log"]).read_text())
                if scenario == "success":
                    self.assertEqual(state["external_state"], "WAITING_FOR_BETA_REVIEW")
                    self.assertIn("external_state=WAITING_FOR_BETA_REVIEW", self.ruby(
                        'require ENV.fetch("PIPELINE_HELPER"); puts JSON.generate(text: '
                        'PlozzTestflightPipeline.describe(JSON.parse(ENV.fetch("RESULT"))))',
                        RESULT=json.dumps(result["results"][0]),
                    )["text"])

    def real_lease_scenario(self, scenario: str) -> None:
        # The production helper explicitly supports sentinel-backed test HOME
        # roots under TMPDIR. Keep that entire namespace inside this checkout.
        temporary_root = self.directory / "temporary-storage"
        home = temporary_root / "home"
        policy = home / ".config/smart-disk-maintenance"
        home.mkdir(parents=True, mode=0o700)
        policy.mkdir(parents=True, mode=0o700)
        sentinel = policy / ".apple-build-interlock-test-root"
        sentinel.touch(mode=0o600)
        lease_root = policy / "apple-build-interlock-v1"
        worker = self.directory / "real-lease-worker.rb"
        coordinator = self.directory / "real-lease-coordinator.rb"
        worker.write_text(REAL_LEASE_WORKER)
        coordinator.write_text(REAL_LEASE_COORDINATOR)
        env = {
            key: value for key, value in self.env.items()
            if not key.startswith(("APPLE_BUILD_LEASE_", "APPLE_BUILD_INTERLOCK_"))
        }
        scenarios = ("failure", "success") if scenario == "failure" else ("success", "success")
        env.update(
            HOME=str(home), TMPDIR=str(temporary_root),
            APPLE_BUILD_INTERLOCK_TESTING="1", APPLE_BUILD_INTERLOCK_TEST_ROOT=str(lease_root),
            REPO_ROOT=str(ROOT), WORKER=str(worker), JOBS=json.dumps(self.jobs(scenarios)),
        )
        process = subprocess.Popen(
            [str(ROOT / "tools/with-apple-build-lease.sh"), "test/fastlane-release", "--", RUBY, str(coordinator)],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True,
        )
        children = []
        coordinator_pid = None

        def wait_until(condition):
            deadline = time.monotonic() + 15
            while not condition():
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail(f"lease fixture exited {process.returncode}: {stdout}\n{stderr}")
                if time.monotonic() >= deadline:
                    self.fail("timed out waiting for isolated lease fixture")
                time.sleep(0.02)

        def records():
            return [json.loads(path.read_text()) for path in (lease_root / "leases").glob("*.json")]

        def assert_locked():
            with (lease_root / "coordination.lock").open("r+") as lock:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

        def lock_available():
            with (lease_root / "coordination.lock").open("r+") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return False
                fcntl.flock(lock, fcntl.LOCK_UN)
                return True

        try:
            wait_until(lambda: (self.directory / "coordinator.json").is_file())
            initial = json.loads((self.directory / "coordinator.json").read_text())
            coordinator_pid = initial["coordinator_pid"]
            self.assertEqual((initial["proof_fd"], initial["lock_fd"]), (8, 9))
            wait_until(lambda: len(list(self.directory.glob("runs/*/[01].json"))) == 2)
            states = sorted(self.directory.glob("runs/*/[01].json"))
            children = [json.loads(path.read_text()) for path in states]
            record = records()
            self.assertEqual(len(record), 1)
            self.assertEqual(record[0]["request_pid"], process.pid)
            self.assertEqual(record[0]["state"], "active")
            self.assertEqual(record[0]["lease_id"], initial["lease_id"])
            lock_stat = (lease_root / "coordination.lock").stat()
            for child in children:
                self.assertEqual((child["proof_fd"], child["lock_fd"]), (8, 9))
                self.assertEqual(child["lease_id"], initial["lease_id"])
                self.assertEqual(child["descriptors"]["9"], {"device": lock_stat.st_dev, "inode": lock_stat.st_ino})
                self.assertEqual(child["descriptors"]["8"], children[0]["descriptors"]["8"])
            assert_locked()

            if scenario == "cancel":
                # Signal only this fixture's coordinator, never the host lease.
                os.kill(coordinator_pid, signal.SIGTERM)
            else:
                (self.directory / "finish-appletvos").touch()
                expected_phase = "failed" if scenario == "failure" else "complete"
                wait_until(lambda: json.loads(states[0].read_text())["phase"] == expected_phase)
                self.assertEqual(json.loads(states[1].read_text())["phase"], "uploading")
                self.assertEqual(records()[0]["state"], "active")
                assert_locked()
                (self.directory / "finish-ios").touch()

            wait_until(lambda: (self.directory / "before-release.json").is_file())
            report = json.loads((self.directory / "before-release.json").read_text())
            self.assertTrue(report["children_reaped"])
            self.assertTrue(all(child["reaped"] for child in report["results"]))
            self.assertEqual(report["record_before_release"]["state"], "active")
            self.assertEqual(len(records()), 1)
            assert_locked()
            expected = {
                "success": ["succeeded", "succeeded"],
                "failure": ["failed", "succeeded"],
                "cancel": ["cancelled", "cancelled"],
            }
            self.assertEqual([child["outcome"] for child in report["results"]], expected[scenario])
            for child in children:
                with self.assertRaises(ProcessLookupError):
                    os.kill(child["pid"], 0)

            (self.directory / "allow-coordinator-exit").touch()
            stdout, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0 if scenario == "success" else 1, stderr)
            self.assertEqual(json.loads(stdout.splitlines()[-1])["success"], scenario == "success")
            if scenario == "success":
                deadline = time.monotonic() + 15
                while records() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertEqual(records(), [])
            else:
                # Failed/cancelled owner retains evidence, not a clean release.
                self.assertEqual(len(records()), 1)
                self.assertEqual(records()[0]["state"], "active")
                self.assertNotIn("release_requested_at", records()[0])
            deadline = time.monotonic() + 15
            while not lock_available() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(lock_available())
        finally:
            for gate in ("finish-appletvos", "finish-ios", "allow-coordinator-exit"):
                (self.directory / gate).touch()
            if process.poll() is None:
                if coordinator_pid is not None:
                    try:
                        os.kill(coordinator_pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    # Only the new fixture session and its recorded workers.
                    for child in children:
                        try:
                            os.killpg(child["pid"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=10)

    def test_real_lease_success_preserves_descriptors_until_both_workers_reaped(self) -> None:
        self.real_lease_scenario("success")

    def test_real_lease_partial_failure_reaps_both_and_retains_evidence(self) -> None:
        self.real_lease_scenario("failure")

    def test_real_lease_cancellation_reaps_both_and_retains_evidence(self) -> None:
        self.real_lease_scenario("cancel")


if __name__ == "__main__":
    unittest.main()
