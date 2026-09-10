#!/bin/bash
#
# dnstapir-maintenance.sh — periodic upkeep for a DNS TAPIR test deployment.
#
# The three runbooks build a deployment that starts itself after a reboot and
# restarts a container that exits, and does nothing else on its own. This script
# is the rest: it renews the certificates that would otherwise expire, keeps the
# logs and stored data from filling the disk, takes the backup the services
# runbook describes, and asserts end to end that observations still travel.
#
# It runs as the unprivileged service account on any of the three hosts, and
# picks its role from the login environment the host bootstrap wrote:
#
#   sudo -iu dnstapir /path/to/dnstapir-maintenance.sh
#
# --install adds a systemd user timer, which needs no root because the service
# accounts already have lingering enabled:
#
#   sudo -iu dnstapir /path/to/dnstapir-maintenance.sh --install
#
# Every task reports what it did. The script exits non-zero if any check failed,
# so a failed run is visible in "systemctl --user list-units --failed" rather
# than only in the journal.

set -euo pipefail

readonly PROGNAME="${0##*/}"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${0##*/}"
readonly SCRIPT_PATH

role=
dry_run=0
do_install=0
do_uninstall=0
renew_before_days=21
log_max_mb=64
keep_logs=4
parquet_days=7
builder_days=7
aggregate_days=90
keep_backups=7
roundtrip_timeout=90
on_calendar='daily'

usage() {
  cat <<USAGE
Usage: $PROGNAME [options]

Runs the maintenance tasks for this host's role. With no options it detects the
role from the login environment and does the work.

Options:
  --role edge|core|services  Override role detection.
  --dry-run                  Report what would change without changing it.
  --install                  Write and enable a systemd user timer, then exit.
  --uninstall                Remove that timer, then exit.
  --on-calendar EXPR         Timer schedule for --install. Default: $on_calendar
  --renew-before DAYS        Renew a node certificate with fewer than this many
                             days left. Edge only. Default: $renew_before_days
  --log-max-mb MB            Rotate a POP log larger than this. Edge only.
                             Default: $log_max_mb
  --keep-logs N              Rotated POP logs to keep. Default: $keep_logs
  --parquet-days DAYS        Delete uploaded histograms older than this. Edge
                             only. Default: $parquet_days
  --builder-days DAYS        Prune Docker build cache unused for this long.
                             Default: $builder_days
  --aggregate-days DAYS      Delete stored aggregates older than this, object
                             and metadata together. Services only. 0 disables.
                             May be fractional, which is only useful for
                             exercising the deletion on fresh data.
                             Default: $aggregate_days
  --keep-backups N           Backup generations to keep. Services only.
                             Default: $keep_backups
  --roundtrip-timeout SECS   How long to wait for the injected observation to
                             reach POP. Edge only. Default: $roundtrip_timeout
  -h, --help                 Show this text.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role)              role="${2:?--role needs a value}"; shift 2 ;;
    --dry-run)           dry_run=1; shift ;;
    --install)           do_install=1; shift ;;
    --uninstall)         do_uninstall=1; shift ;;
    --on-calendar)       on_calendar="${2:?--on-calendar needs a value}"; shift 2 ;;
    --renew-before)      renew_before_days="${2:?--renew-before needs a value}"; shift 2 ;;
    --log-max-mb)        log_max_mb="${2:?--log-max-mb needs a value}"; shift 2 ;;
    --keep-logs)         keep_logs="${2:?--keep-logs needs a value}"; shift 2 ;;
    --parquet-days)      parquet_days="${2:?--parquet-days needs a value}"; shift 2 ;;
    --builder-days)      builder_days="${2:?--builder-days needs a value}"; shift 2 ;;
    --aggregate-days)    aggregate_days="${2:?--aggregate-days needs a value}"; shift 2 ;;
    --keep-backups)      keep_backups="${2:?--keep-backups needs a value}"; shift 2 ;;
    --roundtrip-timeout) roundtrip_timeout="${2:?--roundtrip-timeout needs a value}"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)                   usage >&2; echo "$PROGNAME: unknown argument: $1" >&2; exit 2 ;;
  esac
