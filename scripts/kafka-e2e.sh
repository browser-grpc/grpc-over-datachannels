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

# Redpanda v26 broker binary accepts YAML configuration only: it
# dropped the legacy `redpanda start --kafka-addr ...` CLI flags.
# Generate a per-fixture YAML with rpk, patch it with rpk config
# set, and launch the broker ELF binary directly (the shell
# wrapper's argv0 juggling also breaks the YAML-only binary).
rp_broker_bin() {
    local libexec
    libexec="$(dirname "$REDPANDA_BIN")/../libexec/redpanda"
    if [ -x "$libexec" ]; then
        echo "$libexec"
    else
        echo "$REDPANDA_BIN"
    fi
}

rp_rpk_bin() {
    local rpk_bin
    rpk_bin="$(dirname "$REDPANDA_BIN")/rpk"
    [ -x "$rpk_bin" ] || rpk_bin="$(command -v rpk || true)"
    echo "$rpk_bin"
}

# start_redpanda_instance NAME DATA_DIR RPC_ADDR ADMIN_PORT \
#     KAFKA_API_YAML ADVERTISED_YAML [key=value ...]
# KAFKA_API_YAML / ADVERTISED_YAML are YAML list fragments, e.g.
# '[{address: 127.0.0.1, port: 19093}]' or named listeners with
# '"name":"external"'. Extra key=value pairs go to rpk config set.
start_redpanda_instance() {
    local name="$1" data_dir="$2" rpc_addr="$3" admin_port="$4" \
        kafka_yaml="$5" advertised_yaml="$6"
    shift 6
    local cfg="$TMP/$name.yaml" rpk_bin broker_bin kv
    rpk_bin="$(rp_rpk_bin)"
    [ -n "$rpk_bin" ] || { echo "FAIL: rpk not found next to redpanda" >&2; return 1; }
    broker_bin="$(rp_broker_bin)"
    mkdir -p "$data_dir"
    "$rpk_bin" redpanda config bootstrap --config "$cfg" \
        --self "${rpc_addr%:*}" >/dev/null || return 1
    "$rpk_bin" redpanda config set --config "$cfg" \
        redpanda.data_directory "$data_dir" >/dev/null || return 1
    "$rpk_bin" redpanda config set --config "$cfg" \
        redpanda.rpc_server "{address: ${rpc_addr%:*}, port: ${rpc_addr##*:}}" >/dev/null || return 1
    "$rpk_bin" redpanda config set --config "$cfg" \
        redpanda.advertised_rpc_api "{address: ${rpc_addr%:*}, port: ${rpc_addr##*:}}" >/dev/null || return 1
    "$rpk_bin" redpanda config set --config "$cfg" \
        redpanda.admin "[{address: 127.0.0.1, port: $admin_port}]" >/dev/null || return 1
    "$rpk_bin" redpanda config set --config "$cfg" \
        redpanda.kafka_api "$kafka_yaml" >/dev/null || return 1
    "$rpk_bin" redpanda config set --config "$cfg" \
        redpanda.advertised_kafka_api "$advertised_yaml" >/dev/null || return 1
    for kv in "$@"; do
        "$rpk_bin" redpanda config set --config "$cfg" \
            "${kv%%=*}" "${kv#*=}" >/dev/null || return 1
    done
    "$broker_bin" --redpanda-cfg "$cfg" --smp 1 --memory 512M \
        >"$TMP/$name.log" 2>&1 &
    STARTED_BROKERS+=($!)
}

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

KAFKA_SASL_ADDR=127.0.0.1:19197
PROXY_KAFKA_SASL256_ADDR=127.0.0.1:50208
PROXY_KAFKA_SASL512_ADDR=127.0.0.1:50209
PROXY_KAFKA_SASLPLAIN_ADDR=127.0.0.1:50210

