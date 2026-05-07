# DNS Tapir Project Memory

Last updated: 2026-05-07

This is the working memory for this repository. It should capture what we have
confirmed about DNS Tapir, where the evidence came from, and what still needs
verification.

## Source Inventory

Local tracked docs:

- `README.md`: placeholder project note.
- `edge-dev-howto.md`: local-only Edge stack runbook for resolver plus EDM.
- `dns-tapir-data-flow.svg`: current architecture/data-flow diagram used as the
  main repo-level map.

Ignored upstream research checkouts under `upstream/`:

- `dnstapir/edge-stack`: Compose stack for resolver plus EDM.
- `dnstapir/edm`: Edge DNSTAP Minimiser.
- `dnstapir/unbound`: Unbound container build infrastructure.
- `dnstapir/cli`: CLI with DAWG tooling and POP/RPZ commands.
- `linkdata/edm-loadgen`: synthetic DNSTAP load generator and EDM verifier.
- `dnstapir/pop`: Policy Processor that merges policy into RPZ.
- `dnstapir/aggrec`: Aggregate Receiver for signed parquet uploads.
- `dnstapir/mqtt-bridge`: MQTT/NATS bridge with JWS/schema handling.
- `dnstapir/tapir-analyse-new-qname`: analyzer for first-seen qname events.
- `dnstapir/observation-encoder`: encodes NATS observations into southbound TAPIR
  updates.
- `dnstapir/nodeman`: node enrollment, certificates, and public key lookup.
- `dnstapir/evrec`: archived historical event receiver context.

Public docs consulted:

- DNS TAPIR Architecture: https://www.dnstapir.se/docs/dnstapir-architecture/
- DNS TAPIR Core: https://www.dnstapir.se/docs/dnstapir-core/
- DNS TAPIR Security Brief: https://www.dnstapir.se/docs/security-brief/
- Information Management: https://www.dnstapir.se/docs/tapir-info-mgmt-en/

## System Shape

DNS Tapir is split into Edge and Core.

- Edge runs close to a resolver. It receives resolver telemetry, minimises or
  aggregates it, keeps privacy-sensitive detail local, submits scrubbed events
  and aggregates to Core, and applies resulting local policy.
- Core receives minimised/de-personified data, stores and analyses it, creates
  observations, and feeds policy/intelligence back toward Edge.

Current data-flow map:

1. Resolver/Unbound emits DNSTAP to EDM.
2. EDM minimises response messages.
3. Unknown first-seen names are emitted as signed `new_qname` MQTT events.
4. Core MQTT and `mqtt-bridge` validate JWS payloads and schema, then publish
   NATS events.
5. `tapir-analyse-new-qname` deduplicates/records seen domains and writes
   observation state, including `globally_new`.
6. `observation-encoder` watches observation buckets and publishes a southbound
   TAPIR update.
7. Downbound `mqtt-bridge` signs and publishes observations toward Edge.
8. POP merges Core observations with local allow, deny, and doubt policy.
9. POP serves compact RPZ output by AXFR/IXFR and DNS NOTIFY for resolver
   enforcement.
10. In parallel, EDM writes well-known histograms to parquet and can submit them
    to aggrec over signed HTTP.

Testing direction: the default CI loop should not require Unbound, recursive
DNS queries, or internet access. Drive EDM directly with deterministic DNSTAP
Frame Streams using `edm-loadgen` or a small fixture injector that constructs
DNS response wire messages locally and wraps them in DNSTAP `CLIENT_RESPONSE`
envelopes.

## Component Notes

### edge-stack

`upstream/edge-stack/docker-compose.yaml` defines an internal Docker network
`10.53.0.0/24` with:

- `resolver` at `10.53.0.10`, publishing host ports 53, 443, and 853.
- `edm` at `10.53.0.11`, listening for DNSTAP on TCP port 53535.
- `edm-data` volume mounted at `/var/lib/edm`.

`upstream/edge-stack/unbound/conf.d/dnstap.conf` enables DNSTAP, sends it to
`10.53.0.11@53535`, disables DNSTAP TLS, logs client query and response
messages, and includes identity/version fields.

Important divergence: current `edge-stack` passes EDM flags such as
`--mqtt-signing-key-id`, `--mqtt-topic`, `--mqtt-client-id`, and
`--http-signing-key-id`, but current upstream `dnstapir/edm` does not define
those flags. A practical CI stack must either use compatible revisions or carry
an override matching current EDM flags.

CI note: `edge-stack` and Unbound are useful for production parity checks, but
they should not be in the default end-to-end test loop if direct DNSTAP injection
can cover EDM behavior.

### EDM

