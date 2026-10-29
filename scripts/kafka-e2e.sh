#!/usr/bin/env bash
# Kafka proxy end-to-end suite: starts Apache Kafka + Redpanda
# fixtures (unless already listening, e.g. local docker brokers),
# starts one kafka_proxy (--tcp) per broker, and runs the
# per-language e2e suites (all supported languages) against both.
#
# Broker binaries:
#   KAFKA_HOME    (default /opt/kafka, Dockerfile.ci)
#   REDPANDA_BIN  (default: redpanda on PATH or /opt/redpanda/bin)
#
# Ports: kafka 19092 (controller 19094), redpanda 19093
# (internal 19095, rpc 33145), proxies 50201 (kafka) / 50202
# (redpanda). Brokers that are already accepting connections are
# reused and left running; anything started here is killed on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KAFKA_HOME="${KAFKA_HOME:-/opt/kafka}"
REDPANDA_BIN="${REDPANDA_BIN:-$(command -v redpanda || echo /opt/redpanda/bin/redpanda)}"

KAFKA_ADDR=127.0.0.1:19092
REDPANDA_ADDR=127.0.0.1:19093
PROXY_KAFKA_ADDR=127.0.0.1:50201
PROXY_REDPANDA_ADDR=127.0.0.1:50202

TMP="$(mktemp -d)"
PIDS=()
STARTED_BROKERS=()

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    for pid in "${STARTED_BROKERS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

port_open() {
    (exec 3<>"/dev/tcp/${1%:*}/${1##*:}") 2>/dev/null && exec 3>&- 3<&-
}

wait_port() { # addr seconds label
    local deadline=$((SECONDS + $2))
    while ! port_open "$1"; do
        if [ $SECONDS -ge $deadline ]; then
            echo "FAIL: $3 did not open $1 within $2s" >&2
            return 1
        fi
        sleep 1
    done
    echo "ok: $3 listening on $1"
}

start_kafka() {
    if port_open "$KAFKA_ADDR"; then
        echo "ok: kafka already listening on $KAFKA_ADDR (reusing)"
        return 0
    fi
    local props="$TMP/kafka.properties"
    cat > "$props" <<EOF
process.roles=broker,controller
node.id=1
listeners=PLAINTEXT://0.0.0.0:19092,CONTROLLER://0.0.0.0:19094
advertised.listeners=PLAINTEXT://localhost:19092
controller.listener.names=CONTROLLER
controller.quorum.voters=1@localhost:19094
log.dirs=$TMP/kafka-logs
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
group.initial.rebalance.delay.ms=0
num.partitions=1
EOF
    local cluster_id
    cluster_id="$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)" || return 1
    "$KAFKA_HOME/bin/kafka-storage.sh" format -t "$cluster_id" -c "$props" \
        --ignore-formatted >"$TMP/kafka-format.log" 2>&1 || return 1
    "$KAFKA_HOME/bin/kafka-server-start.sh" "$props" >"$TMP/kafka.log" 2>&1 &
    STARTED_BROKERS+=($!)
    wait_port "$KAFKA_ADDR" 180 "kafka" || { tail -20 "$TMP/kafka.log" >&2; return 1; }
}

SASL_REDPANDA_ADDR=127.0.0.1:19097
PROXY_SASL256_ADDR=127.0.0.1:50203
PROXY_SASL512_ADDR=127.0.0.1:50204
PROXY_SASLPLAIN_ADDR=127.0.0.1:50205

