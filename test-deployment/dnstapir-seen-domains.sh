#!/bin/bash
#
# dnstapir-seen-domains.sh — dump the seen_domains KV bucket as CSV on stdout.
#
# seen_domains is the new-qname analyst's record of every name any Edge has
# ever reported. It has no TTL by design: forgetting a name would make the
# analyst report it as globally new all over again. That makes it the closest
# thing this deployment has to a durable list of observed names.
#
# Each entry maps one name to the nodes that reported it and when each first
# did, so the default output has one row per name and reporter:
#
#   domain,reporter,first_seen,kv_updated
#   ports.ubuntu.com,dyETerSJ...,2026-09-10T07:45:27Z,2026-09-10T07:45:27Z
#
# "reporter" is the reporting node's RFC 7638 JWK thumbprint, which is also what
# it signs uploads with; NodeMan maps it back to a node name. A name reported by
# two nodes produces two rows.
#
# Run it on the Core VM, where the handover bundle supplies the NATS URL, or on
# the services VM, where the credentials file does. Everything is read-only.

set -euo pipefail

readonly PROGNAME="${0##*/}"

bucket=seen_domains
prefix=
nats_url=
read_timeout=120
domains_only=0

usage() {
  cat <<USAGE
Usage: $PROGNAME [options] > seen-domains.csv

Writes the whole $bucket bucket to stdout as CSV. Progress and errors go to
stderr, so redirecting stdout gives a clean file.

Options:
  --domains-only     One row per name, no header, no reporter columns. Suitable
                     for piping into sort, comm or grep -f.
  --bucket NAME      KV bucket to read. Default: $bucket
  --prefix SUBJECT   Subject prefix to strip from each key before reversing the
                     labels. Default: read from the new-qname analyst's config
                     if present, otherwise core-integration-test.internal.seen-domains
  --nats-url URL     NATS URL to read from. Default: resolved from the handover
                     bundle on Core, or the credentials file on the services VM.
  --timeout SECS     How long to wait for the bucket to drain. Default: $read_timeout
  -h, --help         Show this text.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --domains-only) domains_only=1; shift ;;
    --bucket)       bucket="${2:?--bucket needs a value}"; shift 2 ;;
    --prefix)       prefix="${2:?--prefix needs a value}"; shift 2 ;;
    --nats-url)     nats_url="${2:?--nats-url needs a value}"; shift 2 ;;
    --timeout)      read_timeout="${2:?--timeout needs a value}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; echo "$PROGNAME: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s: %s\n' "$PROGNAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Where to read from.
#
# Core holds the handover bundle with ready-made URLs; the services VM holds the
# credentials the bundle was built from and reaches NATS on the loopback. Either
# works, and neither needs an argument.
# ---------------------------------------------------------------------------
if [ -z "$nats_url" ]; then
  if [ -s "${TAPIR_TEST_ROOT:-}/services-bundle/services.env" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TAPIR_TEST_ROOT/services-bundle/services.env"
    nats_url="${TAPIR_SERVICES_NATS_ENCODER_URL:-}"
  elif [ -s "${TAPIR_SERVICES_KEYS:-}/service-credentials.env" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TAPIR_SERVICES_KEYS/service-credentials.env"
    nats_url="nats://encoder:${TAPIR_NATS_ENCODER_PASSWORD:-}@127.0.0.1:4222"
  fi
fi
[ -n "$nats_url" ] || die "no NATS URL; pass --nats-url, or run this where the login environment is set"

if [ -z "$prefix" ]; then
  tapir_config="${TAPIR_TEST_ROOT:-}/core-analysis/tapir-analyse-new-qname/config.toml"
  if [ -r "$tapir_config" ]; then
    prefix="$(awk -F'"' '/^seen_domains_subject_prefix/ { print $2; exit }' "$tapir_config")"
  fi
  prefix="${prefix:-core-integration-test.internal.seen-domains}"
fi

nats() {
  docker run --rm --network host natsio/nats-box:latest \
    nats --server "$nats_url" "$@"
}

# ---------------------------------------------------------------------------
# Read the bucket.
#
# "nats kv watch" replays every current value and then blocks for new ones, so
# the stop condition is the stream's own message count rather than a guess at
# how long the replay takes. The bucket keeps one message per key, so that count
# is exactly the number of names.
# ---------------------------------------------------------------------------
expected="$(nats stream info "KV_$bucket" --json 2>/dev/null \
  | jq -r '.state.messages // empty' || true)"
[ -n "$expected" ] || die "bucket $bucket not found, or NATS did not answer"
log "$bucket holds $expected names"

capture="$(mktemp)"
container="tapir-seen-domains-$$"
cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
  rm -f "$capture"
}
trap cleanup EXIT

nats_watch() {
  docker run --rm --network host --name "$container" natsio/nats-box:latest \
    nats --server "$nats_url" kv watch "$bucket"
}
nats_watch > "$capture" 2>/dev/null &
watch_pid=$!

deadline=$((SECONDS + read_timeout))
while [ "$SECONDS" -lt "$deadline" ]; do
  seen="$(grep -c '^\[' "$capture" 2>/dev/null || true)"
  [ "$seen" -lt "$expected" ] || break
  sleep 1
done

docker rm --force "$container" >/dev/null 2>&1 || true
wait "$watch_pid" 2>/dev/null || true

seen="$(grep -c '^\[' "$capture" 2>/dev/null || true)"
log "read $seen of $expected"
# A short read means a truncated list, which is worse than no list at all
# because nothing downstream can tell the difference.
[ "$seen" -ge "$expected" ] \
  || die "only $seen of $expected entries arrived within ${read_timeout}s; raise --timeout"

# ---------------------------------------------------------------------------
# Emit the CSV.
#
# Python rather than awk because the names are quoted properly by the csv
# module, and the values are JSON.
# ---------------------------------------------------------------------------
python3 - "$capture" "$prefix" "$domains_only" <<'PYCSV'
import csv, datetime, json, re, sys

capture, prefix, domains_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
line_re = re.compile(r"^\[(?P<ts>[^\]]+)\] (?P<op>\w+) \S+ > (?P<key>\S+?): (?P<val>.*)$")
out = csv.writer(sys.stdout, lineterminator="\n")

def iso(unix):
    return datetime.datetime.fromtimestamp(int(unix), datetime.timezone.utc) \
        .strftime("%Y-%m-%dT%H:%M:%SZ")

def domain(key):
    # Keys are the subject prefix followed by the name with its labels reversed,
    # which is how NATS makes a DNS name into a hierarchical subject.
    rest = key[len(prefix) + 1:] if key.startswith(prefix + ".") else key
    return ".".join(reversed(rest.split("."))) if rest else ""

if not domains_only:
    out.writerow(["domain", "reporter", "first_seen", "kv_updated"])

seen_names = set()
for line in open(capture, encoding="utf-8", errors="replace"):
    m = line_re.match(line.rstrip("\n"))
    # Only current values matter; a delete or purge leaves no name behind.
    if not m or m.group("op") != "PUT":
        continue
    name = domain(m.group("key"))
    if not name:
        continue
    if domains_only:
        if name not in seen_names:
            seen_names.add(name)
            out.writerow([name])
        continue
    try:
        reporters = json.loads(m.group("val"))
    except json.JSONDecodeError:
        reporters = {}
    updated = m.group("ts").replace(" ", "T") + "Z"
    if not reporters:
        out.writerow([name, "", "", updated])
    for thumbprint, first in sorted(reporters.items()):
        out.writerow([name, thumbprint, iso(first), updated])
PYCSV
