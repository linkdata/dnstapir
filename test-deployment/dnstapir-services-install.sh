#!/bin/bash
#
# dnstapir-services-install.sh — install the DNS TAPIR persistent services VM.
#
# This is DNS-TAPIR-Services-VM-runbook.md, sections 3 through 10, as one
# script. It bootstraps the host, creates the certificate authority and the
# Core service certificates, starts MongoDB, NATS with JetStream, and the S3
# store, and produces the handover bundle the Core VM needs.
#
# Run it with sudo, from the directory holding dnstapir-host-bootstrap.sh:
#
#   sudo ./dnstapir-services-install.sh --core-ip 192.0.2.10
#
# The privileged half is delegated to dnstapir-host-bootstrap.sh, the same
# script the Core and Edge runbooks use, so all three hosts are bootstrapped
# identically. Everything after it runs as the unprivileged service account.
#
# The script is idempotent. Re-running it on a working host reuses the existing
# CA and credentials, rewrites the configuration, and restarts the services. It
# never deletes a Docker volume, so node records, JetStream buckets and stored
# aggregates survive a re-run.

set -euo pipefail

readonly PROGNAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

service_user=dnstapir
services_root=/opt/dnstapir-services
env_file=.dnstapir-services-env
bootstrap="$SCRIPT_DIR/dnstapir-host-bootstrap.sh"
core_ip=
services_ip=
subid_start=493216
enable_firewall=0
skip_bootstrap=0

usage() {
  cat <<USAGE
Usage: sudo $PROGNAME --core-ip ADDRESS [options]

Required:
  --core-ip ADDRESS       IPv4 address of the DNS TAPIR Core VM. It is the only
                          host allowed to reach the services, and it is the
                          address placed in the Mosquitto certificate.

Options:
  --services-ip ADDRESS   This host's address on the test network.
                          Default: the source address of the default route.
  --service-user NAME     Service account to own the deployment.
                          Default: $service_user
  --services-root PATH    Directory holding the CA, keys and runtime files.
                          Default: $services_root
  --subid-start N         Passed to the bootstrap script, which uses it only
                          when the account has no subordinate IDs yet. useradd
                          allocates a range automatically on Ubuntu, so on an
                          existing account this has no effect. Default: $subid_start
  --enable-firewall       Add the UFW rules AND activate UFW. Without this the
                          rules are added but UFW is left as it is, which on an
                          inactive firewall means the services are reachable
                          from the whole test network.
  --skip-bootstrap        Do not run dnstapir-host-bootstrap.sh. Use only when
                          this script has already bootstrapped the host; a host
                          bootstrapped by hand will not have the directories or
                          the TAPIR_* variables this script needs.
  -h, --help              Show this text.

The handover bundle for Core is written to
$services_root/handover/core-handover.tar.gz.
USAGE
}

log()  { printf '%s: %s\n' "$PROGNAME" "$*"; }
warn() { printf '%s: WARNING: %s\n' "$PROGNAME" "$*" >&2; }
die()  { printf '%s: error: %s\n' "$PROGNAME" "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --core-ip)        core_ip="${2:?--core-ip needs a value}"; shift 2 ;;
    --services-ip)    services_ip="${2:?--services-ip needs a value}"; shift 2 ;;
    --service-user)   service_user="${2:?--service-user needs a value}"; shift 2 ;;
    --services-root)  services_root="${2:?--services-root needs a value}"; shift 2 ;;
    --subid-start)    subid_start="${2:?--subid-start needs a value}"; shift 2 ;;
    --enable-firewall) enable_firewall=1; shift ;;
    --skip-bootstrap) skip_bootstrap=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$core_ip" ] || { usage >&2; die "--core-ip is required"; }

valid_ipv4() {
  case "$1" in
    *[!0-9.]*|'') return 1 ;;
  esac
  local IFS=. parts=() part
  read -r -a parts <<< "$1"
  [ "${#parts[@]}" -eq 4 ] || return 1
  for part in "${parts[@]}"; do
    [ -n "$part" ] || return 1
    [ "$part" -le 255 ] || return 1
  done
  return 0
}

