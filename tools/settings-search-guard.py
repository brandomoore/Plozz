#!/usr/bin/env python3
"""Check independently discovered Settings controls against reviewed coverage."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from fnmatch import fnmatchcase
import json
from pathlib import Path
import re
import sys


def control_key(component: dict, control: dict) -> str:
    label = re.sub(r"\s+", " ", control["label"]).strip()
    return "|".join((component["file"], component["name"], control["context"], control["kind"], label))


def discover(inventory: list[dict], policy: dict) -> list[dict]:
    """Follow component calls, stopping only at reviewed presentation boundaries."""
    by_name: dict[str, list[dict]] = defaultdict(list)
    for component in inventory:
        by_name[component["name"]].append(component)
    boundaries = policy.get("boundaries", {})
    selected = {}
    queue = [
        component for component in inventory
        if component["name"] in policy["roots"]
        or any(component["file"].startswith(prefix) for prefix in policy["directories"])
        or re.search(r"(Settings|Preferences)[^/]*\.swift$", component["file"])
    ]
    while queue:
        component = queue.pop()
        key = (component["file"], component["name"])
        if key in selected or component["name"] in boundaries:
            continue
        selected[key] = component
        for name in component["calls"]:
            candidates = by_name.get(name, [])
            local = [candidate for candidate in candidates if candidate["file"] == component["file"]]
            for candidate in local or candidates:
                if (candidate["file"].startswith(tuple(policy["traversable_directories"]))
                    or candidate["file"] in policy.get("files", [])
                    or re.search(r"(Settings|Preferences)[^/]*\.swift$", candidate["file"])):
                    queue.append(candidate)
    return sorted(selected.values(), key=lambda component: (component["file"], component["name"]))


def check(inventory: list[dict], policy: dict) -> list[str]:
    errors = []
    catalog = {
        pattern for component in inventory for registration in component.get("registrations", [])
        if (pattern := string_pattern(registration["anchor"])) is not None
    }
    names = {component["name"] for component in inventory}
    for root in policy["roots"]:
        if root not in names:
            errors.append(f"Settings root no longer exists: {root}")
    excluded = policy.get("exclusions", {})
    used: Counter[str] = Counter()
    for component in discover(inventory, policy):
        for control in component["controls"]:
            resolved = {
                pattern
                for expression in control["anchors"]
                for value in [expression, *component.get("anchorResolutions", {}).get(expression, [])]
                if (pattern := string_pattern(value)) is not None
            }
            if any(patterns_overlap(source, target) for source in resolved for target in catalog):
                continue
            key = control_key(component, control)
            exemption = excluded.get(key)
            if exemption is None:
                errors.append(
                    f"{component['file']}:{control['line']}: unregistered "
                    f"{component['name']}.{control['context']} {control['kind']} {control['label']}"
                    + (f" (uncatalogued anchors: {control['anchors']})" if control["anchors"] else "")
                )
            elif not exemption.get("reason", "").strip():
                errors.append(f"Coverage exclusion needs a reason: {key}")
            else:
                used[key] += 1
                for target in exemption.get("covered_by", []):
                    if not any(fnmatchcase(target, pattern) for pattern in catalog):
                        errors.append(f"Coverage exclusion points to a missing setting: {key} -> {target}")
    for key, exemption in excluded.items():
        if used[key] != exemption["count"]:
            errors.append(
                f"Stale or widened coverage exclusion ({used[key]} found, "
                f"{exemption['count']} reviewed): {key}"
            )
    for name, boundary in policy.get("boundaries", {}).items():
        components = [component for component in inventory if component["name"] == name]
        if not boundary.get("reason", "").strip() or not components:
            errors.append(f"Stale or undocumented component boundary: {name}")
        actual = Counter(
            control_key(component, control)
            for component in components for control in component["controls"]
        )
        if actual != Counter(boundary["controls"]):
            errors.append(f"Component boundary changed: {name}; review its controls and call sites")
    anchors = {
        pattern for component in inventory for expression in component.get("anchors", [])
        if (pattern := string_pattern(expression)) is not None
    }
    for component in inventory:
        for registration in component.get("registrations", []):
            pattern = string_pattern(registration["anchor"])
            if pattern is None:
                if registration["anchor"] not in policy.get("derived_anchors", {}):
                    errors.append(f"Unresolved catalog anchor: {registration}")
            elif not any(
                patterns_overlap(pattern, anchor) for anchor in anchors
            ):
                errors.append(f"Catalog destination has no source anchor: {registration['id']}")
    return errors


def string_pattern(expression: str) -> str | None:
    if not expression.startswith('"') or not expression.endswith('"'):
        return None
    return re.sub(r"\\\([^)]*\)", "*", expression[1:-1])


def patterns_overlap(left: str, right: str) -> bool:
    # A bare computed/interpolated ID is not evidence that every destination exists.
    if not left or not right or left.startswith("*") or right.startswith("*"):
        return False
    return fnmatchcase(left, right) or fnmatchcase(right, left)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--policy", required=True, type=Path)
    args = parser.parse_args()
    try:
        inventory = json.loads(args.inventory.read_text())
        policy = json.loads(args.policy.read_text())
        errors = check(inventory, policy)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Settings search coverage could not be checked: {error}", file=sys.stderr)
        return 1
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Settings search coverage: {len(discover(inventory, policy))} source components checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