done

failures=0
task() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
# Failures go to stdout with everything else: the whole run is one report, and
# splitting the streams only reorders it. The exit status is the machine signal.
fail() { printf '   FAILED: %s\n' "$*"; failures=$((failures + 1)); }
run()  {
  if [ "$dry_run" -eq 1 ]; then
    printf '   would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Role and environment.
#
# systemd user services do not read the login shell's profile, so the file the
# host bootstrap wrote is sourced here rather than inherited. The services VM
# may also carry a stale .dnstapir-test-env from an earlier layout, so the
# services file is tested first.
# ---------------------------------------------------------------------------
if [ -z "$role" ]; then
  if   [ -r "$HOME/.dnstapir-services-env" ]; then role=services
  elif [ -r "$HOME/.dnstapir-edge-env" ];     then role=edge
  elif [ -r "$HOME/.dnstapir-test-env" ];     then role=core
  else
    echo "$PROGNAME: no DNS TAPIR login environment found; pass --role" >&2
    exit 1
  fi
fi

case "$role" in
  services) env_file="$HOME/.dnstapir-services-env" ;;
  edge)     env_file="$HOME/.dnstapir-edge-env" ;;
  core)     env_file="$HOME/.dnstapir-test-env" ;;
  *)        echo "$PROGNAME: unknown role: $role" >&2; exit 2 ;;
esac
[ -r "$env_file" ] || { echo "$PROGNAME: cannot read $env_file" >&2; exit 1; }
# shellcheck disable=SC1090
. "$env_file"

# ---------------------------------------------------------------------------
# Timer installation.
# ---------------------------------------------------------------------------
unit_dir="$HOME/.config/systemd/user"
unit_name="dnstapir-maintenance"

install_timer() {
  # The round-trip check is the only one that proves every hop, and it needs the
  # sender built by section 13.2 of the Edge runbook. Refuse to install a timer
  # that would silently skip it.
  if [ "$role" = edge ] && [ ! -x "$TAPIR_EDGE_RUN/dnstap-sender/dnstap-sender" ]; then
    echo "$PROGNAME: the DNSTAP sender is missing; build it with section 13.2" >&2
    echo "$PROGNAME: of the Edge runbook before installing the timer" >&2
    exit 1
  fi

  mkdir -p "$unit_dir"
  cat > "$unit_dir/$unit_name.service" <<UNIT
[Unit]
Description=DNS TAPIR $role maintenance
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --role $role
UNIT

  cat > "$unit_dir/$unit_name.timer" <<UNIT
[Unit]
Description=DNS TAPIR $role maintenance

[Timer]
OnCalendar=$on_calendar
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl --user daemon-reload
  systemctl --user enable --now "$unit_name.timer"
  systemctl --user list-timers "$unit_name.timer" --no-pager
  printf '\ninstalled; run it now with: systemctl --user start %s.service\n' "$unit_name"
}

uninstall_timer() {
  systemctl --user disable --now "$unit_name.timer" 2>/dev/null || true
  rm -f "$unit_dir/$unit_name.timer" "$unit_dir/$unit_name.service"
  systemctl --user daemon-reload
  echo "removed"
}

if [ "$do_install" -eq 1 ]; then install_timer; exit 0; fi
if [ "$do_uninstall" -eq 1 ]; then uninstall_timer; exit 0; fi

printf '%s: %s role, %s\n' "$PROGNAME" "$role" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ "$dry_run" -eq 0 ] || printf '%s: dry run, nothing will change\n' "$PROGNAME"