valid_ipv4 "$core_ip" || die "--core-ip is not an IPv4 address: $core_ip"

if [ -z "$services_ip" ]; then
  services_ip="$(ip -4 -oneline route get "$core_ip" 2>/dev/null \
    | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  [ -n "$services_ip" ] || die "could not determine this host's address; pass --services-ip"
  log "detected services address $services_ip"
fi
valid_ipv4 "$services_ip" || die "--services-ip is not an IPv4 address: $services_ip"
[ "$services_ip" != "$core_ip" ] || die "--core-ip and --services-ip are the same address"

# Checked after the arguments so that a typo is reported even when the caller
# forgot sudo, rather than being masked until the second attempt.
[ "$(id -u)" -eq 0 ] || die "run this with sudo"

services_run="$services_root/run"
services_keys="$services_root/keys"
services_ca="$services_root/ca"
services_handover="$services_root/handover"
services_logs="$services_root/logs"

# ---------------------------------------------------------------------------
# 1. Privileged bootstrap, delegated to the shared script.
# ---------------------------------------------------------------------------
if [ "$skip_bootstrap" -eq 1 ]; then
  log "skipping the host bootstrap on request"
  id "$service_user" >/dev/null 2>&1 || die "$service_user does not exist"
else
  [ -x "$bootstrap" ] || die "not found or not executable: $bootstrap"
  log "bootstrapping the host with ${bootstrap##*/}"
  "$bootstrap" \
    --env-file "$env_file" \
    --service-user "$service_user" \
    --subid-start "$subid_start" \
    --dir "0755:$services_root" \
    --dir "0755:$services_run" \
    --dir "0700:$services_keys" \
    --dir "0700:$services_ca" \
    --dir "0750:$services_handover" \
    --dir "0755:$services_logs" \
    <<EOF
TAPIR_SERVICES_VM_IP=$services_ip
TAPIR_CORE_VM_IP=$core_ip
TAPIR_SERVICES_ROOT=$services_root
TAPIR_SERVICES_RUN=$services_run
TAPIR_SERVICES_KEYS=$services_keys
TAPIR_SERVICES_CA=$services_ca
TAPIR_SERVICES_HANDOVER=$services_handover
TAPIR_SERVICES_LOGS=$services_logs
EOF
fi

service_home="$(getent passwd "$service_user" | cut -d: -f6)"
[ -n "$service_home" ] || die "could not determine the home directory of $service_user"
service_group="$(id -gn "$service_user")"

# The bootstrap creates directories only for the --dir flags it is given, and
# writes TAPIR_* variables only for the KEY=VALUE lines on its stdin. Running it
# by hand without those leaves a host with Docker configured but no workspace,
# which then fails much later as a permission denied under /opt. Check here
# instead, where the cause is still obvious.
for d in "$services_root" "$services_run" "$services_keys" \
         "$services_ca" "$services_handover" "$services_logs"; do
  [ -d "$d" ] || die "$d was not created; if the host was bootstrapped by hand, re-run without --skip-bootstrap"
  [ "$(stat -c '%U' "$d")" = "$service_user" ] \
    || die "$d is not owned by $service_user"
done
[ -s "$service_home/$env_file" ] \
  || die "$service_home/$env_file was not written; re-run without --skip-bootstrap"
service_uid="$(id -u "$service_user")"
service_shell="$(getent passwd "$service_user" | cut -d: -f7)"

# Every command block in the runbooks opens with "set -euo pipefail", and dash
# rejects "-o pipefail". An account created by plain useradd gets /bin/sh, so
# "sudo -iu dnstapir" would land the operator in a shell that cannot run the
# documented procedure.
case "$service_shell" in
  */bash) ;;
  *)
    log "changing the login shell of $service_user from $service_shell to /bin/bash"
    chsh --shell /bin/bash "$service_user"
    ;;
esac

