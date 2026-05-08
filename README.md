Helping me to understand and deploy DNS Tapir.

Run the offline E2E harness with:

```bash
go run ./cmd/e2e-test run
```

Missing default `upstream/` checkouts are cloned automatically. You can prepare
them ahead of time with:

```bash
go run ./cmd/e2e-test populate-upstream
```

See [E2E.md](E2E.md) for harness details.