`dnstapir-edm` reads DNSTAP over Unix socket, plaintext TCP, or TLS TCP.
Confirmed flags include `--input-unix`, `--input-tcp`, `--input-tls`,
`--data-dir`, `--config-file`, `--well-known-domains-file`, `--disable-mqtt`,
`--disable-session-files`, and `--disable-histogram-sender`.

EDM processing confirmed from `upstream/edm`:

- It increments `edm_processed_dnstap_total` when frames enter the minimiser.
- It ignores DNSTAP message types whose name ends in `_QUERY`; current hot path
  processes response frames.
- It parses DNS wire responses and ignores malformed DNS, empty question
  sections, invalid names, ignored client IPs, and ignored question names.
- It pseudonymises DNSTAP query/response IP addresses with Crypto-PAn before
  writing local session parquet.
- It uses a DAWG file to classify well-known domains. Well-known names update
  per-domain histogram data.
- Unknown names are deduplicated through an LRU plus Pebble store. First-seen
  names create `new_qname` events if MQTT is enabled.
- It writes session parquet to `parquet/sessions/` and histogram parquet to
  `parquet/histograms/outbox/`.
- It exposes Prometheus metrics at `127.0.0.1:2112/metrics` and pprof at
  `127.0.0.1:6060`.

EDM `new_qname` events:

- JSON fields include `type`, `version`, `qname`, `qtype`, `qclass`, `flags`,
  and `timestamp`.
- `type` is `new_qname`; current version is `0`.
- Events are JWS-signed and published to `events/up/<kid>/new_qname`, where
  `<kid>` is the JWK key ID.

EDM histogram upload:

- Histogram parquet is POSTed to aggrec at `/api/v1/aggregate/histogram`.
- `Content-Type` is `application/vnd.apache.parquet`.
- EDM sends an `Aggregate-Interval` header derived from the histogram filename.
- HTTP Message Signatures are used with `content-type`, `content-length`, and
  `content-digest` covered.

Open compatibility note: current upstream EDM reads signing keys as JWK and
forces `alg=EdDSA`. `edge-stack` currently generates P-256 keys with `step`.
Confirm the intended key format before wiring aggrec or full MQTT paths in CI.

### edm-loadgen

`edm-loadgen` is currently the strongest practical EDM test harness.

- It connects directly to EDM's DNSTAP Frame Streams socket.
- It emits `CLIENT_RESPONSE` DNSTAP envelopes, matching the response-only EDM
  hot path.
- It can launch EDM from a source checkout or binary via `--edm`.
- It can enable an embedded dev-only TLS MQTT broker so EDM's publish path is
  exercised without Core.
- It verifies `edm_processed_dnstap_total`, `edm_new_qname_queued_total`,
  ignored counters, Crypto-PAn cache counters, and seen-qname LRU pressure.
- It has `smoke`, `run`, `serve`, `benchmark`, and `verify` subcommands.

Limit: its embedded MQTT broker counts publishes but does not validate JWS,
ACLs, or client-cert identity. Use it for Edge/EDM CI, not Core trust semantics.

Preferred CI use: run it offline against EDM on loopback or an isolated
container network. If exact fixtures are needed and `edm-loadgen` is too
benchmark-oriented, create a smaller DNSTAP fixture injector that reads explicit
qname/qtype/qclass/rcode/IP/timestamp fixtures, constructs DNS response wire
messages locally, and emits DNSTAP Frame Streams to EDM.

### mqtt-bridge

`mqtt-bridge` supports both directions:

- Upbound: MQTT to NATS. It extracts `kid` from JWS, fetches/caches validation
  keys directly or from Nodeman, verifies the JWS, validates JSON schema, then
  publishes to NATS with useful headers.
- Downbound: NATS to MQTT. It validates schema, signs payloads, and publishes to
  MQTT. Retained MQTT messages are supported downbound.

Its integration test stack already uses Mosquitto and NATS containers. That is
a useful pattern for end-to-end CI.

### tapir-analyse-new-qname

The analyzer subscribes to a NATS event subject such as
`internal.events.new_qname`. It maintains a `seen_domains` bucket and writes
observations such as `globally_new` to configured NATS observation buckets.
Config supports ignored suffixes and pre-provisioned or auto-created buckets.

### observation-encoder

The encoder watches NATS KV observation buckets under an observation subject
prefix, builds an observation vector for a domain, and publishes southbound
TAPIR updates to a configured NATS subject such as `*.down.tapir-pop`.

### aggrec

Aggrec receives aggregate uploads and stores:

- Raw aggregate payload in S3-compatible storage.
- Metadata in MongoDB.
- New aggregate announcements to MQTT and/or NATS if configured.

API facts from source:

