#!/usr/bin/env python3
"""Report fixture coverage for frozen yt-dlp extractor tests.

The Crystal port keeps the pinned Python extractor tests as language-neutral
JSON. This script summarizes that corpus and checks that every implemented
baseline extractor has frozen fixtures available before an extractor batch is
allowed to land.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "baseline" / "crystal"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def implemented_registry_keys() -> list[str]:
    keys: list[str] = []
    for path in [ROOT / "src" / "cr_dlp" / "client.cr"]:
        source = path.read_text(encoding="utf-8")
        keys.extend(re.findall(r'extractor_registry\.(?:register|prepend)\("([^"]+)"', source))
    return [key for key in keys if key != "Fixture"]


def count_matchers(value: Any, counts: Counter[str]) -> None:
    if isinstance(value, dict):
        if "$type" in value:
            counts[f"type:{value['$type']}"] += 1
        elif "$matcher" in value:
            counts[f"matcher:{value['$matcher']}"] += 1
        else:
            counts["exact:dict"] += 1
        for item in value.values():
            count_matchers(item, counts)
    elif isinstance(value, list):
        counts["exact:list"] += 1
        for item in value:
            count_matchers(item, counts)
    elif isinstance(value, str):
        prefixes = {
            "md5:": "hash:md5",
            "re:": "regex",
            "count:": "count",
            "mincount:": "range:mincount",
            "maxcount:": "range:maxcount",
            "contains:": "contains",
            "startswith:": "startswith",
        }
        for prefix, name in prefixes.items():
            if value.startswith(prefix):
                counts[name] += 1
                return
        counts["exact:string"] += 1
    else:
        counts[f"exact:{type(value).__name__}"] += 1


def build_report(next_batch: int) -> dict[str, Any]:
    extractors = load_json(BASELINE / "extractors.json")
    suites = load_json(BASELINE / "extractor_tests.json")
    manifest = load_json(BASELINE / "manifest.json")

    extractor_by_key = {entry["key"]: entry for entry in extractors}
    tests_by_key = {suite["key"]: suite for suite in suites}
    implemented = implemented_registry_keys()
    implemented_baseline = [key for key in implemented if key in extractor_by_key]
    implemented_external = [key for key in implemented if key not in extractor_by_key]

    matcher_counts: Counter[str] = Counter()
    for suite in suites:
        for test in suite.get("tests", []):
            count_matchers(test.get("info_dict", {}), matcher_counts)

    missing_tests = [
        key for key in implemented_baseline
        if key not in tests_by_key or not tests_by_key[key].get("tests")
    ]
    tested_baseline = {
        suite["key"] for suite in suites
        if suite.get("tests") or suite.get("webpage_tests")
    }
    untested_working = [
        entry["key"] for entry in extractors
        if entry.get("working", True) and entry["key"] not in tested_baseline
    ]

    # Preserve upstream order for batch planning. Generic remains the final
    # fallback and is intentionally excluded from early batch suggestions.
    remaining = [
        entry for entry in extractors
        if entry["key"] not in implemented_baseline and entry["key"] != "Generic"
    ]
    suggested_batch = [
        {
            "key": entry["key"],
            "name": entry["name"],
            "module": entry["module"],
            "test_count": entry["test_count"],
            "has_fixtures": entry["key"] in tests_by_key,
        }
        for entry in remaining[:next_batch]
    ]

    return {
        "baseline": {
            "source_commit": manifest["source_commit"],
            "extractor_count": len(extractors),
            "test_suites": len(suites),
            "test_cases": sum(len(suite.get("tests", [])) for suite in suites),
            "webpage_test_cases": sum(len(suite.get("webpage_tests", [])) for suite in suites),
        },
        "implemented": {
            "registry_keys": implemented,
            "baseline_keys": implemented_baseline,
            "external_keys": implemented_external,
            "missing_fixtures": missing_tests,
        },
        "fixture_matchers": dict(sorted(matcher_counts.items())),
        "baseline_without_tests_count": len(untested_working),
        "baseline_without_tests_sample": untested_working[:20],
        "suggested_next_batch": suggested_batch,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Emit JSON only")
    parser.add_argument("--output", type=Path, help="Write the JSON report to a file")
    parser.add_argument("--next-batch", type=int, default=25, help="Number of next extractor candidates to list")
    parser.add_argument(
        "--require-implemented-tested",
        action="store_true",
        help="Fail if an implemented baseline extractor lacks frozen fixtures",
    )
    args = parser.parse_args()

    report = build_report(args.next_batch)
    encoded = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")

    if args.json:
        sys.stdout.write(encoded)
    else:
        baseline = report["baseline"]
        implemented = report["implemented"]
        print(
            f"Frozen baseline: {baseline['extractor_count']} extractors, "
            f"{baseline['test_cases']} tests, {baseline['webpage_test_cases']} webpage tests"
        )
        print(
            f"Implemented baseline extractors: {len(implemented['baseline_keys'])}; "
            f"external preview extractors: {', '.join(implemented['external_keys']) or 'none'}"
        )
        print(f"Matcher families: {', '.join(report['fixture_matchers'].keys())}")
        if implemented["missing_fixtures"]:
            print("Missing fixtures for implemented extractors:")
            for key in implemented["missing_fixtures"]:
                print(f"  - {key}")
        print("Suggested next batch:")
        for entry in report["suggested_next_batch"]:
            marker = "fixtures" if entry["has_fixtures"] else "no fixtures"
            print(f"  - {entry['key']} ({entry['name']}): {entry['test_count']} tests, {marker}")

    if args.require_implemented_tested and report["implemented"]["missing_fixtures"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