# ---------------------------------------------------------------------------
# 2. Unprivileged setup, run as the service account.
#
# The environment is passed explicitly rather than relying on the login shell
# sourcing the file the bootstrap wrote, so this works whatever shell the
# account has and however sudo is configured.
# ---------------------------------------------------------------------------
setup_script="$(mktemp "$service_home/.dnstapir-services-setup.XXXXXX")"
cleanup() { rm -f "$setup_script"; }
trap cleanup EXIT
chown "$service_user:$service_group" "$setup_script"
chmod 0700 "$setup_script"

cat > "$setup_script" <<'SETUP'
set -euo pipefail

: "${TAPIR_SERVICES_VM_IP:?login environment is missing TAPIR_SERVICES_VM_IP}"
: "${TAPIR_CORE_VM_IP:?login environment is missing TAPIR_CORE_VM_IP}"
: "${TAPIR_SERVICES_ROOT:?login environment is missing TAPIR_SERVICES_ROOT}"

step() { printf '\n== %s\n' "$*"; }

docker info --format '{{.SecurityOptions}}' | grep -c rootless >/dev/null \
  || { echo "the docker daemon is not rootless" >&2; exit 1; }

# -- Runbook section 6: the CA and the Core service certificates -------------
step "certificate authority"

CA_KEY="$TAPIR_SERVICES_CA/ca.key"
CA_CERT="$TAPIR_SERVICES_CA/ca.crt"
CA_SERIAL="$TAPIR_SERVICES_CA/ca.srl"
BROKER_DIR="$TAPIR_SERVICES_CA/mosquitto"
BRIDGE_DIR="$TAPIR_SERVICES_CA/mqtt-bridge"

mkdir -p "$BROKER_DIR" "$BRIDGE_DIR"

if [ ! -s "$CA_KEY" ] || [ ! -s "$CA_CERT" ]; then
  test ! -e "$CA_KEY"
  test ! -e "$CA_CERT"
  echo "creating a new CA"
  openssl genpkey -algorithm Ed25519 -out "$CA_KEY"
  openssl req -x509 -new -key "$CA_KEY" -out "$CA_CERT" -days 3650 \
    -subj '/CN=DNS TAPIR test MQTT CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign'
else
  echo "reusing the existing CA"
fi

issue_broker=0
if [ ! -s "$BROKER_DIR/server.crt" ]; then
  issue_broker=1
elif ! openssl x509 -in "$BROKER_DIR/server.crt" -noout -text \
     | grep -c "IP Address:$TAPIR_CORE_VM_IP" >/dev/null; then
  echo "broker certificate does not carry $TAPIR_CORE_VM_IP; reissuing"
  issue_broker=1
fi

if [ "$issue_broker" -eq 1 ]; then
  cat > "$BROKER_DIR/server.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:mosquitto,DNS:dnstapir-core,IP:$TAPIR_CORE_VM_IP
EXT
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$BROKER_DIR/server.key" -out "$BROKER_DIR/server.csr" \
    -subj '/CN=dnstapir-core'
  openssl x509 -req -in "$BROKER_DIR/server.csr" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAserial "$CA_SERIAL" -CAcreateserial \
    -out "$BROKER_DIR/server.crt" -days 825 -extfile "$BROKER_DIR/server.ext"
  rm -f "$BROKER_DIR/server.csr" "$BROKER_DIR/server.ext"
fi

if [ ! -s "$BRIDGE_DIR/client.crt" ]; then
  cat > "$BRIDGE_DIR/client.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectAltName=DNS:mqtt-bridge.core.test
EXT
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$BRIDGE_DIR/client.key" -out "$BRIDGE_DIR/client.csr" \
    -subj '/CN=mqtt-bridge.core.test'
  openssl x509 -req -in "$BRIDGE_DIR/client.csr" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAserial "$CA_SERIAL" -CAcreateserial \
    -out "$BRIDGE_DIR/client.crt" -days 825 -extfile "$BRIDGE_DIR/client.ext"
  rm -f "$BRIDGE_DIR/client.csr" "$BRIDGE_DIR/client.ext"
