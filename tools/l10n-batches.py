#!/usr/bin/env python3
"""Plan bounded translation/review batches and assemble their reviewed artifacts."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


TOOLS = Path(__file__).resolve().parent


def tool_module(name: str) -> Any:
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), TOOLS / f"{name}.py")
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SOURCE = tool_module("l10n-export-source")
ARTIFACTS = tool_module("l10n-export-artifacts")
IMPORTER = tool_module("l10n-import")
MERGER = tool_module("l10n-merge-delta")
SYNC = tool_module("l10n-sync")


def canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def current_packets(languages: list[str] | None, snapshot_path: Path) -> dict[str, dict[str, Any]]:
    catalog = ARTIFACTS.load(SOURCE.CATALOG)
    plural_problems = SYNC.plural_problems(SYNC.active_catalog_strings(catalog.get("strings", {})))
    if plural_problems:
        raise ValueError("Correct English plural structures before batching: " + "; ".join(plural_problems[:5]))
    languages = ARTIFACTS.catalog_languages(catalog) if languages is None else languages
    if not languages or len(set(languages)) != len(languages):
        raise ValueError("Choose a nonempty, duplicate-free language list")
    source_language = catalog.get("sourceLanguage", "en")
    for language in languages:
        if not IMPORTER.LANGUAGE_TAG_RE.fullmatch(language) or language == source_language:
            raise ValueError(f"Invalid target language: {language}")
    snapshot = ARTIFACTS.load(snapshot_path) if snapshot_path.exists() else {}
    loaded: dict[Path, dict[str, Any]] = {}
    info_sources = {}
    info_localizations = {}
    for artifact_key, (path, key) in SOURCE.INFO_CATALOGS.items():
        if path not in loaded:
            loaded[path] = ARTIFACTS.load(path)
        info_sources[artifact_key] = SOURCE.info_source_projection(loaded[path], key)
        info_localizations[artifact_key] = loaded[path]["strings"][key].get("localizations", {})
    return {
        language: SOURCE.export_packet(
            catalog, language, snapshot, info_sources, info_localizations
        )
        for language in sorted(languages)
    }


def plan_batches(
    packets: dict[str, dict[str, Any]], *, max_languages: int = 6,
    max_units: int = 200, max_source_bytes: int = 64_000,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if any(type(value) is not int or value < 1 for value in (max_languages, max_units, max_source_bytes)):
        raise ValueError("Batch limits must be positive")
    if not packets:
        raise ValueError("No target languages")
    hashes = {packet["catalogSHA256"] for packet in packets.values()}
    if len(hashes) != 1:
        raise ValueError("Source packets come from different catalogs")
    groups: dict[bytes, list[str]] = {}
    normalized = {}
    for language, packet in sorted(packets.items()):
        normalized[language] = {
            "sourceLanguage": packet["sourceLanguage"],
            "catalogSHA256": packet["catalogSHA256"],
            "missingFor": None,
            "entries": dict(sorted(packet["entries"].items())),
            "infoPlistEntries": dict(sorted(packet["infoPlistEntries"].items())),
        }
        if packet["entries"] or packet["infoPlistEntries"]:
            groups.setdefault(canonical(normalized[language]), []).append(language)

    files: dict[str, Any] = {}
    batches = []
    for members in groups.values():
        packet = normalized[members[0]]
        units = [
            (kind, key, value)
            for kind in ("entries", "infoPlistEntries")
            for key, value in packet[kind].items()
        ]
        sizes = [len(canonical([kind, key, value])) for kind, key, value in units]
        largest = max(sizes)
        if largest > max_source_bytes:
            raise ValueError("A source entry exceeds --max-source-bytes; increase the budget explicitly")
        width = min(max_languages, max_units, max_source_bytes // largest)
        for start in range(0, len(members), width):
            languages = members[start:start + width]
            chunks: list[list[tuple[str, str, Any]]] = [[]]
            byte_count = 0
            for unit, size in zip(units, sizes):
                if chunks[-1] and (
                    (len(chunks[-1]) + 1) * len(languages) > max_units
                    or byte_count + size * len(languages) > max_source_bytes
                ):
                    chunks.append([])
                    byte_count = 0
                chunks[-1].append(unit)
                byte_count += size * len(languages)
            for chunk in chunks:
                batch_id = f"batch-{len(batches) + 1:03d}"
                source = {**packet, "entries": {}, "infoPlistEntries": {}}
                for kind, key, value in chunk:
                    source[kind][key] = value
                batch = {
                    "id": batch_id,
                    "languages": languages,
                    "unitCount": len(chunk) * len(languages),
                    "sourcePacket": f"{batch_id}-source.json",
                    "sourceSHA256": hashlib.sha256(canonical(source)).hexdigest(),
                    "draftTemplate": f"{batch_id}-template.json",
                    "reviewTemplate": f"{batch_id}-review-template.json",
                    "draftOutput": f"{batch_id}-draft.json",
                    "reviewedOutput": f"{batch_id}-reviewed.json",
                    "reviewEvidence": f"{batch_id}-review.json",
                }
                batches.append(batch)
                files[batch["sourcePacket"]] = source
                files[batch["draftTemplate"]] = {
                    "sourceCatalogSHA256": source["catalogSHA256"],
                    "deltaKeys": list(source["entries"]),
                    "infoPlistKeys": list(source["infoPlistEntries"]),
                    "languages": {language: {} for language in languages},
                    "infoPlistLanguages": {language: {} for language in languages},
                }
                files[batch["reviewTemplate"]] = {
                    "batchID": batch_id, "sourceCatalogSHA256": source["catalogSHA256"],
                    "draftSHA256": None, "reviewedSHA256": None,
                    "languages": languages, "deltaKeys": list(source["entries"]),
                    "infoPlistKeys": list(source["infoPlistEntries"]),
                    "unitCount": batch["unitCount"], "verdict": "pending",
                    "author": {"agentID": None, "model": None, "reasoningEffort": None},
                    "reviewer": {"agentID": None, "model": None, "reasoningEffort": None},
                }
    manifest = {
        "schemaVersion": 1,
        "sourceCatalogSHA256": next(iter(hashes)),
        "languages": sorted(packets),
        "limits": {
            "maxLanguages": max_languages, "maxUnits": max_units,
            "maxSourceBytes": max_source_bytes,
        },
        "unitCount": sum(batch["unitCount"] for batch in batches),
        "batches": batches,
    }
    return manifest, files


def publish_plan(output: Path, manifest: dict[str, Any], files: dict[str, Any]) -> None:
    if output.exists():
        raise ValueError(f"{output}: output already exists; do not overwrite in-flight work")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".l10n-plan-", dir=output.parent) as temporary:
        stage = Path(temporary) / "plan"
        stage.mkdir()
        write(stage / "manifest.json", manifest)
        for name, value in files.items():
            write(stage / name, value)
        stage.rename(output)


def batch_path(root: Path, name: str) -> Path:
    path = (root / name).resolve()
    if path.parent != root.resolve() or Path(name).name != name:
        raise ValueError(f"Batch file must stay inside its plan directory: {name}")
    return path


def validate_review(root: Path, batch: dict[str, Any], source: dict[str, Any]) -> None:
    draft = batch_path(root, batch["draftOutput"])
    reviewed_path = batch_path(root, batch["reviewedOutput"])
    evidence = ARTIFACTS.load(batch_path(root, batch["reviewEvidence"]))
    if type(evidence.get("unitCount")) is not int:
        raise ValueError(f"{batch['id']}: review unitCount must be an integer")
    expected = {
        "batchID": batch["id"],
        "sourceCatalogSHA256": source["catalogSHA256"],
        "draftSHA256": digest(draft),
        "reviewedSHA256": digest(reviewed_path),
        "languages": batch["languages"],
        "deltaKeys": list(source["entries"]),
        "infoPlistKeys": list(source["infoPlistEntries"]),
        "unitCount": batch["unitCount"],
        "verdict": "approved",
    }
    for key, value in expected.items():
        if evidence.get(key) != value:
            raise ValueError(f"{batch['id']}: review {key} does not match the complete batch")
    people = [evidence.get(role) for role in ("author", "reviewer")]
    for person in people:
        if not isinstance(person, dict) or any(
            not isinstance(person.get(key), str) or not person[key].strip()
            for key in ("agentID", "model", "reasoningEffort")
        ):
            raise ValueError(f"{batch['id']}: review requires explicit author/reviewer identity, model, and effort")
        if any(person[key].strip().lower() in {"auto", "default"} for key in ("model", "reasoningEffort")):
            raise ValueError(f"{batch['id']}: record the actual model and effort, not an automatic selection")
    if people[0]["agentID"] == people[1]["agentID"]:
        raise ValueError(f"{batch['id']}: independent review requires another agent")

    reviewed = ARTIFACTS.load(reviewed_path)
    for field, expected_value in (
        ("sourceCatalogSHA256", source["catalogSHA256"]),
        ("deltaKeys", list(source["entries"])),
        ("infoPlistKeys", list(source["infoPlistEntries"])),
    ):
        if reviewed.get(field) != expected_value:
            raise ValueError(f"{batch['id']}: reviewed {field} differs from its source")
    for field, source_field in (("languages", "entries"), ("infoPlistLanguages", "infoPlistEntries")):
        values = reviewed.get(field)
        if not isinstance(values, dict) or set(values) != set(batch["languages"]):
            raise ValueError(f"{batch['id']}: reviewed {field} must include exactly its assigned languages")
        for language, translations in values.items():
            if not isinstance(translations, dict) or set(translations) != set(source[source_field]):
                raise ValueError(f"{batch['id']}: {language} has incomplete or extra {source_field}")
            for key, translation in translations.items():
                if source_field == "entries":
                    if not MERGER.generated_units_are_review_pending(translation):
                        raise ValueError(f"{batch['id']}: {language}/{key} must remain needs_review")
                    projection = source[source_field][key]
                    IMPORTER.validate_localization(
                        language, key, {"localizations": {"en": projection["englishLocalization"]}},
                        translation, False,
                    )
                elif not isinstance(translation, str) or not translation.strip():
                    raise ValueError(f"{batch['id']}: {language}/{key} is an empty permission translation")


def merge_batches(
    manifest_path: Path, artifact_dir: Path, output: Path,
    packets: dict[str, dict[str, Any]],
) -> None:
    manifest = ARTIFACTS.load(manifest_path)
    limits = manifest.get("limits", {})
    if not isinstance(limits, dict):
        raise ValueError("Batch limits must be an object")
    expected, files = plan_batches(
        packets,
        max_languages=limits.get("maxLanguages", 0),
        max_units=limits.get("maxUnits", 0),
        max_source_bytes=limits.get("maxSourceBytes", 0),
    )
    if manifest != expected:
        raise ValueError("Batch plan is stale or incomplete; regenerate from current source and snapshot")
    root = manifest_path.parent
    for batch in manifest["batches"]:
        source = ARTIFACTS.load(batch_path(root, batch["sourcePacket"]))
        if source != files[batch["sourcePacket"]]:
            raise ValueError(f"{batch['id']}: source packet was changed")
        validate_review(root, batch, source)
    if output.exists():
        raise ValueError(f"{output}: output already exists")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".l10n-merge-", dir=output.parent) as temporary:
        stage = Path(temporary) / "artifacts"
        stage.mkdir()
        for language in manifest["languages"]:
            write(stage / f"{language}.json", ARTIFACTS.load(artifact_dir / f"{language}.json"))
        for batch in manifest["batches"]:
            subprocess.run([
                sys.executable, str(TOOLS / "l10n-merge-delta.py"),
                str(batch_path(root, batch["sourcePacket"])),
                str(batch_path(root, batch["reviewedOutput"])), str(stage),
                "--languages", ",".join(batch["languages"]), "--apply",
            ], check=True)
        subprocess.run([
            sys.executable, str(TOOLS / "l10n-import.py"), str(stage),
            "--languages", ",".join(manifest["languages"]),
            "--allow-translated-state", "--require-info-plist",
        ], check=True)
        stage.rename(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    plan = commands.add_parser("plan", help="Export isolated multi-language work packets")
    plan.add_argument("output", type=Path)
    plan.add_argument("--languages", help="Comma-separated tags; defaults to every existing target language")
    plan.add_argument("--snapshot", type=Path, default=SOURCE.DEFAULT_SNAPSHOT)
    plan.add_argument("--max-languages", type=int, default=6)
    plan.add_argument("--max-units", type=int, default=200, help="Maximum locale/key pairs per author/review task")
    plan.add_argument("--max-source-bytes", type=int, default=64_000, help="Source-unit bytes multiplied by target languages")
    merge = commands.add_parser("merge", help="Validate all reviews and assemble full artifacts without editing catalogs")
    merge.add_argument("manifest", type=Path)
    merge.add_argument("artifact_dir", type=Path)
    merge.add_argument("output", type=Path)
    merge.add_argument("--snapshot", type=Path, default=SOURCE.DEFAULT_SNAPSHOT)
    args = parser.parse_args()
    try:
        if args.operation == "plan":
            languages = [tag.strip() for tag in args.languages.split(",")] if args.languages else None
            packets = current_packets(languages, args.snapshot)
            manifest, files = plan_batches(
                packets, max_languages=args.max_languages, max_units=args.max_units,
                max_source_bytes=args.max_source_bytes,
            )
            publish_plan(args.output, manifest, files)
            print(f"✓ Planned {manifest['unitCount']} units in {len(manifest['batches'])} author/reviewer batch pairs.")
        else:
            manifest = ARTIFACTS.load(args.manifest)
            packets = current_packets(manifest.get("languages"), args.snapshot)
            merge_batches(args.manifest, args.artifact_dir, args.output, packets)
            print(f"✓ Reviewed artifacts assembled at {args.output}; import them with l10n-import.py --apply.")
    except (OSError, ValueError, TypeError, KeyError, IMPORTER.ImportErrorDetail, subprocess.CalledProcessError) as error:
        print(f"✗ {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
