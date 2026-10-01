#!/usr/bin/env python3
"""Bounded, readiness-gated Instruments capture of an already-running app."""
import argparse
import collections
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parent.parent


def duration(value):
    match = re.fullmatch(r"(\d+)([sm]?)", value)
    if not match:
        raise argparse.ArgumentTypeError("Use whole seconds or minutes, for example 90s or 3m.")
    seconds = int(match[1]) * (60 if match[2] == "m" else 1)
    if not 10 <= seconds <= 600:
        raise argparse.ArgumentTypeError("Recording must be between 10 and 600 seconds.")
    return seconds


def text(path):
    return path.read_text(errors="replace") if path.exists() else ""


def failed_recording(log):
    return any(marker in log.lower() for marker in [
        "disconnected", "cannot find process", "failed to start", "recording failed"
    ])


def app_process(app, processes, executable=None):
    bundle = Path(unquote(urlparse(app.get("url", "")).path))
    if not bundle.is_absolute() or bundle.suffix != ".app":
        raise RuntimeError("Installed app has no verifiable bundle URL.")
    matches = [p for p in processes
               if Path(unquote(urlparse(p.get("executable", "")).path)).parent == bundle
               and (not executable or Path(unquote(urlparse(p["executable"]).path)).name == executable)]
    if len(matches) != 1:
        raise RuntimeError("Cannot uniquely verify a live executable inside the requested installed bundle.")
    return matches[0]


def validate_unbound_runner(path):
    data = plistlib.loads(path.read_bytes())
    targets = [t for c in data.get("TestConfigurations", []) for t in c.get("TestTargets", [])]
    if not targets:
        targets = [v for k, v in data.items() if not k.startswith("__") and isinstance(v, dict)]
    if not targets or any(
        t.get("UITargetAppPath") or t.get("UITargetAppBundleIdentifier")
        or any(p.endswith(".app") and p != t.get("TestHostPath")
               for p in t.get("DependentProductPaths", []))
        for t in targets
    ):
        raise RuntimeError("Refusing an app-bound runner: current Plozz must not be replaced or relaunched.")