# ---------------------------------------------------------------------------
# Tasks shared by every role.
# ---------------------------------------------------------------------------
report_host() {
  task "host"
  df -h / | tail -1 | sed 's/^/   /'
  docker ps --format '{{.Names}} {{.Status}}' | sed 's/^/   /'

  # A container that is up but wedged still counts as running, so this is a
  # floor rather than a health check. The role checks below are the real ones.
  #
  # Only non-zero exits are worth reporting. Both Compose stacks run one-shot
  # init containers that are supposed to finish and stay finished.
  tapir_exited="$(docker ps -a --filter status=exited --format '{{.Names}} {{.Status}}' \
    | grep -v 'Exited (0)' || true)"
  if [ -n "$tapir_exited" ]; then
    note "containers that exited with an error:"
    printf '%s\n' "$tapir_exited" | sed 's/^/   /'
  fi

  # Where a healthcheck is declared, an unhealthy container is the one case
  # docker itself can tell apart from a working one. Compose will not act on it,
  # so this is where it becomes a failure.
  tapir_unhealthy="$(docker ps --filter health=unhealthy --format '{{.Names}}' || true)"
  if [ -n "$tapir_unhealthy" ]; then
    fail "unhealthy: $(printf '%s' "$tapir_unhealthy" | tr '\n' ' ')"
  fi
}

prune_build_cache() {
  task "docker build cache"
  # Building every component from source leaves gigabytes behind. Images and
  # volumes are never touched: they are the deployment.
  docker system df --format '{{.Type}} {{.Size}} reclaimable {{.Reclaimable}}' 2>/dev/null \
    | sed 's/^/   /' || true
  # The filter takes a duration, so days are expressed in hours.
  run docker builder prune --force --filter "until=$((builder_days * 24))h" \
    | sed 's/^/   /'
}

# ---------------------------------------------------------------------------
# Edge.
# ---------------------------------------------------------------------------
edge_renew_certificate() {
  # $1 label
  # $2 enrolment key directory, where nodeman_client writes
  # $3 command printing the digest of the certificate the service is using
  # $4 command that puts the enrolment copy in front of the service
  tapir_label="$1"
  tapir_keys="$2"
  tapir_inuse="$3"
  tapir_apply="$4"

  if [ ! -r "$tapir_keys/tls.crt" ]; then
    note "$tapir_label: no certificate, not enrolled here"
    return 0
  fi

  tapir_enddate="$(openssl x509 -in "$tapir_keys/tls.crt" -noout -enddate | cut -d= -f2)"

  if openssl x509 -in "$tapir_keys/tls.crt" -noout \
       -checkend "$((renew_before_days * 86400))" >/dev/null; then
    note "$tapir_label: valid past the threshold, expires $tapir_enddate"
  else
    note "$tapir_label: expires $tapir_enddate, renewing"
    if [ "$dry_run" -eq 1 ]; then
      note "would renew $tapir_label"
    else
      tapir_before_epoch="$(date -d "$tapir_enddate" +%s)"

      # Renewal keeps data.json, so Core keeps finding the same signing identity
      # in NodeMan; only the X.509 key and certificate are replaced.
      ( cd "$TAPIR_EDGE_SRC/nodeman" && "$TAPIR_EDGE_UV" run nodeman_client \
          --data-jwk-file "$tapir_keys/data.json" \
          --tls-cert-file "$tapir_keys/tls.crt" \
          --tls-key-file "$tapir_keys/tls.key" \
          --tls-ca-file "$tapir_keys/tls-ca.crt" \
          --server "http://$TAPIR_CORE_VM_IP:$TAPIR_CORE_NODEMAN_PORT" \
          renew ) >> "$TAPIR_EDGE_LOGS/maintenance-renewal.log" 2>&1 \
        || { fail "$tapir_label: renewal failed, see maintenance-renewal.log"; return 0; }

      chmod 0600 "$tapir_keys/data.json" "$tapir_keys/tls.key"
      chmod 0644 "$tapir_keys/tls.crt" "$tapir_keys/tls-ca.crt"

      # Two assertions, and deliberately not "the new certificate now satisfies
      # the threshold": NodeMan issues a fixed validity, so a threshold longer
      # than that can never be met and would reject every renewal it triggered.
      openssl verify -CAfile "$tapir_keys/tls-ca.crt" "$tapir_keys/tls.crt" >/dev/null \
        || { fail "$tapir_label: renewed certificate does not verify"; return 0; }
      tapir_after_epoch="$(date -d "$(openssl x509 -in "$tapir_keys/tls.crt" \
        -noout -enddate | cut -d= -f2)" +%s)"
      [ "$tapir_after_epoch" -gt "$tapir_before_epoch" ] \
        || { fail "$tapir_label: expiry did not move forward"; return 0; }
      note "$tapir_label: renewed to $(openssl x509 -in "$tapir_keys/tls.crt" -noout -enddate | cut -d= -f2)"
    fi
  fi

  # Renewing and applying are separate steps, because a renewal interrupted
  # before its restart leaves the service running on the old certificate while
  # the file on disk looks fine. That state is invisible until the service
  # expires, so compare what the service is using against what was enrolled on
  # every run, not only after a renewal.
  tapir_enrolled_digest="$(sha256sum "$tapir_keys/tls.crt" | cut -d' ' -f1)"
  tapir_inuse_digest="$(eval "$tapir_inuse" 2>/dev/null || true)"
  if [ "$tapir_enrolled_digest" = "$tapir_inuse_digest" ]; then
    note "$tapir_label: the running service is using it"
    return 0
  fi

  note "$tapir_label: the running service has a different certificate, applying"
  if [ "$dry_run" -eq 1 ]; then
    note "would run: $tapir_apply"
    return 0
  fi
  eval "$tapir_apply"
  tapir_inuse_digest="$(eval "$tapir_inuse" 2>/dev/null || true)"
  [ "$tapir_enrolled_digest" = "$tapir_inuse_digest" ] \
    || fail "$tapir_label: the service did not pick up the enrolled certificate"
}

