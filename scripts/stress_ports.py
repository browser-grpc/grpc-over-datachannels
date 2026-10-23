#!/usr/bin/env python3
"""Parallel UDP port-collision stress for the WebRTC suites.

v0.25.1 converted socket-owning tests/harnesses to bind port 0 and
propagate the allocated port, and wrapped external daemons
(openssl s_server, coturn) with startup-liveness retry. Sequential
repeats passed; this runner proves the same suites under contention:
N copies of each collision-prone suite run at the same time, and any
EADDRINUSE / "address already in use" in any output fails the run.

Suites: Rust mux/CID/TURN/OpenSSL/direct tests, Go mux/TURN/direct/
DTLS tests (-race), JS mux/TURN-mux/DTLS/DC/coturn tests, and the
cross-stack webrtc matrix. Set STRESS_N to change copies (default 3).
Copies of one suite run concurrently (the same-fixed-port contention
shape); suites run in phases so total load stays bounded. Logs land
in /tmp/stress_ports/<suite>-<copy>.log.
Exit 0 only if every copy exits 0 with no address-in-use error.
Note: Rust copies run with --test-threads=2 so cross-copy port
contention, not CPU oversubscription, dominates. At high STRESS_N
any remaining non-collision failure is load flake; the collision
count is the signal to read first.
"""
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG_DIR = "/tmp/stress_ports"
COLLISION = re.compile(r"EADDRINUSE|address already in use", re.IGNORECASE)
TIMEOUT_S = 1800

RUST_TESTS = ["mux", "cid_test", "turn", "turn_tcp",
              "dtls_openssl", "webrtc_direct"]

SUITES = [
    ("rust", ["cargo", "test", "--quiet"]
     + sum((["--test", t] for t in RUST_TESTS), [])
     + ["--", "--test-threads=2"],
     "webrtc/rust"),
    ("go", ["go", "test", "-race", "-count=1", "-timeout", "600s",
            "-run", "TestMux|TestTurn|TestDirect|TestDtls", "."],
     "webrtc/go"),
    ("js", ["node", "--test", "test/mux.test.js", "test/turn_mux.test.js",
            "test/dtls.test.js", "test/dc.test.js",
            "test/direct_coturn.test.js"],
     "webrtc/js"),
    ("matrix", ["node", "webrtc_matrix.test.mjs"], "browser-test"),
]


def prebuild():
    """Build Rust test binaries once so parallel copies do not fight
    over the cargo target lock; Go/JS share caches safely."""
    cmd = (["cargo", "test", "--quiet", "--no-run"]
           + sum((["--test", t] for t in RUST_TESTS), []))
    print("prebuild:", " ".join(cmd), flush=True)
    r = subprocess.run(cmd, cwd=os.path.join(ROOT, "webrtc/rust"))
    if r.returncode != 0:
        print("prebuild FAILED")
        return False
    return True


def main():
    n = int(os.environ.get("STRESS_N", "3"))
    os.makedirs(LOG_DIR, exist_ok=True)
    if not prebuild():
        return 1
    print(f"stress: N={n} copies x {len(SUITES)} suites, phased by suite",
          flush=True)
    started = time.time()
    failures = []
    total = 0
    for suite, cmd, cwd in SUITES:
        jobs = []  # (label, proc, log_path, fh)
        for i in range(n):
            log_path = os.path.join(LOG_DIR, f"{suite}-{i}.log")
            fh = open(log_path, "wb")
            proc = subprocess.Popen(cmd, cwd=os.path.join(ROOT, cwd),
                                    stdout=fh, stderr=subprocess.STDOUT)
            jobs.append((f"{suite}-{i}", proc, log_path, fh))
        total += len(jobs)
        for label, proc, log_path, fh in jobs:
            try:
                rc = proc.wait(timeout=TIMEOUT_S)
            except subprocess.TimeoutExpired:
                proc.kill()
                rc = proc.wait()
                failures.append(f"{label}: TIMEOUT after {TIMEOUT_S}s")
                print(f"{label}: TIMEOUT (log {log_path})", flush=True)
                fh.close()
                continue
            fh.close()
            with open(log_path, errors="replace") as lf:
                text = lf.read()
            hits = COLLISION.findall(text)
            ok = rc == 0 and not hits
            print(f"{label}: exit={rc} collisions={len(hits)} "
                  f"{'ok' if ok else 'FAIL'} (log {log_path})", flush=True)
            if not ok:
                failures.append(
                    f"{label}: exit={rc} collisions={len(hits)}")
    elapsed = int(time.time() - started)
    if failures:
        print(f"stress_ports: FAIL ({elapsed}s): " + "; ".join(failures))
        return 1
    print(f"stress_ports: PASS ({total} parallel jobs, {elapsed}s, "
          f"0 address-in-use errors)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