# SASL fixture: a second Redpanda with SASL enabled (SCRAM +
# PLAIN), users rpadmin/proxy (test-only credentials). When the
# script starts this broker it also provisions users/ACLs via
# rpk; an already-listening broker on the port is reused as-is.
start_redpanda_sasl() {
    if port_open "$SASL_REDPANDA_ADDR"; then
        echo "ok: redpanda (sasl) already listening on $SASL_REDPANDA_ADDR (reusing)"
        return 0
    fi
    local rpk_bin
    rpk_bin="$(dirname "$REDPANDA_BIN")/rpk"
    [ -x "$rpk_bin" ] || rpk_bin="$(command -v rpk || true)"
    [ -n "$rpk_bin" ] || { echo "FAIL: rpk not found next to redpanda" >&2; return 1; }
    mkdir -p "$TMP/rp-sasl-data"
    "$REDPANDA_BIN" start --overprovisioned --smp 1 --memory 512M \
        --kafka-addr 0.0.0.0:19097 \
        --advertise-kafka-addr localhost:19097 \
        --rpc-addr 0.0.0.0:33146 \
        --pandaproxy-addr 127.0.0.1:18082 \
        --schema-registry-addr 127.0.0.1:18081 \
        --data-directory "$TMP/rp-sasl-data" \
        --set 'redpanda.admin=[{"address":"127.0.0.1","port":9645}]' \
        >"$TMP/redpanda-sasl.log" 2>&1 &
    STARTED_BROKERS+=($!)
    wait_port "$SASL_REDPANDA_ADDR" 120 "redpanda (sasl)" || { tail -20 "$TMP/redpanda-sasl.log" >&2; return 1; }
    "$rpk_bin" cluster config set enable_sasl true --api-urls 127.0.0.1:9645 >/dev/null || return 1
    "$rpk_bin" cluster config set superusers '["rpadmin","proxy"]' --api-urls 127.0.0.1:9645 >/dev/null || return 1
    "$rpk_bin" cluster config set sasl_mechanisms '["SCRAM","PLAIN"]' --api-urls 127.0.0.1:9645 >/dev/null || return 1
    "$rpk_bin" acl user create rpadmin --password rp-secret --mechanism SCRAM-SHA-256 --api-urls 127.0.0.1:9645 >/dev/null || return 1
    "$rpk_bin" acl user create proxy --password proxy-secret --mechanism SCRAM-SHA-512 --api-urls 127.0.0.1:9645 >/dev/null || return 1
    sleep 2
}

TLS_REDPANDA_ADDR=127.0.0.1:19098
PROXY_TLS_ADDR=127.0.0.1:50206
PROXY_TLS_INSECURE_ADDR=127.0.0.1:50207

# TLS fixture: a third Redpanda with a TLS Kafka listener
# (self-signed CA generated here with openssl). An
# already-listening broker on the port is reused as-is; its
# CA cert is then expected at $KAFKA_E2E_TLS_CA (default
# /tmp/kafka-tls/ca.crt, the local docker fixture layout).
start_redpanda_tls() {
    TLS_CA="${KAFKA_E2E_TLS_CA:-/tmp/kafka-tls/ca.crt}"
    if port_open "$TLS_REDPANDA_ADDR"; then
        echo "ok: redpanda (tls) already listening on $TLS_REDPANDA_ADDR (reusing)"
        return 0
    fi
    command -v openssl >/dev/null || { echo "FAIL: openssl not found" >&2; return 1; }
    local certs="$TMP/tls"
    mkdir -p "$certs" "$TMP/rp-tls-data"
    openssl req -x509 -newkey rsa:2048 -keyout "$certs/ca.key" -out "$certs/ca.crt" \
        -days 365 -nodes -subj "/CN=kafka-test-ca" >/dev/null 2>&1 || return 1
    openssl req -newkey rsa:2048 -keyout "$certs/broker.key" -out "$certs/broker.csr" \
        -nodes -subj "/CN=localhost" >/dev/null 2>&1 || return 1
    printf "subjectAltName=IP:127.0.0.1,DNS:localhost\n" > "$certs/ext.cnf"
    openssl x509 -req -in "$certs/broker.csr" -CA "$certs/ca.crt" -CAkey "$certs/ca.key" \
        -CAcreateserial -out "$certs/broker.crt" -days 365 -extfile "$certs/ext.cnf" \
        >/dev/null 2>&1 || return 1
    chmod 644 "$certs/broker.key"
    TLS_CA="$certs/ca.crt"
    "$REDPANDA_BIN" start --overprovisioned --smp 1 --memory 512M \
        --kafka-addr internal://0.0.0.0:19099,tls://0.0.0.0:19098 \
        --advertise-kafka-addr internal://127.0.0.1:19099,tls://localhost:19098 \
        --rpc-addr 0.0.0.0:33147 \
        --pandaproxy-addr 127.0.0.1:18084 \
        --schema-registry-addr 127.0.0.1:18083 \
        --data-directory "$TMP/rp-tls-data" \
        --set 'redpanda.admin=[{"address":"127.0.0.1","port":9646}]' \
        --set "redpanda.kafka_api_tls=[{\"name\":\"tls\",\"enabled\":true,\"require_client_auth\":false,\"cert_file\":\"$certs/broker.crt\",\"key_file\":\"$certs/broker.key\",\"truststore_file\":\"$certs/ca.crt\"}]" \
        >"$TMP/redpanda-tls.log" 2>&1 &
    STARTED_BROKERS+=($!)
    wait_port "$TLS_REDPANDA_ADDR" 120 "redpanda (tls)" || { tail -20 "$TMP/redpanda-tls.log" >&2; return 1; }
}