edge_certificates() {
  task "node certificates"

  # EDM reads its credentials from a volume that edm-init fills from the
  # enrolment directory, so the certificate in use is the one in that volume.
  #
  # The two command arguments are single-quoted on purpose: they are run through
  # eval inside the function, so their variables must expand there and not here.
  # Deliberately expanded at eval time, not here.
  # shellcheck disable=SC2016
  edge_renew_certificate "edm ($TAPIR_EDGE_ID)" "$TAPIR_EDGE_KEYS" \
    'docker run --rm --volume dnstapir-edge_edm-credentials:/c busybox:latest \
       sha256sum /c/tls.crt | cut -d" " -f1' \
    'docker compose --file "$TAPIR_EDGE_ROOT/compose.yaml" run --rm edm-init >/dev/null
     docker compose --file "$TAPIR_EDGE_ROOT/compose.yaml" restart edm >/dev/null'

  # POP reads its certificate from etc/certs rather than from the enrolment
  # directory, under the names its compiled-in configuration expects.
  # Deliberately expanded at eval time, not here.
  # shellcheck disable=SC2016
  edge_renew_certificate "pop" "$TAPIR_EDGE_ROOT/pop/keys" \
    'sha256sum "$TAPIR_EDGE_ROOT/pop/etc/certs/tapir-edge.crt" | cut -d" " -f1' \
    'install -m 0644 "$TAPIR_EDGE_ROOT/pop/keys/tls.crt"    "$TAPIR_EDGE_ROOT/pop/etc/certs/tapir-edge.crt"
     install -m 0600 "$TAPIR_EDGE_ROOT/pop/keys/tls.key"    "$TAPIR_EDGE_ROOT/pop/etc/certs/tapir-edge.key"
     install -m 0644 "$TAPIR_EDGE_ROOT/pop/keys/tls-ca.crt" "$TAPIR_EDGE_ROOT/pop/etc/certs/tapirCA.crt"
     docker restart pop >/dev/null'
}