def sample_summary(path, pid):
    root = ET.parse(path).getroot()
    ids = {e.get("id"): e for e in root.iter() if e.get("id")}

    def resolve(element):
        return ids.get(element.get("ref"), element) if element is not None else None

    times = []
    threads = collections.Counter()
    bins = collections.Counter()
    for row in root.findall(".//row"):
        thread = resolve(row.find("thread"))
        if thread is None:
            continue
        process = resolve(thread.find("process"))
        if process is None:
            process = resolve(row.find("process"))
        if process is None:
            continue
        process_id = resolve(process.find("pid"))
        if process_id is None or process_id.text != str(pid):
            continue
        stamp = resolve(row.find("sample-time"))
        if stamp is None or not stamp.text:
            continue
        seconds = int(stamp.text) / 1e9
        times.append(seconds)
        threads[thread.get("fmt", "unknown")] += 1
        bins[int(seconds // 5) * 5] += 1
    if not times:
        raise RuntimeError(f"No CPU samples for the verified app PID {pid}; capture is not verified.")
    return {
        "count": len(times), "firstSeconds": min(times), "lastSeconds": max(times),
        "threads": dict(threads), "fiveSecondBins": dict(sorted(bins.items())),
        "symbolicated": False,
    }


@contextmanager
def device_lock(udid):
    directory = Path.home() / ".cache/plozz/device-captures"
    directory.mkdir(parents=True, exist_ok=True)
    # A single resolved hardware ID coordinates all worktrees and CoreDevice aliases.
    with (directory / (re.sub(r"[^a-zA-Z0-9-]", "_", udid) + ".lock")).open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another capture owns this device. It has not been stopped.") from error
        yield


class Capture:
    def __init__(self, args):
        self.args = args
        self.output = Path(args.output_dir).resolve() / (
            time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
        )
        self.output.mkdir(parents=True, exist_ok=False)
        self.owned = []
        self.handles = []
        self.report = {"inputSent": False, "verified": False, "requestedSeconds": args.time_limit}
        self.device = args.device
        self.observer_log = None
        self.serial = 0
        self.lock = None
        self.recorder = None
        self.lease_fds = runpy.run_path(str(ROOT / "tools/run-bounded.py"))["inherited_lease_fds"]()

    def run(self, command, name, timeout=30, env=None, check=True):
        process, log = self.launch(command, name, env)
        try:
            result = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            self.stop(process)
            raise RuntimeError(f"{name} exceeded {timeout}s; see {log}") from error
        if check and result:
            raise RuntimeError(f"{name} failed ({result}); see {log}")
        return result

    def launch(self, command, name, env=None):
        log = self.output / (name + ".log")
        handle = log.open("w")
        self.handles.append(handle)
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=handle,
                                   stderr=subprocess.STDOUT, start_new_session=True,
                                   pass_fds=self.lease_fds)
        self.owned.append(process)
        print(f"{name}: PID {process.pid}; log {log}", flush=True)
        return process, log

    def device_json(self, operation, name):
        path = self.output / (name + ".json")
        options = ["--bundle-id", self.args.bundle_id] if operation == "apps" else []
        self.run(["xcrun", "devicectl", "device", "info", operation, "--device", self.device,
                  *options, "--timeout", "20", "--json-output", str(path)], name, timeout=25)
        return json.loads(path.read_text())["result"]

    def post(self, name):
        self.serial += 1
        self.run(["xcrun", "devicectl", "device", "notification", "post", "--device", self.device,
                  "--name", name, "--timeout", "8"], f"notification-{self.serial}", timeout=12)

    def status(self, phase, acknowledge=False):
        if self.args.no_indicator:
            return
        name = self.args.bundle_id + ".Diagnostics." + phase
        offset = len(text(self.observer_log)) if self.observer_log else 0
        self.post(name)
        if acknowledge:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if f"Observed '{name}.visible'" in text(self.observer_log)[offset:]:
                    return
                time.sleep(0.1)
            raise RuntimeError("The app did not acknowledge its visible status. It must be visible and active "
                               "(not behind a screensaver/system overlay), using a current local Debug build; "
                               "--no-indicator is an explicit opt-out for older/release builds.")

    def prepare_indicator(self):
        if self.args.no_indicator:
            print("On-device indicator explicitly disabled.", flush=True)
            return
        names = [part for phase in ["preparing", "recording", "finished", "failed"]
                 for part in ["--name", self.args.bundle_id + ".Diagnostics." + phase + ".visible"]]
        observer, self.observer_log = self.launch([
            "xcrun", "devicectl", "device", "notification", "observe", "--device", self.device,
            *names, "--session-timeout", str(self.args.time_limit + 800),
            "--timeout", str(self.args.time_limit + 820),
        ], "indicator-observer")
        deadline = time.monotonic() + 15
        while "observation started" not in text(self.observer_log).lower():
            if observer.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Device status observer did not start.")
            time.sleep(0.1)
        self.status("preparing", acknowledge=True)

    def prepare_input(self):
        if not self.args.press_focused:
            return None, None, None
        env = dict(os.environ, PLOZZ_HOME_DEVICE_ID=self.device)
        self.run(["tools/generate-project.sh"], "runner-generation", timeout=120, env=env)
        self.run(["tools/run-physical-home-rows-first.sh", "--build-runner"],
                 "runner-build", timeout=900, env=env)
        paths = list((ROOT / "build/physical-home-paging-release-derived/Build/Products").glob(
            "PlozzPhysicalHomeRowsTests_*.xctestrun"))
        if len(paths) != 1:
            raise RuntimeError("Expected exactly one freshly built unbound runner.")
        validate_unbound_runner(paths[0])
        env.update(
            TEST_RUNNER_PLOZZ_CAPTURE_EXISTING_APP="1",
            TEST_RUNNER_PLOZZ_CAPTURE_FOCUSED_LABEL=self.args.press_focused,
            TEST_RUNNER_PLOZZ_CAPTURE_BUNDLE_ID=self.args.bundle_id,
            TEST_RUNNER_PLOZZ_CAPTURE_OBSERVE_SECONDS=str(min(75, self.args.time_limit - 20)),
        )
        runner, log = self.launch([
            "xcodebuild", "test-without-building", "-xctestrun", str(paths[0]),
            "-destination", f"platform=tvOS,id={self.device}", "-destination-timeout", "30",
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-resultBundlePath", str(self.output / "Remote.xcresult"),
            "-only-testing:PlozzHomeRemoteTests/PhysicalDiagnosticInputTests/testPressFocusedControlAfterRecordingConfirmation",
        ], "remote", env)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            match = re.search(r"PLZCAPTURE ready notification=(\S+)", text(log))
            if match:
                return runner, log, match[1]
            if runner.poll() is not None:
                break
            time.sleep(0.2)
        raise RuntimeError("Remote driver did not verify the requested focused control. No input sent.")

    def record(self, pid, input_runner, input_log, input_notification):
        instrument = (["--template", self.args.template] if self.args.template
                      else ["--template", "Blank", "--instrument", "Time Profiler"])
        for attempt in range(1, 4):
            self.status("preparing")
            ready = "com.thatcube.Plozz.TraceReady." + uuid.uuid4().hex
            listener, listener_log = self.launch(["notifyutil", "-1", ready], f"ready-{attempt}")
            time.sleep(0.2)
            trace = self.output / f"Recording-{attempt}.trace"
            target = ["--attach", self.args.attach or str(pid)] if self.args.template else ["--all-processes"]
            recorder, log = self.launch([
                "xcrun", "xctrace", "record", "--device", self.device, *instrument, *target,
                "--time-limit", f"{self.args.time_limit}s", "--notify-tracing-started", ready,
                "--output", str(trace), "--no-prompt",
            ], f"recorder-{attempt}")
            self.recorder = recorder
            deadline = time.monotonic() + 25
            confirmed = None
            while recorder.poll() is None and not failed_recording(text(log)):
                if listener.poll() == 0 and ready in text(listener_log):
                    confirmed = confirmed or time.monotonic()
                    if time.monotonic() - confirmed >= 5:
                        break
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.1)
            usable = (confirmed is not None and time.monotonic() - confirmed >= 5
                      and recorder.poll() is None and not failed_recording(text(log)))
            if not usable:
                print(f"Attempt {attempt} was not ready; no input sent.", flush=True)
                if recorder.poll() is None and not failed_recording(text(log)):
                    recorder.send_signal(signal.SIGINT)
                try:
                    recorder.wait(timeout=120)
                except subprocess.TimeoutExpired as error:
                    raise RuntimeError("Failed attempt did not finalize; preserving raw files, no input sent.") from error
                if listener.poll() is None:
                    listener.terminate()
                    listener.wait(timeout=5)
                continue
            self.status("recording", acknowledge=True)
            if recorder.poll() is not None or failed_recording(text(log)):
                raise RuntimeError("Recording stopped during the visible acknowledgement; no input sent.")
            print("RECORDING ACTIVE — on-device status acknowledged." if not self.args.no_indicator
                  else "RECORDING ACTIVE — indicator opted out.", flush=True)
            if input_notification:
                if input_runner.poll() is not None:
                    raise RuntimeError("Remote driver expired before recording became ready; no input sent.")
                if recorder.poll() is not None or failed_recording(text(log)):
                    raise RuntimeError("Recording stopped before input authorization; no input sent.")
                self.report.update(inputAttempted=True, inputDeliveryUncertain=True)
                self.post(input_notification)
                self.report["inputSent"] = True
                self.report["inputDeliveryUncertain"] = False
                self.report["inputConfirmationEpoch"] = time.time()
            next_heartbeat = time.monotonic() + 4
            finalizing = False
            deadline = time.monotonic() + self.args.time_limit + 600
            while recorder.poll() is None:
                contents = text(log)
                ended = failed_recording(contents) or any(
                    marker in contents for marker in ["Reached specified time limit", "Stopping recording",
                                                       "Recording completed", "Saving output"]
                )
                if ended and not finalizing:
                    finalizing = True
                    self.status("failed" if failed_recording(contents) else "finished")
                    print("Recording stopped; allowing up to ten minutes for finalization.", flush=True)
                if not finalizing and time.monotonic() >= next_heartbeat:
                    self.status("recording")
                    next_heartbeat = time.monotonic() + 4
                if time.monotonic() > deadline:
                    self.report["finalizationTimedOut"] = True
                    self.stop(recorder)
                    break
                time.sleep(0.2)
            self.status("failed" if failed_recording(text(log)) else "finished")
            if input_runner:
                if input_runner.wait(timeout=90):
                    raise RuntimeError("Remote input observation failed; see remote.log.")
                self.report["inputObserved"] = "PLZCAPTURE select.begin" in text(input_log)
                if not self.report["inputObserved"]:
                    raise RuntimeError("The runner did not send the requested Select press.")
            self.report["recorderExit"] = recorder.returncode
            self.report["disconnected"] = failed_recording(text(log))
            self.report["trace"] = str(trace)
            return trace, instrument
        raise RuntimeError("Three recordings failed readiness. No input sent.")

    def verify(self, trace, instrument, pid):
        toc = self.output / "toc.xml"

        def export_toc(source):
            return self.run(["xcrun", "xctrace", "export", "--input", str(source), "--toc",
                             "--output", str(toc)], "export-toc", timeout=120, check=False)

        if export_toc(trace):
            raw = list(trace.glob("Trace*.run/Attachments/trace-data.atrc"))
            if len(raw) != 1:
                raise RuntimeError("Unfinalized trace has no single recoverable raw stream.")
            recovered = self.output / "Recovered.trace"
            self.run(["xcrun", "xctrace", "import", "--input", str(raw[0]), *instrument,
                      "--output", str(recovered)], "recover", timeout=600)
            trace = recovered
            self.report["recoveredTrace"] = str(trace)
            if export_toc(trace):
                raise RuntimeError("Recovered trace is unreadable; original data retained.")
        root = ET.parse(toc).getroot()
        actual = float(root.findtext(".//summary/duration", "0"))
        self.report.update(actualSeconds=actual, startDate=root.findtext(".//summary/start-date"),
                           endReason=root.findtext(".//summary/end-reason"))
        if actual < self.args.time_limit - 2 or self.report.get("disconnected"):
            raise RuntimeError("Recording did not cover its requested duration; evidence is incomplete.")
        if not self.args.template or self.args.template == "Time Profiler":
            samples = self.output / "cpu-samples.xml"
            schema = "time-sample" if root.find('.//table[@schema="time-sample"]') is not None else "time-profile"
            self.run(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
                      f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
                      "--output", str(samples)], "export-samples", timeout=180)
            self.report["samples"] = sample_summary(samples, pid)
        else:
            raise RuntimeError("Trace retained, but automatic data verification only supports CPU captures.")
        self.report["verified"] = True

    def execute(self):
        print(f"Evidence directory: {self.output}", flush=True)
        details = self.device_json("details", "device")
        self.device = details["hardwareProperties"]["udid"]
        lock = device_lock(self.device)
        lock.__enter__()
        self.lock = lock
        apps = self.device_json("apps", "apps")["apps"]
        app = next((a for a in apps if a.get("bundleIdentifier") == self.args.bundle_id), None)
        if not app:
            raise RuntimeError("Requested app is not installed; it will not be installed by this tool.")
        processes = self.device_json("processes", "processes")["runningProcesses"]
        process = app_process(app, processes, self.args.attach)
        pid = process["processIdentifier"]
        self.report.update(device=self.device, pid=pid, bundleID=self.args.bundle_id,
                           build=app.get("bundleVersion"), version=app.get("version"))
        if self.args.press_focused and details["hardwareProperties"].get("deviceType") != "appleTV":
            raise RuntimeError("--press-focused is a tvOS remote driver; no input sent.")
        runner, log, notification = self.prepare_input()
        self.prepare_indicator()
        trace, instrument = self.record(pid, runner, log, notification)
        self.verify(trace, instrument, pid)

    def stop(self, process):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)

    def close(self):
        try:
            if self.recorder and self.recorder.poll() is None:
                self.recorder.send_signal(signal.SIGINT)
                try:
                    self.recorder.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    self.stop(self.recorder)
            for process in reversed(self.owned):
                if process.poll() is None:
                    self.stop(process)
            for handle in self.handles:
                handle.close()
            (self.output / "report.json").write_text(json.dumps(self.report, indent=2) + "\n")
        finally:
            if self.lock:
                self.lock.__exit__(None, None, None)
                self.lock = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-d", "--device", default=os.environ.get("PLOZZ_TRACE_DEVICE"),
                        help="Explicit device name or ID; no guessed/default TV.")
    parser.add_argument("-l", "--time-limit", type=duration, default=90)
    parser.add_argument("-t", "--template", help="Explicit Instruments template; default is CPU-only sampling.")
    parser.add_argument("-p", "--attach", help="Optional executable name within the installed bundle.")
    parser.add_argument("--bundle-id", default="com.thatcube.Plozz")
    parser.add_argument("--output-dir", default=os.environ.get("PLOZZ_TRACE_DIR", ".build/device-traces"))
    parser.add_argument("--no-indicator", action="store_true", help="Explicit opt-out for older/release builds.")
    parser.add_argument("--press-focused", metavar="EXACT_LABEL",
                        help="tvOS: verify this focused button, then send exactly one Select after readiness.")
    args = parser.parse_args()
    if not args.device:
        parser.error("--device or PLOZZ_TRACE_DEVICE is required.")
    if args.press_focused and args.time_limit < 100:
        parser.error("--press-focused requires at least 100 seconds to capture a long stall.")
    capture = Capture(args)
    try:
        capture.execute()
    except (RuntimeError, subprocess.SubprocessError, OSError, ValueError, KeyError, ET.ParseError,
            KeyboardInterrupt) as error:
        capture.report["error"] = str(error)
        print(f"Capture incomplete: {error}", file=sys.stderr)
        try:
            if capture.lock:
                capture.status("failed")
        except (RuntimeError, subprocess.SubprocessError, OSError) as status_error:
            print(f"Status could not be cleared; badge expires automatically: {status_error}", file=sys.stderr)
        return 1
    finally:
        capture.close()
    print(f"Verified capture: {capture.output / 'report.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
