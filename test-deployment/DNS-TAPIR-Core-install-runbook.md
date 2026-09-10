# DNS TAPIR Core test deployment

**Updated:** 2026-09-03  
**Target:** one Ubuntu 24.04 LTS host  
**Purpose:** local testing and component validation

## 1. Scope

DNS TAPIR Core is a collection of repositories, not a single released
installer. Its public test material is split across:

- [`core-integration-test`](https://github.com/dnstapir/core-integration-test): NATS, Observation Encoder, and analysis containers;
- [`nodeman`](https://github.com/dnstapir/nodeman): node enrollment and certificate renewal;
- [`aggrec`](https://github.com/dnstapir/aggrec): aggregate ingestion, MongoDB metadata, and S3-compatible storage;
- [`mqtt-bridge`](https://github.com/dnstapir/mqtt-bridge): MQTT-to-NATS and NATS-to-MQTT bridging.

This guide installs Docker before issuing any Docker command. The host
administrator performs only the OS and account bootstrap. A dedicated
`dnstapir` account, which has neither `sudo` access nor membership in the
root-equivalent `docker` group, owns the deployment and runs all tests and
services through Rootless Docker.

Sections 7 through 10 are isolated validation sections. Each one defines its
own local variables, resets its own service state before starting, checks its
required ports, and removes its processes, containers, networks, and test
volumes when it exits. After the baseline in Sections 1–6 they can be run in any
order, but only one at a time, because the component environments reuse several
ports. Section 11 is the deliberate exception: it starts a fresh Core analysis
stack and leaves it running, and Section 12 adds the persistent enrollment and
encrypted MQTT ingress services to that stack.

This host keeps no state. MongoDB, NATS with its JetStream buckets, and the
certificate authority all live on a third VM, installed by
`DNS-TAPIR-Services-VM-runbook.md`, so Core can be rebuilt at any commit without
losing node identities, enrolled signing keys or analysis state. Sections 11 and
12 read that VM's address and credentials from the handover bundle it produces,
which must be present at `~/core-handover.tar.gz` before Section 11.

Section 7 remains self-contained: it runs `core-integration-test`'s
`sut/docker-compose.yaml` as the disposable fixture upstream intends, with its
own NATS, and tears it down again. It shares neither a NATS server nor a Compose
project with the persistent stack, so running the integration test on an
installed system is safe.

All privileged setup is in one script next to this runbook,
`dnstapir-host-bootstrap.sh`, which Section 3 invokes. The Edge runbook uses the
same script with different arguments, so the two hosts are bootstrapped
identically. Every step after Section 3 runs unprivileged as `dnstapir`.

### This is not a production deployment

This runbook exercises Core's components on one host. It is not a scaled-down
production topology, and it should not be used as a template for one.

The clearest example is the analysis stack. Section 11 runs the four analysis
containers against a single NATS node on the services VM, reached in plaintext
with a password. Production is a three-node NATS cluster with accounts and
per-service credentials, JetStream on persistent storage, and explicit resource
limits, deployed from Helm charts and Kubernetes manifests. The two are
different things, not different sizes of the same thing.

The same holds elsewhere: NodeMan's administrator password is the literal
`password`, its enrollment API is plain HTTP, the internal CA is disposable, and
every image is an unpinned `latest`. MQTT is the exception: it is encrypted and
client-authenticated with certificates. Do not expose the deployment to the
Internet or use real DNS data.

For a real deployment, start from the official documentation instead:

- [DNS TAPIR technical documentation](https://dnstapir.github.io/techdocs)
- [Core communication patterns](https://dnstapir.github.io/techdocs/core-comms.html),
  [NATS usage](https://dnstapir.github.io/techdocs/nats-usage.html), and
  [observation encodings](https://dnstapir.github.io/techdocs/observation-encodings.html)
- [DNS TAPIR Core documentation](https://www.dnstapir.se/docs/dnstapir-core/)
- The `dnstapir/tapir-deploy` repository holds the Helm charts and Kubernetes
  manifests Core is actually deployed from. It is private, so ask the DNS TAPIR
  operators for access rather than expecting the link to resolve.

## 2. Accounts, variables, and host checklist

The commands use two host accounts:

| Account | Privileges | Responsibilities |
|---|---|---|
| Existing host administrator | `sudo` | Install packages, create the service account, configure Rootless Docker, and assign the workspace |
| `dnstapir` service account | No `sudo`; not in `docker` group | Own repositories and generated files; run Rootless Docker, tests, and services |

Container processes continue to use the users defined by their upstream
images. They do not receive host accounts.

As the host administrator, set the bootstrap variables before using them:

```bash
export TAPIR_SERVICE_USER=dnstapir
export TAPIR_CORE_VM_IP=192.0.2.10
export TAPIR_TEST_ROOT=/opt/dnstapir-test
export TAPIR_SRC="$TAPIR_TEST_ROOT/src"
export TAPIR_LOGS="$TAPIR_TEST_ROOT/logs"
export TAPIR_RUN="$TAPIR_TEST_ROOT/run"
export TAPIR_TOOLS_VENV="$TAPIR_TEST_ROOT/tools-venv"
export TAPIR_UV="$TAPIR_TOOLS_VENV/bin/uv"
```

Section 3 installs the same variables in the `dnstapir` login environment, so
they are set automatically in every later service-account shell.

- [ ] Ubuntu 24.04 LTS host or VM
- [ ] 4 CPU cores
- [ ] 8 GiB RAM
- [ ] 40 GiB free disk space
- [ ] Existing host-administrator account with `sudo`
- [ ] The name `dnstapir` is available for a new service account
- [ ] `TAPIR_CORE_VM_IP` has been changed to this VM's fixed test-network address
- [ ] Internet access to GitHub, GHCR, Docker Hub, and Python package repositories
- [ ] Ports 1883, 27017, 4222, 6379, 8080, 8081, 8222, 8883, 9000, and 9001 are free

Check the host:

```bash
cat /etc/os-release
uname -m
free -h
df -h /
printf 'Core VM address: %s\n' "$TAPIR_CORE_VM_IP"
sudo ss -lntp | grep -E ':(1883|27017|4222|6379|8080|8081|8222|8883|9000|9001)\b' || true
```

## 3. Bootstrap the host as the host administrator

`dnstapir-host-bootstrap.sh` installs the operating-system and Docker packages,
removes the distribution Docker packages that conflict with Docker's own, loads
`nf_tables`, creates the `dnstapir` service account with its subordinate ID
ranges, installs the Rootless Docker prerequisites, creates the workspace,
writes the service account's login environment, and hands the Docker daemon over
to that account.

The script is idempotent, so it is safe to re-run after a partial failure. Read
`--help` for the full option list, and add `--dry-run` to see what a given
invocation would do without changing anything.

The variables set in Section 2 supply the values, so run this from the same
shell:

```bash
sudo ./dnstapir-host-bootstrap.sh \
  --service-user "$TAPIR_SERVICE_USER" \
  --subid-start 231072 \
  --extra-packages 'make' \
  --dir "0755:$TAPIR_TEST_ROOT" \
  --env-file .dnstapir-test-env <<EOF
TAPIR_SERVICE_USER=$TAPIR_SERVICE_USER
TAPIR_CORE_VM_IP=$TAPIR_CORE_VM_IP
TAPIR_TEST_ROOT=$TAPIR_TEST_ROOT
TAPIR_SRC=$TAPIR_SRC
TAPIR_LOGS=$TAPIR_LOGS
TAPIR_RUN=$TAPIR_RUN
TAPIR_TOOLS_VENV=$TAPIR_TOOLS_VENV
TAPIR_UV=$TAPIR_UV
EOF
```

The heredoc is expanded by the administrator's shell, so the login environment
receives the values set in Section 2. `XDG_RUNTIME_DIR`,
`DBUS_SESSION_BUS_ADDRESS` and `DOCKER_HOST` are appended by the script, because
they depend on the service account's UID.

`--subid-start 231072` keeps this host's subordinate ID range clear of the one
the Edge runbook allocates, which matters only if both roles ever share a host.

Do not add `dnstapir` to the `docker` group. Membership of that group is
equivalent to root, and the script refuses to continue if the account is in it.

## 4. Verify the host bootstrap as the host administrator

```bash
docker --version
docker compose version
command -v dockerd-rootless-setuptool.sh
lsmod | grep -c '^nf_tables' >/dev/null
id "$TAPIR_SERVICE_USER"
id -nG "$TAPIR_SERVICE_USER" \
  | tr ' ' '\n' \
  | grep -E '^(sudo|docker)$' || true
grep "^${TAPIR_SERVICE_USER}:" /etc/subuid
grep "^${TAPIR_SERVICE_USER}:" /etc/subgid
awk -F: -v user="$TAPIR_SERVICE_USER" \
  '$1 == user && $3 >= 65536 { found = 1 } END { exit !found }' \
  /etc/subuid
awk -F: -v user="$TAPIR_SERVICE_USER" \
  '$1 == user && $3 >= 65536 { found = 1 } END { exit !found }' \
  /etc/subgid
systemctl is-enabled docker.service || true
```

The `id -nG` command must produce no output, and `systemctl is-enabled
docker.service` must report `disabled`: the system-wide daemon is replaced by
the service account's rootless one.

## 5. Enter the service account

Every deployment, test, and runtime command from this point through Section 14
runs as `dnstapir` without `sudo`. Section 13 also shows the administrator's
login-handoff command for later sessions:

```bash
sudo -iu "$TAPIR_SERVICE_USER"
```

Verify the account and its Rootless Docker daemon. `docker context use
rootless` prints a warning that the exported `DOCKER_HOST` overrides the
selected context. That is expected here: the login environment written by
Section 3 already points `DOCKER_HOST` at the same rootless socket, so both
settings resolve to the same daemon and the warning is harmless.

```bash
test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -z "$(
  id -nG \
    | tr ' ' '\n' \
    | grep -E '^(sudo|docker)$' || true
)"

systemctl --user enable --now docker.service
docker context use rootless
docker version
docker compose version
docker info --format '{{json .SecurityOptions}}' \
  | grep -c rootless >/dev/null
docker run --rm hello-world
```

Create the service-account-owned workspace and install `uv`:

```bash
mkdir -p "$TAPIR_SRC"
mkdir -p "$TAPIR_LOGS"
mkdir -p "$TAPIR_RUN"

python3 -m venv "$TAPIR_TOOLS_VENV"
"$TAPIR_TOOLS_VENV/bin/python" -m pip install --upgrade pip
"$TAPIR_TOOLS_VENV/bin/python" -m pip install uv
"$TAPIR_UV" --version
```

## 6. Download and build all repositories as `dnstapir`

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_NODEMAN_DIR="$TAPIR_SRC/nodeman"
TAPIR_AGGREC_DIR="$TAPIR_SRC/aggrec"
TAPIR_MQTT_BRIDGE_DIR="$TAPIR_SRC/mqtt-bridge"
TAPIR_OBSERVATION_ENCODER_DIR="$TAPIR_SRC/observation-encoder"
TAPIR_LOOPTEST_DIR="$TAPIR_SRC/tapir-analyse-looptest"
TAPIR_NEW_QNAME_DIR="$TAPIR_SRC/tapir-analyse-new-qname"
TAPIR_LISTCHECKER_DIR="$TAPIR_SRC/tapir-analyse-listchecker"

if [ ! -d "$TAPIR_CORE_INTEGRATION_DIR/.git" ]; then
  git clone https://github.com/dnstapir/core-integration-test.git \
    "$TAPIR_CORE_INTEGRATION_DIR"
fi
if [ ! -d "$TAPIR_NODEMAN_DIR/.git" ]; then
  git clone https://github.com/dnstapir/nodeman.git \
    "$TAPIR_NODEMAN_DIR"
fi
if [ ! -d "$TAPIR_AGGREC_DIR/.git" ]; then
  git clone https://github.com/dnstapir/aggrec.git \
    "$TAPIR_AGGREC_DIR"
fi
if [ ! -d "$TAPIR_MQTT_BRIDGE_DIR/.git" ]; then
  git clone https://github.com/dnstapir/mqtt-bridge.git \
    "$TAPIR_MQTT_BRIDGE_DIR"
fi
if [ ! -d "$TAPIR_OBSERVATION_ENCODER_DIR/.git" ]; then
  git clone https://github.com/dnstapir/observation-encoder.git \
    "$TAPIR_OBSERVATION_ENCODER_DIR"
fi
if [ ! -d "$TAPIR_LOOPTEST_DIR/.git" ]; then
  git clone https://github.com/dnstapir/tapir-analyse-looptest.git \
    "$TAPIR_LOOPTEST_DIR"
fi
if [ ! -d "$TAPIR_NEW_QNAME_DIR/.git" ]; then
  git clone https://github.com/dnstapir/tapir-analyse-new-qname.git \
    "$TAPIR_NEW_QNAME_DIR"
fi
if [ ! -d "$TAPIR_LISTCHECKER_DIR/.git" ]; then
  git clone https://github.com/dnstapir/tapir-analyse-listchecker.git \
    "$TAPIR_LISTCHECKER_DIR"
fi

test -d "$TAPIR_CORE_INTEGRATION_DIR/.git"
test -d "$TAPIR_NODEMAN_DIR/.git"
test -d "$TAPIR_AGGREC_DIR/.git"
test -d "$TAPIR_MQTT_BRIDGE_DIR/.git"
test -d "$TAPIR_OBSERVATION_ENCODER_DIR/.git"
test -d "$TAPIR_LOOPTEST_DIR/.git"
test -d "$TAPIR_NEW_QNAME_DIR/.git"
test -d "$TAPIR_LISTCHECKER_DIR/.git"
```

Record every commit:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_NODEMAN_DIR="$TAPIR_SRC/nodeman"
TAPIR_AGGREC_DIR="$TAPIR_SRC/aggrec"
TAPIR_MQTT_BRIDGE_DIR="$TAPIR_SRC/mqtt-bridge"
TAPIR_OBSERVATION_ENCODER_DIR="$TAPIR_SRC/observation-encoder"
TAPIR_LOOPTEST_DIR="$TAPIR_SRC/tapir-analyse-looptest"
TAPIR_NEW_QNAME_DIR="$TAPIR_SRC/tapir-analyse-new-qname"
TAPIR_LISTCHECKER_DIR="$TAPIR_SRC/tapir-analyse-listchecker"
TAPIR_VERSIONS_FILE="$TAPIR_TEST_ROOT/versions.txt"

git -C "$TAPIR_CORE_INTEGRATION_DIR" rev-parse HEAD \
  | sed 's/^/core-integration-test /' \
  | tee "$TAPIR_VERSIONS_FILE"
git -C "$TAPIR_NODEMAN_DIR" rev-parse HEAD \
  | sed 's/^/nodeman /' \
  | tee -a "$TAPIR_VERSIONS_FILE"
git -C "$TAPIR_AGGREC_DIR" rev-parse HEAD \
  | sed 's/^/aggrec /' \
  | tee -a "$TAPIR_VERSIONS_FILE"
git -C "$TAPIR_MQTT_BRIDGE_DIR" rev-parse HEAD \
  | sed 's/^/mqtt-bridge /' \
  | tee -a "$TAPIR_VERSIONS_FILE"
git -C "$TAPIR_OBSERVATION_ENCODER_DIR" rev-parse HEAD \
  | sed 's/^/observation-encoder /' \
  | tee -a "$TAPIR_VERSIONS_FILE"
git -C "$TAPIR_LOOPTEST_DIR" rev-parse HEAD \
  | sed 's/^/tapir-analyse-looptest /' \
  | tee -a "$TAPIR_VERSIONS_FILE"
git -C "$TAPIR_NEW_QNAME_DIR" rev-parse HEAD \
  | sed 's/^/tapir-analyse-new-qname /' \
  | tee -a "$TAPIR_VERSIONS_FILE"
git -C "$TAPIR_LISTCHECKER_DIR" rev-parse HEAD \
  | sed 's/^/tapir-analyse-listchecker /' \
  | tee -a "$TAPIR_VERSIONS_FILE"
cat "$TAPIR_VERSIONS_FILE"
```

Build the four analysis images from the clones. Nothing in this deployment runs
a published DNS TAPIR image: Sections 7 and 11 use what is built here, and
Section 12.3 builds NodeMan and `mqtt-bridge` the same way.

Each repository is a Go program with its entry point under `./cmd`, and each
stamps its commit into `main.commit`. The multistage build below runs the unit
tests, stamps the commit, and produces an image whose entry point is the binary,
matching how the upstream `ko` build behaves and what the Compose files expect:
they set `working_dir: /work` and mount a directory holding `config.toml`, so the
binary must find its configuration in the working directory.

The base image is `fedora:42` rather than a distroless one. These images exist to
be debugged, and a shell in the image is worth more here than a few tens of
megabytes.

```bash
(
set -euo pipefail

TAPIR_BUILD_DIR="$TAPIR_TEST_ROOT/image-build"
TAPIR_IMAGES_ENV="$TAPIR_TEST_ROOT/images.env"
TAPIR_ANALYSIS_DOCKERFILE="$TAPIR_BUILD_DIR/analysis.Dockerfile"

mkdir -p "$TAPIR_BUILD_DIR"

cat > "$TAPIR_ANALYSIS_DOCKERFILE" <<'DOCKERFILE'
FROM golang:latest AS builder
ARG TAPIR_CMD
ARG TAPIR_COMMIT
WORKDIR /src
COPY . .
RUN go test ./... && \
    CGO_ENABLED=0 go build -buildvcs=false \
      -ldflags "-X main.commit=$TAPIR_COMMIT" \
      -o "/out/$TAPIR_CMD" "./cmd/$TAPIR_CMD"

FROM fedora:42
ARG TAPIR_CMD
COPY --from=builder /out/$TAPIR_CMD /usr/bin/$TAPIR_CMD
RUN ln -s /usr/bin/$TAPIR_CMD /usr/bin/tapir-entrypoint
ENTRYPOINT ["/usr/bin/tapir-entrypoint"]
DOCKERFILE

: > "$TAPIR_IMAGES_ENV"

for TAPIR_BUILD_NAME in \
  observation-encoder \
  tapir-analyse-looptest \
  tapir-analyse-new-qname \
  tapir-analyse-listchecker
do
  TAPIR_BUILD_SRC="$TAPIR_SRC/$TAPIR_BUILD_NAME"
  test -d "$TAPIR_BUILD_SRC/.git"
  TAPIR_BUILD_COMMIT="$(git -C "$TAPIR_BUILD_SRC" rev-parse HEAD)"

  docker build \
    --tag "$TAPIR_BUILD_NAME:core-source" \
    --file "$TAPIR_ANALYSIS_DOCKERFILE" \
    --build-arg "TAPIR_CMD=$TAPIR_BUILD_NAME" \
    --build-arg "TAPIR_COMMIT=$TAPIR_BUILD_COMMIT" \
    "$TAPIR_BUILD_SRC"

  docker image inspect "$TAPIR_BUILD_NAME:core-source" \
    --format '{{.Id}}' >/dev/null
done

{
  printf 'TAPIR_INTEGRATION_OBSERVATION_ENCODER_IMG=observation-encoder:core-source\n'
  printf 'TAPIR_INTEGRATION_LOOPTEST_IMG=tapir-analyse-looptest:core-source\n'
  printf 'TAPIR_INTEGRATION_NEW_QNAME_IMG=tapir-analyse-new-qname:core-source\n'
  printf 'TAPIR_INTEGRATION_LISTCHECKER_IMG=tapir-analyse-listchecker:core-source\n'
} > "$TAPIR_IMAGES_ENV"

cat "$TAPIR_IMAGES_ENV"
docker image ls --filter reference='*:core-source' \
  --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}'
)
```

`observation-encoder` builds a command whose directory name matches the
repository name, and so do the three analysts, which is why one Dockerfile with a
`TAPIR_CMD` build argument covers all four. If a future repository breaks that
convention the build fails at `./cmd/$TAPIR_CMD` rather than producing a
mislabelled image.

The image names are written to `$TAPIR_TEST_ROOT/images.env` using the variable
names the upstream Compose file already reads:

```
${TAPIR_INTEGRATION_OBSERVATION_ENCODER_IMG:-ghcr.io/dnstapir/observation-encoder:latest}
```

Sections 7 and 11 source that file, so neither needs to be edited when the images
are rebuilt at a newer commit. Re-run this block to move to a newer commit after
a `git pull`; the Compose projects pick up the new image on their next
recreation.

## 7. Run the official Core integration test as `dnstapir`

Install its Python dependencies:

```bash
(
set -euo pipefail

TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_VENV="$TAPIR_CORE_INTEGRATION_DIR/.venv"

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -d "$TAPIR_CORE_INTEGRATION_DIR/.git"
mkdir -p "$TAPIR_LOGS"

cd "$TAPIR_CORE_INTEGRATION_DIR"
python3 -m venv "$TAPIR_CORE_VENV"
"$TAPIR_CORE_VENV/bin/python" -m pip install --upgrade pip
"$TAPIR_CORE_VENV/bin/python" -m pip install -r requirements.txt
)
```

Confirm the cloned suite contains the deterministic NATS helper. Upstream
`core-integration-test` publishes each test event only after its observation
subscription is established; a clone that predates that change fails
intermittently, in whichever analyst responds fastest, with a
`nats.errors.TimeoutError` that looks like a broken deployment:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
grep -c 'async def send_event_and_check' \
  "$TAPIR_CORE_INTEGRATION_DIR/test_basic.py" >/dev/null
grep -c 'uuid.uuid4' \
  "$TAPIR_CORE_INTEGRATION_DIR/test_basic.py" >/dev/null
```

If either command fails, the clone is older than the fix; update it with
`git -C "$TAPIR_CORE_INTEGRATION_DIR" pull`.

Pull the one upstream image this stack still uses, and confirm the four built in
Section 6 are present. No DNS TAPIR image is pulled: the integration test runs
against the commits cloned on this host.

```bash
set -euo pipefail

TAPIR_IMAGES_ENV="$TAPIR_TEST_ROOT/images.env"

docker pull nats:alpine3.22

test -s "$TAPIR_IMAGES_ENV"
while IFS='=' read -r TAPIR_IMAGE_VAR TAPIR_IMAGE_REF; do
  test -n "$TAPIR_IMAGE_REF"
  docker image inspect "$TAPIR_IMAGE_REF" --format '{{.Id}}' >/dev/null
  printf '%s -> %s\n' "$TAPIR_IMAGE_VAR" "$TAPIR_IMAGE_REF"
done < "$TAPIR_IMAGES_ENV"
```

This section still runs the upstream fixture unmodified. It brings up its own
NATS from `sut/docker-compose.yaml` and tears it down again, so it neither reads
nor writes the persistent analysis state that Section 11 leaves running.

Start from empty test state, then bring the integration stack up in dependency
order. This block checks port 4222 before starting and installs an exit trap that
saves the Compose logs and removes the stack and its test volumes on both
success and failure.

The suite passes without the reset: `test_new_qname` generates a fresh query
name per run, so it does not depend on the new-qname service's no-TTL
`seen_domains` bucket being empty. The reset is kept because this section is a
self-contained validation: it should neither inherit nor leave behind JetStream
state, and it must not disturb a stack left running by Section 11.

The startup order does still matter: the list-checker expects the
`registry_investigation_bucket` to exist, while Observation Encoder creates that
bucket during initialization. Starting every container at once can therefore
cause `test_registry_investigation_single` to time out.

```bash
(
set -euo pipefail

TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_COMPOSE_FILE="$TAPIR_CORE_INTEGRATION_DIR/sut/docker-compose.yaml"
TAPIR_CORE_VENV="$TAPIR_CORE_INTEGRATION_DIR/.venv"
TAPIR_CORE_TEST_LOG="$TAPIR_LOGS/core-integration-test.log"
TAPIR_CORE_SERVICE_LOG="$TAPIR_LOGS/core-integration-services.log"
# Compose reads these; without them it falls back to the published images.
set -a
. "$TAPIR_TEST_ROOT/images.env"
set +a

tapir_core_cleanup() {
  TAPIR_CORE_STATUS=$?
  TAPIR_CORE_CLEANUP_FAILED=0
  set +e
  docker compose --file "$TAPIR_CORE_COMPOSE_FILE" \
    logs --no-color --tail=200 \
    > "$TAPIR_CORE_SERVICE_LOG" 2>&1
  if ! docker compose --file "$TAPIR_CORE_COMPOSE_FILE" \
    down --volumes --remove-orphans; then
    TAPIR_CORE_CLEANUP_FAILED=1
  fi
  if [ "$TAPIR_CORE_STATUS" -eq 0 ] && \
     [ "$TAPIR_CORE_CLEANUP_FAILED" -ne 0 ]; then
    TAPIR_CORE_STATUS=1
  fi
  trap - EXIT
  exit "$TAPIR_CORE_STATUS"
}
trap tapir_core_cleanup EXIT

test -x "$TAPIR_CORE_VENV/bin/pytest"
cd "$TAPIR_CORE_INTEGRATION_DIR"

docker compose --file "$TAPIR_CORE_COMPOSE_FILE" \
  down --volumes --remove-orphans

TAPIR_CORE_PORT_CONTAINERS="$(
  docker ps -q --filter publish=4222
)"
TAPIR_CORE_PORT_LISTENERS="$(
  ss -H -ltn | awk '$4 ~ /:4222$/' || true
)"
if [ -n "$TAPIR_CORE_PORT_CONTAINERS" ] || \
   [ -n "$TAPIR_CORE_PORT_LISTENERS" ]; then
  echo "TCP port 4222 is already in use:" >&2
  docker ps --filter publish=4222 \
    --format '{{.ID}} {{.Names}} {{.Image}} {{.Ports}}'
  ss -H -ltn | awk '$4 ~ /:4222$/'
  false
fi

docker compose --file "$TAPIR_CORE_COMPOSE_FILE" up -d nats

for attempt in $(seq 1 30); do
  if docker compose --file "$TAPIR_CORE_COMPOSE_FILE" exec -T nats \
    busybox wget -qO- http://127.0.0.1:8222/healthz \
    | grep -c ok >/dev/null; then
    break
  fi
  sleep 1
done

docker compose --file "$TAPIR_CORE_COMPOSE_FILE" exec -T nats \
  busybox wget -qO- http://127.0.0.1:8222/healthz \
  | grep -c ok >/dev/null

docker compose --file "$TAPIR_CORE_COMPOSE_FILE" \
  up -d observation-encoder
sleep 3
test -n "$(docker compose --file "$TAPIR_CORE_COMPOSE_FILE" \
  ps --status running -q observation-encoder)"

docker compose --file "$TAPIR_CORE_COMPOSE_FILE" up -d \
  tapir-analyse-looptest \
  tapir-analyse-new-qname \
  tapir-analyse-listchecker
sleep 3
test -n "$(docker compose --file "$TAPIR_CORE_COMPOSE_FILE" \
  ps --status running -q tapir-analyse-looptest)"
test -n "$(docker compose --file "$TAPIR_CORE_COMPOSE_FILE" \
  ps --status running -q tapir-analyse-new-qname)"
test -n "$(docker compose --file "$TAPIR_CORE_COMPOSE_FILE" \
  ps --status running -q tapir-analyse-listchecker)"

docker compose --file "$TAPIR_CORE_COMPOSE_FILE" ps
"$TAPIR_CORE_VENV/bin/pytest" -v 2>&1 \
  | tee "$TAPIR_CORE_TEST_LOG"
)
```

The exit trap has now stopped the stack. Inspect the saved test and service
logs without depending on running containers:

```bash
TAPIR_CORE_TEST_LOG="$TAPIR_LOGS/core-integration-test.log"
TAPIR_CORE_SERVICE_LOG="$TAPIR_LOGS/core-integration-services.log"
tail -n 200 "$TAPIR_CORE_TEST_LOG"
tail -n 200 "$TAPIR_CORE_SERVICE_LOG"
```

## 8. Validate Node Manager as `dnstapir`

Install its dependencies:

```bash
TAPIR_NODEMAN_DIR="$TAPIR_SRC/nodeman"
TAPIR_NODEMAN_CONFIG="$TAPIR_NODEMAN_DIR/test-nodeman.toml"
TAPIR_NODEMAN_SERVER="$TAPIR_NODEMAN_DIR/.venv/bin/nodeman_server"
TAPIR_NODEMAN_PID_FILE="$TAPIR_RUN/nodeman.pid"
TAPIR_NODEMAN_CA_PRIVATE_KEY="$TAPIR_NODEMAN_DIR/internal_ca_private_key.pem"
TAPIR_NODEMAN_CA_CERTIFICATE="$TAPIR_NODEMAN_DIR/internal_ca_certificate.pem"
TAPIR_NODEMAN_TRUSTED_JWKS="$TAPIR_NODEMAN_DIR/trusted_jwks.json"

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -d "$TAPIR_NODEMAN_DIR/.git"
mkdir -p "$TAPIR_LOGS"
mkdir -p "$TAPIR_RUN"

cd "$TAPIR_NODEMAN_DIR"
"$TAPIR_UV" sync
test -x "$TAPIR_NODEMAN_SERVER"
```

Create a disposable internal CA and an empty Core JWKS:

```bash
openssl genpkey \
  -algorithm Ed25519 \
  -out "$TAPIR_NODEMAN_CA_PRIVATE_KEY"
openssl req \
  -x509 \
  -new \
  -key "$TAPIR_NODEMAN_CA_PRIVATE_KEY" \
  -out "$TAPIR_NODEMAN_CA_CERTIFICATE" \
  -days 3650 \
  -subj '/CN=DNS TAPIR test internal CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign'
printf '{"keys":[]}\n' > "$TAPIR_NODEMAN_TRUSTED_JWKS"
chmod 0600 "$TAPIR_NODEMAN_CA_PRIVATE_KEY"
```

Generate an Argon2id hash for the test password `password`:

```bash
NODEMAN_ADMIN_HASH="$(printf '%s\n' 'password' \
  | "$TAPIR_UV" run python \
      -c 'from argon2 import PasswordHasher; import sys; print(PasswordHasher().hash(sys.stdin.readline().rstrip("\n")))')"
printf '%s\n' "$NODEMAN_ADMIN_HASH"
```

Write `test-nodeman.toml`:

```bash
tee "$TAPIR_NODEMAN_CONFIG" >/dev/null <<EOF
[mongodb]
server = "mongodb://127.0.0.1:27017/nodeman"

[internal_ca]
issuer_ca_certificate = "$TAPIR_NODEMAN_DIR/internal_ca_certificate.pem"
issuer_ca_private_key = "$TAPIR_NODEMAN_DIR/internal_ca_private_key.pem"
validity_days = 60

[nodes]
nodeman_url = "http://127.0.0.1:8080"
aggrec_url = "http://127.0.0.1:8080"
domain = "localhost"
trusted_jwks = "$TAPIR_NODEMAN_DIR/trusted_jwks.json"
mqtt_broker = "mqtt://127.0.0.1:1883"

[nodes.mqtt_topics]
tem = "configuration/tem"
pop = "configuration/pop"

[enrollment]
kty = "OKP"
crv = "Ed25519"
alg = "EdDSA"

[http]
trusted_hosts = ["127.0.0.1"]

[[users]]
username = "username"
password_hash = "$NODEMAN_ADMIN_HASH"
EOF
unset NODEMAN_ADMIN_HASH
```

Validate the Node Manager configuration before starting a background process:

```bash
env NODEMAN_CONFIG="$TAPIR_NODEMAN_CONFIG" \
  "$TAPIR_UV" run python \
  -c 'from nodeman.settings import Settings; Settings(); print("Node Manager configuration is valid")'
```

Run the enrollment and renewal validation in a self-cleaning subshell. It
stops a prior Node Manager process only when the recorded PID still belongs to
this section's server, resets its MongoDB project, checks ports 27017 and 8080,
and installs an exit trap before starting anything. The trap always saves the
MongoDB log, stops Node Manager, and removes the Compose project and test
volume.

```bash
(
set -euo pipefail

TAPIR_NODEMAN_DIR="$TAPIR_SRC/nodeman"
TAPIR_NODEMAN_CONFIG="$TAPIR_NODEMAN_DIR/test-nodeman.toml"
TAPIR_NODEMAN_SERVER="$TAPIR_NODEMAN_DIR/.venv/bin/nodeman_server"
TAPIR_NODEMAN_COMPOSE_FILE="$TAPIR_NODEMAN_DIR/docker-compose.yaml"
TAPIR_NODEMAN_PID_FILE="$TAPIR_RUN/nodeman.pid"
TAPIR_NODEMAN_LOG="$TAPIR_LOGS/nodeman.log"
TAPIR_NODEMAN_MONGO_LOG="$TAPIR_LOGS/nodeman-mongo.log"
TAPIR_NODEMAN_OPENAPI="$TAPIR_TEST_ROOT/nodeman-openapi.json"
TAPIR_NODEMAN_CA_PRIVATE_KEY="$TAPIR_NODEMAN_DIR/internal_ca_private_key.pem"
TAPIR_NODEMAN_CA_CERTIFICATE="$TAPIR_NODEMAN_DIR/internal_ca_certificate.pem"
TAPIR_NODEMAN_TRUSTED_JWKS="$TAPIR_NODEMAN_DIR/trusted_jwks.json"
TAPIR_NODEMAN_ENROLLMENT="$TAPIR_NODEMAN_DIR/enrollment.json"
TAPIR_NODEMAN_CLIENT_DATA="$TAPIR_NODEMAN_DIR/data.json"
TAPIR_NODEMAN_TLS_CERTIFICATE="$TAPIR_NODEMAN_DIR/tls.crt"
TAPIR_NODEMAN_TLS_KEY="$TAPIR_NODEMAN_DIR/tls.key"
TAPIR_NODEMAN_TLS_CA="$TAPIR_NODEMAN_DIR/tls-ca.crt"

tapir_stop_nodeman() {
  if [ ! -s "$TAPIR_NODEMAN_PID_FILE" ]; then
    rm -f "$TAPIR_NODEMAN_PID_FILE"
    return
  fi

  TAPIR_NODEMAN_PID="$(cat "$TAPIR_NODEMAN_PID_FILE")"
  if kill -0 "$TAPIR_NODEMAN_PID" 2>/dev/null; then
    TAPIR_NODEMAN_COMMAND="$(
      tr '\0' ' ' < "/proc/$TAPIR_NODEMAN_PID/cmdline" 2>/dev/null || true
    )"
    if [[ "$TAPIR_NODEMAN_COMMAND" == *"$TAPIR_NODEMAN_SERVER"* ]]; then
      kill "$TAPIR_NODEMAN_PID" 2>/dev/null || true
      for attempt in $(seq 1 30); do
        if ! kill -0 "$TAPIR_NODEMAN_PID" 2>/dev/null; then
          break
        fi
        sleep 1
      done
      if kill -0 "$TAPIR_NODEMAN_PID" 2>/dev/null; then
        kill -KILL "$TAPIR_NODEMAN_PID" 2>/dev/null || true
      fi
    fi
  fi
  rm -f "$TAPIR_NODEMAN_PID_FILE"
}

tapir_nodeman_cleanup() {
  TAPIR_NODEMAN_STATUS=$?
  TAPIR_NODEMAN_CLEANUP_FAILED=0
  set +e
  tapir_stop_nodeman
  docker compose --file "$TAPIR_NODEMAN_COMPOSE_FILE" \
    logs --no-color --tail=200 mongo \
    > "$TAPIR_NODEMAN_MONGO_LOG" 2>&1
  if ! docker compose --file "$TAPIR_NODEMAN_COMPOSE_FILE" \
    down --volumes --remove-orphans; then
    TAPIR_NODEMAN_CLEANUP_FAILED=1
  fi
  rm -f "$TAPIR_NODEMAN_CONFIG"
  rm -f "$TAPIR_NODEMAN_CA_PRIVATE_KEY"
  rm -f "$TAPIR_NODEMAN_CA_CERTIFICATE"
  rm -f "$TAPIR_NODEMAN_TRUSTED_JWKS"
  rm -f "$TAPIR_NODEMAN_ENROLLMENT"
  rm -f "$TAPIR_NODEMAN_CLIENT_DATA"
  rm -f "$TAPIR_NODEMAN_TLS_CERTIFICATE"
  rm -f "$TAPIR_NODEMAN_TLS_KEY"
  rm -f "$TAPIR_NODEMAN_TLS_CA"
  if [ "$TAPIR_NODEMAN_STATUS" -eq 0 ] && \
     [ "$TAPIR_NODEMAN_CLEANUP_FAILED" -ne 0 ]; then
    TAPIR_NODEMAN_STATUS=1
  fi
  trap - EXIT
  exit "$TAPIR_NODEMAN_STATUS"
}
trap tapir_nodeman_cleanup EXIT

test -x "$TAPIR_NODEMAN_SERVER"
test -r "$TAPIR_NODEMAN_CONFIG"
cd "$TAPIR_NODEMAN_DIR"

tapir_stop_nodeman
docker compose --file "$TAPIR_NODEMAN_COMPOSE_FILE" \
  down --volumes --remove-orphans

TAPIR_NODEMAN_PORT_CONTAINERS="$(
  {
    docker ps -q --filter publish=27017
    docker ps -q --filter publish=8080
  } | sort -u
)"
TAPIR_NODEMAN_PORT_LISTENERS="$(
  ss -H -ltn | awk '$4 ~ /:(27017|8080)$/' || true
)"
if [ -n "$TAPIR_NODEMAN_PORT_CONTAINERS" ] || \
   [ -n "$TAPIR_NODEMAN_PORT_LISTENERS" ]; then
  echo "Node Manager test ports are already in use:" >&2
  docker ps --filter publish=27017 \
    --format 'port 27017: {{.ID}} {{.Names}} {{.Image}} {{.Ports}}'
  docker ps --filter publish=8080 \
    --format 'port 8080: {{.ID}} {{.Names}} {{.Image}} {{.Ports}}'
  ss -H -ltn | awk '$4 ~ /:(27017|8080)$/'
  false
fi

docker compose --file "$TAPIR_NODEMAN_COMPOSE_FILE" up -d mongo
for attempt in $(seq 1 30); do
  if docker compose --file "$TAPIR_NODEMAN_COMPOSE_FILE" exec -T mongo \
    mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' \
    | grep -cx 1 >/dev/null; then
    break
  fi
  sleep 1
done
docker compose --file "$TAPIR_NODEMAN_COMPOSE_FILE" exec -T mongo \
  mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' \
  | grep -cx 1 >/dev/null

nohup env NODEMAN_CONFIG="$TAPIR_NODEMAN_CONFIG" \
  "$TAPIR_NODEMAN_SERVER" --host 127.0.0.1 --port 8080 --debug \
  > "$TAPIR_NODEMAN_LOG" 2>&1 &
echo "$!" > "$TAPIR_NODEMAN_PID_FILE"

sleep 1
TAPIR_NODEMAN_PID="$(cat "$TAPIR_NODEMAN_PID_FILE")"
if ! kill -0 "$TAPIR_NODEMAN_PID" 2>/dev/null; then
  tail -n 100 "$TAPIR_NODEMAN_LOG"
  false
fi

for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8080/openapi.json \
    > "$TAPIR_NODEMAN_OPENAPI"; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error \
  http://127.0.0.1:8080/openapi.json \
  > "$TAPIR_NODEMAN_OPENAPI"
jq '.paths | keys' "$TAPIR_NODEMAN_OPENAPI"

curl --fail --silent --show-error \
  --user username:password \
  --request POST \
  --output "$TAPIR_NODEMAN_ENROLLMENT" \
  http://127.0.0.1:8080/api/v1/node
chmod 0600 "$TAPIR_NODEMAN_ENROLLMENT"
jq 'keys' "$TAPIR_NODEMAN_ENROLLMENT"

rm -f "$TAPIR_NODEMAN_CLIENT_DATA"
rm -f "$TAPIR_NODEMAN_TLS_CERTIFICATE"
rm -f "$TAPIR_NODEMAN_TLS_KEY"
rm -f "$TAPIR_NODEMAN_TLS_CA"
"$TAPIR_UV" run \
  nodeman_client --debug enroll --file "$TAPIR_NODEMAN_ENROLLMENT"
ls -l \
  "$TAPIR_NODEMAN_CLIENT_DATA" \
  "$TAPIR_NODEMAN_TLS_CERTIFICATE" \
  "$TAPIR_NODEMAN_TLS_KEY" \
  "$TAPIR_NODEMAN_TLS_CA"
openssl x509 \
  -in "$TAPIR_NODEMAN_TLS_CERTIFICATE" \
  -noout -subject -issuer -dates

rm -f "$TAPIR_NODEMAN_TLS_CERTIFICATE"
rm -f "$TAPIR_NODEMAN_TLS_KEY"
rm -f "$TAPIR_NODEMAN_TLS_CA"
"$TAPIR_UV" run nodeman_client --debug renew
openssl x509 \
  -in "$TAPIR_NODEMAN_TLS_CERTIFICATE" \
  -noout -subject -issuer -dates
)
```

The runtime, test CA, client credentials, and generated configuration have been
removed. Inspect the retained validation logs:

```bash
TAPIR_NODEMAN_LOG="$TAPIR_LOGS/nodeman.log"
TAPIR_NODEMAN_MONGO_LOG="$TAPIR_LOGS/nodeman-mongo.log"
tail -n 200 "$TAPIR_NODEMAN_LOG"
tail -n 200 "$TAPIR_NODEMAN_MONGO_LOG"
```

This section passes when enrollment and renewal both validate the generated
certificate before the exit trap removes it.

## 9. Validate Aggregate Receiver as `dnstapir`

Install its dependencies and generate both test-key types:

```bash
TAPIR_AGGREC_DIR="$TAPIR_SRC/aggrec"
TAPIR_AGGREC_CONFIG="$TAPIR_AGGREC_DIR/test-aggrec.toml"
TAPIR_AGGREC_SERVER="$TAPIR_AGGREC_DIR/.venv/bin/aggrec_server"
TAPIR_AGGREC_PID_FILE="$TAPIR_RUN/aggrec.pid"
TAPIR_AGGREC_CLIENTS_DIR="$TAPIR_AGGREC_DIR/clients"
TAPIR_P256_PRIVATE_KEY="$TAPIR_AGGREC_DIR/test-private-p256.pem"
TAPIR_P256_PUBLIC_KEY="$TAPIR_AGGREC_CLIENTS_DIR/test-p256.pem"
TAPIR_ED25519_PRIVATE_KEY="$TAPIR_AGGREC_DIR/test-private-ed25519.pem"
TAPIR_ED25519_PUBLIC_KEY="$TAPIR_AGGREC_CLIENTS_DIR/test-ed25519.pem"

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -d "$TAPIR_AGGREC_DIR/.git"
mkdir -p "$TAPIR_LOGS"
mkdir -p "$TAPIR_RUN"

cd "$TAPIR_AGGREC_DIR"
"$TAPIR_UV" sync
test -x "$TAPIR_AGGREC_SERVER"
mkdir -p "$TAPIR_AGGREC_CLIENTS_DIR"
openssl ecparam -genkey -name prime256v1 -noout \
  -out "$TAPIR_P256_PRIVATE_KEY"
openssl ec -in "$TAPIR_P256_PRIVATE_KEY" -pubout \
  -out "$TAPIR_P256_PUBLIC_KEY"
openssl genpkey -algorithm Ed25519 \
  -out "$TAPIR_ED25519_PRIVATE_KEY"
openssl pkey -in "$TAPIR_ED25519_PRIVATE_KEY" -pubout \
  -out "$TAPIR_ED25519_PUBLIC_KEY"
```

Write `test-aggrec.toml`:

```bash
tee "$TAPIR_AGGREC_CONFIG" >/dev/null <<'EOF'
metadata_base_url = "http://127.0.0.1:8080"
clients_database = "http://localhost:8081/{key_id}.pem"

[s3]
endpoint_url = "http://127.0.0.1:9000"
bucket = "aggregates"
create_bucket = true
access_key_id = "access_key_id"
secret_access_key = "secret_access_key"

[mongodb]
server = "mongodb://127.0.0.1:27017/aggregates"

[http]
trusted_hosts = ["127.0.0.1"]

[nats]
servers = ["nats://127.0.0.1:4222"]
subject = "aggregates"

[key_cache]
size = 1000
ttl = 300
EOF
```

Validate the Aggregate Receiver configuration before starting its dependencies:

```bash
env AGGREC_CONFIG="$TAPIR_AGGREC_CONFIG" \
  "$TAPIR_UV" run python \
  -c 'from aggrec.settings import Settings; Settings(); print("Aggregate Receiver configuration is valid")'
```

Run the signed-upload and storage validation in a self-cleaning subshell. It
resets only its own Compose project, rejects occupied ports before startup, and
installs an exit trap that saves dependency logs, stops Aggregate Receiver, and
removes its containers, networks, volumes, and random payload files. The Caddy
site is host-matched to `localhost:8081`, so its checks intentionally use
`localhost`, not `127.0.0.1`.

The NATS health check here queries the published port from the host rather than
running `busybox wget` inside the container, because the Aggregate Receiver
Compose file pins `nats:latest`. That image is distroless and contains neither
a shell nor `busybox`, so an in-container probe fails with
`executable file not found in $PATH`. Sections 7 and 11 use `nats:alpine3.22`,
which does ship `busybox`, and probe from inside the container. The Aggregate
Receiver Compose file publishes the monitoring port on `127.0.0.1:8222`, so the
host-side probe reaches the same endpoint.

```bash
(
set -euo pipefail

TAPIR_AGGREC_DIR="$TAPIR_SRC/aggrec"
TAPIR_AGGREC_CONFIG="$TAPIR_AGGREC_DIR/test-aggrec.toml"
TAPIR_AGGREC_SERVER="$TAPIR_AGGREC_DIR/.venv/bin/aggrec_server"
TAPIR_AGGREC_COMPOSE_FILE="$TAPIR_AGGREC_DIR/docker-compose.yaml"
TAPIR_AGGREC_PID_FILE="$TAPIR_RUN/aggrec.pid"
TAPIR_AGGREC_LOG="$TAPIR_LOGS/aggrec.log"
TAPIR_AGGREC_DEPENDENCY_LOG="$TAPIR_LOGS/aggrec-dependencies.log"
TAPIR_AGGREC_OPENAPI="$TAPIR_TEST_ROOT/aggrec-openapi.json"
TAPIR_P256_KEY_URL="http://localhost:8081/test-p256.pem"
TAPIR_ED25519_KEY_URL="http://localhost:8081/test-ed25519.pem"
TAPIR_DERIVED_P256_KEY="$TAPIR_RUN/test-p256-derived.pem"
TAPIR_DERIVED_ED25519_KEY="$TAPIR_RUN/test-ed25519-derived.pem"
TAPIR_P256_PAYLOAD="$TAPIR_RUN/random-p256.bin"
TAPIR_ED25519_PAYLOAD="$TAPIR_RUN/random-ed25519.bin"
TAPIR_S3_ENDPOINT_URL="http://127.0.0.1:9000"
TAPIR_S3_BUCKET="aggregates"
TAPIR_S3_ACCESS_KEY_ID="access_key_id"
TAPIR_S3_SECRET_ACCESS_KEY="secret_access_key"
TAPIR_AGGREC_CLIENTS_DIR="$TAPIR_AGGREC_DIR/clients"
TAPIR_P256_PRIVATE_KEY="$TAPIR_AGGREC_DIR/test-private-p256.pem"
TAPIR_P256_PUBLIC_KEY="$TAPIR_AGGREC_CLIENTS_DIR/test-p256.pem"
TAPIR_ED25519_PRIVATE_KEY="$TAPIR_AGGREC_DIR/test-private-ed25519.pem"
TAPIR_ED25519_PUBLIC_KEY="$TAPIR_AGGREC_CLIENTS_DIR/test-ed25519.pem"

tapir_stop_aggrec() {
  if [ ! -s "$TAPIR_AGGREC_PID_FILE" ]; then
    rm -f "$TAPIR_AGGREC_PID_FILE"
    return
  fi

  TAPIR_AGGREC_PID="$(cat "$TAPIR_AGGREC_PID_FILE")"
  if kill -0 "$TAPIR_AGGREC_PID" 2>/dev/null; then
    TAPIR_AGGREC_COMMAND="$(
      tr '\0' ' ' < "/proc/$TAPIR_AGGREC_PID/cmdline" 2>/dev/null || true
    )"
    if [[ "$TAPIR_AGGREC_COMMAND" == *"$TAPIR_AGGREC_SERVER"* ]]; then
      kill "$TAPIR_AGGREC_PID" 2>/dev/null || true
      for attempt in $(seq 1 30); do
        if ! kill -0 "$TAPIR_AGGREC_PID" 2>/dev/null; then
          break
        fi
        sleep 1
      done
      if kill -0 "$TAPIR_AGGREC_PID" 2>/dev/null; then
        kill -KILL "$TAPIR_AGGREC_PID" 2>/dev/null || true
      fi
    fi
  fi
  rm -f "$TAPIR_AGGREC_PID_FILE"
}

tapir_aggrec_cleanup() {
  TAPIR_AGGREC_STATUS=$?
  TAPIR_AGGREC_CLEANUP_FAILED=0
  set +e
  tapir_stop_aggrec
  docker compose --file "$TAPIR_AGGREC_COMPOSE_FILE" \
    logs --no-color --tail=200 \
    > "$TAPIR_AGGREC_DEPENDENCY_LOG" 2>&1
  if ! docker compose --file "$TAPIR_AGGREC_COMPOSE_FILE" \
    down --volumes --remove-orphans; then
    TAPIR_AGGREC_CLEANUP_FAILED=1
  fi
  rm -f "$TAPIR_DERIVED_P256_KEY"
  rm -f "$TAPIR_DERIVED_ED25519_KEY"
  rm -f "$TAPIR_P256_PAYLOAD"
  rm -f "$TAPIR_ED25519_PAYLOAD"
  rm -f "$TAPIR_AGGREC_CONFIG"
  rm -f "$TAPIR_P256_PRIVATE_KEY"
  rm -f "$TAPIR_P256_PUBLIC_KEY"
  rm -f "$TAPIR_ED25519_PRIVATE_KEY"
  rm -f "$TAPIR_ED25519_PUBLIC_KEY"
  rmdir "$TAPIR_AGGREC_CLIENTS_DIR" 2>/dev/null || true
  if [ "$TAPIR_AGGREC_STATUS" -eq 0 ] && \
     [ "$TAPIR_AGGREC_CLEANUP_FAILED" -ne 0 ]; then
    TAPIR_AGGREC_STATUS=1
  fi
  trap - EXIT
  exit "$TAPIR_AGGREC_STATUS"
}
trap tapir_aggrec_cleanup EXIT

test -x "$TAPIR_AGGREC_SERVER"
test -r "$TAPIR_AGGREC_CONFIG"
cd "$TAPIR_AGGREC_DIR"

tapir_stop_aggrec
docker compose --file "$TAPIR_AGGREC_COMPOSE_FILE" \
  down --volumes --remove-orphans

TAPIR_AGGREC_PORT_LISTENERS="$(
  ss -H -ltn \
    | awk '$4 ~ /:(1883|27017|4222|6379|8080|8081|9000|9001)$/' \
    || true
)"
if [ -n "$TAPIR_AGGREC_PORT_LISTENERS" ]; then
  echo "Aggregate Receiver test ports are already in use:" >&2
  docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}'
  printf '%s\n' "$TAPIR_AGGREC_PORT_LISTENERS"
  false
fi

docker compose --file "$TAPIR_AGGREC_COMPOSE_FILE" \
  up -d s3 mongo caddy valkey mosquitto nats

for attempt in $(seq 1 30); do
  if docker compose --file "$TAPIR_AGGREC_COMPOSE_FILE" exec -T mongo \
    mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' \
    | grep -cx 1 >/dev/null; then
    break
  fi
  sleep 1
done
docker compose --file "$TAPIR_AGGREC_COMPOSE_FILE" exec -T mongo \
  mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' \
  | grep -cx 1 >/dev/null

for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8222/healthz \
    | grep -c ok >/dev/null; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error http://127.0.0.1:8222/healthz \
  | grep -c ok >/dev/null

for attempt in $(seq 1 30); do
  if curl --fail --silent "$TAPIR_P256_KEY_URL" >/dev/null && \
     curl --fail --silent "$TAPIR_ED25519_KEY_URL" >/dev/null; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error "$TAPIR_P256_KEY_URL" \
  | openssl pkey -pubin -noout
curl --fail --silent --show-error "$TAPIR_ED25519_KEY_URL" \
  | openssl pkey -pubin -noout

openssl pkey -in "$TAPIR_P256_PRIVATE_KEY" -pubout \
  -out "$TAPIR_DERIVED_P256_KEY"
cmp "$TAPIR_DERIVED_P256_KEY" "$TAPIR_P256_PUBLIC_KEY"
openssl pkey -in "$TAPIR_ED25519_PRIVATE_KEY" -pubout \
  -out "$TAPIR_DERIVED_ED25519_KEY"
cmp "$TAPIR_DERIVED_ED25519_KEY" "$TAPIR_ED25519_PUBLIC_KEY"

nohup env AGGREC_CONFIG="$TAPIR_AGGREC_CONFIG" \
  "$TAPIR_AGGREC_SERVER" --host 127.0.0.1 --port 8080 --debug \
  > "$TAPIR_AGGREC_LOG" 2>&1 &
echo "$!" > "$TAPIR_AGGREC_PID_FILE"

sleep 1
TAPIR_AGGREC_PID="$(cat "$TAPIR_AGGREC_PID_FILE")"
if ! kill -0 "$TAPIR_AGGREC_PID" 2>/dev/null; then
  tail -n 100 "$TAPIR_AGGREC_LOG"
  false
fi

for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8080/openapi.json \
    > "$TAPIR_AGGREC_OPENAPI"; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error \
  http://127.0.0.1:8080/openapi.json \
  > "$TAPIR_AGGREC_OPENAPI"
jq '.paths | keys' "$TAPIR_AGGREC_OPENAPI"

openssl rand 1024 > "$TAPIR_P256_PAYLOAD"
"$TAPIR_UV" run \
  aggrec_client \
  --http-key-id test-p256 \
  --http-key-file "$TAPIR_P256_PRIVATE_KEY" \
  "$TAPIR_P256_PAYLOAD"

openssl rand 1024 > "$TAPIR_ED25519_PAYLOAD"
"$TAPIR_UV" run \
  aggrec_client \
  --http-key-id test-ed25519 \
  --http-key-file "$TAPIR_ED25519_PRIVATE_KEY" \
  "$TAPIR_ED25519_PAYLOAD"

docker compose --file "$TAPIR_AGGREC_COMPOSE_FILE" exec -T mongo \
  mongosh --quiet aggregates --eval 'db.getCollectionNames()'

env \
  TAPIR_S3_ENDPOINT_URL="$TAPIR_S3_ENDPOINT_URL" \
  TAPIR_S3_BUCKET="$TAPIR_S3_BUCKET" \
  TAPIR_S3_ACCESS_KEY_ID="$TAPIR_S3_ACCESS_KEY_ID" \
  TAPIR_S3_SECRET_ACCESS_KEY="$TAPIR_S3_SECRET_ACCESS_KEY" \
  "$TAPIR_UV" run python - <<'PY'
import os

import boto3

bucket = os.environ["TAPIR_S3_BUCKET"]
s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["TAPIR_S3_ENDPOINT_URL"],
    aws_access_key_id=os.environ["TAPIR_S3_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["TAPIR_S3_SECRET_ACCESS_KEY"],
    region_name="us-east-1",
)
objects = s3.list_objects_v2(Bucket=bucket).get("Contents", [])
print(f"bucket={bucket} object_count={len(objects)}")
for item in objects:
    print(f"{item['Key']}\t{item['Size']} bytes")
if len(objects) < 2:
    raise SystemExit("Expected at least two objects in the aggregates bucket")
PY
)
```

The runtime, random payloads, test signing keys, and generated configuration
have been removed. Because the exit trap deletes `test-aggrec.toml` and both
test key pairs on failure as well as on success, a failed run cannot be retried
from the validation block alone: rerun this section from its first block, which
recreates the keys and configuration. The same applies to Section 8. Inspect
the retained Aggregate Receiver and dependency logs:

```bash
TAPIR_AGGREC_LOG="$TAPIR_LOGS/aggrec.log"
TAPIR_AGGREC_DEPENDENCY_LOG="$TAPIR_LOGS/aggrec-dependencies.log"
tail -n 200 "$TAPIR_AGGREC_LOG"
tail -n 200 "$TAPIR_AGGREC_DEPENDENCY_LOG"
```

This section passes when both clients succeed, MongoDB has metadata, and RustFS
has both objects.

## 10. Validate MQTT bridge as `dnstapir`

Build and unit-test the bridge, stage the image context, and build the test
image. The subshell stops at the first failed command, so an absent binary
cannot be followed by a misleading image-build error. Do not add `--user` to
this build container: with Rootless Docker, container UID 0 maps to the
`dnstapir` host UID and can write the service-account-owned bind mount.

```bash
(
set -euo pipefail

TAPIR_MQTT_BRIDGE_DIR="$TAPIR_SRC/mqtt-bridge"
TAPIR_MQTT_BRIDGE_BUILD_DIR="$TAPIR_RUN/mqtt-bridge-build"
TAPIR_MQTT_BRIDGE_CONTEXT_DIR="$TAPIR_RUN/mqtt-bridge-image"
TAPIR_MQTT_BRIDGE_BINARY="$TAPIR_MQTT_BRIDGE_BUILD_DIR/mqtt-bridge"
TAPIR_MQTT_BRIDGE_CONTEXT_BINARY="$TAPIR_MQTT_BRIDGE_CONTEXT_DIR/mqtt-bridge"
TAPIR_MQTT_BRIDGE_DOCKERFILE="$TAPIR_MQTT_BRIDGE_CONTEXT_DIR/Dockerfile"
TAPIR_MQTT_BRIDGE_GO_BUILD_CACHE="$TAPIR_RUN/mqtt-bridge-go-cache/build"
TAPIR_MQTT_BRIDGE_GO_MOD_CACHE="$TAPIR_RUN/mqtt-bridge-go-cache/mod"
TAPIR_MQTT_BRIDGE_IMAGE="mqtt-bridge:itest"
TAPIR_MQTT_BRIDGE_KEEP_BUILD=0

tapir_mqtt_bridge_build_cleanup() {
  TAPIR_MQTT_BRIDGE_BUILD_STATUS="$?"
  set +e
  if [ "$TAPIR_MQTT_BRIDGE_KEEP_BUILD" -eq 0 ]; then
    docker image rm "$TAPIR_MQTT_BRIDGE_IMAGE" 2>/dev/null || true
    rm -f "$TAPIR_MQTT_BRIDGE_BINARY"
    rm -f "$TAPIR_MQTT_BRIDGE_CONTEXT_BINARY"
    rm -f "$TAPIR_MQTT_BRIDGE_DOCKERFILE"
    rmdir "$TAPIR_MQTT_BRIDGE_BUILD_DIR" 2>/dev/null || true
    rmdir "$TAPIR_MQTT_BRIDGE_CONTEXT_DIR" 2>/dev/null || true
  fi
  trap - EXIT
  exit "$TAPIR_MQTT_BRIDGE_BUILD_STATUS"
}
trap tapir_mqtt_bridge_build_cleanup EXIT

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -d "$TAPIR_MQTT_BRIDGE_DIR/.git"
cd "$TAPIR_MQTT_BRIDGE_DIR"

mkdir -p "$TAPIR_MQTT_BRIDGE_BUILD_DIR"
mkdir -p "$TAPIR_MQTT_BRIDGE_CONTEXT_DIR"
mkdir -p "$TAPIR_MQTT_BRIDGE_GO_BUILD_CACHE"
mkdir -p "$TAPIR_MQTT_BRIDGE_GO_MOD_CACHE"
docker run --rm \
  --env GOCACHE=/tmp/go-build \
  --env GOMODCACHE=/tmp/go-mod \
  --env TAPIR_MQTT_BRIDGE_BINARY=/out/mqtt-bridge \
  --volume "$PWD:/src" \
  --volume "$TAPIR_MQTT_BRIDGE_BUILD_DIR:/out" \
  --volume "$TAPIR_MQTT_BRIDGE_GO_BUILD_CACHE:/tmp/go-build" \
  --volume "$TAPIR_MQTT_BRIDGE_GO_MOD_CACHE:/tmp/go-mod" \
  --workdir /src \
  golang:latest \
  sh -c 'go test ./... && CGO_ENABLED=0 go build -buildvcs=false -o "$TAPIR_MQTT_BRIDGE_BINARY" ./cmd/mqtt-bridge'

test -s "$TAPIR_MQTT_BRIDGE_BINARY"
test -x "$TAPIR_MQTT_BRIDGE_BINARY"

install -m 0755 \
  "$TAPIR_MQTT_BRIDGE_BINARY" \
  "$TAPIR_MQTT_BRIDGE_CONTEXT_BINARY"
install -m 0644 \
  itests/sut/Dockerfile \
  "$TAPIR_MQTT_BRIDGE_DOCKERFILE"

test -s "$TAPIR_MQTT_BRIDGE_CONTEXT_BINARY"
test -r "$TAPIR_MQTT_BRIDGE_DOCKERFILE"
ls -lh \
  "$TAPIR_MQTT_BRIDGE_CONTEXT_BINARY" \
  "$TAPIR_MQTT_BRIDGE_DOCKERFILE"

docker build \
  --tag "$TAPIR_MQTT_BRIDGE_IMAGE" \
  --file "$TAPIR_MQTT_BRIDGE_DOCKERFILE" \
  "$TAPIR_MQTT_BRIDGE_CONTEXT_DIR"

docker image inspect "$TAPIR_MQTT_BRIDGE_IMAGE" \
  --format 'image={{.RepoTags}} size={{.Size}}'

TAPIR_MQTT_BRIDGE_KEEP_BUILD=1
)
```

Pull the two dependency images. Do not start the Compose stack manually: the
Go integration test copies the Compose project to a temporary directory, starts
that copy, and stops it during teardown. Reset the bridge's fixed project and
remove any prior test-owned temporary project. Do not stop another section's
stack: the final checks identify a foreign owner and stop this section before
the long Go command if ports 1883 or 4222 are still occupied.

```bash
(
set -euo pipefail

TAPIR_MQTT_BRIDGE_DIR="$TAPIR_SRC/mqtt-bridge"
TAPIR_MQTT_COMPOSE_FILE="$TAPIR_MQTT_BRIDGE_DIR/itests/sut/docker-compose.yaml"
TAPIR_MQTT_BRIDGE_ITEST_TMP="$TAPIR_RUN/mqtt-bridge-itest-tmp"

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -d "$TAPIR_MQTT_BRIDGE_DIR/.git"
test -r "$TAPIR_MQTT_COMPOSE_FILE"
cd "$TAPIR_MQTT_BRIDGE_DIR"
docker compose --file "$TAPIR_MQTT_COMPOSE_FILE" \
  down --volumes --remove-orphans

TAPIR_MQTT_MOSQUITTO_PROJECTS="$(
  docker ps -a \
    --filter ancestor=eclipse-mosquitto:2.0.21-openssl \
    --filter label=com.docker.compose.service=mosquitto \
    --format '{{.Label "com.docker.compose.project"}}'
)"
TAPIR_MQTT_NATS_PROJECTS="$(
  docker ps -a \
    --filter ancestor=nats:alpine3.22 \
    --filter label=com.docker.compose.service=nats \
    --format '{{.Label "com.docker.compose.project"}}'
)"
TAPIR_STALE_MQTT_PROJECTS="$(
  comm -12 \
    <(printf '%s\n' "$TAPIR_MQTT_MOSQUITTO_PROJECTS" \
      | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$TAPIR_MQTT_NATS_PROJECTS" \
      | sed '/^$/d' | sort -u)
)"