# HTTP/2 ingress: kafka_proxy --webrtc-direct behind the
# shipped grpc-dc-proxy (stock HTTP/2 -> DataChannel), driven
# by the generated JS client over its HTTP/2 transport.
run_http2_suite() {
    echo "== building kafka_proxy (webrtc)"
    (cd "$ROOT/rust" && cargo build --features webrtc,kafka-tls --example kafka_proxy) || return 1
    local proxy_bin="$ROOT/rust/target/debug/examples/kafka_proxy"
    "$proxy_bin" --webrtc-direct 127.0.0.1:40401 --broker "$KAFKA_ADDR" \
        >"$TMP/proxy-webrtc.log" 2>&1 &
    PIDS+=($!)
    local ma=""
    local i
    for i in $(seq 1 30); do
        ma=$(grep -o '/ip4[^ ]*' "$TMP/proxy-webrtc.log" 2>/dev/null | head -1 || true)
        [ -n "$ma" ] && break
        sleep 1
    done
    [ -n "$ma" ] || { echo "FAIL: kafka_proxy printed no webrtc multiaddr" >&2; return 1; }
    (cd "$ROOT" && node proxy/grpc-dc-proxy.mjs --dc-dial "$ma" --http2 50551) \
        >"$TMP/http2-bridge.log" 2>&1 &
    PIDS+=($!)
    wait_port "127.0.0.1:50551" 30 "http2 bridge" || return 1
    run "js http2 e2e (kafka via webrtc-direct)" env KAFKA_E2E_HTTP2_ADDR="127.0.0.1:50551" \
        bash -c "cd '$ROOT/js' && timeout 300 node --test test/kafka.test.js"
}

run_tls_suites() {
    run "tls ca-verified e2e (redpanda)" env KAFKA_E2E_PROXY_ADDR="$PROXY_TLS_ADDR" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
    run "tls insecure-skip-verify e2e (redpanda)" env KAFKA_E2E_PROXY_ADDR="$PROXY_TLS_INSECURE_ADDR" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
}

run_sasl_suites() {
    # SASL is a proxy<->broker concern; the generated clients see
    # an ordinary proxy. One suite per mechanism, through the
    # Python client (all languages share this proxy path).
    run "sasl scram-sha-256 e2e (redpanda)" env KAFKA_E2E_PROXY_ADDR="$PROXY_SASL256_ADDR" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
    run "sasl scram-sha-512 e2e (redpanda)" env KAFKA_E2E_PROXY_ADDR="$PROXY_SASL512_ADDR" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
    run "sasl plain e2e (redpanda)" env KAFKA_E2E_PROXY_ADDR="$PROXY_SASLPLAIN_ADDR" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
}

start_redpanda() {
    if port_open "$REDPANDA_ADDR"; then
        echo "ok: redpanda already listening on $REDPANDA_ADDR (reusing)"
        return 0
    fi
    mkdir -p "$TMP/rp-data"
    "$REDPANDA_BIN" start --overprovisioned --smp 1 --memory 512M \
        --kafka-addr internal://127.0.0.1:19095,external://127.0.0.1:19093 \
        --advertise-kafka-addr internal://127.0.0.1:19095,external://localhost:19093 \
        --rpc-addr 127.0.0.1:33145 \
        --data-directory "$TMP/rp-data" >"$TMP/redpanda.log" 2>&1 &
    STARTED_BROKERS+=($!)
    wait_port "$REDPANDA_ADDR" 120 "redpanda" || { tail -20 "$TMP/redpanda.log" >&2; return 1; }
}

FAILED=0
run() { # label, then command with env
    local label="$1"; shift
    echo "== $label"
    if "$@"; then
        echo "ok: $label"
    else
        echo "FAIL: $label" >&2
        FAILED=1
    fi
}

