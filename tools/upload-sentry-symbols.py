#!/usr/bin/env python3
"""Upload only UUID-verified archive dSYMs, never application source files."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
KEYS = ("SENTRY_AUTH_TOKEN", "SENTRY_ORG", "SENTRY_PROJECT", "SENTRY_URL")


def configuration(environ=None, root=ROOT):
    env = dict(os.environ if environ is None else environ)
    home = Path(env.get("HOME", str(Path.home())))
    candidates = [
        env.get("PLOZZ_ENV_FILE"),
        root / ".env.fastlane",
        Path(env.get("XDG_CONFIG_HOME", home / ".config")) / "plozz/env",
    ]
    for candidate in candidates:
        if not candidate or not Path(candidate).is_file():
            continue
        for line in reversed(Path(candidate).read_text().splitlines()):
            match = re.fullmatch(r"\s*(?:export\s+)?(SENTRY_[A-Z_]+)=(.*)", line)
            if not match or match[1] not in KEYS or env.get(match[1], "").strip():
                continue
            value = match[2].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            env[match[1]] = value
    missing = [key for key in KEYS[:3] if not env.get(key, "").strip()]
    if missing:
        raise ValueError("Configure " + ", ".join(missing) +
                         " in the private Plozz env file before distributing a build.")
    cli = shutil.which("sentry-cli", path=env.get("PATH"))
    if not cli:
        raise ValueError("Install sentry-cli before distributing a build (brew install getsentry/tools/sentry-cli).")
    symbol_api_url(env)
    return cli, env


def debug_ids(path):
    result = subprocess.run(
        ["xcrun", "dwarfdump", "--uuid", str(path)],
        capture_output=True, text=True, check=True,
    )
    ids = set(re.findall(r"^UUID: ([0-9A-Fa-f-]{36}) ", result.stdout, re.MULTILINE))
    if not ids:
        raise ValueError(f"No debug UUIDs in {path.name}.")
    return {value.lower() for value in ids}


def archive_symbols(archive):
    archive = Path(archive).resolve(strict=True)
    with (archive / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    app = (archive / "Products" / info["ApplicationProperties"]["ApplicationPath"]).resolve(strict=True)
    if not app.is_relative_to(archive / "Products") or app.suffix != ".app":
        raise ValueError("Archive application path is invalid.")
    symbols = sorted((archive / "dSYMs").glob("*.dSYM/Contents/Resources/DWARF/*"))
    if not symbols or any(not path.resolve().is_relative_to(archive) for path in symbols):
        raise ValueError("Archive has no usable local dSYMs.")
    available = set()
    for path in symbols:
        available.update(debug_ids(path))
    # Own app/extensions must have matching symbols before either platform ships.
    required = set()
    for bundle in [app, *sorted(app.glob("PlugIns/*.appex"))]:
        with (bundle / "Info.plist").open("rb") as stream:
            executable = plistlib.load(stream)["CFBundleExecutable"]
        binary = (bundle / executable).resolve(strict=True)
        if not binary.is_relative_to(bundle):
            raise ValueError("Archive executable path is invalid.")
        required.update(debug_ids(binary))
    if not required.issubset(available):
        raise ValueError("Archive dSYMs do not match every app/extension UUID: " +
                         ", ".join(sorted(required - available)))
    return symbols, available


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def symbol_api_url(env):
    base = env.get("SENTRY_URL", "https://sentry.io").rstrip("/")
    parts = urllib.parse.urlsplit(base)
    if (parts.scheme != "https" or not parts.hostname or parts.username is not None
            or parts.password is not None or parts.query or parts.fragment):
        raise ValueError("SENTRY_URL must be an HTTPS server URL without credentials, query or fragment.")
    org, project = (urllib.parse.quote(env[key], safe="") for key in ("SENTRY_ORG", "SENTRY_PROJECT"))
    return f"{base}/api/0/projects/{org}/{project}/files/dsyms/"


def verify_processed_symbols(ids, env):
    base = symbol_api_url(env)
    opener = urllib.request.build_opener(NoRedirect())
    for debug_id in sorted(ids):
        request = urllib.request.Request(
            base + "?" + urllib.parse.urlencode({"debug_id": debug_id}),
            headers={"Authorization": "Bearer " + env["SENTRY_AUTH_TOKEN"]},
        )
        try:
            with opener.open(request, timeout=30) as response:
                rows = json.load(response)
        except (OSError, ValueError):
            raise ValueError("Could not verify processed Sentry symbols; distribution must not proceed.") from None
        if not isinstance(rows, list):
            raise ValueError("Invalid Sentry symbol response; distribution must not proceed.")
        if not any(
            isinstance(row, dict) and str(row.get("debugId", "")).lower() == debug_id
            and row.get("symbolType") == "macho" and isinstance(row.get("data"), dict)
            and isinstance(row["data"].get("features"), list) and "debug" in row["data"]["features"]
            for row in rows
        ):
            raise ValueError(f"Sentry lacks processed debug information for {debug_id}; distribution must not proceed.")


def upload(archive, cli, env):
    symbols, ids = archive_symbols(archive)
    command = [
        cli, "debug-files", "upload", "--org", env["SENTRY_ORG"],
        "--project", env["SENTRY_PROJECT"], "--wait",
        "--type", "dsym", "--no-sources", "--no-zips",
    ]
    for debug_id in sorted(ids):
        command.extend(["--id", debug_id])
    command.extend(map(str, symbols))
    env = {**env, "SENTRY_LOG_LEVEL": "info"}
    env.pop("SENTRY_ALLOW_FAILURE", None)
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = (result.stdout or "").replace(env["SENTRY_AUTH_TOKEN"], "<redacted>")
    if output:
        print(output, end="" if output.endswith("\n") else "\n")
    if result.returncode:
        raise ValueError("Sentry symbol upload/processing failed; distribution must not proceed.")
    # CLI --require-all rejects some already-processed files; verify the server's exact UUIDs instead.
    verify_processed_symbols(ids, env)
    print(f"Sentry processed {len(ids)} archive debug UUIDs.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check private configuration and CLI availability only.")
    parser.add_argument("archive", nargs="?", type=Path)
    args = parser.parse_args()
    if not args.check and args.archive is None:
        parser.error("provide an .xcarchive or --check")
    try:
        cli, env = configuration()
        if args.check:
            print("Sentry symbol-upload prerequisites are configured.")
        else:
            upload(args.archive, cli, env)
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        # Never dump subprocess output/environment or plist contents on failure.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(f"Sentry symbols: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