- Create endpoint is `POST /api/v1/aggregate/{aggregate_type}`.
- Valid aggregate types include `histogram`, `vector`, and `test`.
- Valid content types include `application/vnd.apache.parquet`.
- It requires `Content-Digest`, `Content-Length`, `Signature`, and
  `Signature-Input`.
- It verifies HTTP Message Signatures, extracts `keyid` as creator, stores the
  request headers, and returns `201 Created` with `Location`.
- Read endpoints include `/api/v1/aggregates/{id}` and
  `/api/v1/aggregates/{id}/payload`.

Its `docker-compose.yaml` starts MinIO, MongoDB, Caddy for client keys, Valkey,
Mosquitto, NATS, OpenTelemetry Collector, Jaeger, and Prometheus.

### POP

POP is the DNS Tapir Policy Processor.

- It merges Core intelligence and local policy into one compact RPZ output.
- Inputs/sources can include RPZ, MQTT, DAWG, CSV files, and HTTPS bootstrap.
- Policy concepts are allowlists, denylists, doubtlists, observations, sources,
  and outputs.
- Policy precedence from README: allowlisted names are excluded; denylisted
  names are included; doubtlisted names are included based on configured tags,
  source count, or tag count.
- `GenerateRpzAxfr` constructs current RPZ state.
- `GenerateRpzIxfr` computes deltas after a TAPIR update.
- `RpzAxfrOut` and `RpzIxfrOut` serve AXFR/IXFR.
- `NotifyDownstreams` is called after RPZ changes.

### Nodeman

Nodeman manages Edge node enrollment, certificates, configuration, and public
keys for signature verifiers.

Key concepts:

- Enrollment key: single-use key issued by a DNS Tapir administrator.
- Data key: node-generated JWK, used to sign submitted data; renewals are
  authenticated by this key.
- Node certificate: short-lived X.509 certificate for TLS client auth.

Nodeman is important for production-like trust tests because mqtt-bridge and
aggrec can use it to resolve public keys by node/key ID.

### evrec

`dnstapir/evrec` is archived as of 2026-02-26. Treat it as historical context
for event receiver behavior, not a current target unless the project explicitly
decides otherwise.

## Privacy And Security Rules

Confirmed from public docs and EDM behavior:

- Raw resolver DNSTAP contains highly privacy-sensitive data and should not be
  stored as a Core input.
- IP addresses, actual or pseudonymised, are never sent to TAPIR Core.
- EDM uses actual client IPs only for local cardinality calculations such as
  HyperLogLog, then stores local session data with Crypto-PAn pseudonymised IPs.
- Histogram data is grouped into one-minute intervals.
- Notifications have timestamps, but they are event-generation timestamps, not
  exact request/response correlation data.
- Events are JSON over MQTTv5 with mTLS and JWS signatures.
- Aggregates are submitted over HTTPS with mTLS and HTTP Message Signatures.

## Practical Local Testing Assets

Already useful:

- `edge-dev-howto.md`: local stack recipe, including Prometheus/Grafana checks
  and DuckDB parquet inspection.
- `upstream/edm-loadgen`: direct DNSTAP generator, verifier, and embedded MQTT
  broker.
- `upstream/mqtt-bridge/itests`: Mosquitto/NATS integration test pattern.
- `upstream/aggrec/docker-compose.yaml`: support services for aggrec tests.

Likely first CI foothold:

1. Build EDM and dnstapir-cli from source.
2. Compile a tiny DAWG from a deterministic CSV.
3. Run EDM on localhost with a temp data dir.
4. Run `edm-loadgen benchmark` or `run` against it without generating DNS
   queries.
5. Verify metrics, MQTT publish counts, and parquet files.

Next CI foothold: define an offline DNSTAP fixture format and either map it onto
`edm-loadgen` or build a minimal injector. That fixture should become the shared
input for EDM assertions, Core `new_qname` assertions, POP/RPZ policy artifact
assertions, and histogram/aggrec assertions.

## Open Questions

- Which exact revisions of `edge-stack` and `edm` are intended to work together?
  Current upstream `edge-stack` uses flags not present in current upstream EDM.
- Should CI use current upstream repos directly, pinned commits, or local forks?
- What is the canonical current schema repository for `new_qname` and southbound
  TAPIR observations?
- What is the minimal POP configuration needed to accept a synthetic southbound
  TAPIR update and serve a resolver-consumable RPZ?
- Can POP expose or generate an RPZ artifact that CI can inspect directly,
  without running a recursive resolver or issuing DNS transfer queries?
- What exact fixture fields are needed for a deterministic DNSTAP injector that
  exercises EDM without live DNS queries?
- Should histogram/aggrec CI test real mTLS, HTTP Message Signatures only, or
  both?
- Is P-256 still intended for Edge data keys, or should current EDM/aggrec tests
  standardize on Ed25519 JWKs?