fi

chmod 0600 "$CA_KEY" "$BROKER_DIR/server.key" "$BRIDGE_DIR/client.key"
chmod 0644 "$CA_CERT" "$BROKER_DIR/server.crt" "$BRIDGE_DIR/client.crt"

openssl verify -CAfile "$CA_CERT" "$BROKER_DIR/server.crt"
openssl verify -CAfile "$CA_CERT" "$BRIDGE_DIR/client.crt"

# The MQTT signing key: Core signs downbound observations with the private half
# and every policy processor verifies against the public half. It lives here so
# that a Core rebuild does not invalidate processors that already trust it.
SIGNER_DIR="$TAPIR_SERVICES_CA/mqtt-signer"
mkdir -p "$SIGNER_DIR"
chmod 0700 "$SIGNER_DIR"

if [ ! -s "$SIGNER_DIR/mqtt-signer.json" ]; then
  echo "creating the MQTT signing key"
  SIGNER_TMP="$(mktemp -d)"
  openssl genpkey -algorithm Ed25519 -out "$SIGNER_TMP/k.pem"
  openssl pkey -in "$SIGNER_TMP/k.pem" -outform DER -out "$SIGNER_TMP/priv.der"
  openssl pkey -in "$SIGNER_TMP/k.pem" -pubout -outform DER -out "$SIGNER_TMP/pub.der"
  # For Ed25519 both PKCS#8 and SPKI carry the 32-byte key in their last 32
  # bytes, so a JWK needs no tooling beyond the standard library.
  python3 - "$SIGNER_TMP" "$SIGNER_DIR" core-mqtt-signer <<'PYSIGNER'