# Apache Kafka SASL fixture: a second KRaft broker with one
# SASL_PLAINTEXT listener advertising PLAIN + SCRAM-SHA-256 +
# SCRAM-SHA-512 (test-only users rpadmin/proxy, provisioned
# below). The Redpanda SASL fixture remains in place; this proves
# the same proxy SASL paths against stock Apache Kafka.
start_kafka_sasl() {
    if port_open "$KAFKA_SASL_ADDR"; then
        echo "ok: kafka (sasl) already listening on $KAFKA_SASL_ADDR (reusing)"
        return 0
    fi
    local props="$TMP/kafka-sasl.properties"
    cat > "$props" <<EOF
process.roles=broker,controller
node.id=2
listeners=SASL_PLAINTEXT://0.0.0.0:19197,CONTROLLER://0.0.0.0:19194
advertised.listeners=SASL_PLAINTEXT://localhost:19197
controller.listener.names=CONTROLLER
controller.quorum.voters=2@localhost:19194
log.dirs=$TMP/kafka-sasl-logs
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
group.initial.rebalance.delay.ms=0
num.partitions=1
listener.security.protocol.map=CONTROLLER:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT
inter.broker.listener.name=SASL_PLAINTEXT
sasl.mechanism.inter.broker.protocol=PLAIN
sasl.enabled.mechanisms=PLAIN,SCRAM-SHA-256,SCRAM-SHA-512
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
# Combined broker+controller node: its own registration RPCs
# arrive as User:ANONYMOUS on the CONTROLLER listener and need
# CLUSTER_ACTION on CLUSTER, which StandardAuthorizer only
# grants to super users or explicit ACLs. Test-only fixture
# (listener not published outside the test host); real
# clusters isolate controllers instead.
super.users=User:admin;User:rpadmin;User:proxy;User:ANONYMOUS
allow.everyone.if.no.acl.found=false
listener.name.sasl_plaintext.plain.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret" user_rpadmin="rp-secret" user_proxy="proxy-secret";
listener.name.sasl_plaintext.scram-sha-256.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="admin-secret";
listener.name.sasl_plaintext.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="admin-secret";
EOF
    local cluster_id
    cluster_id="$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)" || return 1
    "$KAFKA_HOME/bin/kafka-storage.sh" format -t "$cluster_id" -c "$props" \
        --ignore-formatted >"$TMP/kafka-sasl-format.log" 2>&1 || return 1
    "$KAFKA_HOME/bin/kafka-server-start.sh" "$props" >"$TMP/kafka-sasl.log" 2>&1 &
    STARTED_BROKERS+=($!)
    wait_port "$KAFKA_SASL_ADDR" 180 "kafka (sasl)" || { tail -20 "$TMP/kafka-sasl.log" >&2; return 1; }
    local admin_cfg="$TMP/kafka-sasl-admin.properties"
    cat > "$admin_cfg" <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="rpadmin" password="rp-secret";
EOF
    "$KAFKA_HOME/bin/kafka-configs.sh" --bootstrap-server "$KAFKA_SASL_ADDR" \
        --command-config "$admin_cfg" --alter --add-config 'SCRAM-SHA-256=[password=rp-secret]' \
        --entity-type users --entity-name rpadmin >/dev/null || return 1
    "$KAFKA_HOME/bin/kafka-configs.sh" --bootstrap-server "$KAFKA_SASL_ADDR" \
        --command-config "$admin_cfg" --alter --add-config 'SCRAM-SHA-512=[password=proxy-secret]' \
        --entity-type users --entity-name proxy >/dev/null || return 1
    sleep 2
}

RESTART_KAFKA_ADDR=127.0.0.1:19095
PROXY_RESTART_ADDR=127.0.0.1:50211

# Broker-restart leg: a dedicated Kafka with persistent log
# dirs (same TMP across the bounce) proving committed-offset
# resume + proxy connection recovery across a broker restart.
# Driven by scripts/kafka-restart-driver.py (generated python
# client through a --tcp proxy).
start_kafka_restart() {
    local props="$TMP/kafka-restart.properties"
    cat > "$props" <<EOF
process.roles=broker,controller
node.id=3
listeners=PLAINTEXT://0.0.0.0:19095,CONTROLLER://0.0.0.0:19096
advertised.listeners=PLAINTEXT://localhost:19095
controller.listener.names=CONTROLLER
controller.quorum.voters=3@localhost:19096
log.dirs=$TMP/kafka-restart-logs
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
group.initial.rebalance.delay.ms=0
num.partitions=1
EOF
    if [ ! -f "$TMP/kafka-restart.cluster-id" ]; then
        "$KAFKA_HOME/bin/kafka-storage.sh" random-uuid > "$TMP/kafka-restart.cluster-id" || return 1
    fi
    "$KAFKA_HOME/bin/kafka-storage.sh" format -t "$(cat "$TMP/kafka-restart.cluster-id")" \
        -c "$props" --ignore-formatted >"$TMP/kafka-restart-format.log" 2>&1 || return 1
    "$KAFKA_HOME/bin/kafka-server-start.sh" "$props" >"$TMP/kafka-restart.log" 2>&1 &
    KAFKA_RESTART_PID=$!
    STARTED_BROKERS+=($KAFKA_RESTART_PID)
    wait_port "$RESTART_KAFKA_ADDR" 180 "kafka (restart leg)" || { tail -20 "$TMP/kafka-restart.log" >&2; return 1; }
}