edge_rotate_pop_logs() {
  task "POP logs"
  # POP runs in debug mode and never rotates. It holds each file open, so the
  # rotation moves the file aside and restarts POP to reopen it rather than
  # truncating underneath a live descriptor.
  tapir_rotated=0
  for tapir_log in pop.log pop-mqtt.log pop-policy.log pop-dnsengine.log pop-bootstrap.log; do
    tapir_size="$(docker run --rm --volume pop-logs:/l busybox:latest \
      stat -c %s "/l/$tapir_log" 2>/dev/null || echo 0)"
    if [ "$tapir_size" -le "$((log_max_mb * 1024 * 1024))" ]; then
      [ "$tapir_size" -eq 0 ] || note "$tapir_log $((tapir_size / 1048576)) MiB"
      continue
    fi
    note "$tapir_log $((tapir_size / 1048576)) MiB, rotating"
    run docker run --rm --volume pop-logs:/l busybox:latest sh -ec "
      i=$keep_logs
      rm -f /l/$tapir_log.\$i.gz
      while [ \$i -gt 1 ]; do
        j=\$((i - 1))
        [ -f /l/$tapir_log.\$j.gz ] && mv /l/$tapir_log.\$j.gz /l/$tapir_log.\$i.gz
        i=\$j
      done
      mv /l/$tapir_log /l/$tapir_log.1
      gzip /l/$tapir_log.1"
    tapir_rotated=1
  done

  if [ "$tapir_rotated" -eq 1 ]; then
    note "restarting POP so it reopens its logs"
    run docker restart pop >/dev/null
  fi
}

edge_prune_parquet() {
  task "uploaded histograms"
  # EDM moves each uploaded file to sent/ and keeps it forever: one a minute,
  # 1440 a day. The outbox is never touched, because a file still there has not
  # been accepted by the Aggregate Receiver yet.
  tapir_before="$(docker run --rm --volume dnstapir-edge_edm-data:/d busybox:latest \
    sh -c 'ls /d/parquet/histograms/sent 2>/dev/null | wc -l' || echo 0)"
  run docker run --rm --volume dnstapir-edge_edm-data:/d busybox:latest \
    find /d/parquet/histograms/sent -type f -mtime "+$parquet_days" -delete 2>/dev/null || true
  tapir_after="$(docker run --rm --volume dnstapir-edge_edm-data:/d busybox:latest \
    sh -c 'ls /d/parquet/histograms/sent 2>/dev/null | wc -l' || echo 0)"
  note "sent: $tapir_before files before, $tapir_after after"

  tapir_outbox="$(docker run --rm --volume dnstapir-edge_edm-data:/d busybox:latest \
    sh -c 'ls /d/parquet/histograms/outbox 2>/dev/null | wc -l' || echo 0)"
  if [ "$tapir_outbox" -gt 5 ]; then
    fail "outbox holds $tapir_outbox files; uploads to the Aggregate Receiver are not completing"
  else
    note "outbox: $tapir_outbox files pending"
  fi
}

