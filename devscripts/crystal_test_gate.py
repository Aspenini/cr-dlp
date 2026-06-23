#!/usr/bin/env python3
"""Run the Crystal port's deterministic verification gate."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def host_platform() -> str:
    system = platform.system().lower()
    if system.startswith("win"):
        return "windows"
    if system == "darwin":
        return "macos"
    return "linux"


def host_arch() -> str:
    machine = platform.machine().lower()
    if machine in {"amd64", "x64", "x86_64"}:
        return "x86_64"
    if machine in {"arm64", "aarch64"}:
        return "aarch64"
    return machine or "unknown"


class Gate:
    def __init__(self, keep_going: bool):
        self.keep_going = keep_going
        self.results: list[dict[str, object]] = []

    def run(self, name: str, command: list[str], *, timeout: int | None = None) -> bool:
        print(f"==> {name}")
        started = time.monotonic()
        proc = subprocess.run(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        elapsed = time.monotonic() - started
        if proc.stdout:
            print(proc.stdout, end="" if proc.stdout.endswith("\n") else "\n")
        if proc.stderr:
            print(proc.stderr, end="" if proc.stderr.endswith("\n") else "\n", file=sys.stderr)
        result = {
            "name": name,
            "command": command,
            "exit_code": proc.returncode,
            "duration_seconds": round(elapsed, 3),
        }
        self.results.append(result)
        if proc.returncode != 0 and not self.keep_going:
            raise SystemExit(proc.returncode)
        return proc.returncode == 0

    def report(self, path: Path) -> int:
        status = 0 if all(item["exit_code"] == 0 for item in self.results) else 1
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "status": "passed" if status == 0 else "failed",
            "results": self.results,
        }, indent=2) + "\n", encoding="utf-8")
        print(f"wrote gate report: {path}")
        return status


def binary_path() -> Path:
    return ROOT / "bin" / ("cr-dlp.exe" if os.name == "nt" else "cr-dlp")


def package_smoke(gate: Gate) -> bool:
    with tempfile.TemporaryDirectory(prefix="cr-dlp-gate-package-") as temp:
        signature = Path(temp) / "manifest.sig"
        signature.write_text("placeholder-signature", encoding="utf-8")
        return gate.run("package smoke", [
            sys.executable,
            "devscripts/package_crystal_release.py",
            "--binary", str(binary_path()),
            "--out-dir", str(Path(temp) / "dist"),
            "--version", "0.1.0-dev",
            "--platform", host_platform(),
            "--arch", host_arch(),
            "--manifest-signature", str(signature),
        ])


def static_smoke(gate: Gate) -> bool:
    static = ROOT / "bin" / ("cr-dlp-static.exe" if os.name == "nt" else "cr-dlp-static")
    with tempfile.TemporaryDirectory(prefix="cr-dlp-gate-static-") as temp:
        output = Path(temp) / "%(id)s.%(ext)s"
        command = [
            str(static),
            "--no-config-locations",
            "--fixup", "never",
            "-o", str(output),
            "cr-dlp:fixture:static-gate",
        ]
        ok = gate.run("static binary fixture smoke", command)
        if ok:
            expected = Path(temp) / "static-gate.txt"
            if expected.read_text(encoding="utf-8").strip() != "fixture:static-gate":
                gate.results.append({
                    "name": "static binary fixture smoke output",
                    "command": ["read", str(expected)],
                    "exit_code": 1,
                    "duration_seconds": 0,
                })
                return False
        return ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quick", action="store_true", help="Skip release, static, and differential gates")
    parser.add_argument("--release", action="store_true", help="Run release build and package smoke")
    parser.add_argument("--static", action="store_true", help="Run static build and static fixture smoke")
    parser.add_argument("--differential", action="store_true", help="Run Python differential suites")
    parser.add_argument("--keep-going", action="store_true", help="Run all gates even after a failure")
    parser.add_argument("--report", type=Path, default=Path("artifacts/crystal-test-gate.json"))
    args = parser.parse_args()

    full_default = not args.quick and not (args.release or args.static or args.differential)
    run_release = args.release or full_default
    run_static = args.static or full_default
    run_differential = args.differential or full_default

    gate = Gate(args.keep_going)
    try:
        gate.run("python helper syntax", [
            sys.executable, "-m", "py_compile",
            "devscripts/differential_crystal.py",
            "devscripts/differential_jsinterp.py",
            "devscripts/package_crystal_release.py",
            "devscripts/extractor_fixture_report.py",
        ])
        gate.run("format check", ["crystal", "tool", "format", "--check", "src", "spec"])
        gate.run("extractor fixture report", [
            sys.executable,
            "devscripts/extractor_fixture_report.py",
            "--require-implemented-tested",
            "--output", "artifacts/extractor-fixture-report.json",
        ])
        gate.run("crystal specs", ["crystal", "spec", "--error-trace"], timeout=300)
        gate.run("no-codegen build", ["crystal", "build", "src/cr-dlp.cr", "--no-codegen", "--error-trace"], timeout=180)

        if run_release:
            gate.run("release build", ["shards", "build", "--release", "--error-trace"], timeout=300)
            package_smoke(gate)
        elif not binary_path().exists():
            gate.run("debug build for auxiliary gates", ["shards", "build", "--error-trace"], timeout=300)

        if run_static:
            static = ROOT / "bin" / ("cr-dlp-static.exe" if os.name == "nt" else "cr-dlp-static")
            gate.run("static build", [
                "crystal", "build", "src/cr-dlp.cr",
                "-o", str(static),
                "--release", "--static", "--error-trace",
            ], timeout=300)
            static_smoke(gate)

        if run_differential:
            gate.run("metadata/download differential", [sys.executable, "devscripts/differential_crystal.py"], timeout=300)
            gate.run("jsinterp differential", [sys.executable, "devscripts/differential_jsinterp.py"], timeout=300)
    except SystemExit as error:
        gate.report(args.report)
        return int(error.code)

    if shutil.which("git"):
        gate.run("diff whitespace check", ["git", "diff", "--check"])
    return gate.report(args.report)


if __name__ == "__main__":
    raise SystemExit(main())