run_broker_restart_leg() {
    local proxy_bin="$1"
    start_kafka_restart || return 1
    "$proxy_bin" --tcp "$PROXY_RESTART_ADDR" --broker "$RESTART_KAFKA_ADDR" \
        >"$TMP/proxy-restart.log" 2>&1 &
    PIDS+=($!)
    wait_port "$PROXY_RESTART_ADDR" 30 "proxy (restart leg)" || return 1
    local topic="grpc-dc-restart-$(date +%s%N)"
    export KAFKA_RESTART_TOPIC="$topic" KAFKA_RESTART_GROUP="$topic-group"
    run "broker restart phase1 (commit before bounce)" env \
        KAFKA_E2E_PROXY_ADDR="$PROXY_RESTART_ADDR" \
        python3 "$ROOT/scripts/kafka-restart-driver.py" phase1 || return 1
    kill "$KAFKA_RESTART_PID" 2>/dev/null
    wait "$KAFKA_RESTART_PID" 2>/dev/null
    sleep 2
    start_kafka_restart || return 1
    run "broker restart phase2 (resume after bounce)" env \
        KAFKA_E2E_PROXY_ADDR="$PROXY_RESTART_ADDR" \
        python3 "$ROOT/scripts/kafka-restart-driver.py" phase2 || return 1
    # Cleanup only: both phases already passed, so a kill
    # race (broker already exiting) must not fail the leg.
    kill "$KAFKA_RESTART_PID" 2>/dev/null || true
}

run_kafka_sasl_suites() {
    run "sasl scram-sha-256 e2e (apache kafka)" env KAFKA_E2E_PROXY_ADDR="$PROXY_KAFKA_SASL256_ADDR" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
    run "sasl scram-sha-512 e2e (apache kafka)" env KAFKA_E2E_PROXY_ADDR="$PROXY_KAFKA_SASL512_ADDR" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
    run "sasl plain e2e (apache kafka)" env KAFKA_E2E_PROXY_ADDR="$PROXY_KAFKA_SASLPLAIN_ADDR" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_e2e"
}

KAFKA_CLUSTER_ADDR=127.0.0.1:19192
KAFKA_CLUSTER_ADDR2=127.0.0.1:19292