edge_roundtrip() {
  task "observation round trip"
  # The one check that covers every hop: DNSTAP to EDM, MQTT to Mosquitto, the
  # bridge to NATS, the looptest analyst, the encoder, back down the bridge and
  # into POP's list. A component that is up but no longer doing its job -- a
  # bridge with a stale validation key, for instance -- fails here and nowhere
  # else.
  tapir_sender="$TAPIR_EDGE_RUN/dnstap-sender/dnstap-sender"
  if [ ! -x "$tapir_sender" ]; then
    fail "no DNSTAP sender; build it with section 13.2 of the Edge runbook"
    return 0
  fi
  if [ "$dry_run" -eq 1 ]; then
    note "would inject a looptest name and wait for it to reach POP"
    return 0
  fi

  tapir_qname="maint-$(date +%s).from-edge.looptest.dnstapir.se"
  "$tapir_sender" "$tapir_qname" "127.0.0.1:$TAPIR_EDGE_DNSTAP_PORT" >/dev/null

  for _ in $(seq 1 "$roundtrip_timeout"); do
    if docker run --rm --volume pop-logs:/l busybox:latest \
         grep -c "$tapir_qname" /l/pop.log >/dev/null 2>&1; then
      note "$tapir_qname reached POP"
      return 0
    fi
    sleep 1
  done
  fail "$tapir_qname did not reach POP within ${roundtrip_timeout}s"
}

# ---------------------------------------------------------------------------
# Core.
# ---------------------------------------------------------------------------
core_nats() {
  docker run --rm natsio/nats-box:latest \
    nats --server "$TAPIR_SERVICES_NATS_ENCODER_URL" "$@"
}

core_load_services_env() {
  tapir_services_env="$TAPIR_TEST_ROOT/services-bundle/services.env"
  [ -s "$tapir_services_env" ] || return 1
  set -a
  # shellcheck disable=SC1090
  . "$tapir_services_env"
  set +a
}

core_bucket_ttls() {
  task "observation bucket lifetimes"
  # The lifetime that reaches a policy processor comes from the bucket, not from
  # the analysts' configuration, and the buckets outlive Core. Section 11 sets
  # them; this is the regression guard.
  core_load_services_env || { fail "no services bundle"; return 0; }
  for tapir_bucket in globally_new_bucket looptest_bucket registry_investigation_bucket; do
    tapir_age="$(core_nats stream info "KV_$tapir_bucket" --json 2>/dev/null \
      | jq -r '.config.max_age // empty' || true)"
    if [ -z "$tapir_age" ]; then
      fail "$tapir_bucket does not exist"
    elif [ "$tapir_age" -lt 3600000000000 ]; then
      fail "$tapir_bucket max age is $((tapir_age / 1000000000))s, below the deployed 3600"
    else
      note "$tapir_bucket $((tapir_age / 1000000000))s"
    fi
  done
}

core_bridge_signatures() {
  task "MQTT bridge"
  # A bridge whose cached validation key has gone stale stays up, stays
  # connected and discards every message. Nothing else notices.
  tapir_bad="$(docker logs --since 24h core-runtime-mqtt-bridge-1 2>&1 \
    | grep -c 'Bad signature' || true)"
  if [ "$tapir_bad" -gt 0 ]; then
    fail "$tapir_bad discarded messages in the last 24h; restart the bridge (mqtt-bridge#121)"
  else
    note "no discarded messages in the last 24h"
  fi
}

core_certificates() {
  task "broker certificates"
  for tapir_cert in \
    "$TAPIR_TEST_ROOT/core-runtime/mosquitto/pki/server.crt" \
    "$TAPIR_TEST_ROOT/core-runtime/mqtt-bridge/client.crt"
  do
    [ -r "$tapir_cert" ] || { note "${tapir_cert##*/}: absent"; continue; }
    # These are 825-day certificates issued on the services VM, so this is a
    # report rather than a renewal: reissuing them means a new handover bundle.
    if openssl x509 -in "$tapir_cert" -noout -checkend "$((30 * 86400))" >/dev/null; then
      note "${tapir_cert##*/}: $(openssl x509 -in "$tapir_cert" -noout -enddate | cut -d= -f2)"
    else
      fail "${tapir_cert##*/} expires within 30 days; reissue on the services VM and re-run its section 10"
    fi
  done
}

# ---------------------------------------------------------------------------
# Services.
# ---------------------------------------------------------------------------
services_compose() {
  docker compose --file "$TAPIR_SERVICES_RUN/data-services/compose.yaml" \
    --env-file "$TAPIR_SERVICES_KEYS/service-credentials.env" "$@"
}

