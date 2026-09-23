#!/usr/bin/env python3
"""Opt-in native playback checks against real Plex/Jellyfin/Emby/Silo servers.

No secrets on argv, no server provisioning, no cache deletion, no device discovery.
Test players are silent; audio samples are decoded without speaker playback.
"""
from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
SUPPORTED = ("jellyfin", "plex", "emby", "silo")
TARGET = "ProviderPlaybackIntegrationTests"


class ConfigurationError(Exception):
    pass


def private_file(path):
    path = Path(path).expanduser().resolve()
    mode = path.stat()
    if not stat.S_ISREG(mode.st_mode) or mode.st_mode & 0o077 or mode.st_uid != os.getuid():
        raise ConfigurationError("Private files must be owned by you and mode 600.")
    return path


def validate_config(path, providers):
    path = private_file(path)
    try:
        config = json.loads(path.read_text())
    except (OSError, ValueError):
        raise ConfigurationError("Cannot read private configuration JSON.") from None
    if not isinstance(config, dict):
        raise ConfigurationError("Configuration must be a JSON object.")
    for field, lower, upper in [
        ("startupTimeoutSeconds", 10, 90), ("playbackSeconds", 5, 60),
        ("seekSeconds", 5, 3600), ("resumeSeconds", 5, 3600),
    ]:
        value = config.get(field)
        if type(value) not in (int, float) or not lower <= value <= upper:
            raise ConfigurationError(f"Invalid {field}.")
    servers = config.get("servers")
    if not isinstance(servers, dict) or not set(servers).issubset(SUPPORTED):
        raise ConfigurationError("Choose jellyfin, plex, emby or silo; local shares are excluded.")
    for provider in providers:
        server = servers.get(provider)
        if not isinstance(server, dict):
            raise ConfigurationError(f"Missing required server: {provider}.")
        url = urllib.parse.urlsplit(server.get("baseURL", ""))
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ConfigurationError(f"Invalid credential-free URL for {provider}.")
        if any(not isinstance(server.get(key), str) or not server[key] for key in ("serverID", "userID", "itemID")):
            raise ConfigurationError(f"Missing server/user/fixture identity for {provider}.")
        codecs = server.get("codecs")
        allowed = ("server", "h264") if provider == "silo" else ("h264", "hevc")
        if (not isinstance(codecs, list) or not codecs or any(not isinstance(codec, str) for codec in codecs)
                or len(codecs) != len(set(codecs)) or not set(codecs).issubset(allowed)
                or (provider == "silo" and len(codecs) != 1)):
            raise ConfigurationError(f"Invalid codec matrix for {provider}.")
        if any(not isinstance(server.get(key), str) or not server[key]
               for key in ("tokenKeychainService", "tokenKeychainAccount")):
            raise ConfigurationError(f"{provider} needs a dedicated Keychain service/account reference.")
    return path, config


def keychain_token(service, account):
    result = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        capture_output=True, timeout=15,
    )
    if result.returncode or not result.stdout.strip():
        raise ConfigurationError("A configured test token is unavailable in Keychain.")
    return result.stdout.strip()


def stage_credentials(config, output, read_token=keychain_token):
    staged = json.loads(json.dumps(config))
    for provider, server in staged["servers"].items():
        token = read_token(server.pop("tokenKeychainService"), server.pop("tokenKeychainAccount"))
        if not token or len(token) > 16384:
            raise ConfigurationError("Invalid test token.")
        token_path = output / f"{provider}.token"
        with token_path.open("xb") as file:
            os.fchmod(file.fileno(), 0o600)
            file.write(token)
        server["tokenFile"] = str(token_path)
    path = output / "runtime-config.json"
    with path.open("x") as file:
        os.fchmod(file.fileno(), 0o600)
        json.dump(staged, file)
    return path, staged


def scheme_xml(config_path, lease_dir):
    env = ""
    if config_path:
        env = '<EnvironmentVariables>' + "".join(
            f'<EnvironmentVariable key="{key}" value="{escape(str(value), {chr(34): "&quot;"})}" isEnabled="YES"/>'
            for key, value in [
                ("PLOZZ_PLAYBACK_E2E_CONFIG", config_path),
                ("PLOZZ_PLAYBACK_E2E_LEASE_DIR", lease_dir),
            ]
        ) + '</EnvironmentVariables>'
    reference = (
        f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{TARGET}" '
        f'BuildableName="{TARGET}" BlueprintName="{TARGET}" ReferencedContainer="container:"/>'
    )
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.7">
 <BuildAction buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{reference}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="NO">
  <Testables><TestableReference skipped="NO">{reference}</TestableReference></Testables>{env}
 </TestAction>