# Two-broker Apache Kafka cluster (separate from the single
# broker above) for partition-leader routing proof: the Rust
# suite bootstraps only to node 11 and must reach leaders on
# both nodes. Formatted as one KRaft quorum of two.
start_kafka_cluster() {
    if port_open "$KAFKA_CLUSTER_ADDR" && port_open "$KAFKA_CLUSTER_ADDR2"; then
        echo "ok: kafka cluster already listening on $KAFKA_CLUSTER_ADDR,$KAFKA_CLUSTER_ADDR2 (reusing)"
        return 0
    fi
    local cluster_id node props
    cluster_id="$("$KAFKA_HOME/bin/kafka-storage.sh" random-uuid)" || return 1
    for node in 11 12; do
        local client_port=$((19192 + (node - 11) * 100))
        local controller_port=$((19193 + (node - 11) * 100))
        props="$TMP/kafka-cluster-$node.properties"
        cat > "$props" <<EOF
process.roles=broker,controller
node.id=$node
listeners=PLAINTEXT://0.0.0.0:$client_port,CONTROLLER://0.0.0.0:$controller_port
advertised.listeners=PLAINTEXT://localhost:$client_port
controller.listener.names=CONTROLLER
controller.quorum.voters=11@localhost:19193,12@localhost:19293
log.dirs=$TMP/kafka-cluster-logs-$node
offsets.topic.replication.factor=2
offsets.topic.num.partitions=4
transaction.state.log.replication.factor=2
transaction.state.log.min.isr=1
default.replication.factor=2
min.insync.replicas=1
group.initial.rebalance.delay.ms=0
num.partitions=3
EOF
        "$KAFKA_HOME/bin/kafka-storage.sh" format -t "$cluster_id" -c "$props" \
            --ignore-formatted >"$TMP/kafka-cluster-$node-format.log" 2>&1 || return 1
        "$KAFKA_HOME/bin/kafka-server-start.sh" "$props" \
            >"$TMP/kafka-cluster-$node.log" 2>&1 &
        STARTED_BROKERS+=($!)
    done
    wait_port "$KAFKA_CLUSTER_ADDR" 180 "kafka cluster node 11" || { tail -20 "$TMP/kafka-cluster-11.log" >&2; return 1; }
    wait_port "$KAFKA_CLUSTER_ADDR2" 180 "kafka cluster node 12" || { tail -20 "$TMP/kafka-cluster-12.log" >&2; return 1; }
    sleep 5
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
share.coordinator.state.topic.replication.factor=1
share.coordinator.state.topic.min.isr=1
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
    start_redpanda_instance redpanda-sasl "$TMP/rp-sasl-data" \
        127.0.0.1:33146 9645 \
        '[{address: 0.0.0.0, port: 19097}]' \
        '[{address: 127.0.0.1, port: 19097}]' \
        'pandaproxy.pandaproxy_api=[{address: 127.0.0.1, port: 18082}]' \
        'schema_registry.schema_registry_api=[{address: 127.0.0.1, port: 18081}]' \
        || return 1
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
    start_redpanda_instance redpanda-tls "$TMP/rp-tls-data" \
        127.0.0.1:33147 9646 \
        '[{name: internal, address: 0.0.0.0, port: 19099}, {name: tls, address: 0.0.0.0, port: 19098}]' \
        '[{name: internal, address: 127.0.0.1, port: 19099}, {name: tls, address: 127.0.0.1, port: 19098}]' \
        'pandaproxy.pandaproxy_api=[{address: 127.0.0.1, port: 18084}]' \
        'schema_registry.schema_registry_api=[{address: 127.0.0.1, port: 18083}]' \
        "redpanda.kafka_api_tls=[{\"name\":\"tls\",\"enabled\":true,\"require_client_auth\":false,\"cert_file\":\"$certs/broker.crt\",\"key_file\":\"$certs/broker.key\",\"truststore_file\":\"$certs/ca.crt\"}]" \
        || return 1
    wait_port "$TLS_REDPANDA_ADDR" 120 "redpanda (tls)" || { tail -20 "$TMP/redpanda-tls.log" >&2; return 1; }
}

