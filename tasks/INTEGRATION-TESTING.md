# Integration Testing Research Task

## Goal

Research and prototype a practical end-to-end CI/CD test path for DNS Tapir that
starts with deterministic DNSTAP messages injected into EDM and ends with
verifiable outputs from the policy processor that are ready to feed back into a
resolver, plus histogram updates submitted through the aggregate path.

The default loop should not run Unbound or generate live DNS queries. It must be
able to run without internet access. Prefer `edm-loadgen` for DNSTAP injection;
if it is too benchmark-oriented for exact fixture testing, create a smaller
fixture injector that writes DNSTAP Frame Streams directly to EDM.

The test path should be incremental. Each stage should produce useful evidence
on its own, and later stages should reuse the earlier fixtures.

## Current Evidence

Confirmed building blocks:

- `edm-loadgen` can emit EDM-compatible `CLIENT_RESPONSE` DNSTAP frames over
  Frame Streams and reconcile sent counts against EDM Prometheus metrics.
- EDM writes local session parquet and histogram parquet, publishes first-seen
  `new_qname` messages over signed MQTT, and can POST histogram parquet to
  aggrec.
- `edge-stack` wires Unbound DNSTAP to EDM over TCP on an internal Docker
  network. Treat this as production/parity context, not the preferred CI loop.
- `mqtt-bridge` has integration tests for Mosquitto plus NATS, verifies upbound
  JWS payloads, validates schema, and signs downbound messages.
- `tapir-analyse-new-qname` consumes NATS `new_qname` events and writes
  observation/seen-domain state.
- `observation-encoder` watches observation KV state and publishes southbound
  TAPIR updates.
- POP merges policy and serves RPZ by AXFR/IXFR and NOTIFY.
- Aggrec has a local Docker support stack for S3-compatible storage, MongoDB,
  MQTT, NATS, and observability.

Known issues to research early:

- Current `edge-stack` EDM flags do not match current upstream EDM.
- Current EDM signing key handling expects EdDSA JWKs, while `edge-stack`
  currently generates P-256 keys.
- EDM metrics and pprof bind to `127.0.0.1` in current upstream source; container
  CI may need either in-container probes or a configurable bind address patch.
- POP/RPZ verification should avoid requiring a recursive resolver. Prefer
  direct inspection of generated RPZ state or POP outputs; use DNS protocol
  transfer checks only as an optional local compatibility layer.
- A POP library refactor exists locally in `../dnstapir-pop`: root package
  `pop` exposes `Run` and the existing policy/RPZ types. The E2E harness can
  import this package directly via `E2E_POP_REPO` instead of copying POP source
  into a temp test module.
- The prototype harness is now driven from the repository root by
  `go run ./cmd/e2e-test run`.
- EDM has an opt-in manual parquet rotation path for E2E:
  `--enable-manual-parquet-rotation` exposes localhost
  `POST /debug/rotate-parquet` on the metrics server.

## Stage 1: EDM-Only CI Baseline

Purpose: prove DNSTAP-to-EDM behavior without resolver, Core, or POP.

Prototype:

- Build `dnstapir-cli` and EDM from source.
- Generate a deterministic tiny domain CSV and compile
  `well-known-domains.dawg`.
- Generate an EDM TOML config with a fixed test-only Crypto-PAn key.
- Run EDM with `--input-tcp 127.0.0.1:53535`, temp data dir, and
  `--disable-histogram-sender`.
- Run `edm-loadgen benchmark --edm upstream/edm --duration 30s` or a similar
  bounded `run` command.
- Enable the embedded MQTT broker for at least one job so the `new_qname` path
  is exercised. Keep a second no-MQTT job if we need the fastest baseline.

Assertions:

- `edm_processed_dnstap_total` increases and approximately matches loadgen
  sent count after drift settles.
- `edm_ignored_*_total` remains zero for valid synthetic traffic.
- With MQTT enabled, `edm_new_qname_queued_total`, loadgen `mqtt_received`, and
  loadgen `mqtt_edm_topic` increase for unknown names.
- Session parquet appears under `parquet/sessions/` when session files are not
  disabled.
- Histogram parquet appears under `parquet/histograms/outbox/` for well-known
  names after the harness requests manual rotation; natural minute-boundary
  rotation remains an optional compatibility mode.
- The harness parquet reader can read both parquet families and verify expected
  row/count shape without requiring DuckDB.

Acceptance criteria:

- A single CI command starts EDM, sends traffic, stops cleanly, and returns
  machine-readable pass/fail evidence.
- All generated data stays in temp directories or ignored paths.

## Stage 2: Offline DNSTAP Fixture Injection

Purpose: prove exact DNSTAP fixtures can drive EDM deterministically without
Unbound, real DNS queries, recursive resolution, or internet access.

Prototype:

- First try to express the required fixture set with `edm-loadgen run` or a new
  deterministic mode in `edm-loadgen`.
- If `edm-loadgen` cannot provide exact fixture control, create a small test
  injector, likely in Go, that:
  - reads JSON/YAML fixtures containing qname, qtype, qclass, response code,
    client IP, resolver IP, timestamp, DNSTAP identity, and DNSTAP version;
  - constructs DNS response wire messages locally instead of resolving names;
  - wraps them in `CLIENT_RESPONSE` DNSTAP envelopes;
  - sends them over Frame Streams to EDM's TCP or Unix socket input.
