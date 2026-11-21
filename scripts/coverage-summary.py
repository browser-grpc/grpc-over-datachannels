#!/usr/bin/env python3
"""Exercised-vs-skipped summary for env-gated e2e coverage.

Reads a `make test` log (see scripts/ci-test.sh) and reports which
env-gated coverage actually ran versus silently skipped:

  oracle   grpc-java / grpc-go oracle + bridge tests
  kafka    broker-backed Kafka e2e (KAFKA_E2E_* env gates)
  eventbus broker-backed EventBus e2e
  other    every remaining SKIP line

Skip markers recognized across the language suites:
  "TestX SKIP (reason)"   C/JVM/Dart/Zig/Lua/Ruby/PHP style mains
  "skip: reason"          Rust eprintln skips
  "--- SKIP: TestX"       Go test skips
  unittest "skipped=N"    Python summary lines

Exit status: 1 when GRPC_DC_REQUIRE_ORACLE is set and any oracle
skip appears (inside the CI image that is build breakage, not a
skip); 0 otherwise. Kafka/EventBus skips are always reported but
only fail the run when GRPC_DC_REQUIRE_KAFKA is set.
"""
import os, re, sys
from collections import Counter, defaultdict

PATTERNS = [
    re.compile(r"\b\w* ?SKIP \(([^)]*)\)"),
    re.compile(r"^skip: (.+)$", re.M),
    re.compile(r"--- SKIP: (\w+)"),
]

PYTHON_SUMMARY = re.compile(r"skipped=(\d+)")


def category(reason):
    r = reason.lower()
    if "oracle" in r or "interop" in r or "bridge" in r:
        return "oracle"
    if "kafka" in r:
        return "kafka"
    if "eventbus" in r or "event bus" in r:
        return "eventbus"
    return "other"


def main():
    if len(sys.argv) != 2:
        print("usage: coverage-summary.py <make-test-log>")
        return 2
    try:
        text = open(sys.argv[1], errors="replace").read()
    except OSError as e:
        print(f"coverage-summary: cannot read log: {e}")
        return 2
    counts = Counter()
    reasons = defaultdict(Counter)
    for pat in PATTERNS:
        for m in pat.finditer(text):
            reason = m.group(1).strip()
            cat = category(reason)
            counts[cat] += 1
            reasons[cat][reason] += 1
    for m in PYTHON_SUMMARY.finditer(text):
        counts["python-unittest-skips"] += int(m.group(1))

    print("\n== env-gated coverage summary ==")
    if not counts:
        print("no env-gated skips found in log")
    for cat in ("oracle", "kafka", "eventbus", "other", "python-unittest-skips"):
        if counts.get(cat):
            print(f"{cat}: {counts[cat]} skip(s)")
            for reason, n in reasons[cat].most_common(8):
                print(f"  x{n}  {reason}")
    fail = False
    if os.environ.get("GRPC_DC_REQUIRE_ORACLE") and counts.get("oracle"):
        print("FAIL: oracle coverage skipped while GRPC_DC_REQUIRE_ORACLE is set")
        fail = True
    if os.environ.get("GRPC_DC_REQUIRE_KAFKA") and (counts.get("kafka") or counts.get("eventbus")):
        print("FAIL: kafka/eventbus coverage skipped while GRPC_DC_REQUIRE_KAFKA is set")
        fail = True
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
