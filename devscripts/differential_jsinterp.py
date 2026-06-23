#!/usr/bin/env python3
"""Differential runner comparing Python yt_dlp.jsinterp vs Crystal --__jsinterp-eval."""

from __future__ import annotations

import json
import math
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from yt_dlp.jsinterp import JSInterpreter, JS_Undefined  # noqa: E402


CRYSTAL_BIN = ROOT / "cr-dlp.exe" if sys.platform == "win32" else ROOT / "cr-dlp"


def normalize(value):
    if value is JS_Undefined:
        return {"__js_undefined": True}
    if isinstance(value, float) and math.isnan(value):
        return {"__js_nan": True}
    if value is math.inf:
        return "Infinity"
    if value is -math.inf:
        return "-Infinity"
    if isinstance(value, dict):
        return {str(k): normalize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize(v) for v in value]
    return value


def crystal_eval(code: str, func: str, args=()):
    if not CRYSTAL_BIN.exists():
        subprocess.run(["crystal", "build", "-o", str(CRYSTAL_BIN), str(ROOT / "src/cr-dlp.cr")], check=True)
    cmd = [str(CRYSTAL_BIN), "--__jsinterp-eval", code, func]
    for arg in args:
        if arg is JS_Undefined:
            cmd.append("undefined")
        elif arg is None:
            cmd.append("null")
        elif isinstance(arg, float) and math.isnan(arg):
            cmd.append("NaN")
        elif isinstance(arg, bool):
            cmd.append("true" if arg else "false")
        elif isinstance(arg, (list, dict)):
            cmd.append(json.dumps(arg))
        elif arg == "":
            cmd.append("__empty__")
        else:
            cmd.append(str(arg))
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
    return json.loads(proc.stdout.strip())


def compare(code: str, func: str = "f", args=()):
    py = normalize(JSInterpreter(code).call_function(func, *args))
    cr = crystal_eval(code, func, args)
    return py, cr, py == cr


class TestCase:
    def __init__(self, code: str, expected=None, func: str = "f", args=()):
        self.code = code
        self.expected = expected
        self.func = func
        self.args = args


def load_test_cases():
    test_path = ROOT / "test" / "test_jsinterp.py"
    source = test_path.read_text(encoding="utf-8")
    cases = []

    for match in re.finditer(r"self\._test\(\s*(['\"]{3}.*?['\"]{3}|'[^']*'|\"[^\"]*\"|jsi)[^)]*\)", source, re.S):
        call = match.group(0)
        if "Not implemented" in source[max(0, match.start() - 80):match.start()]:
            continue
        if "@unittest.skip" in source[max(0, match.start() - 120):match.start()]:
            continue
        cases.append(call)

    # Hand-picked high-value cases mirroring spec/jsinterp_spec.cr
    manual = [
        TestCase("function f(){;}", None),
        TestCase("function f(){return 42 + 7;}", 49),
        TestCase("function f(){return 42 + undefined;}", math.nan),
        TestCase("function f(a, b){return a / b;}", math.nan, args=(0, 0)),
        TestCase("function f(){return 1 << 5;}", 32),
        TestCase("function f(){return 0 && 1 || 2;}", 2),
        TestCase('function f(){return "a" + "b";}', "ab"),
        TestCase("function f(){var x = 20; x = 30 + 1; return x;}", 31),
        TestCase("function f() { a=0; for (i=0; i-10; i++) {a++} return a }", 10),
        TestCase("function f() { try{return 10} catch(e){return 5} }", 10),
        TestCase("function f() { return undefined === undefined; }", True),
        TestCase("function f() { return undefined; }", JS_Undefined),
        TestCase("function f() { let a = {m1: 42, m2: 0 }; return [a[\"m1\"], a.m2]; }", [42, 0]),
        TestCase('function f(i){return "test".charCodeAt(i)}', 116, args=(0,)),
        TestCase("function f(a, b){return a.join(b)}", "test", args=(list("test"), "")),
        TestCase("function f(a, b){return a.split(b)}", list("test"), args=("test", "")),
        TestCase("function f() { var x = 1; return ++x; }", 2),
        TestCase('function f() { return new Date("Wednesday 31 December 1969 18:01:26 MDT") - 0; }', 86000),
        TestCase(
            """
            function x() { return 2; }
            function y(a) { return x() + (a?a:0); }
            function z() { return y(3); }
            """,
            5,
            func="z",
        ),
        TestCase(
            """
            function f() {
              var g = function() { var P = 2; return P; };
              var P = 1; g(); return P;
            }
            """,
            1,
        ),
    ]
    return manual


def main() -> int:
    failures = []
    for case in load_test_cases():
        py, cr, ok = compare(case.code, case.func, case.args)
        status = "OK" if ok else "FAIL"
        print(f"[{status}] {case.func}{case.args}: py={py!r} cr={cr!r}")
        if not ok:
            failures.append((case, py, cr))

    print(f"\n{len(load_test_cases()) - len(failures)} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