import base64, json, pathlib, sys
tmp, out, kid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
d = (tmp / "priv.der").read_bytes()[-32:]
x = (tmp / "pub.der").read_bytes()[-32:]
common = {"kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid}
(out / "mqtt-signer.json").write_text(json.dumps({**common, "d": b64(d), "x": b64(x)}))
(out / "mqtt-signer-pub.json").write_text(json.dumps({**common, "x": b64(x)}))
PYSIGNER
  rm -rf "$SIGNER_TMP"
else
  echo "reusing the existing MQTT signing key"
fi

chmod 0600 "$SIGNER_DIR/mqtt-signer.json"
chmod 0644 "$SIGNER_DIR/mqtt-signer-pub.json"
python3 -c "
import json, sys
p = json.load(open(sys.argv[1])); q = json.load(open(sys.argv[2]))
assert p['kty'] == 'OKP' and p['crv'] == 'Ed25519' and p['alg'] == 'EdDSA'
assert 'd' in p and 'd' not in q and p['x'] == q['x']
print('signing key ok, kid', p['kid'])
" "$SIGNER_DIR/mqtt-signer.json" "$SIGNER_DIR/mqtt-signer-pub.json"
openssl x509 -in "$BROKER_DIR/server.crt" -noout -subject -dates -ext subjectAltName

# -- Runbook section 7: credentials and configuration ------------------------
step "credentials and configuration"

DATA_DIR="$TAPIR_SERVICES_RUN/data-services"
CREDS="$TAPIR_SERVICES_KEYS/service-credentials.env"
COMPOSE="$DATA_DIR/compose.yaml"

mkdir -p "$DATA_DIR"

if [ ! -s "$CREDS" ]; then
  echo "generating service credentials"
  ( umask 077
    {
      printf 'TAPIR_MONGO_ROOT_USER=root\n'
      printf 'TAPIR_MONGO_ROOT_PASSWORD=%s\n'       "$(openssl rand -hex 24)"
      printf 'TAPIR_MONGO_NODEMAN_PASSWORD=%s\n'    "$(openssl rand -hex 24)"
      printf 'TAPIR_MONGO_AGGREC_PASSWORD=%s\n'     "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_ENCODER_PASSWORD=%s\n'     "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_LOOPTEST_PASSWORD=%s\n'    "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_NEWQNAME_PASSWORD=%s\n'    "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_LISTCHECKER_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_BRIDGE_PASSWORD=%s\n'      "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_AGGREC_PASSWORD=%s\n'      "$(openssl rand -hex 24)"
      printf 'TAPIR_S3_ACCESS_KEY_ID=%s\n'          "$(openssl rand -hex 12)"
      printf 'TAPIR_S3_SECRET_ACCESS_KEY=%s\n'      "$(openssl rand -hex 24)"
    } > "$CREDS"
  )
else
  echo "reusing the existing service credentials"
fi
chmod 0600 "$CREDS"
# Exported, so the values reach "docker compose exec -e VAR" explicitly.
set -a
# shellcheck disable=SC1090
. "$CREDS"
set +a

cat > "$DATA_DIR/nats.conf" <<NATSCONF
listen: 0.0.0.0:4222
http: 0.0.0.0:8222

jetstream {
  store_dir: "/data/jetstream"
}

accounts {
  A: {
    jetstream: enabled
    users: [
      { user: encoder,     password: "$TAPIR_NATS_ENCODER_PASSWORD" }
      { user: looptest,    password: "$TAPIR_NATS_LOOPTEST_PASSWORD" }
      { user: newqname,    password: "$TAPIR_NATS_NEWQNAME_PASSWORD" }
      { user: listchecker, password: "$TAPIR_NATS_LISTCHECKER_PASSWORD" }
      { user: bridge,      password: "$TAPIR_NATS_BRIDGE_PASSWORD" }
      { user: aggrec,      password: "$TAPIR_NATS_AGGREC_PASSWORD" }
    ]
  }
}
NATSCONF
chmod 0600 "$DATA_DIR/nats.conf"

cat > "$COMPOSE" <<COMPOSEFILE
services:
  mongo:
    image: mongo:latest
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: \${TAPIR_MONGO_ROOT_USER}
      MONGO_INITDB_ROOT_PASSWORD: \${TAPIR_MONGO_ROOT_PASSWORD}
    ports:
      - "0.0.0.0:27017:27017/tcp"
    volumes:
      - mongo-data:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "quit(db.adminCommand({ ping: 1 }).ok ? 0 : 2)"]
      interval: 5s
      timeout: 5s
      retries: 30

  nats:
    image: nats:alpine3.22
    user: "0:0"
    restart: unless-stopped
    command: ["--config", "/etc/nats/nats.conf"]
    ports:
      - "0.0.0.0:4222:4222/tcp"
      - "127.0.0.1:8222:8222/tcp"
    volumes:
      - nats-jetstream:/data/jetstream
      - $DATA_DIR/nats.conf:/etc/nats/nats.conf:ro
    healthcheck:
      test: ["CMD-SHELL", "busybox wget http://127.0.0.1:8222/healthz -O - | grep ok"]
      interval: 5s
      timeout: 5s
      retries: 30

  s3:
    image: rustfs/rustfs:latest
    restart: unless-stopped
    command: |
      /data
      --address :9000
      --console-enable
      --console-address :9001
      --access-key \${TAPIR_S3_ACCESS_KEY_ID}
      --secret-key \${TAPIR_S3_SECRET_ACCESS_KEY}
    ports:
      - "0.0.0.0:9000:9000/tcp"
      - "127.0.0.1:9001:9001/tcp"
    volumes:
      - rustfs-data:/data

volumes:
  mongo-data:
  nats-jetstream:
  rustfs-data:
COMPOSEFILE
chmod 0600 "$COMPOSE"

# Left by an earlier layout that seeded the users through
# /docker-entrypoint-initdb.d. It holds two service passwords and nothing reads
# it any more. Removed only after the compose file above stopped mounting it,
# so docker cannot recreate the path as a directory.
rm -f "$DATA_DIR/mongo-init.js"

compose() { docker compose --file "$COMPOSE" --env-file "$CREDS" "$@"; }
compose config >/dev/null

