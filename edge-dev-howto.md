# Running a dnstapir Edge for local development

A step-by-step recipe for getting a **standalone, local-only** dnstapir Edge
([dnstapir/edge-stack](https://github.com/dnstapir/edge-stack)) running on a single
machine — no enrollment, no upstream connectivity, no dnstapir admin needed. You will
end up with Unbound resolving DNS on the host, EDM minimising the queries it sees,
parquet output landing on a Docker volume, and Prometheus metrics exposed for
inspection.

If you instead need to connect to the upstream dev infra at `*.dev.dnstapir.se`, this
how-to is not it — that path requires enrollment credentials issued out-of-band.

This recipe was verified against `edge-stack@main` as of 2026-04-28. The upstream
README is currently two lines and there is no quickstart in the org, so most of the
steps below fill in gaps rather than rephrase existing docs.

## 1. What you'll build

```
                +------------------+         DNSTAP/TCP         +------------------+
  dig --->  53  | resolver         | --- 10.53.0.11:53535 --->  | edm              | --> /var/lib/edm/parquet/
            853 | (Unbound)        |                            | (minimiser)      |     (sessions, histograms)
            443 | 10.53.0.10       |                            | 10.53.0.11       |
                +------------------+                            +------------------+
                       ^                                                ^
                       |                                                |
                  ./unbound/*.conf                                ./keys/, ./edm/config/
                  (read-only mounts)                              (read-only mounts)

         Docker network "internal" — 10.53.0.0/24
```

Two containers and a one-shot init container, on a private Docker network. MQTT and
HTTP aggregates upload (which the upstream `docker-compose.yaml` enables by default)
are turned off in the override file you will write in step 6.

## 2. Prerequisites

- **Docker Engine ≥ 24** with the **Compose v2** plugin (`docker compose`, not
  `docker-compose`).
- ~8 GB RAM free. The compose file caps each of `resolver` and `edm` at 4 GB.
- Host ports **53/tcp**, **53/udp**, **443/tcp**, **443/udp**, **853/tcp** free, plus
  **2112/tcp** and **6060/tcp** which the override file below will publish for
  metrics/pprof. On Linux, binding `:53` typically requires root; on Ubuntu/Debian
  desktops, `systemd-resolved` already holds `:53` — see the troubleshooting section.
- `git`, `make`.
- `step` CLI ([smallstep.com/cli](https://smallstep.com/cli)) **or** `openssl` —
  either is enough to produce the placeholder keys EDM mounts. `step` is cleaner;
  `openssl` works if you don't want a new tool.
- `dig` (BIND `dnsutils` package on Debian/Ubuntu) for sending test queries.
- `duckdb` (optional) — handy for reading the parquet output. The EDM container has
  it pre-installed, so you do not need it on the host.
- A Go toolchain (Go 1.24+). You will use it for two things: building
  `dnstapir-cli` (step 5) and building the EDM container image from source
  (step 5b — the published image is private, see below).

## 3. Clone edge-stack

```bash
git clone https://github.com/dnstapir/edge-stack.git
cd edge-stack
```

All remaining commands assume your shell is in the `edge-stack` directory.

## 4. Generate placeholder keys and config

EDM's container mounts `./keys/` read-only and the run command references
`jws.key`, `tls.crt`, `tls.key`, and `ca.crt` from that directory. Even with MQTT
and HTTP disabled (step 6), the files must exist on disk or the bind-mount will
fail. The bundled `Makefile` generates them.

### Option A — using the `step` CLI (preferred)

The default `make bootstrap` target talks to the upstream Step CA at
`https://step.dev.dnstapir.se:9000` to fetch a CA root. For a fully offline run we
do not need a real CA cert, so substitute a self-signed dummy:

```bash
make keys
make $(make -np 2>/dev/null | awk '/^JWS_PRIVKEY = /{print $3}')   # generates keys/jws.key
make $(make -np 2>/dev/null | awk '/^TLS_PRIVKEY = /{print $3}')   # generates keys/tls.key
step certificate create dummy keys/tls.crt keys/tls.key \
    --profile self-signed --subtle --no-password --insecure --force
cp keys/tls.crt keys/ca.crt
make .env
make edm/config/edm.toml
```

The two `make $(...)` lines just trigger the JWS and TLS keypair targets without
also pulling in the upstream CA fetch. If you'd rather run the targets by hand:

```bash
mkdir -p keys edm/config
step crypto keypair keys/jws-public.key keys/jws.key \
    --insecure --no-password --kty EC --crv P-256
step crypto keypair keys/tls-public.key keys/tls.key \
    --insecure --no-password --kty EC --crv P-256
step certificate create dummy keys/tls.crt keys/tls.key \
    --profile self-signed --subtle --no-password --insecure --force
cp keys/tls.crt keys/ca.crt
echo "NAME=dev-$(whoami)" > .env
echo "cryptopan-key = \"$(openssl rand -base64 15)\"" > edm/config/edm.toml
```

### Option B — using `openssl` only

The bundled `make openssl-boostrap` target (note the typo — that is the actual
target name) generates EC keypairs and a CSR. It has a bug on its last line that
references a nonexistent file `xyzzy-pki.csr`, so the recipe will fail near the
end. Run the equivalent commands directly:

```bash
mkdir -p keys edm/config
openssl ecparam -name prime256v1 -genkey -noout -out keys/jws.key
openssl ec -in keys/jws.key -pubout -out keys/jws-public.key
openssl ecparam -name prime256v1 -genkey -noout -out keys/tls.key
openssl ec -in keys/tls.key -pubout -out keys/tls-public.key
openssl req -x509 -new -key keys/tls.key -out keys/tls.crt \
    -days 365 -subj "/CN=dummy" -nodes
cp keys/tls.crt keys/ca.crt
echo "NAME=dev-$(whoami)" > .env
echo "cryptopan-key = \"$(openssl rand -base64 15)\"" > edm/config/edm.toml
```

After either option you should see:

```
keys/
  ca.crt        ← placeholder, never validated against anything in local-only mode
  jws.key
  jws-public.key
  tls.crt
  tls.key
  tls-public.key
edm/config/
  edm.toml      ← contains cryptopan-key = "<random>"
.env            ← NAME=dev-<you>
```

## 5. Create a `well-known-domains.dawg`

EDM refuses to start without a DAWG file at the path passed to
`--well-known-domains-file`. The file is a compact precomputed lookup that EDM
uses to bin "interesting" domains separately from the long tail. For a local dev
run, a tiny test DAWG is enough.

The compiler is a subcommand of `dnstapir-cli`. Note that `dnstapir/cli` is
**not** `go install`-able directly — its `go.mod` declares `module dnstapir-cli`
without a domain, so the canonical install path is to build from source:

```bash
git clone https://github.com/dnstapir/cli.git /tmp/dnstapir-cli
make -C /tmp/dnstapir-cli build
DNSTAPIR_CLI=/tmp/dnstapir-cli/out/dnstapir-cli
"$DNSTAPIR_CLI" --help    # sanity check
```

Then build the DAWG from a small CSV. Back in the `edge-stack` directory:

```bash
cat > /tmp/tiny-domains.csv <<'EOF'
1,example.com
2,example.org
3,example.net
4,iana.org
5,wikipedia.org
EOF
"$DNSTAPIR_CLI" --standalone dawg compile \
    --format csv \
    --src /tmp/tiny-domains.csv \
    --dawg edm/config/well-known-domains.dawg
```

If you want a realistic DAWG (e.g., the DomCop top 10M list), substitute that CSV
in. Compilation takes a few minutes and the resulting file is ~100 MB.

> **Verify command syntax:** the exact CSV column layout and flag names for
> `dnstapir-cli dawg compile` may differ between cli versions. Run
> `"$DNSTAPIR_CLI" --standalone dawg compile --help` first if the command above
> errors out — the help text is authoritative.

## 5b. Build the EDM and Unbound images locally

The upstream compose file references `ghcr.io/dnstapir/edm:latest` and
`ghcr.io/dnstapir/unbound:latest`, but as of this writing **both packages are
private** — an anonymous `docker pull` returns `DENIED`. There is no published
public image and no GitHub release tarball. You have to build both locally and
tag them with the names compose expects.

Two more issues with the upstream EDM source that this step works around:

- The `dnstapir/edm` repo only ships a `.ko.yaml` (it's released via
  [ko](https://ko.build)), not a `Dockerfile`. We add a small one inline.
- EDM hard-codes its Prometheus metrics endpoint to `127.0.0.1:2112` and pprof to
  `127.0.0.1:6060` — both bind only on container-local loopback, so neither the
  host's port-forward nor a sibling container (like Prometheus) can reach them.
  We patch both to bind on `0.0.0.0` before building.

```bash
# Unbound
git clone https://github.com/dnstapir/unbound.git /tmp/dnstapir-unbound
docker build -t ghcr.io/dnstapir/unbound:latest /tmp/dnstapir-unbound

# EDM
git clone https://github.com/dnstapir/edm.git /tmp/dnstapir-edm
sed -i 's|"127.0.0.1:6060"|"0.0.0.0:6060"|; s|"127.0.0.1:2112"|"0.0.0.0:2112"|' \
    /tmp/dnstapir-edm/pkg/runner/runner.go
cat > /tmp/dnstapir-edm/Dockerfile <<'EOF'
# syntax=docker/dockerfile:1
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=dev-local" \
    -o /out/dnstapir-edm ./cmd/dnstapir-edm

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/dnstapir-edm /usr/bin/dnstapir-edm
USER 65532:65532
ENTRYPOINT ["/usr/bin/dnstapir-edm"]
EOF
docker build -t ghcr.io/dnstapir/edm:latest /tmp/dnstapir-edm
```

Confirm both tags exist:

```bash
docker image ls | grep -E '^ghcr.io/dnstapir/'
```

## 6. Override for local-only mode + a Grafana dashboard

This step does three things in a single override file:

1. **Disable MQTT and HTTP egress.** The upstream `docker-compose.yaml` hard-wires
   EDM to dial `tls://mqtt.dev.dnstapir.se:8883` and
   `https://aggregates.dev.dnstapir.se`. Without enrollment certs, these
   connections fail in a loop and clutter the logs.
2. **Re-enable session parquet output**, which the upstream config explicitly
   disables, so you can see EDM doing its job.
3. **Add Prometheus + Grafana** to scrape EDM's `:2112` metrics and visualise
   them in a browser. EDM exposes things like queries-per-second, well-known vs.
   unknown name ratios, processing latency, and memory pressure as Prometheus
   counters; Grafana turns those into time-series graphs.

### Create the supporting config files

Prometheus needs a scrape config; Grafana needs a datasource provisioning file
and a dashboards provisioning file:

```bash
mkdir -p prometheus \
         grafana/provisioning/datasources \
         grafana/provisioning/dashboards \
         grafana/dashboards

cat > prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: edm
    static_configs:
      - targets: ['edm:2112']
EOF

cat > grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

cat > grafana/provisioning/dashboards/dashboards.yaml <<'EOF'
apiVersion: 1
providers:
  - name: edm
    orgId: 1
    folder: EDM
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
EOF
```

The datasource gets `uid: prometheus` so the provisioned dashboards can reference
it stably (without it Grafana auto-generates a UID and the dashboard JSON would
have to match it). The dashboards provider points at `/var/lib/grafana/dashboards`,
which the override below mounts from `./grafana/dashboards/`.

Three EDM dashboards are reproduced verbatim in **Appendix A** at the end of this
doc — drop each into `grafana/dashboards/<name>.json` and they auto-load when
Grafana starts (and reload within 10 s of any edit, thanks to
`updateIntervalSeconds: 10`).

### Write the override

Create `docker-compose.override.yaml` next to `docker-compose.yaml`. Compose
auto-merges any file with that exact name in the same directory.

```yaml
services:
  edm:
    ports:
      - 2112:2112    # Prometheus metrics, also scraped internally by prometheus below
      - 6060:6060    # pprof
    command:
      - run
      - --input-tcp=10.53.0.11:53535
      - --minimiser-workers=3
      - --data-dir=/var/lib/edm
      - --disable-mqtt
      - --disable-histogram-sender
      - --config-file=/etc/dnstapir/edm/edm.toml
      - --well-known-domains-file=/etc/dnstapir/edm/well-known-domains.dawg

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    networks:
      - internal
    ports:
      - 9090:9090
    depends_on:
      - edm

  grafana:
    image: grafana/grafana-oss:latest
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    environment:
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Admin
      GF_AUTH_DISABLE_LOGIN_FORM: "true"
    networks:
      - internal
    ports:
      - 3000:3000
    depends_on:
      - prometheus
```

Note what changed in the `edm` block vs. the upstream command:

- `--disable-mqtt` added → no MQTT broker connection attempted.
- `--data-dir=/var/lib/edm` added → matches the volume mount in the base compose
  (`edm-data:/var/lib/edm`). EDM's built-in default is `/var/lib/dnstapir/edm`,
  which doesn't exist inside the container and would fail to open the pebble KV
  store at startup.
- `--disable-session-files` removed → session parquet files are written so you can
  inspect them.
- `--disable-histogram-sender` kept → histograms still get computed but nothing is
  uploaded over HTTP. Drop this flag too if you want to see histogram parquet
  output and don't mind the upload retries failing in the background.
- All `--mqtt-*` and `--http-*` flags removed → with the disable flags above, the
  cert/key references they pointed at are no longer needed at runtime (the files
  still need to exist for the read-only volume mount, hence step 4).

The `prometheus` and `grafana` services join the existing `internal` network
(defined in the base compose file) so Prometheus can resolve `edm` by service
name and Grafana can reach Prometheus the same way. Anonymous + admin Grafana
auth is fine for a local dev box; do not copy this for anything else.

Confirm the merge with:

```bash
docker compose config | less
```

Look for the `edm` service's `command:` block and verify it matches the override
above, with no `mqtt.dev.dnstapir.se` or `aggregates.dev.dnstapir.se` left, and
that `prometheus` and `grafana` show up as services.

## 7. Bring the stack up

```bash
docker compose up -d
docker compose ps
```

Expected: `resolver` running, `edm` running, `edm-init` exited 0. Tail the EDM
logs to confirm a clean start:

```bash
docker compose logs -f edm
```

A healthy first second of output mentions opening the input TCP listener, loading
the DAWG file, and reaching steady state. Errors mentioning `mqtt.dev.dnstapir.se`
or "histogram-sender" mean the override didn't load (see troubleshooting).

## 8. Send test queries

The resolver is on `127.0.0.1:53` from the host's perspective. Standard `dig`
works:

```bash
dig @127.0.0.1 example.com +short
dig @127.0.0.1 wikipedia.org +short
dig @127.0.0.1 iana.org +short
```

If port 53 on the host is taken, either free it (see troubleshooting) or remap
the resolver's port mapping in the override file:

```yaml
services:
  resolver:
    ports:
      - 5353:53/tcp
      - 5353:53/udp
```

…and then `dig @127.0.0.1 -p 5353 example.com`.

## 9. Verify the data path

Three quick checks confirm DNSTAP is flowing from resolver → EDM and EDM is
producing minimised output.

**a. Prometheus metrics.** With the override's port mapping:

```bash
curl -s localhost:2112/metrics | grep -E '^edm_' | head
```

You should see counters like `edm_dnstap_processed_total` increasing as you send
more queries.

**b. Parquet files appearing on the volume.** The EDM image is distroless and
has no shell, so list the named volume from a throwaway BusyBox container:

```bash
docker run --rm -v edge-stack_edm-data:/d busybox \
    ls -la /d/parquet/sessions /d/parquet/histograms/outbox
```

You should see `dns_session_block-*.parquet` files appearing once a session
window closes (default ~1 minute). If both directories are empty, send more
queries and wait.

**c. Read a parquet file with DuckDB.** DuckDB isn't installed in the EDM image
either — easiest is a throwaway Python container with the duckdb pip package:

```bash
docker run --rm -v edge-stack_edm-data:/d python:3.13-slim sh -c \
    'pip install -q duckdb && python -c "
import duckdb
print(duckdb.sql(\"select count(*) as rows from read_parquet('"'"'/d/parquet/sessions/*.parquet'"'"')\").fetchall())
"'
```

If you already have `duckdb` on the host, you can copy the parquet files out
with `docker cp` (or read them straight from `/var/lib/docker/volumes/edge-stack_edm-data/_data/`
with `sudo`) and query them locally instead.

Source IPs in the output will be Crypto-PAn-encrypted using the random key
generated in step 4 — that is by design and confirms minimisation is on.

## 9b. Browse the Grafana dashboards

Open `http://localhost:3000` in a browser. Anonymous-admin auth is enabled, so
you land directly on the home screen with no login.

Under **Dashboards → EDM** you'll find three pre-provisioned dashboards (the
JSON files copied from Appendix A in step 6):

| Dashboard | URL | What it shows |
|---|---|---|
| **EDM — Overview** | `http://localhost:3000/d/edm-overview` | Top-line counters (DNSTAP processed, new qnames, ignored, RSS), processing rate, qname queued-vs-discarded, and a stacked breakdown of ignored DNSTAP by reason. |
| **EDM — Internals** | `http://localhost:3000/d/edm-internals` | Cryptopan LRU hit ratio and eviction rate, seen-qname LRU evictions, new_qname channel-buffer length and pipeline backpressure. |
| **EDM — Process health** | `http://localhost:3000/d/edm-process` | Goroutines, OS threads, open FDs, GOMAXPROCS, CPU rate, heap and process memory, GC pause quantiles. |

Each dashboard auto-refreshes every 10 s. If you edit a panel in the UI it'll
also rewrite the on-disk JSON (since `allowUiUpdates: true`), so the dashboard
survives a `docker compose down && up`.

The Prometheus datasource is also wired up — under **Connections → Data sources**
you should see "Prometheus" with `http://prometheus:9090`. For ad-hoc queries
outside the dashboards, **Explore** (compass icon, left rail) is the place. Try:

```
rate(edm_processed_dnstap_total[1m])          # processing rate, queries/sec
edm_new_qname_queued_total                    # cumulative new qname events
go_goroutines{job="edm"}                      # current goroutine count
process_resident_memory_bytes{job="edm"}      # EDM RSS
```

To sanity-check Prometheus directly, hit `http://localhost:9090/targets` — the
`edm` target should be listed as `UP`. If it's `DOWN`, Prometheus can't reach
EDM on the docker network; double-check that both services are on the `internal`
network in `docker compose config`.

### Adding more dashboards

Drop a new `*.json` file into `grafana/dashboards/`. Within `updateIntervalSeconds`
(10 s) Grafana picks it up automatically. The fastest path to a new dashboard is:

1. Build it in the UI (**Dashboards → New**), pick the `Prometheus` datasource.
2. **Settings → JSON Model**, copy the JSON, save it as
   `grafana/dashboards/<your-name>.json`.
3. Make sure the JSON's `datasource` references use `"uid": "prometheus"` so the
   dashboard works on a fresh `docker compose up`.

## 10. Tear down

Stop containers and drop the named volume (otherwise parquet output sticks
around):

```bash
docker compose down -v
```

Optionally also remove generated keys and config:

```bash
make realclean
rm -f docker-compose.override.yaml edm/config/well-known-domains.dawg
rm -rf prometheus grafana
```

## 11. Common pitfalls

- **`bind: address already in use` on port 53** — `systemd-resolved` on
  Ubuntu/Debian holds `:53` by default. Either disable its stub listener
  (`echo 'DNSStubListener=no' | sudo tee -a /etc/systemd/resolved.conf` then
  `sudo systemctl restart systemd-resolved`) or remap the resolver's port via
  the override snippet in step 8.
- **EDM exits with a `well-known-domains` error** — step 5 was skipped or the
  DAWG file is at the wrong path. The container expects it at
  `/etc/dnstapir/edm/well-known-domains.dawg`, which is `./edm/config/well-known-domains.dawg`
  on the host.
- **EDM logs full of `mqtt.dev.dnstapir.se` connection errors** — the override
  file isn't being merged. It must be named exactly `docker-compose.override.yaml`
  (or `.yml`) and live in the same directory as `docker-compose.yaml`. Run
  `docker compose config` to see the merged result and confirm the EDM `command`
  block matches step 6.
- **Resolver returns `SERVFAIL` for everything** — Unbound is configured to
  recurse from the root, which works on most networks but fails behind some
  corporate/captive networks. Add a `forward-zone` snippet to
  `unbound/conf.d/forwarders.conf` (e.g., forward to `1.1.1.1`) and restart the
  resolver container.
- **`make openssl-boostrap` fails on its last line** — known typo in the upstream
  Makefile (`xyzzy-pki.csr` is hard-coded). Step 4 Option B avoids it by running
  the openssl commands directly.
- **Port 2112 or 6060 already in use** — those are added by the override in
  step 6. Either change the host-side port (`- 12112:2112`) or drop the
  `ports:` block on `edm` and `docker compose exec edm curl ...` from inside
  the container instead.
- **Port 3000 or 9090 already in use** — Grafana defaults to `3000` and is a
  common collision (Node dev servers, other Grafana instances). Remap to
  `- 13000:3000` and `- 19090:9090` in the override.
- **Grafana shows the Prometheus datasource as `failed`** — Grafana started
  before the provisioning file existed, or the file has a YAML syntax error.
  Recreate `grafana/provisioning/datasources/prometheus.yml` from step 6, then
  `docker compose restart grafana`.
- **Prometheus `/targets` shows `edm` as DOWN** — usually means EDM crashed,
  failed to bind `:2112`, or isn't on the `internal` network. Check
  `docker compose logs edm` and `docker compose config` to confirm both services
  are wired to the same network.

## 12. Where to go from here

Once the local-only path works, two natural next steps — each its own setup, not
covered here:

- **Connect to the upstream dev infra.** Requires enrollment credentials from a
  dnstapir admin (issued via [nodeman](https://github.com/dnstapir/nodeman)) and
  removing the override file so EDM dials `mqtt.dev.dnstapir.se` and
  `aggregates.dev.dnstapir.se` for real.
- **Run nodeman + a local Step CA alongside edge-stack** for full end-to-end
  testing of enrollment, certificate renewal, and MQTT publishing without
  external infrastructure. The [nodeman README](https://github.com/dnstapir/nodeman)
  has a `make internal_ca` target that is the entry point.

Beyond that the dnstapir org has [pop](https://github.com/dnstapir/pop) (policy
processor), [aggrec](https://github.com/dnstapir/aggrec) (aggregate receiver),
and [evrec](https://github.com/dnstapir/evrec) (event receiver) — each can be
stood up locally to consume what this edge produces.

## Appendix A — Provisioned Grafana dashboards

These three JSON files belong under `grafana/dashboards/` (created in step 6).
Each one references the Prometheus datasource by `"uid": "prometheus"`, so they
work as soon as the datasource provisioning file from step 6 is in place.

The metrics used here come straight from EDM's `/metrics` endpoint as of the
EDM `main` branch verified for this how-to. If your EDM build exposes different
counter names, edit each panel's `expr` accordingly — Grafana picks up changes
within `updateIntervalSeconds` (10 s) without a container restart.

### A.1 — `grafana/dashboards/edm-overview.json`

Top-line counters and rates: total processed/discarded/new-qnames, RSS, the
processing-rate timeseries, queued-vs-discarded new-qname events, and a stacked
breakdown of ignored DNSTAP by reason.

```json
{
  "uid": "edm-overview",
  "title": "EDM — Overview",
  "tags": ["edm", "dnstapir"],
  "schemaVersion": 39,
  "version": 1,
  "timezone": "",
  "refresh": "10s",
  "time": {"from": "now-15m", "to": "now"},
  "templating": {"list": []},
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "DNSTAP packets processed (total)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 0, "w": 6, "h": 4},
      "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "edm_processed_dnstap_total", "legendFormat": "processed"}]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "New qnames seen (total)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 6, "y": 0, "w": 6, "h": 4},
      "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "edm_new_qname_queued_total", "legendFormat": "new qnames"}]
    },
    {
      "id": 3,
      "type": "stat",
      "title": "DNSTAP discarded (total, all reasons)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 12, "y": 0, "w": 6, "h": 4},
      "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "yellow", "value": null}, {"color": "red", "value": 1}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "sum(edm_ignored_client_ip_total + edm_ignored_client_ip_error_total + edm_ignored_dns_parse_error_total + edm_ignored_empty_question_section_total + edm_ignored_invalid_question_name_total + edm_ignored_question_name_total)", "legendFormat": "ignored"}]
    },
    {
      "id": 4,
      "type": "stat",
      "title": "EDM resident memory",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 18, "y": 0, "w": 6, "h": 4},
      "fieldConfig": {"defaults": {"unit": "bytes", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "process_resident_memory_bytes{job=\"edm\"}", "legendFormat": "RSS"}]
    },
    {
      "id": 10,
      "type": "timeseries",
      "title": "DNSTAP processing rate",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8},
      "fieldConfig": {"defaults": {"unit": "ops", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 15, "lineWidth": 2}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "single", "sort": "none"}},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_processed_dnstap_total[1m])", "legendFormat": "processed/s"}]
    },
    {
      "id": 11,
      "type": "timeseries",
      "title": "New-qname events: queued vs discarded",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8},
      "fieldConfig": {"defaults": {"unit": "ops", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 15, "lineWidth": 2}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "single", "sort": "none"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_new_qname_queued_total[1m])", "legendFormat": "queued/s"},
        {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_new_qname_discarded_total[1m])", "legendFormat": "discarded/s"}
      ]
    },
    {
      "id": 20,
      "type": "timeseries",
      "title": "Ignored DNSTAP — by reason (rate)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 12, "w": 24, "h": 8},
      "fieldConfig": {"defaults": {"unit": "ops", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10, "lineWidth": 2, "stacking": {"mode": "normal"}}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_ignored_client_ip_total[1m])", "legendFormat": "client_ip"},
        {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_ignored_client_ip_error_total[1m])", "legendFormat": "client_ip_error"},
        {"refId": "C", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_ignored_dns_parse_error_total[1m])", "legendFormat": "dns_parse_error"},
        {"refId": "D", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_ignored_empty_question_section_total[1m])", "legendFormat": "empty_question"},
        {"refId": "E", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_ignored_invalid_question_name_total[1m])", "legendFormat": "invalid_question_name"},
        {"refId": "F", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_ignored_question_name_total[1m])", "legendFormat": "question_name"}
      ]
    }
  ]
}
```

### A.2 — `grafana/dashboards/edm-internals.json`

Cache and pipeline internals: Cryptopan LRU hit ratio and evictions, seen-qname
LRU evictions, the new_qname channel buffer depth, and pipeline backpressure
(buffer level vs. discard rate).

```json
{
  "uid": "edm-internals",
  "title": "EDM — Internals (caches & pipeline)",
  "tags": ["edm", "dnstapir"],
  "schemaVersion": 39,
  "version": 1,
  "timezone": "",
  "refresh": "10s",
  "time": {"from": "now-30m", "to": "now"},
  "templating": {"list": []},
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Cryptopan LRU hit rate (last 5m)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 0, "w": 8, "h": 5},
      "fieldConfig": {"defaults": {"unit": "percentunit", "min": 0, "max": 1, "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "yellow", "value": 0.5}, {"color": "green", "value": 0.9}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "background", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_cryptopan_lru_hit_total[5m]) / clamp_min(rate(edm_processed_dnstap_total[5m]), 1)", "legendFormat": "hit ratio"}]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Cryptopan LRU evictions (5m rate)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 8, "y": 0, "w": 8, "h": 5},
      "fieldConfig": {"defaults": {"unit": "ops", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 1}, {"color": "red", "value": 100}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_cryptopan_lru_evicted_total[5m])", "legendFormat": "evicted/s"}]
    },
    {
      "id": 3,
      "type": "stat",
      "title": "new_qname channel buffer length",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 16, "y": 0, "w": 8, "h": 5},
      "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 100}, {"color": "red", "value": 800}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "background", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "edm_new_qname_ch_len", "legendFormat": "buffer"}]
    },
    {
      "id": 10,
      "type": "timeseries",
      "title": "Cryptopan LRU: hits vs evictions (rate)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 5, "w": 12, "h": 8},
      "fieldConfig": {"defaults": {"unit": "ops", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 15, "lineWidth": 2}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "single", "sort": "none"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_cryptopan_lru_hit_total[1m])", "legendFormat": "hits/s"},
        {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_cryptopan_lru_evicted_total[1m])", "legendFormat": "evictions/s"}
      ]
    },
    {
      "id": 11,
      "type": "timeseries",
      "title": "Seen-qname LRU evictions (rate)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 12, "y": 5, "w": 12, "h": 8},
      "fieldConfig": {"defaults": {"unit": "ops", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 15, "lineWidth": 2}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "single", "sort": "none"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_seen_qname_lru_evicted_total[1m])", "legendFormat": "evicted/s"}
      ]
    },
    {
      "id": 20,
      "type": "timeseries",
      "title": "new_qname pipeline backpressure",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 13, "w": 24, "h": 8},
      "fieldConfig": {"defaults": {"unit": "short", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 15, "lineWidth": 2}}, "overrides": [{"matcher": {"id": "byName", "options": "channel buffer"}, "properties": [{"id": "custom.axisPlacement", "value": "right"}]}]},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "edm_new_qname_ch_len", "legendFormat": "channel buffer"},
        {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(edm_new_qname_discarded_total[1m])", "legendFormat": "discarded/s (overflow)"}
      ]
    }
  ]
}
```

### A.3 — `grafana/dashboards/edm-process.json`

Go runtime / process health: goroutines, OS threads, open FDs, GOMAXPROCS,
process CPU, heap and process memory, and GC pause quantiles.

```json
{
  "uid": "edm-process",
  "title": "EDM — Process health (Go runtime)",
  "tags": ["edm", "dnstapir", "runtime"],
  "schemaVersion": 39,
  "version": 1,
  "timezone": "",
  "refresh": "10s",
  "time": {"from": "now-30m", "to": "now"},
  "templating": {"list": []},
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Goroutines",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 0, "w": 6, "h": 4},
      "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 500}, {"color": "red", "value": 5000}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_goroutines{job=\"edm\"}", "legendFormat": "goroutines"}]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Open file descriptors",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 6, "y": 0, "w": 6, "h": 4},
      "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 1024}, {"color": "red", "value": 50000}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "process_open_fds{job=\"edm\"}", "legendFormat": "fds"}]
    },
    {
      "id": 3,
      "type": "stat",
      "title": "GOMAXPROCS",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 12, "y": 0, "w": 6, "h": 4},
      "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "none", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_sched_gomaxprocs_threads{job=\"edm\"}", "legendFormat": "gomaxprocs"}]
    },
    {
      "id": 4,
      "type": "stat",
      "title": "Process CPU (5m rate)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 18, "y": 0, "w": 6, "h": 4},
      "fieldConfig": {"defaults": {"unit": "percentunit", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.5}, {"color": "red", "value": 0.9}]}}, "overrides": []},
      "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "value", "colorMode": "value", "graphMode": "area", "justifyMode": "auto", "orientation": "auto"},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "rate(process_cpu_seconds_total{job=\"edm\"}[5m])", "legendFormat": "cpu"}]
    },
    {
      "id": 10,
      "type": "timeseries",
      "title": "Heap memory",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8},
      "fieldConfig": {"defaults": {"unit": "bytes", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 15, "lineWidth": 2}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_memstats_heap_alloc_bytes{job=\"edm\"}", "legendFormat": "heap in-use"},
        {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_memstats_heap_sys_bytes{job=\"edm\"}", "legendFormat": "heap from system"},
        {"refId": "C", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_memstats_next_gc_bytes{job=\"edm\"}", "legendFormat": "next GC target"}
      ]
    },
    {
      "id": 11,
      "type": "timeseries",
      "title": "Process memory",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8},
      "fieldConfig": {"defaults": {"unit": "bytes", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 15, "lineWidth": 2}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "process_resident_memory_bytes{job=\"edm\"}", "legendFormat": "RSS"},
        {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "process_virtual_memory_bytes{job=\"edm\"}", "legendFormat": "virtual"}
      ]
    },
    {
      "id": 20,
      "type": "timeseries",
      "title": "GC pause duration (quantiles)",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 0, "y": 12, "w": 12, "h": 8},
      "fieldConfig": {"defaults": {"unit": "s", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 10, "lineWidth": 2}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_gc_duration_seconds{job=\"edm\", quantile=\"0.5\"}", "legendFormat": "p50"},
        {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_gc_duration_seconds{job=\"edm\", quantile=\"0.75\"}", "legendFormat": "p75"},
        {"refId": "C", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_gc_duration_seconds{job=\"edm\", quantile=\"1\"}", "legendFormat": "max"}
      ]
    },
    {
      "id": 21,
      "type": "timeseries",
      "title": "Goroutines & OS threads",
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "gridPos": {"x": 12, "y": 12, "w": 12, "h": 8},
      "fieldConfig": {"defaults": {"unit": "short", "custom": {"drawStyle": "line", "lineInterpolation": "smooth", "fillOpacity": 15, "lineWidth": 2}}, "overrides": []},
      "options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "targets": [
        {"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_goroutines{job=\"edm\"}", "legendFormat": "goroutines"},
        {"refId": "B", "datasource": {"type": "prometheus", "uid": "prometheus"}, "expr": "go_threads{job=\"edm\"}", "legendFormat": "OS threads"}
      ]
    }
  ]
}
```