- Include fixtures for known domains, unknown first-seen names, repeated names,
  ignored suffixes or IPs, and a small number of intentionally malformed frames
  when EDM behavior is defined.
- Keep all networking on loopback or an isolated container network. Block
  outbound internet in CI if the runner supports it.

Assertions:

- EDM metrics increase by the exact fixture count, minus any intentionally
  ignored or malformed fixtures.
- EDM ignored counters match the fixtures that should be ignored.
- Session parquet contains the expected qnames, qtypes, qclasses, timestamps,
  and pseudonymised IP fields.
- Histogram parquet contains only well-known-domain traffic from the fixture set.
- MQTT `new_qname` output contains only the expected first-seen unknown names.
- No external DNS lookup, recursive resolver, or privileged host port is used.

Acceptance criteria:

- A single offline command injects a fixed fixture file into EDM and produces
  repeatable metrics, MQTT, session parquet, and histogram parquet assertions.

## Stage 3: Core Event And Policy Artifact Loop

Purpose: prove first-seen qnames can become policy input and POP can produce
resolver-consumable RPZ, without requiring a resolver to be running in the
default CI path.

Prototype path A, full component route:

- Start the embedded `e2e-test mqtt-broker`, NATS with JetStream,
  `mqtt-bridge` upbound,
  `tapir-analyse-new-qname`, `observation-encoder`, `mqtt-bridge` downbound,
  and POP.
- Configure EDM to publish signed `events/up/<kid>/new_qname`.
- Configure upbound bridge to validate JWS and schema, then publish to the
  analyzer NATS subject.
- Pre-create or auto-create NATS KV buckets for `globally_new` and
  `seen_domains`.
- Configure observation encoder to publish southbound TAPIR updates.
- Configure downbound bridge to sign southbound updates to the topic POP reads.
- Configure POP with a minimal source and policy that turns a synthetic
  observation into a RPZ entry.

Prototype path B, reduced first target:

- Bypass analyzer/encoder initially by injecting one known-good TAPIR update
  directly into POP's expected source path.
- Use that to validate POP policy and generated RPZ state before debugging the
  full Core chain.
- Prefer direct inspection of POP's generated zone/RPZ output or internal test
  helper outputs. Add AXFR/IXFR/NOTIFY checks only as optional local protocol
  compatibility tests, still without a recursive resolver or internet access.

Assertions:

- Upbound bridge rejects malformed/unsigned events and accepts EDM-signed events.
- Analyzer writes expected observation state for a synthetic unknown domain.
- Observation encoder publishes a southbound TAPIR update for that domain.
- POP consumes the update and changes its RPZ state.
- Direct POP/RPZ inspection shows an RPZ CNAME or other expected action for the
  test domain.
- Optional local-only protocol checks show POP can serve AXFR/IXFR and emit
  NOTIFY for the changed RPZ.

Acceptance criteria:

- CI can demonstrate at least one synthetic DNSTAP message leading to a
  verifiable RPZ policy artifact. Resolver enforcement can be a separate
  compatibility test, not part of the default loop.

## Stage 4: Histogram And Aggrec Path

Purpose: prove well-known-domain aggregates are generated, uploaded, stored,
and announced.

Prototype:

- Run aggrec with its local Docker support services: MinIO, MongoDB, Mosquitto,
  NATS, and test key database.
- Run EDM with histogram sender enabled and `--http-url` pointed at aggrec.
- Use Ed25519 JWK test keys unless project confirms another canonical key
  format.
- Generate well-known traffic with `edm-loadgen` or the offline DNSTAP fixture
  injector.
- Let EDM rotate/flush a histogram file and POST it.

Assertions:

- Aggrec returns `201 Created` and a `Location` header for
  `/api/v1/aggregate/histogram`.
- MongoDB contains metadata with aggregate type `histogram`, creator key ID,
  content digest, content type, and interval.
- MinIO contains the parquet object.
- Aggrec emits a new aggregate message to MQTT or NATS when configured.
- EDM moves sent histogram files from `outbox` to `sent`.

Acceptance criteria:

- CI can verify both local histogram parquet contents and aggrec's stored copy
  from the same test run.

## CI/CD Design Notes

- Prefer short, deterministic, isolated jobs over one huge integration job.
- Pin upstream component revisions for the test harness once a compatible set is
  known.
- Use high host ports in CI and avoid privileged binds.
- The default path must pass with no outbound internet access.
- Do not generate recursive DNS queries in default CI. Drive EDM with DNSTAP
  fixtures instead.
- Keep generated keys, DAWGs, parquet, Pebble stores, and clone caches outside
  tracked source.
- Use JSON output from `edm-loadgen benchmark` for machine assertions.
- Use the Go harness parquet reader to inspect parquet contents.
- Inspect POP/RPZ output directly for default CI. If DNS protocol checks are
  needed, keep them optional, local-only, and non-recursive.

## Research Deliverables

- A compatibility matrix of component revisions and required overrides.
- A minimal compose or script for Stage 1.
- An offline DNSTAP fixture format and either an `edm-loadgen` recipe or a small
  injector implementation for Stage 2.
- A POP fixture: minimal config, source update, expected RPZ record, and direct
  output assertions.
- An aggrec fixture: test keys, config, upload assertion, metadata assertion,
  object-store assertion, and announcement assertion.
- An optional resolver compatibility note describing what would be needed to
  test Unbound/RPZ enforcement outside the default CI loop.
- A final recommendation for which stages should run on every PR versus nightly
  or release pipelines.
