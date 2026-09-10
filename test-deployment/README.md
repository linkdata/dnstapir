# DNS TAPIR test deployment

Runbooks and scripts for standing up a three-VM DNS TAPIR test environment from
source. Every DNS TAPIR component is built from a clone rather than pulled as a
published image, so the deployment is whatever commit you checked out.

The Edge runs both halves of the pipeline: EDM carries data up to Core, and
TAPIR-POP brings Core's conclusions back down. Both are needed, because a
round-trip is what DNS TAPIR's own looptest verifies.

EDM sends two kinds of data up, and both paths are exercised here: `new_qname`
events over MQTT for names it has not seen, and aggregated histograms over
signed HTTP to the Aggregate Receiver. Which path a name takes is decided by the
well-known-domains filter, so the runbook installs the published filter rather
than a stub — with a stub, practically everything takes the event path and the
aggregate half is never tested.

## The three VMs

| VM | Runbook | Holds state |
|---|---|---|
| Services | [`DNS-TAPIR-Services-VM-runbook.md`](DNS-TAPIR-Services-VM-runbook.md) | **Yes** — CA, MongoDB, JetStream, S3 objects |
| Core | [`DNS-TAPIR-Core-install-runbook.md`](DNS-TAPIR-Core-install-runbook.md) | No |
| Edge | [`DNS-TAPIR-Edge-DNSTAP-receiver-runbook.md`](DNS-TAPIR-Edge-DNSTAP-receiver-runbook.md) | Only its enrolled credentials |

Install them in that order. The services VM is first because it issues the
certificate authority and produces the handover bundle the Core VM needs.

The split exists so Core can be rebuilt at any commit without losing node
identities, enrolled signing keys or analysis state. That is the property worth
protecting: a rebuilt Core does not disturb a running Edge, because the CA
arrives from the bundle and the Edge's signing key never left the services VM.

## Scripts

- `dnstapir-host-bootstrap.sh` — every step that needs root, shared by all three
  runbooks so the hosts are bootstrapped identically. Installs the OS and Docker
  packages, creates the unprivileged service account with its subordinate ID
  ranges, sets up Rootless Docker, and writes the account's login environment.
  Idempotent; `--dry-run` shows what it would do.
- `dnstapir-services-install.sh` — the services VM runbook, sections 3 to 10, as
  one script. Delegates the privileged half to the bootstrap script.

Everything after the bootstrap runs as an unprivileged `dnstapir` account with
Rootless Docker. That account has no `sudo` and is not in the `docker` group.

## Security posture

This deliberately mirrors the posture of the deployed DNS TAPIR environment
rather than improving on it, so that it exercises a configuration someone
actually operates.

| Path | Transport | Authentication |
|---|---|---|
| Edge → Core Mosquitto | TLS 1.3 | Client certificate, plus a topic ACL |
| Core → Edge observations | signed JWS over that MQTT link | Verified against a key NodeMan hands each node at enrolment |
| Edge → Core aggregates | Plaintext HTTP on the test network | Signed HTTP messages, verified against the node's key from NodeMan |
| Core services → NATS | Plaintext | Username and password in the URL |
| Core services → MongoDB | Plaintext | SCRAM, one user per service |
| Core aggrec → S3 | Plaintext | Access keys |

**The network is the barrier for everything except MQTT.** The services VM's
ports are reachable only from the Core VM, enforced by firewall rules. If the
firewall is off there is no second control.

NATS is not mutually authenticated because no DNS TAPIR component can present a
client certificate to it: both consumers call `nats.Connect` with a URL and no
options, so every credential mechanism beyond URL userinfo is unreachable.
Closing that needs an upstream change in `mqtt-bridge` and `tapir-analyse-lib`.

Do not expose any of this to the Internet or point it at real DNS data.

## Validation status

The Core and Edge runbooks have been run end to end against real VMs, twice,
including a full wipe and reinstall and a reboot of all three hosts. Commands
are extracted from the runbooks programmatically rather than retyped, so what
passed is what is written here.

Not yet exercised, and worth knowing before you rely on it:

- The services runbook has never been run **as written** — only
  `dnstapir-services-install.sh`, which implements it. Its CA and signing-key
  steps have been exercised directly.
- The backup and restore procedure in services runbook section 11. An untested
  restore is not a backup, and the CA cannot be recreated.
- The privileged bootstrap on a genuinely fresh host since the runbooks last
  changed.
- Core sections 8, 9 and 10 (the disposable NodeMan, Aggregate Receiver and MQTT
  bridge validations). The Aggregate Receiver itself runs persistently and has
  been exercised end to end; section 9 is a separate throwaway harness.
- Both firewall sections, and the Edge's Unbound configuration.

## Conventions

- Every command block is meant to stand alone in a fresh shell. A block that
  needs credentials loads them itself rather than inheriting them from an
  earlier section.
- Assertions that end a pipeline use `grep -c ... >/dev/null`, never a trailing
  `grep -q`. Under `set -o pipefail` an early-exiting `grep -q` kills its
  producer with `SIGPIPE`, and `pipefail` reports that as a failure of the whole
  pipeline even though the pattern matched.
- Validation sections clean up after themselves with exit traps and never delete
  a volume belonging to another section.

## Known differences from a deployed environment

Beyond the obvious ones — single instances, no Kubernetes, the security noted
above — the analysis stack still uses the integration fixture's NATS subjects
and bucket names rather than the deployed `internal.*` / `public.to-edge.*`
namespace, the list checker reads data embedded in its binary instead of a real
feed and therefore emits `registry_investigation` rather than
`newly_registered`, and NodeMan issues 60-day certificates where a deployment
uses 15 with automatic renewal. Observation TTLs and the well-known-domains
filter *have* been aligned with deployed values, because leaving them at the
fixture's made the system behave qualitatively differently.