# -- Runbook section 8: start and verify -------------------------------------
step "starting the persistent services"

compose pull --quiet
compose up -d mongo nats s3

for attempt in $(seq 1 60); do
  if compose ps --format '{{.Service}} {{.Health}}' \
    | grep -c '^mongo healthy$' >/dev/null; then
    break
  fi
  sleep 2
done
compose ps --format '{{.Service}} {{.Health}}' | grep -c '^mongo healthy$' >/dev/null \
  || { echo "MongoDB did not become healthy" >&2; compose logs --tail=50 mongo >&2; exit 1; }

for attempt in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8222/healthz 2>/dev/null | grep -c ok >/dev/null; then
    break
  fi
  sleep 2
done
curl -fsS http://127.0.0.1:8222/healthz | grep -c ok >/dev/null \
  || { echo "NATS did not become healthy" >&2; compose logs --tail=50 nats >&2; exit 1; }

# aggrec creates its bucket only when storing an aggregate, but its healthcheck
# does head_bucket on every call, so make the bucket up front or the Aggregate
# Receiver reports 502 until data happens to arrive.
awscli() {
  docker run --rm --network host \
    --env AWS_ACCESS_KEY_ID="$TAPIR_S3_ACCESS_KEY_ID" \
    --env AWS_SECRET_ACCESS_KEY="$TAPIR_S3_SECRET_ACCESS_KEY" \
    --env AWS_DEFAULT_REGION=us-east-1 \
    amazon/aws-cli:latest --endpoint-url http://127.0.0.1:9000 "$@"
}
awscli s3api create-bucket --bucket aggregates >/dev/null 2>&1 || true
awscli s3api head-bucket --bucket aggregates >/dev/null
echo "aggregates bucket present"

# The per-service users are created here rather than through
# /docker-entrypoint-initdb.d. That hook runs as the mongodb account after the
# entrypoint drops privileges, so it cannot read a mode-0600 file owned by the
# service account, and it only runs at all on an empty data volume. Doing it
# here works on an existing volume too, which is what a re-run or a restore
# needs, and it keeps the passwords out of a world-readable file.
step "per-service database users"

compose exec -T \
  -e TAPIR_MONGO_NODEMAN_PASSWORD -e TAPIR_MONGO_AGGREC_PASSWORD \
  mongo mongosh --quiet \
    --username "$TAPIR_MONGO_ROOT_USER" --password "$TAPIR_MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin --eval '
      const wanted = [
        { db: "nodeman",    user: "nodeman", pwd: process.env.TAPIR_MONGO_NODEMAN_PASSWORD },
        { db: "aggregates", user: "aggrec",  pwd: process.env.TAPIR_MONGO_AGGREC_PASSWORD },
      ];
      for (const w of wanted) {
        if (!w.pwd) { throw new Error("no password supplied for " + w.user); }
        const d = db.getSiblingDB(w.db);
        if (d.getUser(w.user)) {
          d.changeUserPassword(w.user, w.pwd);
          print("updated " + w.user + "@" + w.db);
        } else {
          d.createUser({ user: w.user, pwd: w.pwd, roles: [{ role: "dbOwner", db: w.db }] });
          print("created " + w.user + "@" + w.db);
        }
      }
    '

step "verification"

compose ps --format '{{.Service}} {{.State}} {{.Health}}'

printf 'jetstream store_dir: %s\n' \
  "$(curl -fsS http://127.0.0.1:8222/varz | jq -r '.jetstream.config.store_dir')"
printf 'nats auth_required:  %s\n' \
  "$(curl -fsS http://127.0.0.1:8222/varz | jq -r '.auth_required')"

curl -fsS http://127.0.0.1:8222/varz | jq -e '.auth_required == true' >/dev/null \
  || { echo "NATS is not requiring authentication" >&2; exit 1; }

