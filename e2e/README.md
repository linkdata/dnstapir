# DNS Tapir E2E Harness

This directory contains the first offline end-to-end test harness for the path:

```text
DNSTAP fixture -> EDM -> new_qname MQTT -> mqtt-bridge -> NATS
  -> tapir-analyse-new-qname -> observation-encoder -> mqtt-bridge
  -> POP direct RPZ artifact -> EDM parquet assertions
```

The default command is:

```bash
./e2e/run.sh
```

Runtime constraints:

- No Unbound or recursive resolver is started.
- No live DNS queries are generated.
- DNSTAP input is deterministic and local.
- MQTT uses a plain local port selected from `28884` upward; JWS validation is
  the authenticity check in this offline smoke path.
- Generated keys, configs, DAWGs, logs, broker state, NATS state, and parquet
  files live under `/.e2e-work/`.

Host prerequisites:

- `go`
- `mosquitto`
- ignored upstream checkouts under `/upstream/`

The runner installs a pinned `nats-server` into `.e2e-work/tools` unless
`E2E_NATS_SERVER` points at an explicit binary.

The harness result is written to:

```text
.e2e-work/results/summary.json
```

The summary includes `dnstap_sent`, `mqtt_new_qname_seen`,
`core_observations_seen`, `rpz_records`, `session_parquet_rows`, and
`histogram_parquet_rows`.
