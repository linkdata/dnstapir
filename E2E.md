# DNS Tapir E2E Harness

This repository contains the first offline end-to-end test harness for the path:

```text
DNSTAP fixture -> EDM -> new_qname MQTT -> mqtt-bridge -> NATS
  -> tapir-analyse-new-qname -> observation-encoder -> mqtt-bridge
  -> POP direct RPZ artifact -> EDM parquet assertions
```

The default command is:

```bash
go run ./cmd/e2e-test run
```

The runner auto-detects the repository root when it is launched from anywhere
inside this checkout; pass `--root` only when running it from elsewhere.

Runtime constraints:

- No Unbound or recursive resolver is started.
- No live DNS queries are generated.
- DNSTAP input is deterministic and local.
- MQTT uses an embedded `e2e-test mqtt-broker` on a plain local port selected
  from `28884` upward; JWS validation is the authenticity check in this offline
  smoke path.
- Generated keys, configs, DAWGs, logs, broker state, NATS state, and parquet
  files live under `/.e2e-work/`.
- By default the runner starts EDM with `--enable-manual-parquet-rotation` and
  posts to `http://127.0.0.1:2112/debug/rotate-parquet` after fixture
  injection, so parquet assertions do not wait for the natural minute boundary.
  Use `--manual-parquet-rotation=false` to exercise the natural rotation path.

Host prerequisites:

- `go`
- ignored upstream checkouts under `/upstream/`

The Go runner is intended to work on Linux and macOS.

The runner uses `E2E_NATS_SERVER` when set, otherwise reuses
`.e2e-work/tools/nats-server` or `nats-server` from `PATH`; if neither exists,
it installs the pinned version into `.e2e-work/tools`.

The default immediate parquet path requires an EDM build that supports
`--enable-manual-parquet-rotation`.

POP RPZ verification uses a direct test driver. Set `E2E_POP_REPO` to choose a
POP checkout explicitly. If it is unset, the runner prefers a sibling
`../dnstapir-pop` package checkout and falls back to `upstream/pop`. Refactored
`package pop` checkouts are imported with a local `replace`; old `package main`
checkouts use the legacy in-package test shim.

Long-running native services are started by `e2e-test run` in their own
process groups and torn down during runner cleanup. The `supervise` subcommand
remains available for focused debugging.

The harness result is written to:

```text
.e2e-work/results/summary.json
```

The summary includes `dnstap_sent`, `mqtt_new_qname_seen`,
`core_observations_seen`, `rpz_records`, `session_parquet_rows`, and
`histogram_parquet_rows`.