# HTTP/2 ingress: kafka_proxy --webrtc-direct behind the
# shipped grpc-dc-proxy (stock HTTP/2 -> DataChannel), driven
# by the generated JS client over its HTTP/2 transport.
run_http2_suite() {
    echo "== building kafka_proxy (webrtc)"
    (cd "$ROOT/apps/kafka-proxy" && cargo build --features webrtc,kafka-tls) || return 1
    local proxy_bin="$ROOT/apps/kafka-proxy/target/debug/kafka_proxy"
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

run_native_legs() {
    # kafka-native collapsed form: in-process library, no
    # proxy. Verified against Apache Kafka (admin semantics
    # are broker-specific; the proxy suites cover Redpanda).
    run "rust direct e2e (apache kafka)" env KAFKA_PROXY_E2E_BROKER="$KAFKA_ADDR" \
        bash -c "cd '$ROOT/rust' && cargo test --test kafka_direct_e2e --test kafka_admin_e2e --test kafka_kip848_e2e --test kafka_share_e2e"
    echo "== building libkafka_native (cdylib)"
    (cd "$ROOT/crates/kafka-service" && cargo build && cp target/debug/libkafka_service.so target/debug/libkafka_native.so) || { FAILED=1; return 1; }
    run "python native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_native"
    run "rust ffi e2e (apache kafka)" env KAFKA_PROXY_E2E_BROKER="$KAFKA_ADDR" \
        bash -c "cd '$ROOT/rust' && cargo test --test kafka_native_ffi_e2e"
    run "ruby native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT' && ruby ruby/tests/main.rb TestKafkaNative"
    run "dart native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/dart' && dart tests/main.dart TestKafkaNative"
    run "csharp native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/csharp' && dotnet run --project tests/Tests.csproj -c Release -- TestKafkaNative"
    run "swift native e2e (apache kafka)" env KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        bash -c "mkdir -p '$TMP/swiftmod' && printf 'module KafkaNativeC [system] {\n  header \"$ROOT/crates/kafka-service/include/kafka_native.h\"\n  link \"kafka_native\"\n  export *\n}\n' > '$TMP/swiftmod/module.modulemap' && swiftc -swift-version 5 -O '$ROOT'/swift/grpcdc/*.swift '$ROOT/swift/tests/TestKafkaNative.swift' -I '$TMP/swiftmod' -L '$ROOT/crates/kafka-service/target/debug' -lkafka_native -o '$TMP/swift_kafka_native' && LD_LIBRARY_PATH='$ROOT/crates/kafka-service/target/debug' '$TMP/swift_kafka_native'"
    run "cpp native e2e (apache kafka)" env KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        bash -c "g++ -std=c++17 -pthread -O1 -I'$ROOT/cpp' -I'$ROOT' -I'$ROOT/crates/kafka-service/include' '$ROOT/cpp/tests/test_kafka_native.cpp' -L'$ROOT/crates/kafka-service/target/debug' -lkafka_native -Wl,-rpath,'$ROOT/crates/kafka-service/target/debug' -o '$TMP/cpp_kafka_native' && '$TMP/cpp_kafka_native'"
    run "go native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GOFLAGS=-buildvcs=false \
        CGO_LDFLAGS="-L$ROOT/crates/kafka-service/target/debug -Wl,-rpath,$ROOT/crates/kafka-service/target/debug" \
        bash -c "cd '$ROOT/go' && go test -tags kafka_native -run TestKafkaNativeRoundtrip ."
    run "js native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_ADDON="$TMP/kafka_native_addon.node" \
        bash -c "cc -O2 -fPIC -shared -I/usr/local/include/node -I'$ROOT/crates/kafka-service/include' '$ROOT/js/src/kafka_native_addon.c' -L'$ROOT/crates/kafka-service/target/debug' -lkafka_native -Wl,-rpath,'$ROOT/crates/kafka-service/target/debug' -o '$TMP/kafka_native_addon.node' && cd '$ROOT/js' && node --test test/kafka_native.test.js"
    run "php native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/php' && php -d ffi.enable=true tests/main.php TestKafkaNative"
    run "scala native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_JNI="$TMP/libkafka_native_jni.so" \
        bash -c "cc -shared -fPIC -I$(dirname $(dirname $(readlink -f $(command -v javac))))/include -I$(dirname $(dirname $(readlink -f $(command -v javac))))/include/linux -I'$ROOT/crates/kafka-service/include' '$ROOT/java/jni/kafka_native_jni.c' -L'$ROOT/crates/kafka-service/target/debug' -lkafka_native -o '$TMP/libkafka_native_jni.so' && cd '$ROOT' && LD_LIBRARY_PATH='$ROOT/crates/kafka-service/target/debug' java -cp \"$(scala_libs)\" tests.Main TestKafkaNative"
    run "kotlin native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_JNI="$TMP/libkafka_native_jni.so" \
        bash -c "cc -shared -fPIC -I$(dirname $(dirname $(readlink -f $(command -v javac))))/include -I$(dirname $(dirname $(readlink -f $(command -v javac))))/include/linux -I'$ROOT/crates/kafka-service/include' '$ROOT/java/jni/kafka_native_jni.c' -L'$ROOT/crates/kafka-service/target/debug' -lkafka_native -o '$TMP/libkafka_native_jni.so' && cd '$ROOT' && LD_LIBRARY_PATH='$ROOT/crates/kafka-service/target/debug' java -jar kotlin/build/tests.jar TestKafkaNative"
    run "lua native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        LUA_CPATH="$TMP/?.so" \
        LD_LIBRARY_PATH="$ROOT/crates/kafka-service/target/debug" \
        bash -c "cc -O2 -fPIC -shared -I/usr/include/lua5.4 '$ROOT/lua/native/kafka_native_lua.c' -L'$ROOT/crates/kafka-service/target/debug' -lkafka_native -Wl,-rpath,'$ROOT/crates/kafka-service/target/debug' -o '$TMP/kafka_native_core.so' && cd '$ROOT' && lua5.4 lua/tests/main.lua TestKafkaNative"
    run "zig native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/zig' && zig build --prefix build && ./build/bin/tests TestKafkaNative"
    run "js differential e2e (proxy vs native)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        KAFKA_E2E_PROXY_ADDR="$PROXY_KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_ADDON="$TMP/kafka_native_addon.node" \
        bash -c "cd '$ROOT/js' && node --test test/kafka_native_differential.test.js"
    run "go differential e2e (proxy vs native)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        KAFKA_E2E_PROXY_ADDR="$PROXY_KAFKA_ADDR" \
        GOFLAGS=-buildvcs=false \
        CGO_LDFLAGS="-L$ROOT/crates/kafka-service/target/debug -Wl,-rpath,$ROOT/crates/kafka-service/target/debug" \
        bash -c "cd '$ROOT/go' && go test -tags kafka_native -run TestKafkaDifferential -count=1 ."
    run "dart differential e2e (proxy vs native)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        KAFKA_E2E_PROXY_ADDR="$PROXY_KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/dart' && dart tests/main.dart TestKafkaDifferential"
    run "csharp differential e2e (proxy vs native)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        KAFKA_E2E_PROXY_ADDR="$PROXY_KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/csharp' && dotnet run --project tests --no-build -- TestKafkaDifferential"
    run "python differential e2e (proxy vs native)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        KAFKA_E2E_PROXY_ADDR="$PROXY_KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_native.TestKafkaDifferential"
    run "java native e2e (apache kafka)" env \
        KAFKA_E2E_BROKER="$KAFKA_ADDR" \
        GRPC_DC_KAFKA_NATIVE_JNI="$TMP/libkafka_native_jni.so" \
        bash -c "cc -shared -fPIC -I$(dirname $(dirname $(readlink -f $(command -v javac))))/include -I$(dirname $(dirname $(readlink -f $(command -v javac))))/include/linux -I'$ROOT/crates/kafka-service/include' '$ROOT/java/jni/kafka_native_jni.c' -L'$ROOT/crates/kafka-service/target/debug' -lkafka_native -o '$TMP/libkafka_native_jni.so' && cd '$ROOT/java' && mkdir -p '$TMP/jbuild' && javac -encoding UTF-8 -d '$TMP/jbuild' grpcdc/KafkaNative.java grpcdc/Marshaler.java grpcdc/Unmarshaler.java grpcdc/kafka/v1/*.java tests/TestKafkaNative.java && LD_LIBRARY_PATH='$ROOT/crates/kafka-service/target/debug' java -cp '$TMP/jbuild' tests.TestKafkaNative"
    run "c ffi smoke (apache kafka)" \
        bash -c "cc -O1 -I'$ROOT/crates/kafka-service/include' '$ROOT/crates/kafka-service/tests/ffi_smoke.c' -L'$ROOT/crates/kafka-service/target/debug' -lkafka_native -Wl,-rpath,'$ROOT/crates/kafka-service/target/debug' -o '$TMP/ffi_smoke' && '$TMP/ffi_smoke' '$KAFKA_ADDR'"
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
    start_redpanda_instance redpanda "$TMP/rp-data" \
        127.0.0.1:33145 9644 \
        '[{name: internal, address: 127.0.0.1, port: 19095}, {name: external, address: 127.0.0.1, port: 19093}]' \
        '[{name: internal, address: 127.0.0.1, port: 19095}, {name: external, address: 127.0.0.1, port: 19093}]' \
        || return 1
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
    (cd "$ROOT/rust" && cargo build --release) || return 1
    # Dart is always rebuilt: the compile is seconds, and a
    # stale prebuilt binary silently lacks new dispatch cases.
    (cd "$ROOT" && mkdir -p dart/build && dart compile exe dart/tests/main.dart -o dart/build/tests) || return 1
    # Java is always rebuilt: build-if-missing silently ran
    # stale classes when a new test class was added (the
    # streams interpreter's first gate run hit exactly that).
    (cd "$ROOT/java" && mkdir -p build && javac -encoding UTF-8 -d build $(find grpcdc examples tests -name '*.java')) || return 1
    if [ ! -f "$ROOT/kotlin/build/tests.jar" ] || [ -n "$(find "$ROOT/kotlin/grpcdc" "$ROOT/kotlin/tests" -name '*.kt' -newer "$ROOT/kotlin/build/tests.jar" 2>/dev/null)" ]; then
        (cd "$ROOT" && mkdir -p kotlin/build && kotlinc -include-runtime kotlin/grpcdc/*.kt kotlin/examples/Pb.kt kotlin/examples/EchoMessages.kt kotlin/examples/EchoRequestStruct.kt kotlin/examples/EchoResponseStruct.kt kotlin/examples/EchoGrpcDc.kt kotlin/examples/EchoServiceImpl.kt kotlin/examples/StdioTransport.kt kotlin/examples/DynamicEchoService.kt kotlin/examples/interop/*.kt kotlin/tests/*.kt -d kotlin/build/tests.jar) || return 1
    fi
    if [ ! -f "$ROOT/scala/build/tests.jar" ] || [ -n "$(find "$ROOT/scala/grpcdc" "$ROOT/scala/tests" -name '*.scala' -newer "$ROOT/scala/build/tests.jar" 2>/dev/null)" ]; then
        (cd "$ROOT" && mkdir -p scala/build && scalac -d scala/build/tests.jar scala/grpcdc/*.scala scala/examples/EchoMessages.scala scala/examples/EchoRequestStruct.scala scala/examples/EchoResponseStruct.scala scala/examples/EchoGrpcDc.scala scala/examples/EchoServiceImpl.scala scala/examples/StdioTransport.scala scala/examples/DynamicEchoService.scala scala/examples/interop/*.scala scala/tests/*.scala) || return 1
    fi
    # C# is always rebuilt too (incremental; a stale dll
    # silently lacks new dispatch cases).
    (cd "$ROOT/csharp" && dotnet build tests/Tests.csproj --nologo -v q) || return 1
    if [ ! -x "$ROOT/swift/build/tests" ]; then
        (cd "$ROOT" && mkdir -p swift/build && swiftc -swift-version 5 -O -L $ROOT/rust/target/release -lgrpc_dc -Xlinker -rpath -Xlinker $ROOT/rust/target/release swift/grpcdc/*.swift swift/examples/Pb.swift swift/examples/EchoMessages.swift swift/examples/EchoRequestStruct.swift swift/examples/EchoResponseStruct.swift swift/examples/StructDcBridge.swift swift/examples/EchoGrpcDc.swift swift/examples/EchoServiceImpl.swift swift/examples/StdioTransport.swift swift/examples/DynamicEchoService.swift swift/examples/interop/*.swift $(ls swift/tests/*.swift | grep -v TestKafkaNative.swift) -o swift/build/tests) || return 1
    fi
    if [ ! -x "$ROOT/cpp/build/tests" ]; then
        (cd "$ROOT" && mkdir -p cpp/build && g++ -std=c++17 -pthread -O1 -Icpp -I. cpp/tests/main.cpp cpp/tests/test_codec.cpp cpp/tests/test_echo.cpp cpp/tests/test_interop.cpp cpp/tests/test_interop_oracle.cpp cpp/tests/test_interop_server_oracle.cpp cpp/tests/test_oracle.cpp cpp/tests/test_dynamic.cpp cpp/tests/test_bdd.cpp cpp/tests/test_deadline.cpp cpp/tests/test_inline_pump.cpp cpp/tests/test_pb_messages.cpp cpp/tests/test_bdd_schemas.cpp cpp/tests/test_sidecar.cpp cpp/tests/test_bdd_sidecar.cpp cpp/tests/test_eventbus.cpp cpp/tests/test_kafka_e2e.cpp cpp/tests/test_tracing.cpp cpp/tests/test_struct_codec.cpp -L rust/target/release -lgrpc_dc -Wl,-rpath,$ROOT/rust/target/release -o cpp/build/tests) || return 1
    fi
    if [ ! -x "$ROOT/zig/build/bin/tests" ]; then
        (cd "$ROOT/zig" && zig build --prefix build) || return 1
    fi
    if [ ! -x "$ROOT/c/build/tests" ]; then
        (cd "$ROOT" && mkdir -p c/build && gcc -std=c99 -Wall -Wextra -pthread -O1 -Ic -Ic/examples -Ic/tests c/grpcdc/grpcdc.c c/grpcdc/memory_transport.c c/grpcdc/sidecar_transport.c c/grpcdc/dynamic.c c/examples/stdio_transport.c c/tests/main.c -L rust/target/release -lgrpc_dc -Wl,-rpath,$ROOT/rust/target/release -o c/build/tests) || return 1
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
    run "js streams e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/js' && node --test test/kafka_streams.test.js"
    run "python streams e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_streams"
    run "go e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/go' && go test -run 'TestKafka' ."
    run "ruby e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && ruby ruby/tests/main.rb TestKafkaE2E"
    run "php e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && php php/tests/main.php TestKafkaE2E"
    run "dart e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/dart' && ./build/tests TestKafkaE2E && ./build/tests TestKafkaShareE2E"
    run "lua e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && ${LUA:-lua5.4} lua/tests/main.lua TestKafkaE2E"
    run "java e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/java' && java -cp build tests.TestKafkaE2E"
    run "java streams e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/java' && java -cp build tests.TestKafkaStreamsE2E"
    run "go streams e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/go' && go test -run 'TestKafkaStreamsScenarios' ."
    run "kotlin e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && java -jar kotlin/build/tests.jar TestKafkaE2E"
    run "scala e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT' && java -cp '$(scala_libs)' tests.Main TestKafkaE2E"
    run "csharp e2e ($label)" env KAFKA_E2E_PROXY_ADDR="$proxy" \
        bash -c "cd '$ROOT/csharp' && dotnet run --project tests --no-build -- TestKafkaE2E && dotnet run --project tests --no-build -- TestKafkaShareE2E"
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
    (cd "$ROOT/apps/kafka-proxy" && cargo build --features kafka-tls) || exit 1
    local proxy_bin="$ROOT/apps/kafka-proxy/target/debug/kafka_proxy"

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
    run_native_legs

    start_kafka_cluster || exit 1
    run "rust multi-broker leader routing (apache kafka)" env \
        KAFKA_PROXY_E2E_BROKER="$KAFKA_CLUSTER_ADDR" KAFKA_PROXY_E2E_CLUSTER=1 \
        bash -c "cd '$ROOT/rust' && cargo test --test kafka_proxy_e2e kafka_proxy_multi_broker_leader_routing"

    run_broker_restart_leg "$proxy_bin" || FAILED=1

    start_kafka_sasl || exit 1
    "$proxy_bin" --tcp "$PROXY_KAFKA_SASL256_ADDR" --broker "$KAFKA_SASL_ADDR" \
        --sasl-scram-sha-256 rpadmin rp-secret >"$TMP/proxy-kafka-sasl256.log" 2>&1 &
    PIDS+=($!)
    "$proxy_bin" --tcp "$PROXY_KAFKA_SASL512_ADDR" --broker "$KAFKA_SASL_ADDR" \
        --sasl-scram-sha-512 proxy proxy-secret >"$TMP/proxy-kafka-sasl512.log" 2>&1 &
    PIDS+=($!)
    "$proxy_bin" --tcp "$PROXY_KAFKA_SASLPLAIN_ADDR" --broker "$KAFKA_SASL_ADDR" \
        --sasl-plain proxy proxy-secret >"$TMP/proxy-kafka-saslplain.log" 2>&1 &
    PIDS+=($!)
    wait_port "$PROXY_KAFKA_SASL256_ADDR" 30 "proxy (kafka sasl)" || exit 1
    run_kafka_sasl_suites
    run "python native sasl e2e (apache kafka)" env \
        KAFKA_E2E_SASL_BROKER="$KAFKA_SASL_ADDR" \
        KAFKA_E2E_SASL_USER=proxy KAFKA_E2E_SASL_PASS=proxy-secret \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_native.TestKafkaNativeSasl"

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
    run "python native tls e2e (redpanda)" env \
        KAFKA_E2E_TLS_BROKER="$TLS_REDPANDA_ADDR" \
        KAFKA_E2E_TLS_CA="$TLS_CA" \
        GRPC_DC_KAFKA_NATIVE_LIB="$ROOT/crates/kafka-service/target/debug/libkafka_native.so" \
        bash -c "cd '$ROOT/python' && python3 -m unittest tests.test_kafka_native.TestKafkaNativeTls"

    run_http2_suite || FAILED=1

    if [ "$FAILED" -ne 0 ]; then
        echo "kafka e2e: FAILURES (logs in run output above)" >&2
        exit 1
    fi
    echo "kafka e2e: all suites green against kafka + redpanda"
}

main "$@"