# The per-service MongoDB user must be able to reach its own database.
compose exec -T mongo mongosh --quiet \
  --username nodeman --password "$TAPIR_MONGO_NODEMAN_PASSWORD" \
  --authenticationDatabase nodeman \
  --eval 'db.getSiblingDB("nodeman").stats().db' \
  || { echo "the nodeman MongoDB user cannot reach its database" >&2; exit 1; }

# ... and must not be able to reach the other one.
if compose exec -T mongo mongosh --quiet \
  --username nodeman --password "$TAPIR_MONGO_NODEMAN_PASSWORD" \
  --authenticationDatabase nodeman \
  --eval 'db.getSiblingDB("aggregates").stats().db' >/dev/null 2>&1; then
  echo "the nodeman user can read the aggregates database; roles were not applied" >&2
  exit 1
fi
echo "per-database MongoDB roles are in force"

# -- Runbook section 10: the Core handover bundle ----------------------------
step "handover bundle"

BUNDLE_DIR="$TAPIR_SERVICES_HANDOVER/core"
BUNDLE="$TAPIR_SERVICES_HANDOVER/core-handover.tar.gz"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/ca"
chmod -R 0700 "$BUNDLE_DIR"

install -m 0600 "$CA_KEY"                 "$BUNDLE_DIR/ca/ca.key"
install -m 0644 "$CA_CERT"                "$BUNDLE_DIR/ca/ca.crt"
install -m 0644 "$BROKER_DIR/server.crt"  "$BUNDLE_DIR/ca/server.crt"
install -m 0600 "$BROKER_DIR/server.key"  "$BUNDLE_DIR/ca/server.key"
install -m 0644 "$BRIDGE_DIR/client.crt"  "$BUNDLE_DIR/ca/client.crt"
install -m 0600 "$BRIDGE_DIR/client.key"  "$BUNDLE_DIR/ca/client.key"
install -m 0600 "$TAPIR_SERVICES_CA/mqtt-signer/mqtt-signer.json" \
  "$BUNDLE_DIR/ca/mqtt-signer.json"
install -m 0644 "$TAPIR_SERVICES_CA/mqtt-signer/mqtt-signer-pub.json" \
  "$BUNDLE_DIR/ca/mqtt-signer-pub.json"

( umask 077
  cat > "$BUNDLE_DIR/services.env" <<BUNDLEENV
TAPIR_SERVICES_VM_IP=$TAPIR_SERVICES_VM_IP
TAPIR_SERVICES_MONGO_NODEMAN_URL=mongodb://nodeman:$TAPIR_MONGO_NODEMAN_PASSWORD@$TAPIR_SERVICES_VM_IP:27017/nodeman
TAPIR_SERVICES_MONGO_AGGREC_URL=mongodb://aggrec:$TAPIR_MONGO_AGGREC_PASSWORD@$TAPIR_SERVICES_VM_IP:27017/aggregates
TAPIR_SERVICES_NATS_ENCODER_URL=nats://encoder:$TAPIR_NATS_ENCODER_PASSWORD@$TAPIR_SERVICES_VM_IP:4222
TAPIR_SERVICES_NATS_LOOPTEST_URL=nats://looptest:$TAPIR_NATS_LOOPTEST_PASSWORD@$TAPIR_SERVICES_VM_IP:4222
TAPIR_SERVICES_NATS_NEWQNAME_URL=nats://newqname:$TAPIR_NATS_NEWQNAME_PASSWORD@$TAPIR_SERVICES_VM_IP:4222
TAPIR_SERVICES_NATS_LISTCHECKER_URL=nats://listchecker:$TAPIR_NATS_LISTCHECKER_PASSWORD@$TAPIR_SERVICES_VM_IP:4222
TAPIR_SERVICES_NATS_BRIDGE_URL=nats://bridge:$TAPIR_NATS_BRIDGE_PASSWORD@$TAPIR_SERVICES_VM_IP:4222
TAPIR_SERVICES_NATS_AGGREC_URL=nats://aggrec:$TAPIR_NATS_AGGREC_PASSWORD@$TAPIR_SERVICES_VM_IP:4222
TAPIR_SERVICES_S3_ENDPOINT=http://$TAPIR_SERVICES_VM_IP:9000
TAPIR_SERVICES_S3_ACCESS_KEY_ID=$TAPIR_S3_ACCESS_KEY_ID
TAPIR_SERVICES_S3_SECRET_ACCESS_KEY=$TAPIR_S3_SECRET_ACCESS_KEY
BUNDLEENV
)