services_backup() {
  task "backup"
  # Section 11 of the services runbook. This host holds the only state and the
  # CA cannot be recreated, so the backup is the point of the whole split.
  tapir_creds="$TAPIR_SERVICES_KEYS/service-credentials.env"
  tapir_dir="$TAPIR_SERVICES_ROOT/backup/$(date -u +%Y%m%dT%H%M%SZ)"
  # shellcheck disable=SC1090
  . "$tapir_creds"

  if [ "$dry_run" -eq 1 ]; then
    note "would write a backup generation to $tapir_dir"
    return 0
  fi

  mkdir -p "$tapir_dir"
  chmod 0700 "$tapir_dir"

  services_compose exec -T mongo \
    mongodump --quiet --archive --gzip \
      --username "$TAPIR_MONGO_ROOT_USER" \
      --password "$TAPIR_MONGO_ROOT_PASSWORD" \
      --authenticationDatabase admin \
    < /dev/null \
    > "$tapir_dir/mongo.archive.gz" \
    || { fail "mongodump failed"; return 0; }
  test -s "$tapir_dir/mongo.archive.gz" || { fail "mongo archive is empty"; return 0; }

  # JetStream and the object store are volume copies, which need those two
  # stopped. MongoDB above is dumped online, so only these are interrupted.
  services_compose stop nats s3 >/dev/null 2>&1
  for tapir_vol in $(docker volume ls --quiet | grep -E 'nats-jetstream|rustfs-data'); do
    docker run --rm \
      --volume "$tapir_vol:/from:ro" \
      --volume "$tapir_dir:/to" \
      busybox:latest \
      tar -czf "/to/$tapir_vol.tar.gz" -C /from . \
      || fail "volume copy failed: $tapir_vol"
  done
  services_compose start nats s3 >/dev/null 2>&1

  tar -czf "$tapir_dir/ca-and-keys.tar.gz" -C "$TAPIR_SERVICES_ROOT" ca keys
  chmod 0600 "$tapir_dir"/*.gz
  note "wrote $(du -sh "$tapir_dir" | cut -f1) to $tapir_dir"

  # Keep a bounded number of generations. This is still not an off-host copy:
  # a backup that exists only on the host it protects is not a backup.
  tapir_stale="$(find "$TAPIR_SERVICES_ROOT/backup" -mindepth 1 -maxdepth 1 -type d \
    | sort -r | tail -n "+$((keep_backups + 1))")"
  if [ -n "$tapir_stale" ]; then
    printf '%s\n' "$tapir_stale" | while read -r tapir_old; do
      note "removing old generation ${tapir_old##*/}"
      rm -rf "$tapir_old"
    done
  fi
  note "REMINDER: copy $TAPIR_SERVICES_ROOT/backup off this VM"
}