while IFS= read -r TAPIR_STALE_MQTT_PROJECT; do
  [ -n "$TAPIR_STALE_MQTT_PROJECT" ] || continue
  TAPIR_STALE_MQTT_WORKING_DIR="$(
    docker ps -a \
      --filter "label=com.docker.compose.project=$TAPIR_STALE_MQTT_PROJECT" \
      --format '{{.Label "com.docker.compose.project.working_dir"}}' \
      | sed -n '1p'
  )"
  case "$TAPIR_STALE_MQTT_WORKING_DIR" in
    "$TAPIR_MQTT_BRIDGE_ITEST_TMP"|"$TAPIR_MQTT_BRIDGE_ITEST_TMP"/*)
      docker compose \
        --project-name "$TAPIR_STALE_MQTT_PROJECT" \
        --file "$TAPIR_MQTT_COMPOSE_FILE" \
        down --volumes --remove-orphans
      ;;
  esac
done <<< "$TAPIR_STALE_MQTT_PROJECTS"

TAPIR_MQTT_PORT_1883_CONTAINERS="$(
  docker ps -q --filter publish=1883
)"
TAPIR_MQTT_PORT_4222_CONTAINERS="$(
  docker ps -q --filter publish=4222
)"
TAPIR_MQTT_PORT_LISTENERS="$(
  ss -H -ltn | awk '$4 ~ /:(1883|4222)$/' || true
)"

if [ -n "$TAPIR_MQTT_PORT_1883_CONTAINERS" ] || \
   [ -n "$TAPIR_MQTT_PORT_4222_CONTAINERS" ] || \
   [ -n "$TAPIR_MQTT_PORT_LISTENERS" ]; then
  echo "Ports required by the MQTT integration test are still occupied:" >&2
  docker ps --filter publish=1883 \
    --format 'port 1883: {{.ID}} {{.Names}} {{.Image}} {{.Ports}}'
  docker ps --filter publish=4222 \
    --format 'port 4222: {{.ID}} {{.Names}} {{.Image}} {{.Ports}}'
  ss -H -ltn | awk '$4 ~ /:(1883|4222)$/'
  false
fi

docker pull eclipse-mosquitto:2.0.21-openssl
docker pull nats:alpine3.22
)
```

Run and save the bridge integration test. The test runs inside the Go container
but creates sibling containers through the service account's Rootless Docker
daemon. The Docker socket and test temporary directory must therefore be
mounted at their exact host paths. The explicit host override prevents
Testcontainers from selecting an unreachable Rootless bridge gateway for the
Ryuk readiness check; `127.0.0.1` is correct because the runner uses the host
network. Do not add `--user`: container UID 0 maps to the `dnstapir` host UID
under Rootless Docker and can access the socket.

```bash
(
set -euo pipefail

TAPIR_MQTT_BRIDGE_DIR="$TAPIR_SRC/mqtt-bridge"
TAPIR_MQTT_COMPOSE_FILE="$TAPIR_MQTT_BRIDGE_DIR/itests/sut/docker-compose.yaml"
TAPIR_SERVICE_UID="$(id -u)"
TAPIR_ROOTLESS_RUNTIME_DIR="/run/user/$TAPIR_SERVICE_UID"
TAPIR_DOCKER_SOCKET="$TAPIR_ROOTLESS_RUNTIME_DIR/docker.sock"
TAPIR_DOCKER_HOST="unix://$TAPIR_DOCKER_SOCKET"
TAPIR_MQTT_BRIDGE_ITEST_TMP="$TAPIR_RUN/mqtt-bridge-itest-tmp"
TAPIR_MQTT_BRIDGE_GO_BUILD_CACHE="$TAPIR_RUN/mqtt-bridge-go-cache/build"
TAPIR_MQTT_BRIDGE_GO_MOD_CACHE="$TAPIR_RUN/mqtt-bridge-go-cache/mod"
TAPIR_MQTT_BRIDGE_BUILD_DIR="$TAPIR_RUN/mqtt-bridge-build"
TAPIR_MQTT_BRIDGE_CONTEXT_DIR="$TAPIR_RUN/mqtt-bridge-image"
TAPIR_MQTT_BRIDGE_IMAGE="mqtt-bridge:itest"

tapir_mqtt_bridge_cleanup() {
  TAPIR_MQTT_BRIDGE_STATUS="$?"
  TAPIR_MQTT_BRIDGE_CLEANUP_FAILED=0
  set +e

  TAPIR_MQTT_MOSQUITTO_PROJECTS="$(
    docker ps -a \
      --filter ancestor=eclipse-mosquitto:2.0.21-openssl \
      --filter label=com.docker.compose.service=mosquitto \
      --format '{{.Label "com.docker.compose.project"}}' \
      | sed '/^$/d' | sort -u
  )"
  TAPIR_MQTT_NATS_PROJECTS="$(
    docker ps -a \
      --filter ancestor=nats:alpine3.22 \
      --filter label=com.docker.compose.service=nats \
      --format '{{.Label "com.docker.compose.project"}}' \
      | sed '/^$/d' | sort -u
  )"
  TAPIR_MQTT_TEST_PROJECTS="$(
    comm -12 \
      <(printf '%s\n' "$TAPIR_MQTT_MOSQUITTO_PROJECTS") \
      <(printf '%s\n' "$TAPIR_MQTT_NATS_PROJECTS") \
      | sed '/^$/d'
  )"

  while IFS= read -r TAPIR_MQTT_TEST_PROJECT; do
    [ -n "$TAPIR_MQTT_TEST_PROJECT" ] || continue
    TAPIR_MQTT_PROJECT_WORKING_DIR="$(
      docker ps -a \
        --filter "label=com.docker.compose.project=$TAPIR_MQTT_TEST_PROJECT" \
        --format '{{.Label "com.docker.compose.project.working_dir"}}' \
        | sed -n '1p'
    )"
    case "$TAPIR_MQTT_PROJECT_WORKING_DIR" in
      "$TAPIR_MQTT_BRIDGE_ITEST_TMP"|"$TAPIR_MQTT_BRIDGE_ITEST_TMP"/*)
        if ! docker compose \
          --project-name "$TAPIR_MQTT_TEST_PROJECT" \
          --file "$TAPIR_MQTT_COMPOSE_FILE" \
          down --volumes --remove-orphans; then
          TAPIR_MQTT_BRIDGE_CLEANUP_FAILED=1
        fi
        ;;
    esac
  done <<< "$TAPIR_MQTT_TEST_PROJECTS"

  if docker image inspect "$TAPIR_MQTT_BRIDGE_IMAGE" >/dev/null 2>&1; then
    if ! docker image rm "$TAPIR_MQTT_BRIDGE_IMAGE"; then
      TAPIR_MQTT_BRIDGE_CLEANUP_FAILED=1
    fi
  fi
  rm -f "$TAPIR_MQTT_BRIDGE_BUILD_DIR/mqtt-bridge"
  rm -f "$TAPIR_MQTT_BRIDGE_CONTEXT_DIR/mqtt-bridge"
  rm -f "$TAPIR_MQTT_BRIDGE_CONTEXT_DIR/Dockerfile"
  rmdir "$TAPIR_MQTT_BRIDGE_BUILD_DIR" 2>/dev/null || true
  rmdir "$TAPIR_MQTT_BRIDGE_CONTEXT_DIR" 2>/dev/null || true
  rmdir "$TAPIR_MQTT_BRIDGE_ITEST_TMP" 2>/dev/null || true
  if [ "$TAPIR_MQTT_BRIDGE_STATUS" -eq 0 ] && \
     [ "$TAPIR_MQTT_BRIDGE_CLEANUP_FAILED" -ne 0 ]; then
    TAPIR_MQTT_BRIDGE_STATUS=1
  fi
  trap - EXIT
  exit "$TAPIR_MQTT_BRIDGE_STATUS"
}
trap tapir_mqtt_bridge_cleanup EXIT

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -d "$TAPIR_MQTT_BRIDGE_DIR/.git"
test -S "$TAPIR_DOCKER_SOCKET"
mkdir -p "$TAPIR_MQTT_BRIDGE_ITEST_TMP"
mkdir -p "$TAPIR_MQTT_BRIDGE_GO_BUILD_CACHE"
mkdir -p "$TAPIR_MQTT_BRIDGE_GO_MOD_CACHE"
docker --host "$TAPIR_DOCKER_HOST" info \
  --format '{{json .SecurityOptions}}' \
  | grep -c rootless >/dev/null
docker image inspect "$TAPIR_MQTT_BRIDGE_IMAGE" >/dev/null

cd "$TAPIR_MQTT_BRIDGE_DIR"
docker run --rm \
  --network host \
  --env DOCKER_HOST="$TAPIR_DOCKER_HOST" \
  --env TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="$TAPIR_DOCKER_SOCKET" \
  --env TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1 \
  --env XDG_RUNTIME_DIR="$TAPIR_ROOTLESS_RUNTIME_DIR" \
  --env TMPDIR="$TAPIR_MQTT_BRIDGE_ITEST_TMP" \
  --env GOCACHE=/tmp/go-build \
  --env GOMODCACHE=/tmp/go-mod \
  --volume "$TAPIR_DOCKER_SOCKET:$TAPIR_DOCKER_SOCKET" \
  --volume "$PWD:$PWD:ro" \
  --volume "$TAPIR_MQTT_BRIDGE_ITEST_TMP:$TAPIR_MQTT_BRIDGE_ITEST_TMP" \
  --volume "$TAPIR_MQTT_BRIDGE_GO_BUILD_CACHE:/tmp/go-build" \
  --volume "$TAPIR_MQTT_BRIDGE_GO_MOD_CACHE:/tmp/go-mod" \
  --workdir "$PWD" \
  golang:latest \
  go test -count=1 -v --tags=itests ./itests/... \
  2>&1 | tee "$TAPIR_LOGS/mqtt-bridge-integration-test.log"
)
```

Inspect the saved integration-test output. The exit trap removes any temporary
Compose project left by either a successful or failed test, along with the
staged binary, build context, and `mqtt-bridge:itest` image. There is therefore
no fixed project whose service logs can be queried afterward. The Go caches are
retained to make a later run faster:

```bash
tail -n 200 "$TAPIR_LOGS/mqtt-bridge-integration-test.log"
```

This section passes when the Go integration test exits with status zero.

## 11. Leave the Core analysis stack running as `dnstapir`

This section needs the baseline setup, cloned repositories, and images built in
Sections 1–6, plus a reachable services VM and its handover bundle at
`~/core-handover.tar.gz`. It does not depend on any validation environment or
running container from Sections 7–10.

The analysis containers run the images built in Section 6, so this stack is
whatever commit was cloned rather than whatever `latest` happens to point at,
and they publish to the NATS server on the services VM rather than to a local
one. JetStream state therefore outlives a Core rebuild.

This stack does **not** reuse `sut/docker-compose.yaml`. Section 7 runs that file
as the disposable upstream fixture with its own NATS, and reusing it here would
make the two share a Compose project name and a NATS server, so running the
integration test would tear down the running analysis stack. Keeping them
separate removes that hazard at the cost of copying four configuration files.

Each copy differs from upstream in exactly one line, the `[nats] url`. Subjects,
bucket names and TTLs are upstream's, so the analysts behave here as the
integration test exercises them.

```bash
(
set -euo pipefail

TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_ROOT="$TAPIR_TEST_ROOT/core-analysis"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_CORE_ANALYSIS_ROOT/compose.yaml"
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"
TAPIR_IMAGES_ENV="$TAPIR_TEST_ROOT/images.env"

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -s "$TAPIR_IMAGES_ENV"

# This is the first section that needs the services VM, so it unpacks the
# handover bundle. Section 12.1 refreshes it; either may run first.
if [ ! -s "$TAPIR_SERVICES_DIR/services.env" ]; then
  test -s "$HOME/core-handover.tar.gz"
  mkdir -p "$TAPIR_SERVICES_DIR"
  chmod 0700 "$TAPIR_SERVICES_DIR"
  tar -xzf "$HOME/core-handover.tar.gz" -C "$TAPIR_SERVICES_DIR" --strip-components=1
fi
test -s "$TAPIR_SERVICES_DIR/services.env"
set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
# shellcheck disable=SC1090
. "$TAPIR_IMAGES_ENV"
set +a

timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222"

mkdir -p "$TAPIR_CORE_ANALYSIS_ROOT"

# One configuration directory per service, copied from upstream with only the
# NATS URL changed. Each service gets its own credentials, so the services VM
# can report which component published what.
tapir_stage_config() {
  TAPIR_STAGE_SERVICE="$1"
  TAPIR_STAGE_URL="$2"
  TAPIR_STAGE_DIR="$TAPIR_CORE_ANALYSIS_ROOT/$TAPIR_STAGE_SERVICE"

  rm -rf "${TAPIR_STAGE_DIR:?}"
  cp -a \
    "$TAPIR_CORE_INTEGRATION_DIR/sut/$TAPIR_STAGE_SERVICE" \
    "$TAPIR_STAGE_DIR"

  # Exactly one url line, or the upstream layout changed and the rewrite below
  # would silently do the wrong thing.
  test "$(grep -c '^url = ' "$TAPIR_STAGE_DIR/config.toml")" -eq 1
  sed -i "s|^url = .*|url = \"$TAPIR_STAGE_URL\"|" \
    "$TAPIR_STAGE_DIR/config.toml"
  grep -c "^url = \"nats://" "$TAPIR_STAGE_DIR/config.toml" >/dev/null

  chmod 0600 "$TAPIR_STAGE_DIR/config.toml"
}

tapir_stage_config observation-encoder       "$TAPIR_SERVICES_NATS_ENCODER_URL"
tapir_stage_config tapir-analyse-looptest    "$TAPIR_SERVICES_NATS_LOOPTEST_URL"
tapir_stage_config tapir-analyse-new-qname   "$TAPIR_SERVICES_NATS_NEWQNAME_URL"
tapir_stage_config tapir-analyse-listchecker "$TAPIR_SERVICES_NATS_LISTCHECKER_URL"

cat > "$TAPIR_CORE_ANALYSIS_COMPOSE" <<EOF
services:
  observation-encoder:
    image: $TAPIR_INTEGRATION_OBSERVATION_ENCODER_IMG
    user: "0:0"
    working_dir: /work
    restart: unless-stopped
    volumes:
      - $TAPIR_CORE_ANALYSIS_ROOT/observation-encoder:/work:ro

  tapir-analyse-looptest:
    image: $TAPIR_INTEGRATION_LOOPTEST_IMG
    user: "0:0"
    working_dir: /work
    restart: unless-stopped
    depends_on:
      - observation-encoder
    volumes:
      - $TAPIR_CORE_ANALYSIS_ROOT/tapir-analyse-looptest:/work:ro

  tapir-analyse-new-qname:
    image: $TAPIR_INTEGRATION_NEW_QNAME_IMG
    user: "0:0"
    working_dir: /work
    restart: unless-stopped
    depends_on:
      - observation-encoder
    volumes:
      - $TAPIR_CORE_ANALYSIS_ROOT/tapir-analyse-new-qname:/work:ro

  tapir-analyse-listchecker:
    image: $TAPIR_INTEGRATION_LISTCHECKER_IMG
    user: "0:0"
    working_dir: /work
    restart: unless-stopped
    depends_on:
      - observation-encoder
    volumes:
      - $TAPIR_CORE_ANALYSIS_ROOT/tapir-analyse-listchecker:/work:ro
EOF
chmod 0600 "$TAPIR_CORE_ANALYSIS_COMPOSE"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" config >/dev/null

# Observation Encoder creates the KV buckets the analysts expect, so it starts
# first. Starting everything at once can leave an analyst waiting for a bucket
# that does not exist yet.
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" up -d observation-encoder
sleep 5
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q observation-encoder)"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" up -d \
  tapir-analyse-looptest \
  tapir-analyse-new-qname \
  tapir-analyse-listchecker
sleep 5

for TAPIR_ANALYSIS_SERVICE in \
  observation-encoder \
  tapir-analyse-looptest \
  tapir-analyse-new-qname \
  tapir-analyse-listchecker
do
  test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
    ps --status running -q "$TAPIR_ANALYSIS_SERVICE")"
done

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --format '{{.Service}} {{.State}}'
)
```

The configuration files hold NATS passwords, so they are mode 0600. The
containers run as UID 0, which Rootless Docker maps to the unprivileged service
account, so they can read them without host root — the same arrangement
Section 12.4 uses for Mosquitto's key.

`restart: unless-stopped` is declared in this file rather than applied afterwards
with `docker update`. The upstream fixture sets `restart: no` deliberately,
because it is a test harness that creates and removes its stack around a
`pytest` run. A stack meant to stay running is a different thing, and now that it
has its own Compose file it can simply say so.

Section 13 has the post-reboot verification.

At this point:

- the analysis stack is running against the services VM;
- JetStream buckets and their contents outlive this host;
- if Section 8 was run, Node Manager enrollment and renewal were validated;
- if Section 9 was run, Aggregate Receiver uploads and storage were validated;
- if Section 10 was run, MQTT bridge message flow was validated;
- logs and repository commit IDs are under `$TAPIR_TEST_ROOT`.

## 12. Install persistent enrollment and encrypted MQTT ingress as `dnstapir`

This section needs the repositories from Section 6 and the running analysis
stack from Section 11. It does not depend on the disposable validation state
from Sections 7–10. It builds persistent NodeMan and `mqtt-bridge` images,
creates one test CA, issues separate broker and bridge certificates, and starts
MongoDB, NodeMan, Mosquitto, and `mqtt-bridge` in that order.

MQTT on TCP 8883 uses TLS 1.3 and requires a client certificate. NodeMan uses
the same CA to enroll Edge clients and stores each Edge's public data-signing
JWK so `mqtt-bridge` can verify signed messages. The NodeMan API remains HTTP
on TCP 8080 for this private test deployment.

### 12.1 Define persistent paths and verify the services VM

The persistent services read their state from the services VM, so this block
loads the handover bundle Section 10 of the services runbook produced and
confirms the two endpoints Core depends on are reachable.

```bash
set -euo pipefail

TAPIR_SERVICES_BUNDLE="$HOME/core-handover.tar.gz"
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"

test -s "$TAPIR_SERVICES_BUNDLE"
rm -rf "$TAPIR_SERVICES_DIR"
mkdir -p "$TAPIR_SERVICES_DIR"
chmod 0700 "$TAPIR_SERVICES_DIR"
tar -xzf "$TAPIR_SERVICES_BUNDLE" -C "$TAPIR_SERVICES_DIR" --strip-components=1
set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
set +a
test -n "$TAPIR_SERVICES_VM_IP"

TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_NODEMAN_SOURCE="$TAPIR_SRC/nodeman"
TAPIR_MQTT_BRIDGE_SOURCE="$TAPIR_SRC/mqtt-bridge"
TAPIR_CORE_RUNTIME_ROOT="$TAPIR_TEST_ROOT/core-runtime"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_CORE_RUNTIME_ROOT/compose.yaml"
TAPIR_CORE_NODEMAN_DIR="$TAPIR_CORE_RUNTIME_ROOT/nodeman"
TAPIR_CORE_NODEMAN_CONFIG="$TAPIR_CORE_NODEMAN_DIR/nodeman.toml"
TAPIR_CORE_CA_DIR="$TAPIR_CORE_RUNTIME_ROOT/ca"
TAPIR_CORE_BROKER_PKI_DIR="$TAPIR_CORE_RUNTIME_ROOT/mosquitto/pki"
TAPIR_CORE_BRIDGE_DIR="$TAPIR_CORE_RUNTIME_ROOT/mqtt-bridge"
TAPIR_CORE_MQTT_BRIDGE_IMAGE=mqtt-bridge:core-runtime
TAPIR_CORE_NODEMAN_IMAGE=nodeman:core-runtime

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -n "$TAPIR_CORE_VM_IP"
test -d "$TAPIR_NODEMAN_SOURCE/.git"
test -d "$TAPIR_MQTT_BRIDGE_SOURCE/.git"
docker info --format '{{json .SecurityOptions}}' | grep -c rootless >/dev/null

# The services VM must answer on both ports before anything is configured
# against it, because a wrong address surfaces later as a slow retry loop
# rather than a clean failure.
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/27017"

printf 'Core=%s Services=%s\n' "$TAPIR_CORE_VM_IP" "$TAPIR_SERVICES_VM_IP"
```

Nothing here touches the `sut` project. Section 7 keeps its own disposable NATS,
and the persistent stack now uses the services VM, so the two no longer share a
NATS or a Compose project name. Running Section 7 on an installed system is
therefore safe.

### 12.2 Install the CA and service certificates

The CA lives on the services VM so that it outlives this host. Core receives a
copy of the issuer key, because NodeMan signs Edge certificate requests itself,
along with the Mosquitto and `mqtt-bridge` certificates the services runbook
issued for this VM's address.

Nothing is generated here. If a certificate is wrong or missing, fix it on the
services VM and rebuild the bundle; do not create a local CA, or Edge nodes will
be issued certificates that no other host trusts.

```bash
set -euo pipefail

TAPIR_CORE_RUNTIME_ROOT="$TAPIR_TEST_ROOT/core-runtime"
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"
TAPIR_CORE_CA_DIR="$TAPIR_CORE_RUNTIME_ROOT/ca"
TAPIR_CORE_BROKER_PKI_DIR="$TAPIR_CORE_RUNTIME_ROOT/mosquitto/pki"
TAPIR_CORE_BRIDGE_DIR="$TAPIR_CORE_RUNTIME_ROOT/mqtt-bridge"

for f in ca/ca.key ca/ca.crt ca/server.crt ca/server.key ca/client.crt ca/client.key; do
  test -s "$TAPIR_SERVICES_DIR/$f"
done

mkdir -p "$TAPIR_CORE_CA_DIR" "$TAPIR_CORE_BROKER_PKI_DIR" "$TAPIR_CORE_BRIDGE_DIR"

install -m 0600 "$TAPIR_SERVICES_DIR/ca/ca.key" "$TAPIR_CORE_CA_DIR/ca.key"
install -m 0644 "$TAPIR_SERVICES_DIR/ca/ca.crt" "$TAPIR_CORE_CA_DIR/ca.crt"

install -m 0600 "$TAPIR_SERVICES_DIR/ca/server.key" "$TAPIR_CORE_BROKER_PKI_DIR/server.key"
install -m 0644 "$TAPIR_SERVICES_DIR/ca/server.crt" "$TAPIR_CORE_BROKER_PKI_DIR/server.crt"
install -m 0644 "$TAPIR_SERVICES_DIR/ca/ca.crt"     "$TAPIR_CORE_BROKER_PKI_DIR/ca.crt"

install -m 0600 "$TAPIR_SERVICES_DIR/ca/client.key" "$TAPIR_CORE_BRIDGE_DIR/client.key"
install -m 0644 "$TAPIR_SERVICES_DIR/ca/client.crt" "$TAPIR_CORE_BRIDGE_DIR/client.crt"
install -m 0644 "$TAPIR_SERVICES_DIR/ca/ca.crt"     "$TAPIR_CORE_BRIDGE_DIR/ca.crt"

openssl verify -CAfile "$TAPIR_CORE_CA_DIR/ca.crt" "$TAPIR_CORE_BROKER_PKI_DIR/server.crt"
openssl verify -CAfile "$TAPIR_CORE_CA_DIR/ca.crt" "$TAPIR_CORE_BRIDGE_DIR/client.crt"

# The Edge verifies the broker by address, so the SAN must carry this VM's.
openssl x509 -in "$TAPIR_CORE_BROKER_PKI_DIR/server.crt" -noout -text \
  | grep -c "IP Address:$TAPIR_CORE_VM_IP" >/dev/null

openssl x509 -in "$TAPIR_CORE_CA_DIR/ca.crt" -noout -subject -fingerprint -sha256
openssl x509 -in "$TAPIR_CORE_BROKER_PKI_DIR/server.crt" \
  -noout -subject -issuer -dates -ext subjectAltName
```

Record the CA fingerprint printed above. Both CAs a test network is likely to
hold carry the same subject, `CN = DNS TAPIR test MQTT CA`, so the fingerprint
is the only way to tell an Edge issued by this CA from one issued by a
previous, locally generated one.

### 12.3 Build the persistent NodeMan and mqtt-bridge images

These are the last two images, after the four built in Section 6. Every DNS
TAPIR process in this deployment now runs a binary compiled from a clone on this
host, and `$TAPIR_TEST_ROOT/versions.txt` records the commit for each.

The `mqtt-bridge` image uses a multistage build, so no host bind-mounted output
directory is involved and the earlier file-ownership problem cannot recur.

```bash
set -euo pipefail

TAPIR_NODEMAN_SOURCE="$TAPIR_SRC/nodeman"
TAPIR_MQTT_BRIDGE_SOURCE="$TAPIR_SRC/mqtt-bridge"
TAPIR_CORE_RUNTIME_ROOT="$TAPIR_TEST_ROOT/core-runtime"
TAPIR_CORE_MQTT_BRIDGE_DOCKERFILE="$TAPIR_CORE_RUNTIME_ROOT/mqtt-bridge.Dockerfile"
TAPIR_CORE_MQTT_BRIDGE_IMAGE=mqtt-bridge:core-runtime
TAPIR_CORE_NODEMAN_IMAGE=nodeman:core-runtime

test -d "$TAPIR_NODEMAN_SOURCE/.git"
test -d "$TAPIR_MQTT_BRIDGE_SOURCE/.git"
mkdir -p "$TAPIR_CORE_RUNTIME_ROOT"

cat > "$TAPIR_CORE_MQTT_BRIDGE_DOCKERFILE" <<'EOF'
FROM golang:latest AS builder
WORKDIR /src
COPY . .
RUN go test ./... && \
    CGO_ENABLED=0 go build -buildvcs=false -o /out/mqtt-bridge ./cmd/mqtt-bridge

FROM fedora:42
COPY --from=builder /out/mqtt-bridge /usr/bin/mqtt-bridge
ENTRYPOINT ["mqtt-bridge", "-config-file", "/etc/dnstapir/mqtt-bridge/config.toml"]
EOF

docker build \
  --tag "$TAPIR_CORE_NODEMAN_IMAGE" \
  "$TAPIR_NODEMAN_SOURCE"
docker build \
  --tag "$TAPIR_CORE_MQTT_BRIDGE_IMAGE" \
  --file "$TAPIR_CORE_MQTT_BRIDGE_DOCKERFILE" \
  "$TAPIR_MQTT_BRIDGE_SOURCE"

docker image inspect "$TAPIR_CORE_NODEMAN_IMAGE" \
  --format 'nodeman={{.Id}} size={{.Size}}'
docker image inspect "$TAPIR_CORE_MQTT_BRIDGE_IMAGE" \
  --format 'mqtt-bridge={{.Id}} size={{.Size}}'
```

### 12.4 Write NodeMan, Mosquitto, and mqtt-bridge configuration

```bash
set -euo pipefail

TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_COMPOSE_FILE="$TAPIR_CORE_INTEGRATION_DIR/sut/docker-compose.yaml"
TAPIR_NODEMAN_SOURCE="$TAPIR_SRC/nodeman"
TAPIR_MQTT_BRIDGE_SOURCE="$TAPIR_SRC/mqtt-bridge"
TAPIR_CORE_RUNTIME_ROOT="$TAPIR_TEST_ROOT/core-runtime"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_CORE_RUNTIME_ROOT/compose.yaml"
TAPIR_CORE_NODEMAN_DIR="$TAPIR_CORE_RUNTIME_ROOT/nodeman"
TAPIR_CORE_NODEMAN_CONFIG="$TAPIR_CORE_NODEMAN_DIR/nodeman.toml"
TAPIR_CORE_NODEMAN_JWKS="$TAPIR_CORE_NODEMAN_DIR/trusted-jwks.json"
TAPIR_CORE_CA_DIR="$TAPIR_CORE_RUNTIME_ROOT/ca"
TAPIR_CORE_CA_KEY="$TAPIR_CORE_CA_DIR/ca.key"
TAPIR_CORE_CA_CERT="$TAPIR_CORE_CA_DIR/ca.crt"
TAPIR_CORE_MOSQUITTO_DIR="$TAPIR_CORE_RUNTIME_ROOT/mosquitto"
TAPIR_CORE_MOSQUITTO_CONFIG="$TAPIR_CORE_MOSQUITTO_DIR/mosquitto.conf"
TAPIR_CORE_MOSQUITTO_ACL="$TAPIR_CORE_MOSQUITTO_DIR/mosquitto.acl"
TAPIR_CORE_BROKER_PKI_DIR="$TAPIR_CORE_MOSQUITTO_DIR/pki"
TAPIR_CORE_BRIDGE_DIR="$TAPIR_CORE_RUNTIME_ROOT/mqtt-bridge"
TAPIR_CORE_BRIDGE_CONFIG="$TAPIR_CORE_BRIDGE_DIR/config.toml"
TAPIR_CORE_BRIDGE_SCHEMA="$TAPIR_CORE_BRIDGE_DIR/new_qname.json"
TAPIR_CORE_MQTT_BRIDGE_IMAGE=mqtt-bridge:core-runtime
TAPIR_CORE_NODEMAN_IMAGE=nodeman:core-runtime
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"

# Each block stands alone in a fresh shell, so the services credentials are
# loaded here rather than inherited from Section 12.1.
test -s "$TAPIR_SERVICES_DIR/services.env"
set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
set +a
test -n "$TAPIR_SERVICES_MONGO_NODEMAN_URL"
test -n "$TAPIR_SERVICES_NATS_BRIDGE_URL"

mkdir -p \
  "$TAPIR_CORE_NODEMAN_DIR" \
  "$TAPIR_CORE_MOSQUITTO_DIR" \
  "$TAPIR_CORE_BRIDGE_DIR"
test -s "$TAPIR_CORE_CA_KEY"
test -s "$TAPIR_CORE_CA_CERT"
test -s "$TAPIR_CORE_BROKER_PKI_DIR/server.key"
test -s "$TAPIR_CORE_BROKER_PKI_DIR/server.crt"
test -s "$TAPIR_CORE_BRIDGE_DIR/client.key"
test -s "$TAPIR_CORE_BRIDGE_DIR/client.crt"

cd "$TAPIR_NODEMAN_SOURCE"
"$TAPIR_UV" sync
TAPIR_NODEMAN_ADMIN_HASH="$(printf '%s\n' password \
  | "$TAPIR_UV" run python \
      -c 'from argon2 import PasswordHasher; import sys; print(PasswordHasher().hash(sys.stdin.readline().rstrip("\n")))')"

printf '{"keys":[]}\n' > "$TAPIR_CORE_NODEMAN_JWKS"
cat > "$TAPIR_CORE_NODEMAN_CONFIG" <<EOF
[mongodb]
server = "$TAPIR_SERVICES_MONGO_NODEMAN_URL"

[internal_ca]
issuer_ca_certificate = "/etc/dnstapir/nodeman-ca/ca.crt"
issuer_ca_private_key = "/etc/dnstapir/nodeman-ca/ca.key"
validity_days = 60

[nodes]
nodeman_url = "http://$TAPIR_CORE_VM_IP:8080"
domain = "edge.test"
trusted_jwks = "/etc/dnstapir/nodeman/trusted-jwks.json"
mqtt_broker = "mqtts://$TAPIR_CORE_VM_IP:8883"

[nodes.mqtt_topics]
tem = "configuration/tem"
pop = "configuration/pop"

[enrollment]
kty = "OKP"
crv = "Ed25519"
alg = "EdDSA"

[http]
trusted_hosts = ["0.0.0.0/0"]
healthcheck_hosts = ["0.0.0.0/0"]

[[users]]
username = "username"
password_hash = "$TAPIR_NODEMAN_ADMIN_HASH"
EOF
unset TAPIR_NODEMAN_ADMIN_HASH

cat > "$TAPIR_CORE_MOSQUITTO_CONFIG" <<'EOF'
per_listener_settings true
user root
listener 8883 0.0.0.0
protocol mqtt
cafile /mosquitto/pki/ca.crt
certfile /mosquitto/pki/server.crt
keyfile /mosquitto/pki/server.key
require_certificate true
use_identity_as_username true
allow_anonymous false
acl_file /mosquitto/config/mosquitto.acl
tls_version tlsv1.3
persistence false
EOF

cat > "$TAPIR_CORE_MOSQUITTO_ACL" <<'EOF'
# %u is the certificate common name, because use_identity_as_username is on.
# An Edge can therefore only publish under its own node name.
pattern readwrite events/up/%u/#
pattern readwrite status/up/%u/#
pattern read observations/down/#
pattern read config/down/#

user mqtt-bridge.core.test
topic read events/up/#
topic write observations/down/#
EOF
chmod 0644 "$TAPIR_CORE_MOSQUITTO_CONFIG"
# Mosquitto refuses to load a world-readable ACL in newer releases. Container
# UID 0 maps to the service account under Rootless Docker, and mosquitto.conf
# keeps the broker running as root, so 0600 is still readable here.
chmod 0600 "$TAPIR_CORE_MOSQUITTO_ACL"

install -m 0644 \
  "$TAPIR_MQTT_BRIDGE_SOURCE/itests/sut/mqtt-bridge/new_qname.json" \
  "$TAPIR_CORE_BRIDGE_SCHEMA"
cat > "$TAPIR_CORE_BRIDGE_CONFIG" <<EOF
Debug = true

MqttUrl = "mqtts://mosquitto:8883"
MqttCaCert = "/etc/dnstapir/mqtt-bridge/ca.crt"
MqttClientCert = "/etc/dnstapir/mqtt-bridge/client.crt"
MqttClientKey = "/etc/dnstapir/mqtt-bridge/client.key"
NatsUrl = "$TAPIR_SERVICES_NATS_BRIDGE_URL"
NodemanApiUrl = "http://nodeman:8080/api/v1"

[[Bridges]]
Direction = "up"
MqttTopic = "events/up/+/new_qname"
NatsSubject = "core-integration-test.events.new_qname"
NatsQueue = "eventQ"
Key = ""
Schema = "/etc/dnstapir/mqtt-bridge/new_qname.json"
EOF

cat > "$TAPIR_CORE_RUNTIME_COMPOSE" <<EOF
services:
  nodeman:
    image: $TAPIR_CORE_NODEMAN_IMAGE
    user: "0:0"
    restart: unless-stopped
    environment:
      NODEMAN_CONFIG: /etc/dnstapir/nodeman/nodeman.toml
    ports:
      - "0.0.0.0:8080:8080/tcp"
    volumes:
      - $TAPIR_CORE_NODEMAN_DIR:/etc/dnstapir/nodeman:ro
      - $TAPIR_CORE_CA_DIR:/etc/dnstapir/nodeman-ca:ro

  mosquitto:
    image: eclipse-mosquitto:2.0.21-openssl
    user: "0:0"
    restart: unless-stopped
    ports:
      - "0.0.0.0:8883:8883/tcp"
    volumes:
      - $TAPIR_CORE_MOSQUITTO_CONFIG:/mosquitto/config/mosquitto.conf:ro
      - $TAPIR_CORE_MOSQUITTO_ACL:/mosquitto/config/mosquitto.acl:ro
      - $TAPIR_CORE_BROKER_PKI_DIR:/mosquitto/pki:ro

  mqtt-bridge:
    image: $TAPIR_CORE_MQTT_BRIDGE_IMAGE
    user: "0:0"
    restart: unless-stopped
    depends_on:
      - nodeman
      - mosquitto
    volumes:
      - $TAPIR_CORE_BRIDGE_DIR:/etc/dnstapir/mqtt-bridge:ro
EOF

chmod 0600 \
  "$TAPIR_CORE_NODEMAN_CONFIG" \
  "$TAPIR_CORE_CA_KEY" \
  "$TAPIR_CORE_BROKER_PKI_DIR/server.key" \
  "$TAPIR_CORE_BRIDGE_DIR/client.key"
chmod 0644 \
  "$TAPIR_CORE_NODEMAN_JWKS" \
  "$TAPIR_CORE_MOSQUITTO_CONFIG" \
  "$TAPIR_CORE_BRIDGE_CONFIG" \
  "$TAPIR_CORE_BRIDGE_SCHEMA" \
  "$TAPIR_CORE_RUNTIME_COMPOSE"

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" config --quiet
docker run --rm \
  --entrypoint python \
  --user 0:0 \
  --env NODEMAN_CONFIG=/etc/dnstapir/nodeman/nodeman.toml \
  --volume "$TAPIR_CORE_NODEMAN_DIR:/etc/dnstapir/nodeman:ro" \
  --volume "$TAPIR_CORE_CA_DIR:/etc/dnstapir/nodeman-ca:ro" \
  "$TAPIR_CORE_NODEMAN_IMAGE" \
  -c 'from nodeman.settings import Settings; Settings(); print("NodeMan configuration is valid")'
```

Container UID 0 maps to the unprivileged `dnstapir` host UID under Rootless
Docker. The explicit `user: "0:0"` entries let these test containers read the
service-account-owned mode-0600 keys without giving them host root privileges.

Two settings above are load-bearing and fail in ways that are easy to misread:

- `user root` in `mosquitto.conf` is required in addition to `user: "0:0"` in
  the Compose file. Mosquitto drops privileges to its own built-in `mosquitto`
  account after startup unless the configuration says otherwise. That account is
  container UID 1883, which Rootless Docker maps to a subordinate host UID, not
  to `dnstapir`. It therefore cannot read the mode-0600 `server.key` owned by
  `dnstapir`, and Mosquitto restarts continuously logging
  `Unable to load server key file ... Check keyfile` with
  `OpenSSL Error ... Permission denied`. The image entrypoint also prints
  harmless `chown: ... Read-only file system` lines for the read-only mounts.
- `acl_file` is mode 0600 for the same reason `server.key` is: Mosquitto warns
  that a world-readable ACL will be refused by future releases. It is what
  confines an Edge to its own node name. With
  `use_identity_as_username true`, Mosquitto sets the username from the client
  certificate's common name, so `pattern readwrite events/up/%u/#` lets a node
  publish only under the name it enrolled as. Without the ACL, any client
  holding a CA-issued certificate can publish as any node, and `mqtt-bridge`
  will accept the message as long as the signature verifies against whichever
  key NodeMan holds for the claimed name. A deployed Core runs the same pattern.
- `MqttUrl` must use the `mqtts://` scheme. `mqtt-bridge` configures TLS only
  when the URL scheme is `mqtts` or `tls`; with `mqtt://` it silently ignores
  `MqttCaCert`, `MqttClientCert`, and `MqttClientKey` and opens a plaintext
  connection. Against the TLS-only listener the broker then logs
  `OpenSSL Error ... wrong version number` and the bridge retries forever with
  `connection reset by peer`, while its container still reports as running.

### 12.5 Start the persistent services in dependency order

The trap removes only this partial runtime if startup fails. It does not stop
the Section 11 analysis stack, and it cannot reach the databases: they are on
the services VM, which is the point of putting them there.

MongoDB no longer starts here. NodeMan connects to the services VM with the
credentials from the handover bundle, so a Core rebuild keeps every node record
and every enrolled signing key.

A running `mqtt-bridge` container is not by itself evidence of a working
bridge: it stays up while retrying a failed broker connection. The block
therefore also waits for `connection up and ready for use` in the bridge log
and for the matching `New client connected` line, with the bridge certificate
identity as the username, in the Mosquitto log.

Every assertion in these runbooks that ends a pipeline counts matches with
`grep -c ... >/dev/null` rather than short-circuiting with `grep -q`. This is
deliberate and applies throughout, not only here.

In a `set -o pipefail` block, `<producer> | grep -q PATTERN` is unsafe. `grep
-q` exits the moment it matches; if the producer still has output to write it
dies of `SIGPIPE`, and `pipefail` reports that failure as the status of the
whole pipeline even though the pattern was found. `set -e` then aborts the
block. A `| tee FILE | grep -q ...` pipeline is the worst case, because `tee` is
always still writing when `grep -q` leaves.

Because it turns on how much output was left, the failure is a race and is easy
to mistake for something else: the same command succeeds on short output and
starts failing as it grows. Observed statuses are `255` from `docker compose
logs` and `141` (`128 + SIGPIPE`) from `tee`. `grep -c` reads to end of input,
so the producer is never cut off, and a zero count still yields a non-zero
status.

`grep -q PATTERN FILE` with no pipeline is unaffected and is still used for
file checks.

```bash
(
set -euo pipefail

TAPIR_CORE_RUNTIME_ROOT="$TAPIR_TEST_ROOT/core-runtime"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_CORE_RUNTIME_ROOT/compose.yaml"
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"
TAPIR_CORE_CA_CERT="$TAPIR_CORE_RUNTIME_ROOT/ca/ca.crt"
TAPIR_CORE_BRIDGE_KEY="$TAPIR_CORE_RUNTIME_ROOT/mqtt-bridge/client.key"
TAPIR_CORE_BRIDGE_CERT="$TAPIR_CORE_RUNTIME_ROOT/mqtt-bridge/client.crt"
TAPIR_CORE_RUNTIME_LOG="$TAPIR_LOGS/core-runtime-startup.log"
TAPIR_CORE_RUNTIME_KEEP_RUNNING=0

tapir_core_runtime_cleanup() {
  TAPIR_CORE_RUNTIME_STATUS="$?"
  set +e
  if [ "$TAPIR_CORE_RUNTIME_KEEP_RUNNING" -eq 0 ]; then
    docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
      logs --no-color --tail=200 > "$TAPIR_CORE_RUNTIME_LOG" 2>&1
    docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
      down --remove-orphans
  fi
  trap - EXIT
  exit "$TAPIR_CORE_RUNTIME_STATUS"
}
trap tapir_core_runtime_cleanup EXIT

test -r "$TAPIR_CORE_RUNTIME_COMPOSE"
test -r "$TAPIR_CORE_CA_CERT"
test -r "$TAPIR_CORE_BRIDGE_KEY"
test -r "$TAPIR_CORE_BRIDGE_CERT"
test -s "$TAPIR_SERVICES_DIR/services.env"
set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
set +a
mkdir -p "$TAPIR_LOGS"

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  down --remove-orphans

TAPIR_CORE_RUNTIME_PORT_CONTAINERS="$({
  docker ps -q --filter publish=8080
  docker ps -q --filter publish=8883
} | sort -u)"
TAPIR_CORE_RUNTIME_PORT_LISTENERS="$(
  ss -H -ltn | awk '$4 ~ /:(8080|8883)$/' || true
)"
if [ -n "$TAPIR_CORE_RUNTIME_PORT_CONTAINERS" ] || \
   [ -n "$TAPIR_CORE_RUNTIME_PORT_LISTENERS" ]; then
  echo 'Core runtime ports 8080 or 8883 are already in use:' >&2
  docker ps --filter publish=8080 \
    --format 'port 8080: {{.ID}} {{.Names}} {{.Image}} {{.Ports}}'
  docker ps --filter publish=8883 \
    --format 'port 8883: {{.ID}} {{.Names}} {{.Image}} {{.Ports}}'
  ss -H -ltn | awk '$4 ~ /:(8080|8883)$/'
  false
fi

# mqtt-bridge publishes to the services VM, so that is what must answer here.
# The sut stack is not involved: Section 7 owns it and it may well be down.
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222"

docker pull eclipse-mosquitto:2.0.21-openssl

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" up -d nodeman
for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8080/openapi.json \
    > "$TAPIR_CORE_RUNTIME_ROOT/nodeman-openapi.json"; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error \
  http://127.0.0.1:8080/openapi.json \
  > "$TAPIR_CORE_RUNTIME_ROOT/nodeman-openapi.json"

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" up -d mosquitto
for attempt in $(seq 1 30); do
  if openssl s_client \
    -connect 127.0.0.1:8883 \
    -servername mosquitto \
    -verify_hostname mosquitto \
    -verify_return_error \
    -CAfile "$TAPIR_CORE_CA_CERT" \
    -cert "$TAPIR_CORE_BRIDGE_CERT" \
    -key "$TAPIR_CORE_BRIDGE_KEY" \
    < /dev/null 2>&1 \
    | grep -c 'Verification: OK' >/dev/null; then
    break
  fi
  sleep 1
done
openssl s_client \
  -connect 127.0.0.1:8883 \
  -servername mosquitto \
  -verify_hostname mosquitto \
  -verify_return_error \
  -CAfile "$TAPIR_CORE_CA_CERT" \
  -cert "$TAPIR_CORE_BRIDGE_CERT" \
  -key "$TAPIR_CORE_BRIDGE_KEY" \
  < /dev/null 2>&1 \
  | tee "$TAPIR_LOGS/core-mqtt-tls-check.log" \
  | grep -c 'Verification: OK' >/dev/null

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" up -d mqtt-bridge
sleep 3
test -n "$(docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  ps --status running -q nodeman)"
test -n "$(docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  ps --status running -q mosquitto)"
test -n "$(docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  ps --status running -q mqtt-bridge)"

for attempt in $(seq 1 30); do
  if docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
    logs --no-color mqtt-bridge 2>&1 \
    | grep -c 'connection up and ready for use' >/dev/null; then
    break
  fi
  sleep 1
done
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  logs --no-color mqtt-bridge 2>&1 \
  | grep -c 'connection up and ready for use' >/dev/null
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  logs --no-color mosquitto 2>&1 \
  | grep -c "New client connected .* u'mqtt-bridge.core.test'" >/dev/null

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" ps
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  logs --no-color --tail=100 nodeman mosquitto mqtt-bridge \
  | tee "$TAPIR_CORE_RUNTIME_LOG"
TAPIR_CORE_RUNTIME_KEEP_RUNNING=1
)
```

### 12.6 Permit Edge enrollment and MQTT from the Edge VM

Return to the Core administrator and set the Edge address before using it:

```bash
exit
export TAPIR_EDGE_VM_IP=192.0.2.21
sudo ufw allow \
  proto tcp \
  from "$TAPIR_EDGE_VM_IP" \
  to any \
  port 8080 \
  comment 'DNS TAPIR Edge NodeMan'
sudo ufw allow \
  proto tcp \
  from "$TAPIR_EDGE_VM_IP" \
  to any \
  port 8883 \
  comment 'DNS TAPIR Edge MQTT TLS'
sudo ufw status numbered
```

If UFW is inactive, the rules are recorded but do not filter traffic.

### 12.7 Create and transfer a one-time Edge enrollment file

Enter `dnstapir` again. The node name must be a fully qualified name under the
NodeMan domain configured above. This example produces a single-use bootstrap
file containing the enrollment key.

The `scp` at the end of this block assumes the Core `dnstapir` account can
authenticate to the Edge VM over SSH. Neither runbook creates that trust, and
the service account is created with a locked password and no SSH key, so the
copy fails with `Permission denied (publickey,password)` unless an
administrator has provisioned a key for it beforehand. Either provision that
key first, or relay the file through an administrator workstation that already
has access to both VMs:

```bash
# From a workstation with SSH access to both VMs.
scp core:"$TAPIR_EDGE_ENROLLMENT_FILE" ./enrollment.json
scp ./enrollment.json edge:/tmp/edge-receiver-01.edge.test-enrollment.json
shred -u ./enrollment.json
```

The file contains the single-use enrollment key, so remove every intermediate
copy as soon as the transfer completes.

This block creates the node record, so the name must not already exist, and a
node name cannot be reused through the API once it has been created.

NodeMan does not translate a duplicate name into a clean conflict: it lets
MongoDB's unique index raise, so the API answers `HTTP 500` with a
`mongoengine.errors.NotUniqueError` / `E11000 duplicate key error ... index:
name_1` traceback in the NodeMan log, and `curl --fail` reports only
`The requested URL returned error: 500`.

`DELETE /api/v1/node/{name}` does not release the name. It is a soft delete: it
stamps a `deleted` timestamp and leaves the document in `nodeman.nodes`, so the
name disappears from `GET /api/v1/nodes` while the unique index still holds it.
A subsequent `POST` for the same name therefore still fails with `HTTP 500`.

List the nodes, and pick one of three ways forward:

```bash
TAPIR_NODEMAN_ADMIN_URL=http://127.0.0.1:8080
curl --fail --silent --show-error --user username:password \
  "$TAPIR_NODEMAN_ADMIN_URL/api/v1/nodes" | jq '.nodes[].name'
```

- enroll a name that has never been used, which is the simplest option for a
  test deployment;
- remove the soft-deleted document so the name becomes free again:

```bash
TAPIR_EDGE_NODE_NAME=edge-receiver-01.edge.test
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"

set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
set +a

docker run --rm --network host mongo:latest \
  mongosh --quiet "$TAPIR_SERVICES_MONGO_NODEMAN_URL" \
  --eval "db.nodes.deleteOne({name: '$TAPIR_EDGE_NODE_NAME'})" \
  < /dev/null
```

- or discard all enrollment state by dropping the `nodeman` database on the
  services VM. That is a services-VM operation, not a Core one: the node records
  survive a Core rebuild precisely because they do not live here.

Any of these discards the node's enrolled signing key, so the Edge must run the
full enrollment in Edge runbook Section 7.3 again; its existing `data.json` and
certificate become useless.

**Restart `mqtt-bridge` after the Edge re-enrolls.** The bridge caches
validation keys in an LRU keyed by the node name and queries NodeMan only on a
cache miss (`app/upbridge/upbridge.go`). Re-enrolment reuses the name, so the
cache keeps returning the retired key and every message from the node is
discarded with `Bad signature from MQTT, err: 'could not verify message using
any of the signatures or keys'` — even though NodeMan is serving the new key
correctly. Nothing on the Edge side looks wrong, and MQTT still connects, so the
symptom reads as a signing fault on the Edge rather than a stale cache on Core:

```bash
docker compose \
  --file "$TAPIR_TEST_ROOT/core-runtime/compose.yaml" \
  restart mqtt-bridge
```

```bash
export TAPIR_SERVICE_USER=dnstapir
sudo -iu "$TAPIR_SERVICE_USER"
```

```bash
set -euo pipefail

TAPIR_EDGE_NODE_NAME=edge-receiver-01.edge.test
TAPIR_EDGE_ADMIN_USER=edgeadmin
TAPIR_EDGE_VM_IP=192.0.2.21
TAPIR_NODEMAN_ADMIN_URL=http://127.0.0.1:8080
TAPIR_NODEMAN_CREATE_PAYLOAD="$TAPIR_RUN/$TAPIR_EDGE_NODE_NAME-create.json"
TAPIR_EDGE_ENROLLMENT_FILE="$TAPIR_RUN/$TAPIR_EDGE_NODE_NAME-enrollment.json"
TAPIR_EDGE_REMOTE_ENROLLMENT="/tmp/$TAPIR_EDGE_NODE_NAME-enrollment.json"

test "$(id -un)" = "$TAPIR_SERVICE_USER"
curl --fail --silent --show-error \
  "$TAPIR_NODEMAN_ADMIN_URL/openapi.json" >/dev/null

jq -n \
  --arg name "$TAPIR_EDGE_NODE_NAME" \
  '{name: $name, tags: ["edge", "dnstap"]}' \
  > "$TAPIR_NODEMAN_CREATE_PAYLOAD"
curl --fail --silent --show-error \
  --user username:password \
  --header 'Content-Type: application/json' \
  --request POST \
  --data-binary "@$TAPIR_NODEMAN_CREATE_PAYLOAD" \
  --output "$TAPIR_EDGE_ENROLLMENT_FILE" \
  "$TAPIR_NODEMAN_ADMIN_URL/api/v1/node"
rm -f "$TAPIR_NODEMAN_CREATE_PAYLOAD"
chmod 0600 "$TAPIR_EDGE_ENROLLMENT_FILE"

jq -e \
  --arg name "$TAPIR_EDGE_NODE_NAME" \
  --arg url "http://$TAPIR_CORE_VM_IP:8080" \
  '.name == $name and ((.nodeman_url | rtrimstr("/")) == $url) and
   (.key.d | type == "string")' \
  "$TAPIR_EDGE_ENROLLMENT_FILE" >/dev/null

scp \
  "$TAPIR_EDGE_ENROLLMENT_FILE" \
  "$TAPIR_EDGE_ADMIN_USER@$TAPIR_EDGE_VM_IP:$TAPIR_EDGE_REMOTE_ENROLLMENT"
rm -f "$TAPIR_EDGE_ENROLLMENT_FILE"
```

Section 7 of the Edge runbook installs this file, performs enrollment, verifies
the issued certificate, and removes the single-use bootstrap file.

At this point the persistent Core services are installed and running:

- NodeMan and its MongoDB store;
- Mosquitto on `mqtts://<Core-IP>:8883`, requiring a CA-issued client certificate;
- `mqtt-bridge`, authenticated to Mosquitto with its own client certificate;
- the Section 11 NATS, encoder, and analyst services.

## 13. Operating commands as `dnstapir`

After a logout or reboot, the host administrator can enter the service account
with the following commands. The `sudo` operation only changes the login
identity; all subsequent runtime commands execute as `dnstapir`:

```bash
export TAPIR_SERVICE_USER=dnstapir
sudo -iu "$TAPIR_SERVICE_USER"
```

Confirm the identity, environment, and Rootless Docker connection before using
the operating commands:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
TAPIR_CORE_RUNTIME_ROOT="$TAPIR_TEST_ROOT/core-runtime"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_CORE_RUNTIME_ROOT/compose.yaml"

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -n "$TAPIR_SRC"
test -n "$DOCKER_HOST"
test -d "$TAPIR_CORE_INTEGRATION_DIR/.git"
test -r "$TAPIR_CORE_ANALYSIS_COMPOSE"
test -r "$TAPIR_CORE_RUNTIME_COMPOSE"
systemctl --user is-active docker.service
docker info --format '{{json .SecurityOptions}}' \
  | grep -c rootless >/dev/null
```

Show status:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_TEST_ROOT/core-runtime/compose.yaml"
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" ps
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" ps
```

### After a reboot

Both stacks come back without intervention. The service account has systemd
lingering enabled, so its user manager and Rootless Docker daemon start at boot,
and every container carries `restart: unless-stopped`.

Convergence is not instant. Docker starts containers independently of the
Compose `depends_on` ordering, so `nodeman` may restart until MongoDB is
healthy, and `mqtt-bridge` may restart until NATS and Mosquitto answer. Both
settle on their own. Wait for the checks below rather than intervening:

```bash
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"
set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
set +a
(
set -euo pipefail

TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_TEST_ROOT/core-runtime/compose.yaml"

systemctl --user is-active docker.service
for attempt in $(seq 1 60); do
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222" \
     && curl --fail --silent http://127.0.0.1:8080/openapi.json >/dev/null \
     && docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
       logs --no-color mqtt-bridge 2>&1 \
       | grep -c 'connection up and ready for use' >/dev/null; then
    break
  fi
  sleep 5
done

timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222"
curl --fail --silent http://127.0.0.1:8080/openapi.json >/dev/null
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  logs --no-color mqtt-bridge 2>&1 \
  | grep -c 'connection up and ready for use' >/dev/null
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" ps
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" ps
)
```

If the analysis stack is absent rather than merely restarting, its containers
were recreated at some point without the restart policy that Section 11 applies.
Re-run the Section 11 block; it is idempotent and reapplies the policy.

Follow NodeMan, Mosquitto, and bridge logs:

```bash
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_TEST_ROOT/core-runtime/compose.yaml"
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  logs --follow nodeman mosquitto mqtt-bridge
```

Inspect the CA, broker, and mqtt-bridge client certificate expiry dates. The
three `checkend` commands fail if a certificate expires within seven days:

```bash
set -euo pipefail

TAPIR_CORE_CA_CERT="$TAPIR_TEST_ROOT/core-runtime/ca/ca.crt"
TAPIR_CORE_BROKER_CERT="$TAPIR_TEST_ROOT/core-runtime/mosquitto/pki/server.crt"
TAPIR_CORE_BRIDGE_CERT="$TAPIR_TEST_ROOT/core-runtime/mqtt-bridge/client.crt"

openssl x509 -in "$TAPIR_CORE_CA_CERT" -noout -subject -issuer -dates
openssl x509 -in "$TAPIR_CORE_BROKER_CERT" -noout -subject -issuer -dates
openssl x509 -in "$TAPIR_CORE_BRIDGE_CERT" -noout -subject -issuer -dates
openssl x509 -in "$TAPIR_CORE_CA_CERT" -noout -checkend 604800
openssl x509 -in "$TAPIR_CORE_BROKER_CERT" -noout -checkend 604800
openssl x509 -in "$TAPIR_CORE_BRIDGE_CERT" -noout -checkend 604800
```

Follow NATS logs:

```bash
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"
set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
set +a
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
# NATS runs on the services VM; follow its log there, not here.
ssh dnstapir@"$TAPIR_SERVICES_VM_IP" \
  'docker compose --file "$TAPIR_SERVICES_RUN/data-services/compose.yaml" \
     --env-file "$TAPIR_SERVICES_KEYS/service-credentials.env" logs --follow nats'
```

Follow Observation Encoder logs:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  logs --follow observation-encoder
```

Follow loop-test logs:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  logs --follow tapir-analyse-looptest
```

Follow new-qname logs:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  logs --follow tapir-analyse-new-qname
```

Follow list-checker logs:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  logs --follow tapir-analyse-listchecker
```

Stop the persistent ingress first, then the analysis stack:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_TEST_ROOT/core-runtime/compose.yaml"
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  down --remove-orphans
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  down --remove-orphans
```

Start the complete Core in dependency order. This starts NATS first, then the
analysis consumers, followed by MongoDB, NodeMan, Mosquitto, and finally
`mqtt-bridge`:

```bash
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"
set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
set +a
(
set -euo pipefail

TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_TEST_ROOT/core-runtime/compose.yaml"
TAPIR_CORE_CA_CERT="$TAPIR_TEST_ROOT/core-runtime/ca/ca.crt"
TAPIR_CORE_BRIDGE_KEY="$TAPIR_TEST_ROOT/core-runtime/mqtt-bridge/client.key"
TAPIR_CORE_BRIDGE_CERT="$TAPIR_TEST_ROOT/core-runtime/mqtt-bridge/client.crt"
TAPIR_CORE_OPERATING_LOG="$TAPIR_LOGS/core-operating-startup.log"
TAPIR_CORE_KEEP_RUNNING=0

tapir_core_operating_cleanup() {
  TAPIR_CORE_OPERATING_STATUS="$?"
  set +e
  if [ "$TAPIR_CORE_KEEP_RUNNING" -eq 0 ]; then
    docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
      logs --no-color --tail=200 \
      > "$TAPIR_LOGS/core-runtime-operating-failure.log" 2>&1
    docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
      down --remove-orphans
    docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
      logs --no-color --tail=200 \
      > "$TAPIR_CORE_OPERATING_LOG" 2>&1
    docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
      down --remove-orphans
  fi
  trap - EXIT
  exit "$TAPIR_CORE_OPERATING_STATUS"
}
trap tapir_core_operating_cleanup EXIT

test "$(id -un)" = "$TAPIR_SERVICE_USER"
test -r "$TAPIR_CORE_ANALYSIS_COMPOSE"
test -r "$TAPIR_CORE_RUNTIME_COMPOSE"
test -r "$TAPIR_CORE_CA_CERT"
test -r "$TAPIR_CORE_BRIDGE_KEY"
test -r "$TAPIR_CORE_BRIDGE_CERT"
mkdir -p "$TAPIR_LOGS"
cd "$TAPIR_CORE_INTEGRATION_DIR"

for attempt in $(seq 1 30); do
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222"; then
    break
  fi
  sleep 1
done

timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  up -d observation-encoder
sleep 3
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q observation-encoder)"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" up -d \
  tapir-analyse-looptest \
  tapir-analyse-new-qname \
  tapir-analyse-listchecker
sleep 3
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q tapir-analyse-looptest)"
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q tapir-analyse-new-qname)"
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q tapir-analyse-listchecker)"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" ps

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" up -d nodeman
for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8080/openapi.json >/dev/null; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error \
  http://127.0.0.1:8080/openapi.json >/dev/null

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" up -d mosquitto
for attempt in $(seq 1 30); do
  if openssl s_client \
    -connect 127.0.0.1:8883 \
    -servername mosquitto \
    -verify_hostname mosquitto \
    -verify_return_error \
    -CAfile "$TAPIR_CORE_CA_CERT" \
    -cert "$TAPIR_CORE_BRIDGE_CERT" \
    -key "$TAPIR_CORE_BRIDGE_KEY" \
    < /dev/null 2>&1 | grep -c 'Verification: OK' >/dev/null; then
    break
  fi
  sleep 1
done
openssl s_client \
  -connect 127.0.0.1:8883 \
  -servername mosquitto \
  -verify_hostname mosquitto \
  -verify_return_error \
  -CAfile "$TAPIR_CORE_CA_CERT" \
  -cert "$TAPIR_CORE_BRIDGE_CERT" \
  -key "$TAPIR_CORE_BRIDGE_KEY" \
  < /dev/null 2>&1 | grep -c 'Verification: OK' >/dev/null

docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" up -d mqtt-bridge
sleep 3
test -n "$(docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  ps --status running -q mqtt-bridge)"
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" ps
TAPIR_CORE_KEEP_RUNNING=1
)
```

## 14. Troubleshooting as `dnstapir`

Verify the Rootless Docker user service and socket first:

```bash
test "$(id -un)" = "$TAPIR_SERVICE_USER"
printf '%s\n' "$DOCKER_HOST"
systemctl --user --no-pager --full status docker.service
journalctl --user --unit docker.service --lines 100 --no-pager
docker context show
docker info --format '{{json .SecurityOptions}}'
```

Show occupied test ports and container port mappings:

```bash
ss -lntp | grep -E ':(1883|27017|4222|6379|8080|8081|8222|8883|9000|9001)\b' || true
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Inspect the logs retained by the self-cleaning validation sections:

```bash
TAPIR_CORE_TEST_LOG="$TAPIR_LOGS/core-integration-test.log"
TAPIR_CORE_SERVICE_LOG="$TAPIR_LOGS/core-integration-services.log"
TAPIR_NODEMAN_LOG="$TAPIR_LOGS/nodeman.log"
TAPIR_NODEMAN_MONGO_LOG="$TAPIR_LOGS/nodeman-mongo.log"
TAPIR_AGGREC_LOG="$TAPIR_LOGS/aggrec.log"
TAPIR_AGGREC_DEPENDENCY_LOG="$TAPIR_LOGS/aggrec-dependencies.log"
TAPIR_MQTT_BRIDGE_TEST_LOG="$TAPIR_LOGS/mqtt-bridge-integration-test.log"

test ! -f "$TAPIR_CORE_TEST_LOG" || tail -n 200 "$TAPIR_CORE_TEST_LOG"
test ! -f "$TAPIR_CORE_SERVICE_LOG" || tail -n 200 "$TAPIR_CORE_SERVICE_LOG"
test ! -f "$TAPIR_NODEMAN_LOG" || tail -n 200 "$TAPIR_NODEMAN_LOG"
test ! -f "$TAPIR_NODEMAN_MONGO_LOG" || tail -n 200 "$TAPIR_NODEMAN_MONGO_LOG"
test ! -f "$TAPIR_AGGREC_LOG" || tail -n 200 "$TAPIR_AGGREC_LOG"
test ! -f "$TAPIR_AGGREC_DEPENDENCY_LOG" || tail -n 200 "$TAPIR_AGGREC_DEPENDENCY_LOG"
test ! -f "$TAPIR_MQTT_BRIDGE_TEST_LOG" || tail -n 200 "$TAPIR_MQTT_BRIDGE_TEST_LOG"
```

Inspect both persistent stacks if Section 11 or Section 12 left them
running:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
TAPIR_CORE_RUNTIME_COMPOSE="$TAPIR_TEST_ROOT/core-runtime/compose.yaml"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" ps
# NATS is on the services VM; see its runbook Section 12 for its logs.
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  logs --tail=200 observation-encoder
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  logs --tail=200 tapir-analyse-looptest
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  logs --tail=200 tapir-analyse-new-qname
docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  logs --tail=200 tapir-analyse-listchecker
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" ps
docker compose --file "$TAPIR_CORE_RUNTIME_COMPOSE" \
  logs --tail=300 mongo nodeman mosquitto mqtt-bridge
```

Remove the retained Go caches when reclaiming disk space or resetting the
workspace. The Go module cache is written with read-only directories and files,
so `rm -rf` alone fails with `Permission denied` on every entry; make the tree
writable first:

```bash
test -n "$TAPIR_RUN"
chmod -R u+w "$TAPIR_RUN/mqtt-bridge-go-cache"
rm -rf "$TAPIR_RUN/mqtt-bridge-go-cache"
```

Stop and remove the fixed-name projects and their test volumes before a clean
retry:

```bash
TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
TAPIR_NODEMAN_DIR="$TAPIR_SRC/nodeman"
TAPIR_NODEMAN_COMPOSE_FILE="$TAPIR_NODEMAN_DIR/docker-compose.yaml"
TAPIR_AGGREC_DIR="$TAPIR_SRC/aggrec"
TAPIR_AGGREC_COMPOSE_FILE="$TAPIR_AGGREC_DIR/docker-compose.yaml"
TAPIR_MQTT_BRIDGE_DIR="$TAPIR_SRC/mqtt-bridge"
TAPIR_MQTT_COMPOSE_FILE="$TAPIR_MQTT_BRIDGE_DIR/itests/sut/docker-compose.yaml"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  down --volumes --remove-orphans
docker compose --file "$TAPIR_NODEMAN_COMPOSE_FILE" \
  down --volumes --remove-orphans
docker compose --file "$TAPIR_AGGREC_COMPOSE_FILE" \
  down --volumes --remove-orphans
docker compose --file "$TAPIR_MQTT_COMPOSE_FILE" \
  down --volumes --remove-orphans
```

After collecting those logs, retry from fresh NATS state. The suite can also be
re-run against the existing container, because every test uses a query name that
is either unique per run or exempt from new-qname deduplication; a fresh
stack is used here only so a retry starts from known state:

```bash
TAPIR_SERVICES_DIR="$TAPIR_TEST_ROOT/services-bundle"
set -a
# shellcheck disable=SC1091
. "$TAPIR_SERVICES_DIR/services.env"
set +a
(
set -euo pipefail

TAPIR_CORE_INTEGRATION_DIR="$TAPIR_SRC/core-integration-test"
TAPIR_CORE_ANALYSIS_COMPOSE="$TAPIR_TEST_ROOT/core-analysis/compose.yaml"
TAPIR_CORE_VENV="$TAPIR_CORE_INTEGRATION_DIR/.venv"
TAPIR_CORE_RETRY_LOG="$TAPIR_LOGS/core-integration-test-retry.log"
TAPIR_CORE_RETRY_SERVICE_LOG="$TAPIR_LOGS/core-integration-services-retry.log"
# Compose reads these; without them it falls back to the published images.
set -a
. "$TAPIR_TEST_ROOT/images.env"
set +a

tapir_core_retry_cleanup() {
  TAPIR_CORE_RETRY_STATUS="$?"
  TAPIR_CORE_RETRY_CLEANUP_FAILED=0
  set +e
  docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
    logs --no-color --tail=200 \
    > "$TAPIR_CORE_RETRY_SERVICE_LOG" 2>&1
  if ! docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
    down --volumes --remove-orphans; then
    TAPIR_CORE_RETRY_CLEANUP_FAILED=1
  fi
  if [ "$TAPIR_CORE_RETRY_STATUS" -eq 0 ] && \
     [ "$TAPIR_CORE_RETRY_CLEANUP_FAILED" -ne 0 ]; then
    TAPIR_CORE_RETRY_STATUS=1
  fi
  trap - EXIT
  exit "$TAPIR_CORE_RETRY_STATUS"
}
trap tapir_core_retry_cleanup EXIT

test -x "$TAPIR_CORE_VENV/bin/pytest"
cd "$TAPIR_CORE_INTEGRATION_DIR"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  down --volumes --remove-orphans

for attempt in $(seq 1 30); do
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222"; then
    break
  fi
  sleep 1
done

timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TAPIR_SERVICES_VM_IP/4222"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  up -d observation-encoder
sleep 3
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q observation-encoder)"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" up -d \
  tapir-analyse-looptest \
  tapir-analyse-new-qname \
  tapir-analyse-listchecker
sleep 3
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q tapir-analyse-looptest)"
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q tapir-analyse-new-qname)"
test -n "$(docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" \
  ps --status running -q tapir-analyse-listchecker)"

docker compose --file "$TAPIR_CORE_ANALYSIS_COMPOSE" ps
"$TAPIR_CORE_VENV/bin/pytest" -vv -s 2>&1 \
  | tee "$TAPIR_CORE_RETRY_LOG"
)
```

## 15. Completion checklist

- [ ] `dnstapir-host-bootstrap.sh` completed and its verification section passed
- [ ] Docker Engine and Compose installed before any project Docker command
- [ ] Dedicated `dnstapir` account created with no `sudo` access
- [ ] `dnstapir` is not a member of the root-equivalent `docker` group
- [ ] `newuidmap`, `newgidmap`, and `slirp4netns` are installed
- [ ] Rootless Docker reports the `rootless` security option
- [ ] Workspace, repositories, logs, and processes are owned by `dnstapir`
- [ ] Project Docker and service commands run as `dnstapir` without `sudo`
- [ ] Eight repositories cloned
- [ ] Eight commit IDs recorded
- [ ] Four analysis images built from source and tagged `:core-source`
- [ ] `images.env` names the four built images and is read by Sections 7 and 11
- [ ] No `ghcr.io/dnstapir/*` image is pulled anywhere in this runbook
- [ ] Cloned `core-integration-test` includes the subscribe-before-publish helper
- [ ] Each integration-test run starts from fresh NATS/JetStream state
- [ ] NATS starts first and passes its health check
- [ ] Observation Encoder starts before the analyst containers
- [ ] Core integration tests pass
- [ ] Node Manager configuration validates before startup
- [ ] Node Manager enrollment succeeds
- [ ] Node Manager certificate renewal succeeds
- [ ] Aggregate Receiver configuration validates before startup
- [ ] Aggregate Receiver accepts the P-256 aggregate
- [ ] Aggregate Receiver accepts the Ed25519 aggregate
- [ ] Aggregate metadata appears in MongoDB
- [ ] Aggregate objects appear in RustFS
- [ ] MQTT bridge integration test passes
- [ ] Persistent NodeMan and mqtt-bridge images build successfully
- [ ] Persistent NodeMan is reachable on TCP 8080
- [ ] Broker certificate contains the Core VM IP as a subject alternative name
- [ ] CA, broker, and mqtt-bridge certificate expiry checks pass
- [ ] Mosquitto accepts only CA-issued client certificates on TCP 8883
- [ ] Mosquitto enforces an ACL confining each Edge to `events/up/<its own name>/#`
- [ ] mqtt-bridge authenticates to Mosquitto with its own client certificate
- [ ] Mosquitto runs with `user root` so it can read its mode-0600 server key
- [ ] `mqtt-bridge` connects over `mqtts://` and logs `connection up and ready for use`
- [ ] mqtt-bridge uses NodeMan for enrolled Edge data-signing keys
- [ ] Validation sections leave no test containers or test volumes running
- [ ] Disposable test keys, credentials, payloads, and staged bridge files are removed
- [ ] Validation output and service logs remain under `$TAPIR_LOGS`
- [ ] Core analysis stack is running at the end, against the services VM
- [ ] NodeMan, Mosquitto, and mqtt-bridge are running at the end
- [ ] No MongoDB or NATS container runs on this host; both are on the services VM
- [ ] The services VM answers on TCP 4222 and 27017
- [ ] NodeMan logs `MongoDB connected` against the services VM
- [ ] The installed CA fingerprint matches the services VM's
- [ ] Pipeline assertions use `grep -c ... >/dev/null`, never a terminal `grep -q`
- [ ] The Edge node name has never been enrolled before, or its record was fully removed

## 16. Sources

- [DNS TAPIR Core documentation](https://www.dnstapir.se/docs/dnstapir-core/)
- [DNS TAPIR technical documentation](https://dnstapir.github.io/techdocs)
- [DNS TAPIR security brief](https://www.dnstapir.se/docs/security-brief/)
- [Core integration test](https://github.com/dnstapir/core-integration-test)
- [Core integration Compose file](https://github.com/dnstapir/core-integration-test/blob/main/sut/docker-compose.yaml)
- [New-qname integration-test configuration](https://github.com/dnstapir/core-integration-test/blob/main/sut/tapir-analyse-new-qname/config.toml)
- [Observation Encoder](https://github.com/dnstapir/observation-encoder)
- [Loop-test analyst](https://github.com/dnstapir/tapir-analyse-looptest)
- [New-qname analyst](https://github.com/dnstapir/tapir-analyse-new-qname)
- [List-checker analyst](https://github.com/dnstapir/tapir-analyse-listchecker)
- [Node Manager](https://github.com/dnstapir/nodeman)
- [Node Manager settings schema](https://github.com/dnstapir/nodeman/blob/main/nodeman/settings.py)
- [Aggregate Receiver](https://github.com/dnstapir/aggrec)
- [Aggregate Receiver settings schema](https://github.com/dnstapir/aggrec/blob/main/aggrec/settings.py)
- [MQTT bridge](https://github.com/dnstapir/mqtt-bridge)
- [MQTT bridge TLS configuration](https://github.com/dnstapir/mqtt-bridge/blob/main/README.md)
- [Mosquitto TLS configuration reference](https://mosquitto.org/man/mosquitto-conf-5.html)
- [Docker Engine for Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Linux post-installation](https://docs.docker.com/engine/install/linux-postinstall/)
- [Docker Rootless mode](https://docs.docker.com/engine/security/rootless/)
- [Docker Rootless operation](https://docs.docker.com/engine/security/rootless/tips/)
- [Testcontainers for Go configuration](https://golang.testcontainers.org/features/configuration/)
- [Running Testcontainers tests inside Docker](https://golang.testcontainers.org/system_requirements/ci/dind_patterns/)