tar -czf "$BUNDLE" -C "$TAPIR_SERVICES_HANDOVER" core
# 0640 in a 0750 directory: members of the service account's group can read the
# bundle without sudo, which is what the transfer to Core needs.
chmod 0640 "$BUNDLE"
rm -rf "$BUNDLE_DIR"

tar -tzf "$BUNDLE"
sha256sum "$BUNDLE"
SETUP

chown "$service_user:$service_group" "$setup_script"

log "running the unprivileged setup as $service_user"
sudo -iu "$service_user" env \
  TAPIR_SERVICES_VM_IP="$services_ip" \
  TAPIR_CORE_VM_IP="$core_ip" \
  TAPIR_SERVICES_ROOT="$services_root" \
  TAPIR_SERVICES_RUN="$services_run" \
  TAPIR_SERVICES_KEYS="$services_keys" \
  TAPIR_SERVICES_CA="$services_ca" \
  TAPIR_SERVICES_HANDOVER="$services_handover" \
  TAPIR_SERVICES_LOGS="$services_logs" \
  XDG_RUNTIME_DIR="/run/user/$service_uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$service_uid/bus" \
  DOCKER_HOST="unix:///run/user/$service_uid/docker.sock" \
  bash "$setup_script"

# ---------------------------------------------------------------------------
# 3. Firewall.
# ---------------------------------------------------------------------------
log "adding UFW rules for $core_ip"
for port in 27017 4222 9000; do
  ufw allow from "$core_ip" to any port "$port" proto tcp \
    comment "DNS TAPIR Core -> services" >/dev/null
done

firewall_active=0
if ufw status | head -n 1 | grep -c 'Status: active' >/dev/null; then
  firewall_active=1
fi

if [ "$enable_firewall" -eq 1 ] && [ "$firewall_active" -eq 0 ]; then
  # SSH first. Enabling UFW without this locks out every remote session,
  # including the one running this script.
  log "allowing SSH before activating UFW"
  ufw allow 22/tcp comment 'SSH' >/dev/null
  log "activating UFW"
  ufw --force enable
  firewall_active=1
fi

ufw status verbose | sed 's/^/  /'

# ---------------------------------------------------------------------------
# 4. Summary.
# ---------------------------------------------------------------------------
cat <<SUMMARY

$PROGNAME: done.

  services address   $services_ip
  core address       $core_ip
  service account    $service_user
  deployment root    $services_root
  handover bundle    $services_handover/core-handover.tar.gz

Next steps:

  1. Copy the handover bundle to the Core VM. Neither account has SSH trust to
     the other, so relay it through a workstation that reaches both:

       scp <admin>@$services_ip:$services_handover/core-handover.tar.gz .
       scp core-handover.tar.gz <admin>@$core_ip:/tmp/
       rm -f core-handover.tar.gz

     It holds the CA private key and every service password. Remove every
     intermediate copy once Core has unpacked it.

  2. Take a backup, per section 11 of the runbook, and copy it off this VM.
     The CA cannot be recreated: losing it invalidates every Edge certificate.

SUMMARY

if [ "$firewall_active" -eq 0 ]; then
  cat >&2 <<'UNPROTECTED'
WARNING: UFW is not active, so the rules just added are recorded but not
enforced. MongoDB on 27017, NATS on 4222 and the S3 store on 9000 are reachable
from the whole test network, with only a password in front of them and nothing
at all in front of the S3 console. The network is the only barrier in this
design; there is no second control behind it.

Activate it with:

  sudo ufw allow 22/tcp && sudo ufw enable

or re-run this script with --enable-firewall.
UNPROTECTED
fi