services_prune_aggregates() {
  task "stored aggregates"
  # A string comparison, not an integer one, so a fractional day is accepted.
  if [ "$aggregate_days" = 0 ]; then
    note "retention disabled"
    return 0
  fi
  # shellcheck disable=SC1090,SC1091
  . "$TAPIR_SERVICES_KEYS/service-credentials.env"

  # The object goes first and the metadata second, so an interrupted run leaves
  # a document pointing at nothing -- visible and repairable -- rather than an
  # object nothing refers to, which nothing would ever find again.
  tapir_keys_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tapir_keys_file'" RETURN

  services_compose exec -T mongo mongosh --quiet \
    --username aggrec --password "$TAPIR_MONGO_AGGREC_PASSWORD" \
    --authenticationDatabase aggregates \
    --eval "
      const cutoff = ObjectId.createFromTime(
        Math.floor(Date.now() / 1000) - $aggregate_days * 86400);
      db.getSiblingDB('aggregates').aggregates
        .find({_id: {\$lt: cutoff}}, {s3_object_key: 1})
        .forEach(d => print(d._id + ' ' + d.s3_object_key));
    " < /dev/null > "$tapir_keys_file" || { fail "could not list old aggregates"; return 0; }

  tapir_count="$(grep -c . "$tapir_keys_file" || true)"
  if [ "$tapir_count" -eq 0 ]; then
    note "nothing older than $aggregate_days days"
    return 0
  fi
  note "$tapir_count aggregates older than $aggregate_days days"
  if [ "$dry_run" -eq 1 ]; then
    note "would delete them, object and metadata together"
    return 0
  fi

  while read -r tapir_id tapir_key; do
    [ -n "$tapir_key" ] || continue
    docker run --rm --network host \
      --env AWS_ACCESS_KEY_ID="$TAPIR_S3_ACCESS_KEY_ID" \
      --env AWS_SECRET_ACCESS_KEY="$TAPIR_S3_SECRET_ACCESS_KEY" \
      --env AWS_DEFAULT_REGION=us-east-1 \
      amazon/aws-cli:latest --endpoint-url http://127.0.0.1:9000 \
      s3api delete-object --bucket aggregates --key "$tapir_key" >/dev/null 2>&1 || true
    services_compose exec -T mongo mongosh --quiet \
      --username aggrec --password "$TAPIR_MONGO_AGGREC_PASSWORD" \
      --authenticationDatabase aggregates \
      --eval "db.getSiblingDB('aggregates').aggregates.deleteOne({_id: ObjectId('$tapir_id')})" \
      < /dev/null >/dev/null || fail "could not delete metadata for $tapir_id"
  done < "$tapir_keys_file"
  note "removed $tapir_count aggregates"
}

services_state_report() {
  task "state"
  curl -fsS http://127.0.0.1:8222/jsz 2>/dev/null \
    | jq -r '"jetstream: \(.storage) bytes, \(.streams) streams, \(.consumers) consumers"' \
    | sed 's/^/   /' \
    || fail "NATS monitoring endpoint did not answer"
  docker system df -v 2>/dev/null | sed -n '/VOLUME NAME/,/^$/p' | sed 's/^/   /'

  task "firewall"
  # The only control in front of MongoDB, NATS and the object store. The rules
  # are recorded whether or not UFW is running, so the state has to be checked.
  if ufw status 2>/dev/null | head -1 | grep -c 'Status: active' >/dev/null; then
    note "UFW active"
  else
    fail "UFW is inactive: MongoDB, NATS and the object store are open to the test network"
  fi
}

services_certificates() {
  task "CA and issued certificates"
  openssl x509 -in "$TAPIR_SERVICES_CA/ca.crt" -noout -enddate | sed 's/^/   CA /'
  for tapir_cert in mosquitto/server.crt mqtt-bridge/client.crt; do
    [ -r "$TAPIR_SERVICES_CA/$tapir_cert" ] || continue
    if openssl x509 -in "$TAPIR_SERVICES_CA/$tapir_cert" -noout \
         -checkend "$((30 * 86400))" >/dev/null; then
      note "$tapir_cert $(openssl x509 -in "$TAPIR_SERVICES_CA/$tapir_cert" -noout -enddate | cut -d= -f2)"
    else
      fail "$tapir_cert expires within 30 days; reissue and re-run section 10"
    fi
  done
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------
report_host

case "$role" in
  edge)
    edge_certificates
    edge_rotate_pop_logs
    edge_prune_parquet
    prune_build_cache
    edge_roundtrip
    ;;
  core)
    core_certificates
    core_bucket_ttls
    core_bridge_signatures
    prune_build_cache
    ;;
  services)
    services_certificates
    services_state_report
    services_prune_aggregates
    services_backup
    prune_build_cache
    ;;
esac

printf '\n%s: %s checks failed\n' "$PROGNAME" "$failures"
[ "$failures" -eq 0 ]