</Scheme>'''


def verified(summary, expected):
    return (summary.get("result") == "Passed" and summary.get("failedTests") == 0
            and summary.get("skippedTests") == 0 and summary.get("expectedFailures") == 0
            and summary.get("passedTests") == expected and summary.get("totalTestCount") == expected)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def cleanup_owned(lease_dir, config):
    results = []
    for path in sorted(lease_dir.glob("*.json")):
        try:
            lease = json.loads(path.read_text())
            provider = lease["provider"]
            server = config["servers"][provider]
            session = lease["sessionID"]
            device = lease["deviceID"]
            if provider not in SUPPORTED or not session or not device.startswith("plozz-playback-test-"):
                raise ConfigurationError("Invalid owned encoding record.")
            if (lease.get("serverID") != server["serverID"] or lease.get("userID") != server["userID"]
                    or lease.get("baseURL", "").rstrip("/") != server["baseURL"].rstrip("/")):
                raise ConfigurationError("Encoding lease does not belong to the configured server/account.")
            token = private_file(server["tokenFile"]).read_text().strip()
            body = None
            if provider == "silo":
                credential = json.loads(token)
                if credential.get("expiresAt", 0) + 978307200 <= time.time():
                    raise ConfigurationError("Silo cleanup requires a current dedicated credential.")
                installation = lease.get("installationID")
                if not installation or not lease.get("stopID"):
                    raise ConfigurationError("Missing Silo installation/stop ownership.")
                endpoint = "/api/v2/playback/" + urllib.parse.quote(session, safe="")
                query = {}
                headers = {"Authorization": "Bearer " + credential["accessToken"],
                           "X-Profile-Id": credential["profileID"], "Content-Type": "application/json"}
                if credential.get("profileToken"):
                    headers["X-Profile-Token"] = credential["profileToken"]
                body = json.dumps({"installation_id": installation, "stop_id": lease["stopID"]}).encode()
                method = "DELETE"
            elif provider == "plex":
                endpoint = "/video/:/transcode/universal/stop"
                query = {"session": session}
                headers = {"X-Plex-Token": token, "X-Plex-Client-Identifier": device}
                method = "GET"
            else:
                endpoint = "/Videos/ActiveEncodings"
                query = {"deviceId": device, "playSessionId": session}
                headers = {"X-Emby-Token": token}
                method = "DELETE"
            url = server["baseURL"].rstrip("/") + endpoint + "?" + urllib.parse.urlencode(query)
            request = urllib.request.Request(url, headers=headers, method=method, data=body)
            with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
                if not 200 <= response.status < 300:
                    raise ConfigurationError("Encoding cleanup not acknowledged.")
                if provider == "silo" and json.loads(response.read(4096)).get("outcome") not in ("stopped", "replayed"):
                    raise ConfigurationError("Silo cleanup receipt not acknowledged.")
            path.unlink()
            results.append({"provider": provider, "status": "acknowledged"})
        except Exception as error:
            # Never serialize exception text: HTTP errors can contain authenticated URLs.
            results.append({"status": "failed", "errorType": type(error).__name__})
    return results


def recover_run(path, config):
    root = (ROOT / ".build/provider-playback-tests").resolve()
    path = path.resolve()
    if path.parent != root or not (path / "leases").is_dir():
        raise ConfigurationError("Recovery requires one exact retained playback-test run.")
    recovery = path / ("recovery-" + str(uuid.uuid4()))
    recovery.mkdir(mode=0o700)
    try:
        _, staged = stage_credentials(config, recovery)
        results = cleanup_owned(path / "leases", staged)
        (recovery / "result.json").write_text(json.dumps(results, indent=2))
        print(f"Owned encoding recovery evidence: {recovery}")
        return 1 if any(row["status"] == "failed" for row in results) else 0
    finally:
        for token in recovery.glob("*.token"):
            token.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--providers", default="jellyfin,plex,emby,silo")
    parser.add_argument("--sim-id")
    parser.add_argument("--recover-run", type=Path, help="Retry only the owned encoding leases from this exact retained run.")
    parser.add_argument("--platform", choices=("iOS", "tvOS"), default="iOS")
    parser.add_argument("--self-test", action="store_true", help="Run harness unit tests only; never a real-server pass.")
    parser.add_argument("--fixture-self-test", action="store_true", help="Play generated media against a loopback API fixture; NOT real-provider validation.")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args(argv)
    if args.self_test and args.fixture_self_test:
        parser.error("Choose one self-test mode.")
    if args.config and (args.self_test or args.fixture_self_test):
        parser.error("Self-tests must not be supplied real-server configuration.")
    if args.recover_run and (args.self_test or args.fixture_self_test):
        parser.error("Recovery cannot be combined with self-tests.")
    if not args.recover_run and not args.sim_id:
        parser.error("--sim-id must name your owned simulator.")
    os.environ.setdefault("GIT_CONFIG_PARAMETERS", "'safe.bareRepository=all'")
    if not os.environ.get("APPLE_BUILD_LEASE_PROTOCOL"):
        os.execv("/bin/bash", ["/bin/bash", str(ROOT / "tools/with-apple-build-lease.sh"),
                              "plozz/provider-playback-tests", "--", sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    spec = importlib.util.spec_from_file_location("playback_bounded", ROOT / "tools/run-bounded.py")
    bounded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bounded)
    lease_fds = bounded.inherited_lease_fds()
    if not lease_fds:
        raise ConfigurationError("Authenticated build lease is required.")
    providers = args.providers.split(",")
    if len(set(providers)) != len(providers) or not set(providers).issubset(SUPPORTED) or not providers:
        raise ConfigurationError("Choose jellyfin, plex, emby or silo. Local shares are excluded.")
    config_path, config = (None, {})
    if not args.self_test and not args.fixture_self_test:
        if args.config is None:
            raise ConfigurationError("Real-server run requires --config; absence is not a passing test.")
        config_path, config = validate_config(args.config, providers)
    if args.recover_run:
        return recover_run(args.recover_run, config)
    if not 60 <= args.timeout <= 3600:
        raise ConfigurationError("Use a bounded timeout between 60 and 3600 seconds.")

    output = ROOT / ".build/provider-playback-tests" / str(uuid.uuid4())
    output.mkdir(parents=True, mode=0o700)
    leases = output / "leases"
    leases.mkdir(mode=0o700)
    name = "_PlozzProviderPlayback_" + output.name.replace("-", "")
    scheme = ROOT / ".swiftpm/xcode/xcshareddata/xcschemes" / (name + ".xcscheme")
    project = ROOT / "Plozz.xcodeproj"
    saved_project = output / "Plozz.xcodeproj"
    summary = {}
    status = 1
    cleanup = []
    evidence = []
    fixture_server = None
    lock = (ROOT / ".build/provider-playback-tests/runner.lock").open("w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def run(label, command, seconds, check=True):
        with (output / f"{label}.log").open("w") as log:
            result = subprocess.run(
                [sys.executable, str(ROOT / "tools/run-bounded.py"), str(seconds), label, "--", *command],
                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, pass_fds=lease_fds,
            )
        if result.returncode and check:
            raise ConfigurationError(f"{label} failed; inspect retained private evidence.")
        return result.returncode

    try:
        if config and not args.fixture_self_test:
            config_path, config = stage_credentials(config, output)
        if args.fixture_self_test:
            media = output / "synthetic-media"
            (media / "hls").mkdir(parents=True)
            run("fixture-encode", [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-n",
                "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-t", "90", "-c:v", "libx264", "-preset", "ultrafast", "-threads", "2",
                "-pix_fmt", "yuv420p", "-g", "48", "-b:v", "4000k",
                "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-movflags", "+faststart", str(media / "source.mp4"),
            ], 180)
            run("fixture-hls", [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-n",
                "-i", str(media / "source.mp4"), "-c:v", "libx264",
                "-preset", "ultrafast", "-threads", "2", "-b:v", "1808k",
                "-maxrate", "1808k", "-bufsize", "3616k", "-g", "48",
                "-c:a", "aac", "-b:a", "128k", "-f", "hls", "-hls_time", "2",
                "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4", str(media / "hls/media.m3u8"),
            ], 180)
            fixture_spec = importlib.util.spec_from_file_location("playback_fixture", ROOT / "tools/provider-playback-fixture-server.py")
            fixture_module = importlib.util.module_from_spec(fixture_spec)
            fixture_spec.loader.exec_module(fixture_module)
            fixture_server = fixture_module.FixtureServer(media)
            origin = fixture_server.start()
            token_path = output / "synthetic-token"
            token_path.write_text(fixture_server.token)
            token_path.chmod(0o600)
            silo_token_path = output / "synthetic-silo-token"
            silo_token_path.write_text(json.dumps({
                "loginID": str(uuid.uuid4()), "accountID": "account", "profileID": "profile",
                "accessToken": fixture_server.token, "refreshToken": "unused-synthetic-refresh",
                "expiresAt": 4102444800 - 978307200,
            }))
            silo_token_path.chmod(0o600)
            config = {
                "startupTimeoutSeconds": 30, "playbackSeconds": 5, "seekSeconds": 30, "resumeSeconds": 12,
                "servers": {provider: {
                    "baseURL": origin, "serverID": "fixture",
                    "userID": "account:profile" if provider == "silo" else "user",
                    "tokenFile": str(silo_token_path if provider == "silo" else token_path),
                    "itemID": "movie", "mediaSourceID": "7" if provider == "plex" else "version",
                    "codecs": ["h264"],
                } for provider in providers},
            }
            config_path = output / "synthetic-config.json"
            config_path.write_text(json.dumps(config))
            config_path.chmod(0o600)
        run("architecture", [sys.executable, "tools/arch-guard.py"], 60)
        run("test-hygiene", [sys.executable, "tools/test-hygiene.py"], 60)
        run("simulator", ["xcrun", "simctl", "bootstatus", args.sim_id, "-b"], 180)
        scheme.parent.mkdir(parents=True, exist_ok=True)
        scheme.write_text(scheme_xml(config_path, leases))
        if project.exists():
            project.rename(saved_project)
        selectors = ([f"-only-testing:{TARGET}/PlaybackHarnessTests"] if args.self_test else [
            f"-only-testing:{TARGET}/ProviderPlaybackIntegrationTests/test{name.title()}Playback" for name in providers
        ])
        build_status = run("xcodebuild", [
            "xcodebuild", "test", "-scheme", name, "-destination", f"platform={args.platform} Simulator,id={args.sim_id}",
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-derivedDataPath", str(ROOT / ".build/provider-playback-derived-data"),
            "-resultBundlePath", str(output / "Test.xcresult"),
            "-clonedSourcePackagesDirPath", str(ROOT / ".build/package-workspaces/provider-playback-tests"),
            "-packageCachePath", str(Path.home() / "Library/Caches/org.swift.swiftpm"),
            "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
            "COMPILER_INDEX_STORE_ENABLE=NO", "DEBUG_INFORMATION_FORMAT=dwarf",
            "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO", *selectors,
        ], args.timeout, check=False)
        with (output / "summary.json").open("w") as summary_file:
            result = subprocess.run(
                [sys.executable, "tools/run-bounded.py", "120", "playback result summary", "--",
                 "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(output / "Test.xcresult")],
                cwd=ROOT, stdout=summary_file, pass_fds=lease_fds,
            )
        if result.returncode:
            raise ConfigurationError("No authoritative test result.")
        summary = json.loads((output / "summary.json").read_text())
        complete = build_status == 0 and verified(summary, 4 if args.self_test else len(providers))
        if complete and not args.self_test:
            attachments = output / "attachments"
            run("export-evidence", [
                "xcrun", "xcresulttool", "export", "attachments",
                "--path", str(output / "Test.xcresult"), "--output-path", str(attachments),
            ], 120)
            for test in json.loads((attachments / "manifest.json").read_text()):
                for attachment in test["attachments"]:
                    if "-playback-evidence" in attachment.get("suggestedHumanReadableName", ""):
                        evidence.append(json.loads((attachments / attachment["exportedFileName"]).read_bytes()))
            if {row.get("provider") for row in evidence} != set(providers):
                complete = False
        status = 0 if complete else 1
    finally:
        cleanup = cleanup_owned(leases, config) if config else []
        for token_path in output.glob("*.token"):
            token_path.unlink()
        if fixture_server:
            fixture_server.close()
        if any(row["status"] == "failed" for row in cleanup):
            status = 1
        if scheme.exists():
            scheme.unlink()
        if saved_project.exists():
            if project.exists():
                raise ConfigurationError(f"Project restoration conflict; both projects preserved. Evidence: {output}")
            saved_project.rename(project)
        (output / "result.json").write_text(json.dumps({
            "kind": "harness-unit-tests" if args.self_test else "synthetic-provider-contract-playback" if args.fixture_self_test else "real-provider-playback",
            "status": "passed" if status == 0 else "failed",
            "requiredProviders": [] if args.self_test else providers,
            "siloQuality": "custom 1080p / 2000 Kbps total limit through native quality preference and video bandwidth cap",
            "localShares": "out-of-scope",
            "summary": {key: summary.get(key) for key in ("result", "passedTests", "failedTests", "skippedTests")},
            "ownedEncodingCleanup": cleanup,
            "providerEvidence": evidence,
        }, indent=2))
        print(f"Retained playback test evidence: {output}")
        lock.close()
    return status


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ConfigurationError, OSError) as error:
        print(f"Provider playback tests did not pass: {error}", file=sys.stderr)
        raise SystemExit(2)