# Build-if-missing for the compiled languages' test binaries.
# In a full `make test` run the per-language targets have already
# built these; standalone `make test-kafka` builds what it needs.
build_clients() {
    echo "== building language test clients (if missing)"
    if [ ! -x "$ROOT/dart/build/tests" ]; then
        (cd "$ROOT" && mkdir -p dart/build && dart compile exe dart/tests/main.dart -o dart/build/tests) || return 1
    fi
    if [ ! -f "$ROOT/java/build/tests/TestKafkaE2E.class" ]; then
        (cd "$ROOT/java" && mkdir -p build && javac -encoding UTF-8 -d build $(find grpcdc examples tests -name '*.java')) || return 1
    fi
    if [ ! -f "$ROOT/kotlin/build/tests.jar" ]; then
        (cd "$ROOT" && mkdir -p kotlin/build && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/DynamicEchoService.kt kotlin/examples/interop/*.kt kotlin/tests/*.kt -d kotlin/build/tests.jar) || return 1
    fi
    if [ ! -f "$ROOT/scala/build/tests.jar" ]; then
        (cd "$ROOT" && mkdir -p scala/build && scalac -d scala/build/tests.jar scala/grpcdc/*.scala scala/examples/EchoMessages.scala scala/examples/EchoGrpcDc.scala scala/examples/EchoServiceImpl.scala scala/examples/StdioTransport.scala scala/examples/DynamicEchoService.scala scala/examples/interop/*.scala scala/tests/*.scala) || return 1
    fi
    if [ ! -f "$ROOT/csharp/tests/bin/Debug/net8.0/GrpcdcTests.dll" ]; then
        (cd "$ROOT/csharp" && dotnet build tests/Tests.csproj --nologo -v q) || return 1
    fi
    if [ ! -x "$ROOT/swift/build/tests" ]; then
        (cd "$ROOT" && mkdir -p swift/build && swiftc -swift-version 5 -O swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/DynamicEchoService.swift swift/examples/interop/*.swift swift/tests/*.swift -o swift/build/tests) || return 1
    fi
    if [ ! -x "$ROOT/cpp/build/tests" ]; then
        (cd "$ROOT" && mkdir -p cpp/build && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/tests/main.cpp cpp/tests/test_codec.cpp cpp/tests/test_echo.cpp cpp/tests/test_interop.cpp cpp/tests/test_interop_oracle.cpp cpp/tests/test_interop_server_oracle.cpp cpp/tests/test_oracle.cpp cpp/tests/test_dynamic.cpp cpp/tests/test_bdd.cpp cpp/tests/test_deadline.cpp cpp/tests/test_inline_pump.cpp cpp/tests/test_pb_messages.cpp cpp/tests/test_bdd_schemas.cpp cpp/tests/test_sidecar.cpp cpp/tests/test_bdd_sidecar.cpp cpp/tests/test_eventbus.cpp cpp/tests/test_kafka_e2e.cpp -o cpp/build/tests) || return 1
    fi
    if [ ! -x "$ROOT/zig/build/bin/tests" ]; then
        (cd "$ROOT/zig" && zig build --prefix build) || return 1
    fi
    if [ ! -x "$ROOT/c/build/tests" ]; then
        (cd "$ROOT" && mkdir -p c/build && gcc -std=c99 -Wall -Wextra -pthread -O1 -Ic -Ic/examples -Ic/tests c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/grpcdc/sidecar_transport.c c/grpcdc/dynamic.c c/examples/stdio_transport.c c/tests/main.c -o c/build/tests) || return 1
    fi
}

scala_libs() {
    local home="${SCALA3_HOME:-}"
    if [ -z "$home" ]; then
        home="$(dirname "$(dirname "$(readlink -f "$(command -v scalac)")")")"
    fi
    echo "$ROOT/scala/build/tests.jar:$home/lib/scala3-library_3-3.3.6.jar:$home/lib/scala-library-2.13.16.jar"
}

run_suites() { # broker_addr proxy_addr label
    local broker="$1" proxy="$2" label="$3"
    run "rust e2e ($label)" env KAFKA_PROXY_E2E_BROKER="$broker" \
        bash -c "cd '$ROOT/rust' && cargo test --test kafka_proxy_e2e"
    run "python e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
    run "js e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/js' && node --test test/kafka.test.js"
    run "go e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/go' && go test -run 'TestKafka' ."
    run "ruby e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && ruby ruby/tests/main.rb TestKafkaE2E"
    run "php e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && php php/tests/main.php TestKafkaE2E"
    run "dart e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/dart' && ./build/tests TestKafkaE2E"
    run "lua e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && lua lua/tests/main.lua TestKafkaE2E"
    run "java e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/java' && java -cp build tests.TestKafkaE2E"
    run "kotlin e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && java -jar kotlin/build/tests.jar TestKafkaE2E"
    run "scala e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && java -cp '$(scala_libs)' tests.Main TestKafkaE2E"
    run "csharp e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/csharp' && dotnet run --project tests --no-build -- TestKafkaE2E"
    run "swift e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/swift' && ./build/tests TestKafkaE2E"
    run "cpp e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/cpp' && ./build/tests TestKafkaE2E"
    run "zig e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/zig' && ./build/bin/tests TestKafkaE2E"
    run "c e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && ./c/build/tests TestKafkaE2E"
}

main() {
    start_kafka || exit 1
    start_redpanda || exit 1

    build_clients || exit 1

    echo "== building kafka_proxy"
    (cd "$ROOT/rust" && cargo build --features kafka-tls --example kafka_proxy) || exit 1
    local proxy_bin="$ROOT/rust/target/debug/examples/kafka_proxy"

    "$proxy_bin" --tcp "$PROXY_KAFKA_ADDR" --broker "$KAFKA_ADDR" \
        >"$TMP/proxy-kafka.log" 2>&1 &
    PIDS+=($!)
    "$proxy_bin" --tcp "$PROXY_REDPANDA_ADDR" --broker "$REDPANDA_ADDR" \
        >"$TMP/proxy-redpanda.log" 2>&1 &
    PIDS+=($!)
    wait_port "$PROXY_KAFKA_ADDR" 30 "proxy (kafka)" || exit 1
    wait_port "$PROXY_REDPANDA_ADDR" 30 "proxy (redpanda)" || exit 1

    run_suites "$KAFKA_ADDR" "$PROXY_KAFKA_ADDR" "apache kafka"
    run_suites "$REDPANDA_ADDR" "$PROXY_REDPANDA_ADDR" "redpanda"

    start_redpanda_sasl || exit 1
    "$proxy_bin" --tcp "$PROXY_SASL256_ADDR" --broker "$SASL_REDPANDA_ADDR" \
        --sasl-scram-sha-256 rpadmin rp-secret >"$TMP/proxy-sasl256.log" 2>&1 &
    PIDS+=($!)
    "$proxy_bin" --tcp "$PROXY_SASL512_ADDR" --broker "$SASL_REDPANDA_ADDR" \
        --sasl-scram-sha-512 proxy proxy-secret >"$TMP/proxy-sasl512.log" 2>&1 &
    PIDS+=($!)
    "$proxy_bin" --tcp "$PROXY_SASLPLAIN_ADDR" --broker "$SASL_REDPANDA_ADDR" \
        --sasl-plain proxy proxy-secret >"$TMP/proxy-saslplain.log" 2>&1 &
    PIDS+=($!)
    wait_port "$PROXY_SASL256_ADDR" 30 "proxy (sasl)" || exit 1
    run_sasl_suites

    start_redpanda_tls || exit 1
    "$proxy_bin" --tcp "$PROXY_TLS_ADDR" --broker "$TLS_REDPANDA_ADDR" \
        --tls-ca-cert "$TLS_CA" >"$TMP/proxy-tls.log" 2>&1 &
    PIDS+=($!)
    "$proxy_bin" --tcp "$PROXY_TLS_INSECURE_ADDR" --broker "$TLS_REDPANDA_ADDR" \
        --tls-insecure-skip-verify >"$TMP/proxy-tls-insecure.log" 2>&1 &
    PIDS+=($!)
    wait_port "$PROXY_TLS_ADDR" 30 "proxy (tls)" || exit 1
    run_tls_suites

    run_http2_suite || FAILED=1

    if [ "$FAILED" -ne 0 ]; then
        echo "kafka e2e: FAILURES (logs in run output above)" >&2
        exit 1
    fi
    echo "kafka e2e: all suites green against kafka + redpanda"
}

main "$@"
