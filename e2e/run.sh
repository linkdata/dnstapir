#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${ROOT}/upstream"
WORK="${E2E_WORKDIR:-${ROOT}/.e2e-work}"
BIN="${WORK}/bin"
TOOLS="${WORK}/tools"
LOG="${WORK}/logs"
CONF="${WORK}/conf"
KEYS="${WORK}/keys"
RESULTS="${WORK}/results"
EDM_DATA="${WORK}/edm-data"
GO_CACHE="${WORK}/gocache"
GO_MOD_CACHE="${E2E_GOMODCACHE:-${WORK}/gomodcache}"
NATS_SERVER_VERSION="${E2E_NATS_SERVER_VERSION:-v2.12.7}"
NATS_SERVER_BIN="${E2E_NATS_SERVER:-}"
FIXTURE="${ROOT}/e2e/fixtures/dnstap-fixtures.json"

choose_free_port() {
  local start="$1"
  local port
  for ((port = start; port < start + 100; port++)); do
    if ! ( : >"/dev/tcp/127.0.0.1/${port}" ) >/dev/null 2>&1; then
      printf '%s\n' "${port}"
      return 0
    fi
  done
  printf 'unable to find a free port at or above %s\n' "${start}" >&2
  return 1
}

MQTT_PORT="${E2E_MQTT_PORT:-$(choose_free_port 28884)}"
NATS_PORT="${E2E_NATS_PORT:-14222}"
EDM_DNSTAP_PORT="${E2E_EDM_DNSTAP_PORT:-53535}"
EDM_METRICS_PORT=2112
MQTT_URL="mqtt://127.0.0.1:${MQTT_PORT}"
NATS_URL="nats://127.0.0.1:${NATS_PORT}"
EDM_KID="e2e-edm"
BRIDGE_KID="e2e-bridge"

PIDS=()

