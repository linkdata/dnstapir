# DNS TAPIR persistent services test deployment

**Updated:** 2026-09-10  
**Target:** one Ubuntu 24.04 LTS VM  
**Purpose:** persistent state and CA material for the Core and Edge test VMs

> **Validation status.** The Core and Edge runbooks in this directory were run
> end to end against real VMs. This one has not been. The CA procedure in
> Section 6 is lifted unchanged from the validated Core runbook; the rest is
> written to the same conventions but should be treated as a bring-up exercise
> rather than a replay.

## 1. Scope and topology

This VM holds everything that must outlive a Core or Edge reinstall: the
certificate authority, the databases, the message-bus storage, and the object
store. Core and Edge become disposable, rebuilt from source at any commit, while
node identities, enrolled signing keys, JetStream buckets, and stored aggregates
stay here.

Three VMs:

| VM | Rebuilt from | Holds state |
|---|---|---|
| Services (this runbook) | This runbook, rarely | **Yes** — CA, MongoDB, JetStream, S3 objects |
| Core | `DNS-TAPIR-Core-install-runbook.md`, freely | No |
| Edge | `DNS-TAPIR-Edge-DNSTAP-receiver-runbook.md`, freely | Only its enrolled credentials |

This VM runs three services and holds one set of files:

- **MongoDB** — NodeMan node records and enrolled signing JWKs, plus Aggregate
  Receiver metadata. SCRAM authentication with one user per consuming service.
- **NATS with JetStream** — the analysis bus and its KV buckets, on a named
  volume instead of inside the container.
- **RustFS** — S3-compatible storage for aggregates, standing in for the S3
  bucket a deployed Core uses.
- **The CA and the MQTT signing key** — the issuer key and certificate NodeMan
  needs to enroll and renew Edge nodes, the Mosquitto and `mqtt-bridge`
  certificates Core runs with, and the key Core signs downbound observations
  with. These are files, not a service. Generating them here and handing Core a
  copy is what lets Core be rebuilt without invalidating every Edge.

Mosquitto stays on the Core VM: it holds no state, and it is the port the Edge
firewall rule targets.

The Edge VM never contacts this host. It reaches Core's NodeMan and Mosquitto
only, and receives the CA certificate it needs through enrollment.

All privileged setup is in one script next to this runbook,
`dnstapir-host-bootstrap.sh`, which Section 3 invokes. The Core and Edge runbooks
use the same script with different arguments, so all three hosts are bootstrapped
identically. Every step after Section 3 runs unprivileged as `dnstapir`.

### The security model, and why it looks thin

This deployment deliberately mirrors the posture of the deployed DNS TAPIR
environment rather than improving on it. A test bed hardened beyond what runs in
practice exercises a configuration nobody operates, and hides the failure modes
that matter.

| Path | Transport | Authentication |
|---|---|---|
| Edge → Core Mosquitto | TLS 1.3 | **Client certificate**, plus a topic ACL |
| NodeMan → Edge enrollment | HTTP on the test network | Single-use enrollment key |
| Core services → NATS | Plaintext | Username and password in the URL |
| Core services → MongoDB | Plaintext | SCRAM, one user per service |
| Core aggrec → RustFS | Plaintext | S3 access keys |

**The network is the barrier for everything except MQTT.** NATS, MongoDB and
RustFS are reachable only from the Core VM address, enforced by the Section 9
firewall rules. That is the same arrangement a deployed Core relies on, where the
equivalent services sit behind an internal load balancer inside a cluster
boundary.

Two consequences follow, and they are worth stating rather than discovering:

- **If the firewall is off, there is no second control.** A host that reaches
  port 4222 with a password has full publish, subscribe and JetStream rights,
  including deleting the KV buckets this VM exists to preserve. Section 9 checks
  that UFW is actually active for exactly this reason.
- **Core is fully trusted with this VM's state.** Core is the disposable machine
  running bleeding-edge code, and it holds credentials granting complete access
  here. A broken Core can destroy the data a rebuild is supposed to protect, so
  Section 11's backup is not optional ceremony.

Client certificates are not used for NATS because no DNS TAPIR component can
present one: both consumers call `nats.Connect` with a URL and no options, in
`mqtt-bridge/inject/nats/nats.go` and `tapir-analyse-lib/nats/nats.go`. Every
credential mechanism beyond URL userinfo — `RootCAs`, `ClientCert`,
`UserCredentials`, `Nkey` — is a connection option those call sites never pass.
Closing that would be an upstream change in two repositories, not a configuration
change here.

Where the code *does* support identity, this runbook uses it: per-service SCRAM
users in MongoDB, per-service NATS users, and certificate-authenticated MQTT with
a topic ACL confining each Edge to its own node name.

### This is not a production services host

Everything here is single-instance: one MongoDB rather than a replica set, one
NATS rather than a three-node cluster, a local object store rather than S3, and
no secret management beyond mode-0600 files. Passwords are generated once and
never rotated. The CA is a test CA whose key sits unencrypted on disk.

For a real deployment, start from the official documentation instead:

- [DNS TAPIR technical documentation](https://dnstapir.github.io/techdocs)
- [Core communication patterns](https://dnstapir.github.io/techdocs/core-comms.html)
  and [NATS usage](https://dnstapir.github.io/techdocs/nats-usage.html)
- The `dnstapir/tapir-deploy` repository holds the Helm charts and Kubernetes
  manifests Core is actually deployed from. It is private, so ask the DNS TAPIR
  operators for access rather than expecting the link to resolve.

## 2. Accounts, variables, and host checklist

| Label | Account | Work |
|---|---|---|
| `[services-admin]` | Existing VM administrator with `sudo` | Install packages, create the service account, configure Rootless Docker, set firewall rules |
| `[services-service]` | `dnstapir`, no `sudo`, not in `docker` group | Own the CA and service data, run Rootless Docker, operate the services |
| `[core-service]` | Existing Core `dnstapir` account | Receive the handover bundle from Section 10 |

The examples use documentation addresses. As `[services-admin]`, replace them
with the fixed addresses on the test network, then set every variable before
using it:

```bash
export TAPIR_SERVICES_VM_IP=192.0.2.30
export TAPIR_CORE_VM_IP=192.0.2.10

export TAPIR_SERVICES_SERVICE_USER=dnstapir
export TAPIR_SERVICES_ROOT=/opt/dnstapir-services
export TAPIR_SERVICES_RUN="$TAPIR_SERVICES_ROOT/run"
export TAPIR_SERVICES_KEYS="$TAPIR_SERVICES_ROOT/keys"
export TAPIR_SERVICES_CA="$TAPIR_SERVICES_ROOT/ca"
export TAPIR_SERVICES_HANDOVER="$TAPIR_SERVICES_ROOT/handover"
export TAPIR_SERVICES_LOGS="$TAPIR_SERVICES_ROOT/logs"
```

Section 3 installs the same variables in the `dnstapir` login environment, so
they are set automatically in every later service-account shell.

Port allocation on this host:

| Port | Service | Bound to |
|---|---|---|
| 27017 | MongoDB | `0.0.0.0` |
| 4222 | NATS client | `0.0.0.0` |
| 8222 | NATS monitoring | `127.0.0.1` |
| 9000 | RustFS S3 | `0.0.0.0` |
| 9001 | RustFS console | `127.0.0.1` |

Checklist:

- [ ] Ubuntu 24.04 LTS host or VM
- [ ] 2 CPU cores
- [ ] 4 GiB RAM
- [ ] 40 GiB free disk space, most of it for JetStream and S3 objects
- [ ] Existing administrator account with `sudo`
- [ ] The name `dnstapir` is available for a new service account
- [ ] `TAPIR_SERVICES_VM_IP` and `TAPIR_CORE_VM_IP` are this network's fixed addresses
- [ ] Internet access to Docker Hub
- [ ] Ports 4222, 8222, 9000, 9001, and 27017 are free
- [ ] UFW is installed, because it is the only barrier in front of these services

Check the host:

```bash
lsb_release -d
nproc
free -h
df -h /
printf 'Services VM address: %s\n' "$TAPIR_SERVICES_VM_IP"
printf 'Core VM address:     %s\n' "$TAPIR_CORE_VM_IP"
sudo ss -lntp | grep -E ':(4222|8222|9000|9001|27017)\b' || true
```

## 3. Bootstrap the host as `[services-admin]`

`dnstapir-host-bootstrap.sh` installs the operating-system and Docker packages,
removes the distribution Docker packages that conflict with Docker's own, loads
`nf_tables`, creates the `dnstapir` service account with its subordinate ID
ranges, installs the Rootless Docker prerequisites, creates the directory layout,
writes the service account's login environment, and hands the Docker daemon over
to that account.

The script is idempotent, so it is safe to re-run after a partial failure. Read
`--help` for the full option list, and add `--dry-run` to see what a given
invocation would do without changing anything.

The variables set in Section 2 supply the values, so run this from the same
shell:

```bash
set -euo pipefail

sudo ./dnstapir-host-bootstrap.sh \
  --env-file .dnstapir-services-env \
  --service-user "$TAPIR_SERVICES_SERVICE_USER" \
  --subid-start 493216 \
  --extra-packages "jq openssl" \
  --dir "0755:$TAPIR_SERVICES_ROOT" \
  --dir "0755:$TAPIR_SERVICES_RUN" \
  --dir "0700:$TAPIR_SERVICES_KEYS" \
  --dir "0700:$TAPIR_SERVICES_CA" \
  --dir "0750:$TAPIR_SERVICES_HANDOVER" \
  --dir "0755:$TAPIR_SERVICES_LOGS" \
  <<EOF
TAPIR_SERVICES_VM_IP=$TAPIR_SERVICES_VM_IP
TAPIR_CORE_VM_IP=$TAPIR_CORE_VM_IP
TAPIR_SERVICES_ROOT=$TAPIR_SERVICES_ROOT
TAPIR_SERVICES_RUN=$TAPIR_SERVICES_RUN
TAPIR_SERVICES_KEYS=$TAPIR_SERVICES_KEYS
TAPIR_SERVICES_CA=$TAPIR_SERVICES_CA
TAPIR_SERVICES_HANDOVER=$TAPIR_SERVICES_HANDOVER
TAPIR_SERVICES_LOGS=$TAPIR_SERVICES_LOGS
EOF
```

The heredoc is expanded by the administrator's shell, so the login environment
receives the values set in Section 2. `XDG_RUNTIME_DIR`,
`DBUS_SESSION_BUS_ADDRESS` and `DOCKER_HOST` are appended by the script, because
they depend on the service account's UID.

`--subid-start 493216` keeps this host's subordinate ID range clear of the ones
the Core and Edge runbooks allocate, which matters only if the roles ever share a
host.

Do not add `dnstapir` to the `docker` group. Membership of that group is
equivalent to root, and the script refuses to continue if the account is in it.

## 4. Verify the host bootstrap as `[services-admin]`

```bash
set -euo pipefail

id "$TAPIR_SERVICES_SERVICE_USER"
id -nG "$TAPIR_SERVICES_SERVICE_USER" | tr ' ' '\n' | grep -cx docker >/dev/null \
  && { echo "service account is in the docker group" >&2; exit 1; } || true
systemctl is-enabled docker.service || true
loginctl show-user "$TAPIR_SERVICES_SERVICE_USER" --property=Linger

for d in "$TAPIR_SERVICES_ROOT" "$TAPIR_SERVICES_RUN" "$TAPIR_SERVICES_KEYS" \
         "$TAPIR_SERVICES_CA" "$TAPIR_SERVICES_HANDOVER" "$TAPIR_SERVICES_LOGS"; do
  stat -c '%n %U:%G %a' "$d"
done

command -v newuidmap newgidmap slirp4netns
```

`systemctl is-enabled docker.service` must report `disabled`: the system-wide
daemon is replaced by the service account's rootless one. `$TAPIR_SERVICES_KEYS`
and `$TAPIR_SERVICES_CA` must be mode `0700` and owned by the service account.
`$TAPIR_SERVICES_HANDOVER` is `0750` instead, so that members of the service
account's group can collect the bundle without `sudo`.

## 5. Enter the service account as `[services-service]`

Every command from this point through Section 13 runs as `dnstapir` without
`sudo`, except Section 9, which is labelled `[services-admin]`.

```bash
sudo -iu dnstapir
```

```bash
set -euo pipefail

id
printf 'services=%s core=%s\n' "$TAPIR_SERVICES_VM_IP" "$TAPIR_CORE_VM_IP"
systemctl --user is-active docker.service
docker context use rootless || true
docker info --format '{{.SecurityOptions}}' | grep -c rootless >/dev/null
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
```

`docker context use rootless` prints a warning that the exported `DOCKER_HOST`
overrides the selected context. That is expected: the login environment written
by Section 3 already points `DOCKER_HOST` at the same rootless socket.

## 6. Create the CA, service certificates and signing key as `[services-service]`

This is the procedure the Core runbook used to run locally, moved here so the CA
survives a Core rebuild. NodeMan needs the issuer private key to sign Edge
certificate requests, so Core receives a *copy* rather than a delegation — the
same arrangement a deployed NodeMan uses, where the key arrives as a mounted
secret.

Existing files are reused, so rerunning this block replaces nothing: not the CA
that has already issued Edge certificates, and not the key Core's broker is
running with. That property is the whole point — the CA outlives everything
else, and a re-run is how the bundle is regenerated after a Core rebuild.

```bash
set -euo pipefail

TAPIR_SERVICES_CA_KEY="$TAPIR_SERVICES_CA/ca.key"
TAPIR_SERVICES_CA_CERT="$TAPIR_SERVICES_CA/ca.crt"
TAPIR_SERVICES_CA_SERIAL="$TAPIR_SERVICES_CA/ca.srl"
TAPIR_SERVICES_BROKER_DIR="$TAPIR_SERVICES_CA/mosquitto"
TAPIR_SERVICES_BROKER_KEY="$TAPIR_SERVICES_BROKER_DIR/server.key"
TAPIR_SERVICES_BROKER_CSR="$TAPIR_SERVICES_BROKER_DIR/server.csr"
TAPIR_SERVICES_BROKER_CERT="$TAPIR_SERVICES_BROKER_DIR/server.crt"
TAPIR_SERVICES_BROKER_EXT="$TAPIR_SERVICES_BROKER_DIR/server.ext"
TAPIR_SERVICES_BRIDGE_DIR="$TAPIR_SERVICES_CA/mqtt-bridge"
TAPIR_SERVICES_BRIDGE_KEY="$TAPIR_SERVICES_BRIDGE_DIR/client.key"
TAPIR_SERVICES_BRIDGE_CSR="$TAPIR_SERVICES_BRIDGE_DIR/client.csr"
TAPIR_SERVICES_BRIDGE_CERT="$TAPIR_SERVICES_BRIDGE_DIR/client.crt"
TAPIR_SERVICES_BRIDGE_EXT="$TAPIR_SERVICES_BRIDGE_DIR/client.ext"

mkdir -p "$TAPIR_SERVICES_BROKER_DIR" "$TAPIR_SERVICES_BRIDGE_DIR"

if [ ! -s "$TAPIR_SERVICES_CA_KEY" ] || [ ! -s "$TAPIR_SERVICES_CA_CERT" ]; then
  test ! -e "$TAPIR_SERVICES_CA_KEY"
  test ! -e "$TAPIR_SERVICES_CA_CERT"
  openssl genpkey \
    -algorithm Ed25519 \
    -out "$TAPIR_SERVICES_CA_KEY"
  openssl req \
    -x509 \
    -new \
    -key "$TAPIR_SERVICES_CA_KEY" \
    -out "$TAPIR_SERVICES_CA_CERT" \
    -days 3650 \
    -subj '/CN=DNS TAPIR test MQTT CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign'
fi

# Reissued only when missing, or when the Core address changed and the
# certificate no longer carries it. Issuing a new one unconditionally would
# replace the key Core is running with every time this block is re-read.
TAPIR_SERVICES_ISSUE_BROKER=0
if [ ! -s "$TAPIR_SERVICES_BROKER_CERT" ]; then
  TAPIR_SERVICES_ISSUE_BROKER=1
elif ! openssl x509 -in "$TAPIR_SERVICES_BROKER_CERT" -noout -text \
     | grep -c "IP Address:$TAPIR_CORE_VM_IP" >/dev/null; then
  echo "broker certificate does not carry $TAPIR_CORE_VM_IP; reissuing"
  TAPIR_SERVICES_ISSUE_BROKER=1
fi

if [ "$TAPIR_SERVICES_ISSUE_BROKER" -eq 1 ]; then
  cat > "$TAPIR_SERVICES_BROKER_EXT" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:mosquitto,DNS:dnstapir-core,IP:$TAPIR_CORE_VM_IP
EOF

  openssl req \
    -new \
    -newkey ec \
    -pkeyopt ec_paramgen_curve:P-256 \
    -nodes \
    -keyout "$TAPIR_SERVICES_BROKER_KEY" \
    -out "$TAPIR_SERVICES_BROKER_CSR" \
    -subj '/CN=dnstapir-core'
  openssl x509 \
    -req \
    -in "$TAPIR_SERVICES_BROKER_CSR" \
    -CA "$TAPIR_SERVICES_CA_CERT" \
    -CAkey "$TAPIR_SERVICES_CA_KEY" \
    -CAserial "$TAPIR_SERVICES_CA_SERIAL" \
    -CAcreateserial \
    -out "$TAPIR_SERVICES_BROKER_CERT" \
    -days 825 \
    -extfile "$TAPIR_SERVICES_BROKER_EXT"
fi

if [ ! -s "$TAPIR_SERVICES_BRIDGE_CERT" ]; then
  cat > "$TAPIR_SERVICES_BRIDGE_EXT" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectAltName=DNS:mqtt-bridge.core.test
EOF

  openssl req \
    -new \
    -newkey ec \
    -pkeyopt ec_paramgen_curve:P-256 \
    -nodes \
    -keyout "$TAPIR_SERVICES_BRIDGE_KEY" \
    -out "$TAPIR_SERVICES_BRIDGE_CSR" \
    -subj '/CN=mqtt-bridge.core.test'
  openssl x509 \
    -req \
    -in "$TAPIR_SERVICES_BRIDGE_CSR" \
    -CA "$TAPIR_SERVICES_CA_CERT" \
    -CAkey "$TAPIR_SERVICES_CA_KEY" \
    -CAserial "$TAPIR_SERVICES_CA_SERIAL" \
    -CAcreateserial \
    -out "$TAPIR_SERVICES_BRIDGE_CERT" \
    -days 825 \
    -extfile "$TAPIR_SERVICES_BRIDGE_EXT"
fi

chmod 0600 \
  "$TAPIR_SERVICES_CA_KEY" \
  "$TAPIR_SERVICES_BROKER_KEY" \
  "$TAPIR_SERVICES_BRIDGE_KEY"
chmod 0644 \
  "$TAPIR_SERVICES_CA_CERT" \
  "$TAPIR_SERVICES_BROKER_CERT" \
  "$TAPIR_SERVICES_BRIDGE_CERT"

openssl verify -CAfile "$TAPIR_SERVICES_CA_CERT" "$TAPIR_SERVICES_BROKER_CERT"
openssl verify -CAfile "$TAPIR_SERVICES_CA_CERT" "$TAPIR_SERVICES_BRIDGE_CERT"
openssl x509 -in "$TAPIR_SERVICES_BROKER_CERT" \
  -noout -subject -issuer -dates -ext subjectAltName

rm -f \
  "$TAPIR_SERVICES_BROKER_CSR" \
  "$TAPIR_SERVICES_BROKER_EXT" \
  "$TAPIR_SERVICES_BRIDGE_CSR" \
  "$TAPIR_SERVICES_BRIDGE_EXT"
```

The broker certificate must carry the Core VM address as an IP subject
alternative name, because the Edge verifies the broker by address. The
`subjectAltName` line in the output above is where to check that, rather than
after an Edge fails to connect.

The certificates last 825 days and the CA 10 years, so neither needs renewing
within the life of a test deployment. Section 12 has the expiry check anyway.

### The MQTT signing key

Core signs the observations it sends down to Edge policy processors, and each
processor verifies them against the public half. That key belongs here for the
same reason the CA does: if Core generated it, a Core rebuild would produce a
new one and every enrolled policy processor would silently stop trusting the
feed — silently, because a processor with a stale key keeps running and simply
receives nothing.

It is an Ed25519 JWK. `openssl` has no JWK output, but for Ed25519 both the
PKCS#8 and SubjectPublicKeyInfo encodings carry the 32-byte key as their final
32 bytes, so no extra tooling is needed.

```bash
set -euo pipefail

TAPIR_SERVICES_SIGNER_DIR="$TAPIR_SERVICES_CA/mqtt-signer"
TAPIR_SERVICES_SIGNER_KID=core-mqtt-signer

mkdir -p "$TAPIR_SERVICES_SIGNER_DIR"
chmod 0700 "$TAPIR_SERVICES_SIGNER_DIR"

if [ ! -s "$TAPIR_SERVICES_SIGNER_DIR/mqtt-signer.json" ]; then
  TAPIR_SERVICES_SIGNER_TMP="$(mktemp -d)"
  openssl genpkey -algorithm Ed25519 -out "$TAPIR_SERVICES_SIGNER_TMP/k.pem"
  openssl pkey -in "$TAPIR_SERVICES_SIGNER_TMP/k.pem" \
    -outform DER -out "$TAPIR_SERVICES_SIGNER_TMP/priv.der"
  openssl pkey -in "$TAPIR_SERVICES_SIGNER_TMP/k.pem" \
    -pubout -outform DER -out "$TAPIR_SERVICES_SIGNER_TMP/pub.der"

  python3 - "$TAPIR_SERVICES_SIGNER_TMP" "$TAPIR_SERVICES_SIGNER_DIR" \
    "$TAPIR_SERVICES_SIGNER_KID" <<'PYSIGNER'
import base64, json, pathlib, sys
tmp, out, kid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
d = (tmp / "priv.der").read_bytes()[-32:]
x = (tmp / "pub.der").read_bytes()[-32:]
common = {"kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid}
(out / "mqtt-signer.json").write_text(json.dumps({**common, "d": b64(d), "x": b64(x)}))
(out / "mqtt-signer-pub.json").write_text(json.dumps({**common, "x": b64(x)}))
PYSIGNER

  rm -rf "$TAPIR_SERVICES_SIGNER_TMP"
fi

chmod 0600 "$TAPIR_SERVICES_SIGNER_DIR/mqtt-signer.json"
chmod 0644 "$TAPIR_SERVICES_SIGNER_DIR/mqtt-signer-pub.json"

# The private key must carry d; the public half must not.
python3 -c "
import json, sys
p = json.load(open(sys.argv[1])); q = json.load(open(sys.argv[2]))
assert p['kty'] == 'OKP' and p['crv'] == 'Ed25519' and p['alg'] == 'EdDSA'
assert 'd' in p and 'd' not in q and p['x'] == q['x'] and p['kid'] == q['kid']
print('signing key ok, kid', p['kid'])
" "$TAPIR_SERVICES_SIGNER_DIR/mqtt-signer.json" \
  "$TAPIR_SERVICES_SIGNER_DIR/mqtt-signer-pub.json"
```

Like the CA, this block reuses an existing key rather than replacing one that
enrolled processors already trust.

## 7. Write the persistent services configuration as `[services-service]`

Generate the credentials, then write the MongoDB initialisation script, the NATS
configuration, and the Compose file.

Each consuming service gets its own MongoDB user with `dbOwner` on only its own
database, and its own NATS user. A deployed Core does the same for MongoDB. For
NATS it uses fewer accounts than there are services; one per service costs
nothing here and means `connz` can tell you which component published something,
which matters when the point of the environment is end-to-end debugging.

```bash
set -euo pipefail

TAPIR_SERVICES_DATA_DIR="$TAPIR_SERVICES_RUN/data-services"
TAPIR_SERVICES_CREDS="$TAPIR_SERVICES_KEYS/service-credentials.env"

mkdir -p "$TAPIR_SERVICES_DATA_DIR"

if [ ! -s "$TAPIR_SERVICES_CREDS" ]; then
  ( umask 077
    {
      printf 'TAPIR_MONGO_ROOT_USER=root\n'
      printf 'TAPIR_MONGO_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_MONGO_NODEMAN_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_MONGO_AGGREC_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_ENCODER_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_LOOPTEST_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_NEWQNAME_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_LISTCHECKER_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_BRIDGE_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_NATS_AGGREC_PASSWORD=%s\n' "$(openssl rand -hex 24)"
      printf 'TAPIR_S3_ACCESS_KEY_ID=%s\n' "$(openssl rand -hex 12)"
      printf 'TAPIR_S3_SECRET_ACCESS_KEY=%s\n' "$(openssl rand -hex 24)"
    } > "$TAPIR_SERVICES_CREDS"
  )
fi
chmod 0600 "$TAPIR_SERVICES_CREDS"
# Exported, so the values reach "docker compose exec -e VAR" explicitly.
set -a
# shellcheck disable=SC1090
. "$TAPIR_SERVICES_CREDS"
set +a

cat > "$TAPIR_SERVICES_DATA_DIR/nats.conf" <<EOF
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
EOF
chmod 0600 "$TAPIR_SERVICES_DATA_DIR/nats.conf"
```

All six users share one account, so they share the same subject space and
JetStream store. That is deliberate: it matches how a deployed Core is
configured, and the analysts genuinely do read and write each other's subjects.
Per-user `permissions` blocks would be the next step if this environment ever
needed to contain a misbehaving analyst, and NATS supports them without any code
change.

```bash
set -euo pipefail

TAPIR_SERVICES_DATA_DIR="$TAPIR_SERVICES_RUN/data-services"
TAPIR_SERVICES_DATA_COMPOSE="$TAPIR_SERVICES_DATA_DIR/compose.yaml"

cat > "$TAPIR_SERVICES_DATA_COMPOSE" <<EOF
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
      - $TAPIR_SERVICES_DATA_DIR/nats.conf:/etc/nats/nats.conf:ro
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
EOF
chmod 0600 "$TAPIR_SERVICES_DATA_COMPOSE"

docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_KEYS/service-credentials.env" config >/dev/null
echo "compose file is valid"
```

`nats` runs as container UID 0 so it can read the mode-0600 configuration holding
the passwords. Under Rootless Docker that maps to the unprivileged `dnstapir`
host UID, not to host root.

The per-service MongoDB users are **not** created through
`/docker-entrypoint-initdb.d`. That hook runs after the entrypoint drops
privileges to the `mongodb` account, which cannot read a mode-0600 file owned by
the service account under Rootless Docker: the entrypoint logs
`EACCES: permission denied` and then carries on, leaving a healthy MongoDB with
only the root user and a failure that surfaces much later. The hook also runs
only on an empty data volume, so it would never help a re-run or a restore.
Section 8 creates the users after startup instead.

## 8. Start the persistent services as `[services-service]`

The trap removes a partial startup. It never deletes the named volumes, because
those are the state this VM exists to keep.

```bash
set -euo pipefail

TAPIR_SERVICES_DATA_COMPOSE="$TAPIR_SERVICES_RUN/data-services/compose.yaml"
TAPIR_SERVICES_CREDS="$TAPIR_SERVICES_KEYS/service-credentials.env"
TAPIR_SERVICES_STARTUP_LOG="$TAPIR_SERVICES_LOGS/startup.log"

# Compose reads the credentials through --env-file, but the bucket creation
# below passes two of them to a container of its own, so this shell needs them.
# shellcheck disable=SC1090
. "$TAPIR_SERVICES_CREDS"

compose() {
  docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
    --env-file "$TAPIR_SERVICES_CREDS" "$@"
}

tapir_services_started=0
tapir_services_cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$tapir_services_started" -eq 0 ]; then
    compose logs --no-color --tail=200 > "$TAPIR_SERVICES_STARTUP_LOG" 2>&1 || true
    compose down --remove-orphans || true
    echo "startup failed; logs in $TAPIR_SERVICES_STARTUP_LOG" >&2
  fi
  return "$status"
}
trap tapir_services_cleanup EXIT

compose up -d mongo nats s3

for attempt in $(seq 1 60); do
  if compose ps --format '{{.Service}} {{.Health}}' \
    | grep -c '^mongo healthy$' >/dev/null; then
    break
  fi
  sleep 2
done
compose ps --format '{{.Service}} {{.Health}}' | grep -c '^mongo healthy$' >/dev/null

for attempt in $(seq 1 60); do
  if curl -s http://127.0.0.1:8222/healthz | grep -c ok >/dev/null; then
    break
  fi
  sleep 2
done
curl -s http://127.0.0.1:8222/healthz | grep -c ok >/dev/null

# The Aggregate Receiver only creates its bucket when it first stores an
# aggregate, but its healthcheck does head_bucket on every call. Without the
# bucket the service reports 502 until data happens to arrive, so create it
# here where the object store lives.
docker run --rm --network host \
  --env AWS_ACCESS_KEY_ID="$TAPIR_S3_ACCESS_KEY_ID" \
  --env AWS_SECRET_ACCESS_KEY="$TAPIR_S3_SECRET_ACCESS_KEY" \
  --env AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:latest --endpoint-url http://127.0.0.1:9000 \
  s3api create-bucket --bucket aggregates >/dev/null 2>&1 || true

docker run --rm --network host \
  --env AWS_ACCESS_KEY_ID="$TAPIR_S3_ACCESS_KEY_ID" \
  --env AWS_SECRET_ACCESS_KEY="$TAPIR_S3_SECRET_ACCESS_KEY" \
  --env AWS_DEFAULT_REGION=us-east-1 \
  amazon/aws-cli:latest --endpoint-url http://127.0.0.1:9000 \
  s3api head-bucket --bucket aggregates >/dev/null

compose ps
tapir_services_started=1
trap - EXIT
echo "persistent services are running"
```

Create the per-service database users. This is idempotent: it updates the
password if the user already exists, so it is also how a credential change is
applied to an existing deployment.

```bash
set -euo pipefail

TAPIR_SERVICES_DATA_COMPOSE="$TAPIR_SERVICES_RUN/data-services/compose.yaml"
TAPIR_SERVICES_CREDS="$TAPIR_SERVICES_KEYS/service-credentials.env"
set -a
# shellcheck disable=SC1090
. "$TAPIR_SERVICES_CREDS"
set +a

docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_CREDS" exec -T \
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
    ' < /dev/null
```

Confirm the per-service accounts exist and JetStream is storing outside the
container:

```bash
set -euo pipefail

TAPIR_SERVICES_DATA_COMPOSE="$TAPIR_SERVICES_RUN/data-services/compose.yaml"
TAPIR_SERVICES_CREDS="$TAPIR_SERVICES_KEYS/service-credentials.env"
# shellcheck disable=SC1090
. "$TAPIR_SERVICES_CREDS"

curl -s http://127.0.0.1:8222/varz | jq -r '.jetstream.config.store_dir'
curl -s http://127.0.0.1:8222/varz | jq -r '.auth_required'

docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_CREDS" exec -T mongo \
  mongosh --quiet \
    --username "$TAPIR_MONGO_ROOT_USER" \
    --password "$TAPIR_MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval 'db.getSiblingDB("nodeman").getUsers().users.map(u => u.user + "@" + u.db)' \
    < /dev/null

docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_CREDS" exec -T mongo \
  mongosh --quiet \
    --username nodeman \
    --password "$TAPIR_MONGO_NODEMAN_PASSWORD" \
    --authenticationDatabase nodeman \
    --eval 'db.getSiblingDB("nodeman").stats().db' < /dev/null

# ... and must not reach the other one. The roles are the only thing keeping
# these two services apart, so assert the negative rather than assuming it.
if docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_CREDS" exec -T mongo \
  mongosh --quiet \
    --username nodeman \
    --password "$TAPIR_MONGO_NODEMAN_PASSWORD" \
    --authenticationDatabase nodeman \
    --eval 'db.getSiblingDB("aggregates").stats().db' </dev/null >/dev/null 2>&1
then
  echo "the nodeman user can read the aggregates database" >&2
  exit 1
fi
echo "per-database roles are in force"
```

`auth_required` must be `true`. The two `mongosh` calls are a pair: the first
proves the per-service user reaches its own database, the second that it reaches
no other. A user that can read both means `dbOwner` was granted on `admin`
somewhere, not on the single database named here.

## 9. Permit access from the Core VM as `[services-admin]`

Open a second shell as the administrator. Only the Core VM needs these ports; the
Edge VM never contacts this host.

**This is the only barrier in front of MongoDB, NATS and RustFS.** Confirm UFW is
active rather than assuming it, because the rules are recorded either way and an
inactive firewall leaves all three services open to the whole test network.

```bash
set -euo pipefail

export TAPIR_CORE_VM_IP=192.0.2.10

for port in 27017 4222 9000; do
  sudo ufw allow from "$TAPIR_CORE_VM_IP" to any port "$port" proto tcp \
    comment "DNS TAPIR Core -> services"
done

sudo ufw status | head -1 | grep -c 'Status: active' >/dev/null \
  || { echo "UFW is INACTIVE: these services are unprotected" >&2; exit 1; }
sudo ufw status numbered | grep -E '27017|4222|9000' || true
```

Verify from the Core VM that the ports answer, and from any other host that they
do not.

## 10. Export the Core handover bundle as `[services-service]`

Core needs the CA key and certificate, the Mosquitto and `mqtt-bridge`
certificates, the MQTT signing key from Section 6, and the connection strings
for MongoDB, NATS and RustFS.

```bash
set -euo pipefail

TAPIR_SERVICES_CREDS="$TAPIR_SERVICES_KEYS/service-credentials.env"
TAPIR_SERVICES_BUNDLE_DIR="$TAPIR_SERVICES_HANDOVER/core"
TAPIR_SERVICES_BUNDLE="$TAPIR_SERVICES_HANDOVER/core-handover.tar.gz"

# shellcheck disable=SC1090
. "$TAPIR_SERVICES_CREDS"

rm -rf "$TAPIR_SERVICES_BUNDLE_DIR"
mkdir -p "$TAPIR_SERVICES_BUNDLE_DIR/ca"
chmod -R 0700 "$TAPIR_SERVICES_BUNDLE_DIR"

install -m 0600 "$TAPIR_SERVICES_CA/ca.key" "$TAPIR_SERVICES_BUNDLE_DIR/ca/ca.key"
install -m 0644 "$TAPIR_SERVICES_CA/ca.crt" "$TAPIR_SERVICES_BUNDLE_DIR/ca/ca.crt"
install -m 0644 "$TAPIR_SERVICES_CA/mosquitto/server.crt" \
  "$TAPIR_SERVICES_BUNDLE_DIR/ca/server.crt"
install -m 0600 "$TAPIR_SERVICES_CA/mosquitto/server.key" \
  "$TAPIR_SERVICES_BUNDLE_DIR/ca/server.key"
install -m 0644 "$TAPIR_SERVICES_CA/mqtt-bridge/client.crt" \
  "$TAPIR_SERVICES_BUNDLE_DIR/ca/client.crt"
install -m 0600 "$TAPIR_SERVICES_CA/mqtt-bridge/client.key" \
  "$TAPIR_SERVICES_BUNDLE_DIR/ca/client.key"
install -m 0600 "$TAPIR_SERVICES_CA/mqtt-signer/mqtt-signer.json" \
  "$TAPIR_SERVICES_BUNDLE_DIR/ca/mqtt-signer.json"
install -m 0644 "$TAPIR_SERVICES_CA/mqtt-signer/mqtt-signer-pub.json" \
  "$TAPIR_SERVICES_BUNDLE_DIR/ca/mqtt-signer-pub.json"

( umask 077
  cat > "$TAPIR_SERVICES_BUNDLE_DIR/services.env" <<EOF
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
EOF
)

tar -czf "$TAPIR_SERVICES_BUNDLE" -C "$TAPIR_SERVICES_HANDOVER" core
chmod 0640 "$TAPIR_SERVICES_BUNDLE"
rm -rf "$TAPIR_SERVICES_BUNDLE_DIR"

tar -tzf "$TAPIR_SERVICES_BUNDLE"
sha256sum "$TAPIR_SERVICES_BUNDLE"
```

The bundle holds the CA private key and every service password. It is mode 0640
in a 0750 directory, so anyone in the service account's group can read it —
membership of that group is therefore equivalent to holding every secret on this
host. Transfer it the way the Core runbook transfers its enrollment file, and
remove every intermediate copy once Core has unpacked it.

Neither this runbook nor the Core one creates SSH trust between the service
accounts, and each account is created with a locked password and no SSH key. A
direct `scp` therefore fails with `Permission denied (publickey,password)` unless
an administrator has provisioned a key beforehand. Relaying through an
administrator workstation that already reaches both VMs is the simpler option:

```bash
# From a workstation with SSH access to both VMs.
scp servicesadmin@192.0.2.30:/opt/dnstapir-services/handover/core-handover.tar.gz .
scp core-handover.tar.gz coreadmin@192.0.2.10:/tmp/
rm -f core-handover.tar.gz
```

Regenerating the bundle is safe and idempotent: it reads existing material and
creates no new keys or passwords. Re-run it whenever Core is rebuilt.

## 11. Backup and restore as `[services-service]`

This host is the only one holding state, so its backup is the only backup. The CA
directory matters most: losing it invalidates every Edge certificate, and no
reinstall can recreate it.

```bash
set -euo pipefail

TAPIR_SERVICES_DATA_COMPOSE="$TAPIR_SERVICES_RUN/data-services/compose.yaml"
TAPIR_SERVICES_CREDS="$TAPIR_SERVICES_KEYS/service-credentials.env"
TAPIR_SERVICES_BACKUP_DIR="$TAPIR_SERVICES_ROOT/backup/$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$TAPIR_SERVICES_BACKUP_DIR"
chmod 0700 "$TAPIR_SERVICES_BACKUP_DIR"

# shellcheck disable=SC1090
. "$TAPIR_SERVICES_CREDS"

docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_CREDS" exec -T mongo \
  mongodump --quiet --archive --gzip \
    --username "$TAPIR_MONGO_ROOT_USER" \
    --password "$TAPIR_MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
  < /dev/null \
  > "$TAPIR_SERVICES_BACKUP_DIR/mongo.archive.gz"
test -s "$TAPIR_SERVICES_BACKUP_DIR/mongo.archive.gz"

# JetStream and S3: volume copies, taken with those services stopped.
docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_CREDS" stop nats s3

for vol in $(docker volume ls --quiet | grep -E 'nats-jetstream|rustfs-data'); do
  docker run --rm \
    --volume "$vol:/from:ro" \
    --volume "$TAPIR_SERVICES_BACKUP_DIR:/to" \
    busybox:latest \
    tar -czf "/to/$vol.tar.gz" -C /from .
  test -s "$TAPIR_SERVICES_BACKUP_DIR/$vol.tar.gz"
done

docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_CREDS" start nats s3

# The CA and the credentials are plain files, not volumes.
tar -czf "$TAPIR_SERVICES_BACKUP_DIR/ca-and-keys.tar.gz" \
  -C "$TAPIR_SERVICES_ROOT" ca keys
chmod 0600 "$TAPIR_SERVICES_BACKUP_DIR"/*.gz

ls -l "$TAPIR_SERVICES_BACKUP_DIR"
```

Restoring is the same in reverse: stop the services, `tar -xzf` each archive into
a freshly created volume, restore `ca-and-keys.tar.gz` under
`$TAPIR_SERVICES_ROOT`, then `mongorestore --archive --gzip` the dump. Restore the
keys first, because the credentials in them are what the Compose file
interpolates.

Copy the backup off this VM. A backup that exists only on the host it protects is
not a backup.

## 12. Operating commands as `[services-service]`

```bash
sudo -iu dnstapir
id
printf 'services=%s core=%s\n' "$TAPIR_SERVICES_VM_IP" "$TAPIR_CORE_VM_IP"
systemctl --user is-active docker.service
docker info --format '{{.SecurityOptions}}' | grep -c rootless >/dev/null
```

Show status:

```bash
docker compose --file "$TAPIR_SERVICES_RUN/data-services/compose.yaml" \
  --env-file "$TAPIR_SERVICES_KEYS/service-credentials.env" ps
```

### After a reboot

Everything returns without intervention: the service account has systemd
lingering enabled, so Rootless Docker starts at boot, and every service declares
`restart: unless-stopped`. Convergence is not instant, so wait for the checks
rather than intervening:

```bash
set -euo pipefail

for attempt in $(seq 1 60); do
  if curl -s http://127.0.0.1:8222/healthz | grep -c ok >/dev/null; then
    break
  fi
  sleep 2
done
curl -s http://127.0.0.1:8222/healthz | grep -c ok >/dev/null && echo "NATS ok"
curl -s http://127.0.0.1:8222/varz | jq -r '.jetstream.config.store_dir'
curl -s http://127.0.0.1:8222/connz | jq -r '.connections[] | "\(.name) \(.ip)"'

docker compose --file "$TAPIR_SERVICES_RUN/data-services/compose.yaml" \
  --env-file "$TAPIR_SERVICES_KEYS/service-credentials.env" \
  ps --format '{{.Service}} {{.State}} {{.Health}}'

sudo ufw status | head -1
```

The `connz` output names which Core services are currently attached, which is the
payoff for giving each one its own NATS user.

Follow logs:

```bash
docker compose --file "$TAPIR_SERVICES_RUN/data-services/compose.yaml" \
  --env-file "$TAPIR_SERVICES_KEYS/service-credentials.env" \
  logs --follow nats mongo
```

Check the CA and Core certificate expiry. Nothing here expires within a normal
test cycle, so a failure means the clock or the files are wrong:

```bash
set -euo pipefail

openssl x509 -in "$TAPIR_SERVICES_CA/ca.crt" -noout -subject -dates
for c in mosquitto/server.crt mqtt-bridge/client.crt; do
  openssl x509 -in "$TAPIR_SERVICES_CA/$c" -noout -subject -dates
  openssl x509 -in "$TAPIR_SERVICES_CA/$c" -noout -checkend 604800 \
    || echo "$c expires within seven days"
done
```

### Stop and start

```bash
docker compose --file "$TAPIR_SERVICES_RUN/data-services/compose.yaml" \
  --env-file "$TAPIR_SERVICES_KEYS/service-credentials.env" stop

docker compose --file "$TAPIR_SERVICES_RUN/data-services/compose.yaml" \
  --env-file "$TAPIR_SERVICES_KEYS/service-credentials.env" up -d
```

Never use `down --volumes` here. It deletes every node record, every JetStream
bucket and every stored aggregate at once.

## 13. Troubleshooting as `[services-service]`

### A Core service cannot connect

Check the firewall first, then credentials. There is no TLS layer to rule out.

```bash
sudo ufw status | grep -E '27017|4222|9000' || echo "no rules"
curl -s http://127.0.0.1:8222/varz | jq -r '.auth_required'
curl -s http://127.0.0.1:8222/connz | jq -r '.connections[] | "\(.ip) \(.name)"'
```

A rejected NATS login appears in the server log as an authorization violation
naming the user, which is the fastest way to find a stale password in a Core
config.

### A MongoDB password does not work

Re-run the user-provisioning block in Section 8: it updates the password of an
existing user. To change a single user by hand:

```bash
set -euo pipefail

TAPIR_SERVICES_DATA_COMPOSE="$TAPIR_SERVICES_RUN/data-services/compose.yaml"
TAPIR_SERVICES_CREDS="$TAPIR_SERVICES_KEYS/service-credentials.env"
# shellcheck disable=SC1090
. "$TAPIR_SERVICES_CREDS"

docker compose --file "$TAPIR_SERVICES_DATA_COMPOSE" \
  --env-file "$TAPIR_SERVICES_CREDS" exec -T mongo \
  mongosh --quiet \
    --username "$TAPIR_MONGO_ROOT_USER" \
    --password "$TAPIR_MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval "db.getSiblingDB('nodeman').changeUserPassword('nodeman', '$TAPIR_MONGO_NODEMAN_PASSWORD')" \
    < /dev/null
```

Re-run Section 10 afterwards so Core's bundle carries the new value.

### A node name cannot be enrolled again

That is a Core-side condition, but it is more visible now that MongoDB survives a
Core reinstall: NodeMan soft-deletes node records, so the unique index keeps
holding a name that no longer appears in `GET /api/v1/nodes`. Section 12.7 of the
Core runbook lists the ways forward. The collection lives in this host's
`mongo-data` volume, so rebuilding Core does not clear it.

### Reclaiming disk space

JetStream and S3 grow without bound in a long-running test deployment.

```bash
curl -s http://127.0.0.1:8222/jsz | jq -r '.memory, .storage, .streams, .consumers'
docker system df -v | head -30
```

## 14. Completion checklist

- [ ] `dnstapir-host-bootstrap.sh` completed and its verification section passed
- [ ] Dedicated `dnstapir` account created with no `sudo` access
- [ ] `dnstapir` is not a member of the root-equivalent `docker` group
- [ ] Rootless Docker reports the `rootless` security option
- [ ] The CA key and certificate exist, mode 0600 and 0644
- [ ] Mosquitto and `mqtt-bridge` certificates verify against the CA
- [ ] The broker certificate carries the Core VM address as an IP SAN
- [ ] MongoDB has `nodeman` and `aggrec` users with `dbOwner` on their own database only
- [ ] NATS reports `auth_required` true and has one user per Core service
- [ ] JetStream reports a `store_dir` on the named volume, not inside the container
- [ ] The `aggregates` bucket exists, so the Aggregate Receiver's healthcheck passes
- [ ] **UFW is active** and restricts 27017, 4222 and 9000 to the Core VM address
- [ ] The ports are unreachable from any address other than the Core VM
- [ ] The handover bundle contains the CA, both Core certificates, the MQTT
      signing key, and `services.env`
- [ ] The handover directory is `0750` and the bundle `0640`, readable by the service group
- [ ] A backup has been taken and copied off this VM
- [ ] Every service declares `restart: unless-stopped` and returns after a reboot
- [ ] No procedure in this runbook uses `down --volumes`

## 15. Sources

- [DNS TAPIR technical documentation](https://dnstapir.github.io/techdocs)
- [Core communication patterns](https://dnstapir.github.io/techdocs/core-comms.html)
- [NATS usage](https://dnstapir.github.io/techdocs/nats-usage.html)
- [Node Manager](https://github.com/dnstapir/nodeman)
- [Node Manager settings schema](https://github.com/dnstapir/nodeman/blob/main/nodeman/settings.py)
- [Aggregate Receiver](https://github.com/dnstapir/aggrec)
- [MQTT bridge NATS client](https://github.com/dnstapir/mqtt-bridge/blob/main/inject/nats/nats.go)
- [Analyst NATS client](https://github.com/dnstapir/tapir-analyse-lib/blob/main/nats/nats.go)
- [NATS server authorization](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/auth_intro)
- [MongoDB SCRAM authentication](https://www.mongodb.com/docs/manual/core/security-scram/)
- [Docker Engine for Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Rootless mode](https://docs.docker.com/engine/security/rootless/)
