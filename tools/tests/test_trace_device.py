import argparse
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("trace_device", ROOT / "tools/trace-device.py")
trace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trace)


class TraceDeviceTests(unittest.TestCase):
    def test_pid_must_belong_to_exact_installed_bundle(self):
        app = {"url": "file:///private/apps/canonical/Plozz.app/"}
        canonical = {"executable": "file:///private/apps/canonical/Plozz.app/Plozz", "processIdentifier": 12}
        branded = {"executable": "file:///private/apps/branded/Plozz.app/Plozz", "processIdentifier": 34}
        self.assertEqual(trace.app_process(app, [branded, canonical]), canonical)
        with self.assertRaisesRegex(RuntimeError, "Cannot uniquely verify"):
            trace.app_process(app, [branded])
        with self.assertRaisesRegex(RuntimeError, "no verifiable bundle URL"):
            trace.app_process({}, [canonical])

    def test_bounded_durations(self):
        self.assertEqual(trace.duration("3m"), 180)
        self.assertEqual(trace.duration("90s"), 90)
        for value in ["0", "9", "601s", "forever", "-10s", "1.5m"]:
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                trace.duration(value)

    def test_disconnect_is_failure_even_when_xctrace_exits_zero(self):
        self.assertTrue(trace.failed_recording("Device got disconnected, ending recording...\nOutput file saved"))
        self.assertFalse(trace.failed_recording("Reached specified time limit\nOutput file saved"))

    def test_cpu_samples_resolve_references_and_exclude_other_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "samples.xml"
            path.write_text("""<root>
              <row><sample-time>1000000000</sample-time><thread id="t" fmt="Main Thread">
                <process id="p"><pid>123</pid></process></thread></row>
              <row><sample-time>2000000000</sample-time><thread ref="t"/></row>
              <row><sample-time>3000000000</sample-time><thread fmt="Other">
                <process><pid>456</pid></process></thread></row></root>""")
            result = trace.sample_summary(path, 123)
            self.assertEqual(result["count"], 2)
            self.assertEqual(result["threads"], {"Main Thread": 2})
            self.assertEqual(result["lastSeconds"], 2)
            self.assertFalse(result["symbolicated"])
            self.assertEqual(trace.sample_summary(path, 123, window=(1.5, 2.5))["count"], 1)
            with self.assertRaisesRegex(RuntimeError, "capture window"):
                trace.sample_summary(path, 123, window=(5, 10))
            with self.assertRaisesRegex(RuntimeError, "No CPU samples"):
                trace.sample_summary(path, 987)

    def test_unbound_driver_cannot_replace_current_app(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runner.xctestrun"
            for target in [
                {"UITargetAppPath": "/Plozz.app"},
                {"UITargetAppBundleIdentifier": "com.thatcube.Plozz"},
                {"DependentProductPaths": ["/build/Plozz.app"]},
                {"DependentProductPaths": ["/build/Another.app"]},
            ]:
                path.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [target]}]}))
                with self.assertRaisesRegex(RuntimeError, "app-bound"):
                    trace.validate_unbound_runner(path)
            path.write_bytes(plistlib.dumps({
                "TestConfigurations": [{"TestTargets": [{"BlueprintName": "UnboundDriver"}]}]
            }))
            trace.validate_unbound_runner(path)

    def test_finalization_timeout_preserves_trace_for_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            launch = capture.launch
            stopped = []
            def stalled(command, name, env=None):
                process, log = launch(command, name, env)
                if "recorder" in name:
                    process.poller = lambda: None
                    process.send_signal = lambda signal: None
                return process, log
            def stop(process):
                stopped.append(process)
                process.poller = lambda: 0
            capture.launch = stalled
            capture.stop = stop
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                source, _ = capture.record(123, None, None, None)
            self.assertEqual(source.name, "Recording-1.trace")
            self.assertTrue(capture.report["finalizationTimedOut"])
            self.assertGreaterEqual(capture.clock, 620)
            self.assertEqual(stopped, [capture.recorder])

    def test_failed_recordings_never_trigger_remote_input(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=3)
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                with self.assertRaisesRegex(RuntimeError, "Three recordings failed readiness"):
                    capture.record(123, FakeProcess(), Path(directory) / "remote.log", "select-once")
            self.assertEqual(capture.posts, [])
            self.assertNotIn("recording", [phase for _, phase in capture.statuses])

    def test_ready_cue_and_single_press_require_sustained_recording(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=1)
            log = Path(directory) / "remote.log"
            log.write_text("PLZCAPTURE select.begin")
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                capture.record(123, FakeProcess(), log, "select-once")
            self.assertEqual(len(capture.posts), 1)
            self.assertEqual(capture.posts[0][1], "select-once")
            ready_time = next(t for t, phase in capture.statuses if phase == "recording")
            self.assertGreaterEqual(ready_time - capture.record_start, 5)
            self.assertGreaterEqual(capture.posts[0][0], ready_time)
            self.assertTrue(capture.report["inputObserved"])

    def test_missing_visible_ack_does_not_authorize_input(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            def reject(phase, acknowledge=False):
                if phase == "recording" and acknowledge:
                    raise RuntimeError("No visible badge")
            capture.status = reject
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                with self.assertRaisesRegex(RuntimeError, "No visible badge"):
                    capture.record(123, FakeProcess(), Path(directory) / "remote.log", "select-once")
            self.assertEqual(capture.posts, [])

    def test_manual_start_and_visible_ack_do_not_consume_requested_window(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            capture.args.auto_start = False
            capture.start_delay = 17
            capture.ack_delay = 2
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                capture.record(123, None, None, None)
            self.assertTrue(capture.report["captureWindowCompleted"])
            self.assertGreaterEqual(capture.report["captureWindowSeconds"], 20)
            self.assertGreaterEqual(capture.report["captureWindowStartAfterReadySeconds"], 24)
            phases = [phase for _, phase in capture.statuses]
            self.assertIn("ready", phases)
            self.assertIn("saving", phases)
            self.assertNotIn("finished", phases, "Only successful data verification may announce completion.")
            self.assertFalse((capture.output / "ready.json").exists())

    def test_manual_start_timeout_never_enters_recording(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            capture.args.auto_start = False
            capture.args.start_timeout = 10
            capture.start_delay = 100
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                with self.assertRaisesRegex(RuntimeError, "Start confirmation timed out"):
                    capture.record(123, None, None, None)
            self.assertNotIn("recording", [phase for _, phase in capture.statuses])
            self.assertEqual(capture.posts, [])
            self.assertFalse((capture.output / "ready.json").exists())

    def test_early_recorder_exit_is_not_a_complete_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            capture.recording_duration = 10
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                capture.record(123, None, None, None)
            self.assertFalse(capture.report["captureWindowCompleted"])
            self.assertLess(capture.report["captureWindowSeconds"], 20)
            self.assertEqual(capture.statuses[-1][1], "failed")

    def test_unrelated_start_notification_cannot_begin_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            capture.args.auto_start = False
            launch = capture.launch
            def unrelated(command, name, env=None):
                process, log = launch(command, name, env)
                if name.startswith("start-"):
                    log.write_text("a-different-recording")
                return process, log
            capture.launch = unrelated
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                with self.assertRaisesRegex(RuntimeError, "Start listener failed"):
                    capture.record(123, None, None, None)
            self.assertNotIn("recording", [phase for _, phase in capture.statuses])

    def test_setup_samples_cannot_verify_an_empty_requested_window(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            capture.report.update(captureWindowStartedEpoch=4, captureWindowEndedEpoch=24)
            def run(command, name, **kwargs):
                if name == "export-toc":
                    (capture.output / "toc.xml").write_text(
                        '<trace-toc><run><summary><duration>30</duration>'
                        '<start-date>1970-01-01T00:00:00Z</start-date></summary>'
                        '<data><table schema="time-sample"/></data></run></trace-toc>')
                elif name == "export-samples":
                    (capture.output / "cpu-samples.xml").write_text(
                        '<root><row><sample-time>1000000000</sample-time>'
                        '<thread><process><pid>123</pid></process></thread></row></root>')
                return 0
            capture.run = run
            with self.assertRaisesRegex(RuntimeError, "No CPU samples"):
                capture.verify(capture.output / "Recording.trace", [], 123)

    def test_recording_window_must_be_complete_even_if_export_contains_long_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            capture.report["captureWindowCompleted"] = False
            def run(command, name, **kwargs):
                (capture.output / "toc.xml").write_text(
                    '<trace-toc><run><summary><duration>200</duration></summary></run></trace-toc>')
                return 0
            capture.run = run
            with self.assertRaisesRegex(RuntimeError, "requested duration"):
                capture.verify(capture.output / "Recording.trace", [], 123)

    def test_disconnect_during_visible_ack_does_not_authorize_input(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            def disconnect(phase, acknowledge=False):
                if phase == "recording" and acknowledge:
                    (capture.output / "recorder-1.log").write_text("Device got disconnected")
            capture.status = disconnect
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                with self.assertRaisesRegex(RuntimeError, "stopped during the visible acknowledgement"):
                    capture.record(123, FakeProcess(), Path(directory) / "remote.log", "select-once")
            self.assertEqual(capture.posts, [])
            self.assertEqual(capture.attempt, 1)

    def test_input_is_never_retried_after_disconnect(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            log = Path(directory) / "remote.log"
            log.write_text("PLZCAPTURE select.begin")
            def press(name):
                capture.posts.append(name)
                (capture.output / "recorder-1.log").write_text("Device got disconnected")
            capture.post = press
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                capture.record(123, FakeProcess(), log, "select-once")
            self.assertTrue(capture.report["disconnected"])
            self.assertEqual(capture.posts, ["select-once"])
            self.assertEqual(capture.attempt, 1)

    def test_failed_notification_delivery_is_reported_as_uncertain_not_safe_to_repeat(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            def ambiguous_delivery(name):
                raise RuntimeError("Device notification timed out")
            capture.post = ambiguous_delivery
            with patch.object(trace.time, "monotonic", capture.now), patch.object(trace.time, "sleep", capture.sleep):
                with self.assertRaisesRegex(RuntimeError, "notification timed out"):
                    capture.record(123, FakeProcess(), Path(directory) / "remote.log", "select-once")
            self.assertTrue(capture.report["inputAttempted"])
            self.assertTrue(capture.report["inputDeliveryUncertain"])
            self.assertEqual(capture.attempt, 1)

    def test_unfinalized_raw_stream_recovers_without_discarding_idle_app_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            source = capture.output / "Recording.trace"
            raw = source / "Trace1.run/Attachments/trace-data.atrc"
            raw.parent.mkdir(parents=True)
            raw.write_bytes(b"retained raw fixture")
            commands = []
            def run(command, name, **kwargs):
                commands.append(command)
                if name == "export-toc":
                    if str(source) in command:
                        return 1
                    (capture.output / "toc.xml").write_text(
                        '<trace-toc><run><summary><duration>20</duration>'
                        '<start-date>1970-01-01T00:00:00Z</start-date></summary>'
                        '<data><table schema="time-sample"/></data></run></trace-toc>')
                elif name == "export-samples":
                    (capture.output / "cpu-samples.xml").write_text(
                        '<root><row><sample-time>1000000000</sample-time>'
                        '<thread fmt="Main Thread"><process><pid>123</pid></process></thread></row></root>')
                return 0
            capture.run = run
            capture.verify(source, ["--template", "Blank", "--instrument", "Time Profiler"], 123)
            self.assertTrue(capture.report["verified"])
            self.assertEqual(capture.report["samples"]["lastSeconds"], 1)
            self.assertTrue(raw.exists())
            self.assertEqual(sum("import" in command for command in commands), 1)

    def test_cleanup_keeps_device_lock_until_owned_children_and_report_are_finished(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = FakeCapture(Path(directory), failures=0)
            events = []
            class Lock:
                def __exit__(self, *args):
                    self_test.assertTrue((capture.output / "report.json").exists())
                    events.append("unlock")
            self_test = self
            capture.lock = Lock()
            capture.recorder = None
            capture.owned = [FakeProcess()]
            capture.handles = []
            capture.stop = lambda process: events.append("stop-owned")
            capture.close()
            self.assertEqual(events, ["stop-owned", "unlock"])


class FakeProcess:
    def __init__(self, poll=None):
        self.poller = poll or (lambda: None)
        self.returncode = 0

    def poll(self):
        return self.poller()

    def wait(self, timeout=None):
        return 0

    def terminate(self):
        self.poller = lambda: 0

    def send_signal(self, signal):
        self.poller = lambda: 0


class FakeCapture(trace.Capture):
    def __init__(self, output, failures):
        self.output = output
        self.args = argparse.Namespace(template=None, attach=None, time_limit=20, no_indicator=False,
                                       auto_start=True, start_timeout=60)
        self.device = "fixture"
        self.report = {"captureWindowCompleted": True, "captureWindowStartedEpoch": 0,
                       "captureWindowEndedEpoch": 20}
        self.clock = 0
        self.failures = failures
        self.attempt = 0
        self.posts = []
        self.statuses = []
        self.record_start = 0

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.clock += seconds

    def status(self, phase, acknowledge=False):
        self.statuses.append((self.clock, phase))
        if phase == "recording" and acknowledge:
            self.clock += getattr(self, "ack_delay", 0)

    def post(self, name):
        self.posts.append((self.clock, name))

    def launch(self, command, name, env=None):
        log = self.output / (name + ".log")
        if command[0] == "notifyutil":
            log.write_text(command[-1])
            if name.startswith("start-"):
                start = self.clock
                return FakeProcess(lambda: 0 if self.clock - start >= getattr(self, "start_delay", 0) else None), log
            return FakeProcess(lambda: 0), log
        self.attempt += 1
        self.record_start = self.clock
        if self.attempt <= self.failures:
            log.write_text("Device got disconnected, ending recording...")
            return FakeProcess(lambda: 0), log
        log.write_text("Ctrl-C to stop the recording")
        start = self.clock
        limit = int(command[command.index("--time-limit") + 1].removesuffix("s"))
        return FakeProcess(lambda: 0 if self.clock - start >= getattr(self, "recording_duration", limit) else None), log


if __name__ == "__main__":
    unittest.main()
