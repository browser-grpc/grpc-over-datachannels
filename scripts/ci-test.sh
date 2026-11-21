#!/bin/bash
# CI test entry: run `make test`, tee the log, then print the
# env-gated exercised-vs-skipped summary (scripts/coverage-
# summary.py). The exit status is make's, upgraded to failure
# when required coverage (GRPC_DC_REQUIRE_ORACLE /
# GRPC_DC_REQUIRE_KAFKA) was skipped. Dockerfile.ci's CMD points
# here so every image run ends with the summary.
set -u
LOG="${GRPC_DC_TEST_LOG:-/tmp/grpc-dc-test.log}"
make test 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
python3 scripts/coverage-summary.py "$LOG" || status=1
exit $status