log() {
  printf '[e2e] %s\n' "$*"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

start_bg() {
  local name="$1"
  shift
  log "starting ${name}"
  "$@" >"${LOG}/${name}.log" 2>&1 &
  PIDS+=("$!")
}

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
  done
  local deadline=$((SECONDS + 5))
  while (( SECONDS < deadline )); do
    local alive=false
    for pid in "${PIDS[@]:-}"; do
      if kill -0 "${pid}" >/dev/null 2>&1; then
        alive=true
      fi
    done
    if [[ "${alive}" == false ]]; then
      return
    fi
    sleep 0.2
  done
  for pid in "${PIDS[@]:-}"; do
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

wait_port() {
  local port="$1"
  local name="$2"
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if ( : >"/dev/tcp/127.0.0.1/${port}" ) >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  printf 'timed out waiting for %s on port %s\n' "${name}" "${port}" >&2
  return 1
}

wait_files() {
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    local all_ready=true
    local path
    for path in "$@"; do
      if [[ ! -s "${path}" ]]; then
        all_ready=false
      fi
    done
    if [[ "${all_ready}" == true ]]; then
      return 0
    fi
    sleep 1
  done
  printf 'timed out waiting for files: %s\n' "$*" >&2
  return 1
}

build_go() {
  local name="$1"
  local dir="$2"
  local pkg="$3"
  log "building ${name}"
  (
    cd "${dir}"
    GOCACHE="${GO_CACHE}" GOMODCACHE="${GO_MOD_CACHE}" go build -o "${BIN}/${name}" "${pkg}"
  )
}

ensure_nats_server() {
  if [[ -n "${NATS_SERVER_BIN}" ]]; then
    return
  fi
  mkdir -p "${TOOLS}"
  NATS_SERVER_BIN="${TOOLS}/nats-server"
  if [[ ! -x "${NATS_SERVER_BIN}" ]]; then
    log "installing nats-server ${NATS_SERVER_VERSION} into ${TOOLS}"
    GOBIN="${TOOLS}" GOCACHE="${GO_CACHE}" GOMODCACHE="${GO_MOD_CACHE}" \
      go install "github.com/nats-io/nats-server/v2@${NATS_SERVER_VERSION}"
  fi
}

write_configs() {
  cat >"${CONF}/tiny-domains.csv" <<'EOF'
rank,domain
1,example.com
2,example.org
3,example.net
EOF

  cat >"${CONF}/edm.toml" <<'EOF'
cryptopan-key = "dnstapir-e2e-key"
EOF

  cat >"${CONF}/mqtt-bridge.toml" <<EOF
Debug = true
MqttUrl = "${MQTT_URL}"
MqttCaCert = ""
MqttClientCert = ""
MqttClientKey = ""
NatsUrl = "${NATS_URL}"
NodemanApiUrl = "https://127.0.0.1/unused"

[[Bridges]]
Direction = "up"
MqttTopic = "events/up/${EDM_KID}/new_qname"
NatsSubject = "internal.events.new_qname"
NatsQueue = "new-qname-e2e"
Key = "${KEYS}/edm-jws.json"
Schema = "${ROOT}/e2e/schemas/new_qname.json"

[[Bridges]]
Direction = "down"
MqttTopic = "observations/down/tapir-pop"
MqttRetain = false
NatsSubject = "e2e.down.tapir-pop"
NatsQueue = "tapir-pop-e2e"
Key = "${KEYS}/bridge-jws.json"
Schema = "${ROOT}/e2e/schemas/edge_observations.json"
EOF

  cat >"${CONF}/analyzer.toml" <<EOF
debug = true
ignore_suffixes = []

[nats]
debug = true
url = "${NATS_URL}"
event_subject = "internal.events.new_qname"
observation_subject_prefix = "internal.observations"
seen_domains_subject_prefix = "internal.seen-domains"
private_subject_prefix = "internal.service.tapir-analyse-new-qname"

[[nats.observation_buckets]]
observation = "globally_new"
name = "globally_new"
create = true
ttl = 3600

[nats.seen_domains_bucket]
name = "seen_domains"
create = true

[api]
active = false
EOF

  cat >"${CONF}/observation-encoder.toml" <<EOF
debug = true
ttl_margin = 5

[nats]
url = "${NATS_URL}"
subject_southbound = "e2e.down.tapir-pop"
observation_subject_prefix = "internal.observations"

[[nats.buckets]]
name = "globally_new"
ttl = 3600

[api]
active = false
EOF

  cat >"${CONF}/unsigned-new-qname.json" <<'EOF'
{"type":"new_qname","version":0,"qname":"unsigned-rpz-e2e.invalid.","qtype":1,"qclass":1,"timestamp":"2026-01-02T03:04:08Z"}
EOF
}

run_pop_driver() {
  local poptmp="${WORK}/pop-driver"
  rm -rf "${poptmp}"
  mkdir -p "${poptmp}"
  cp "${UPSTREAM}/pop/"*.go "${UPSTREAM}/pop/go.mod" "${UPSTREAM}/pop/go.sum" "${poptmp}/"
  cp "${ROOT}/e2e/popdriver/pop_e2e_driver_test.go.tmpl" "${poptmp}/pop_e2e_driver_test.go"
  (
    cd "${poptmp}"
    E2E_POP_OBSERVATION="${RESULTS}/downbound-observation.json" \
    E2E_POP_ARTIFACT="${RESULTS}/pop-artifact.json" \
    E2E_POP_FORBIDDEN_DOMAIN="unsigned-rpz-e2e.invalid." \
    GOCACHE="${GO_CACHE}" \
    GOMODCACHE="${GO_MOD_CACHE}" \
    go test -vet=off -run TestE2EPopArtifact .
  )
}

main() {
  need_cmd go
  need_cmd mosquitto

  for repo in edm cli mqtt-bridge tapir-analyse-new-qname observation-encoder pop; do
    if [[ ! -d "${UPSTREAM}/${repo}" ]]; then
      printf 'missing upstream checkout: %s\n' "${UPSTREAM}/${repo}" >&2
      exit 1
    fi
  done

  rm -rf "${BIN}" "${LOG}" "${CONF}" "${KEYS}" "${RESULTS}" "${EDM_DATA}" "${WORK}/nats" "${GO_CACHE}"
  mkdir -p "${BIN}" "${TOOLS}" "${LOG}" "${CONF}" "${KEYS}" "${RESULTS}" "${EDM_DATA}"
  ensure_nats_server

  build_go e2e-tools "${ROOT}/e2e" ./cmd/e2e-tools
  build_go dnstapir-edm "${UPSTREAM}/edm" ./cmd/dnstapir-edm
  build_go dnstapir-cli "${UPSTREAM}/cli" .
  build_go mqtt-bridge "${UPSTREAM}/mqtt-bridge" ./cmd/mqtt-bridge
  build_go tapir-analyse-new-qname "${UPSTREAM}/tapir-analyse-new-qname" ./cmd/tapir-analyse-new-qname
  build_go observation-encoder "${UPSTREAM}/observation-encoder" ./cmd/observation-encoder

  "${BIN}/e2e-tools" keygen --dir "${KEYS}" --edm-kid "${EDM_KID}" --bridge-kid "${BRIDGE_KID}"
  write_configs

  "${BIN}/dnstapir-cli" --standalone dawg compile \
    --format csv \
    --src "${CONF}/tiny-domains.csv" \
    --dawg "${CONF}/well-known-domains.dawg"

  start_bg nats "${NATS_SERVER_BIN}" -js -p "${NATS_PORT}" -sd "${WORK}/nats"
  wait_port "${NATS_PORT}" nats
  start_bg mosquitto mosquitto -p "${MQTT_PORT}" -v
  wait_port "${MQTT_PORT}" mosquitto

  start_bg mqtt-bridge "${BIN}/mqtt-bridge" -config-file "${CONF}/mqtt-bridge.toml"
  start_bg analyzer "${BIN}/tapir-analyse-new-qname" -config "${CONF}/analyzer.toml"
  start_bg observation-encoder "${BIN}/observation-encoder" -config "${CONF}/observation-encoder.toml"
  sleep 2

  "${BIN}/e2e-tools" mqtt-publish \
    --server "${MQTT_URL}" \
    --topic "events/up/${EDM_KID}/new_qname" \
    --payload-file "${CONF}/unsigned-new-qname.json"

  start_bg capture-upbound "${BIN}/e2e-tools" mqtt-capture \
    --server "${MQTT_URL}" \
    --topic "events/up/${EDM_KID}/new_qname" \
    --verify-key "${KEYS}/edm-jws-public.json" \
    --out "${RESULTS}/upbound-new-qname.json" \
    --timeout 75s

  start_bg capture-downbound "${BIN}/e2e-tools" mqtt-capture \
    --server "${MQTT_URL}" \
    --topic "observations/down/tapir-pop" \
    --verify-key "${KEYS}/bridge-jws-public.json" \
    --out "${RESULTS}/downbound-observation.json" \
    --timeout 75s

  start_bg edm env DEBUG=false "${BIN}/dnstapir-edm" run \
    --input-tcp "127.0.0.1:${EDM_DNSTAP_PORT}" \
    --data-dir "${EDM_DATA}" \
    --config-file "${CONF}/edm.toml" \
    --well-known-domains-file "${CONF}/well-known-domains.dawg" \
    --disable-histogram-sender \
    --disable-mqtt-filequeue \
    --mqtt-server "${MQTT_URL}" \
    --mqtt-client-cert-file "${KEYS}/client.crt" \
    --mqtt-client-key-file "${KEYS}/client.key" \
    --mqtt-signing-key-file "${KEYS}/edm-jws.json"

  wait_port "${EDM_DNSTAP_PORT}" edm-dnstap
  wait_port "${EDM_METRICS_PORT}" edm-metrics

  "${BIN}/e2e-tools" inject \
    --fixture "${FIXTURE}" \
    --target "tcp://127.0.0.1:${EDM_DNSTAP_PORT}" \
    --out "${RESULTS}/inject.json"

  wait_files "${RESULTS}/upbound-new-qname.json" "${RESULTS}/downbound-observation.json"

  run_pop_driver

  "${BIN}/e2e-tools" parquet-check \
    --fixture "${FIXTURE}" \
    --data-dir "${EDM_DATA}" \
    --timeout 75s \
    --out "${RESULTS}/parquet.json"

  "${BIN}/e2e-tools" summarize \
    --inject "${RESULTS}/inject.json" \
    --upbound "${RESULTS}/upbound-new-qname.json" \
    --downbound "${RESULTS}/downbound-observation.json" \
    --pop "${RESULTS}/pop-artifact.json" \
    --parquet "${RESULTS}/parquet.json" \
    --out "${RESULTS}/summary.json"

  log "summary written to ${RESULTS}/summary.json"
  cat "${RESULTS}/summary.json"
}

main "$@"
