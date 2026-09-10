#!/bin/bash
#
# dnstapir-host-bootstrap.sh — privileged host bootstrap shared by the
# DNS TAPIR Core and Edge test-deployment runbooks.
#
# This is every step in those runbooks that needs root. It installs the OS and
# Docker packages, creates the unprivileged service account and its subordinate
# ID ranges, installs the Rootless Docker prerequisites, hands the Docker daemon
# over to the service account, creates the workspace directories, and writes the
# service account's login environment. Everything after it runs unprivileged.
#
# Run it with sudo, from the runbook's own directory:
#
#   sudo ./dnstapir-host-bootstrap.sh --service-user dnstapir \
#     --subid-start 231072 --env-file .dnstapir-test-env \
#     --dir 0755:/opt/dnstapir-test <<'EOF'
#   TAPIR_TEST_ROOT=/opt/dnstapir-test
#   EOF
#
# The variables for the login environment are read from standard input as
# KEY=VALUE lines, so a runbook can pass them with a heredoc that its own shell
# expands. XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS and DOCKER_HOST are added
# automatically, because they depend on the service account's UID.
#
# The script is idempotent: it can be re-run after a partial failure, and
# re-running it on a working host changes nothing.

set -euo pipefail

readonly PROGNAME="${0##*/}"

# Packages both runbooks need, plus the Rootless Docker prerequisites. Per-role
# extras are added with --extra-packages.
readonly BASE_PACKAGES=(
  ca-certificates
  curl
  dbus-user-session
  git
  jq
  openssl
  python3
  python3-pip
  python3-venv
  slirp4netns
  ufw
  uidmap
)

# Distribution packages that conflict with Docker's own.
readonly CONFLICTING_PACKAGES=(
  containerd
  docker-buildx
  docker-compose
  docker-compose-v2
  docker-doc
  docker.io
  podman-docker
  runc
)

readonly DOCKER_PACKAGES=(
  containerd.io
  docker-buildx-plugin
  docker-ce
  docker-ce-cli
  docker-ce-rootless-extras
  docker-compose-plugin
)

service_user=dnstapir
subid_start=231072
env_file=
extra_packages=()
dirs=()
dry_run=0

usage() {
  cat <<USAGE
Usage: sudo $PROGNAME --env-file NAME [options] < vars

Required:
  --env-file NAME         Login environment file to write in the service
                          account's home directory, e.g. .dnstapir-test-env.

Options:
  --service-user NAME     Service account to create and use.
                          Default: $service_user
  --subid-start N         Lowest subordinate UID/GID to consider when
                          allocating a range. Default: $subid_start
  --extra-packages "A B"  Additional apt packages for this role.
  --dir MODE:PATH         Directory to create, owned by the service account.
                          Repeatable. Example: --dir 0700:/opt/x/keys
  --dry-run               Print what would be done and change nothing.
  -h, --help              Show this text.

Standard input supplies the login environment as KEY=VALUE lines. Blank lines
and lines starting with # are ignored.
USAGE
}

log()  { printf '%s: %s\n' "$PROGNAME" "$*"; }
warn() { printf '%s: %s\n' "$PROGNAME" "$*" >&2; }
die()  { warn "$*"; exit 1; }

# run COMMAND... — execute, or describe it under --dry-run.
run() {
  if [ "$dry_run" -eq 1 ]; then
    printf '  would run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --service-user)   service_user="${2:?--service-user needs a value}"; shift 2 ;;
    --subid-start)    subid_start="${2:?--subid-start needs a value}"; shift 2 ;;
    --env-file)       env_file="${2:?--env-file needs a value}"; shift 2 ;;
    --extra-packages) read -r -a extra_packages <<<"${2:?--extra-packages needs a value}"; shift 2 ;;
    --dir)            dirs+=("${2:?--dir needs MODE:PATH}"); shift 2 ;;
    --dry-run)        dry_run=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$env_file" ] || { usage >&2; die "--env-file is required"; }
case "$env_file" in
  */*) die "--env-file must be a bare file name, not a path: $env_file" ;;
esac
case "$subid_start" in
  ''|*[!0-9]*) die "--subid-start must be a number: $subid_start" ;;
esac
for spec in ${dirs+"${dirs[@]}"}; do
  case "$spec" in
    [0-7][0-7][0-7][0-7]:/*) ;;
    *) die "--dir needs MODE:ABSOLUTE_PATH, e.g. 0755:/opt/x, got: $spec" ;;
  esac
done

if [ "$dry_run" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  die "must run as root; use: sudo $PROGNAME ..."
fi

# Read the login environment from stdin before anything else, so a malformed
# input fails before the host is modified.
env_vars=()
if [ ! -t 0 ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      [A-Za-z_]*=*) env_vars+=("$line") ;;
      *) die "standard input must contain KEY=VALUE lines, got: $line" ;;
    esac
  done
fi

log "service account: $service_user"
log "login environment: ~/$env_file with ${#env_vars[@]} variable(s)"
[ "$dry_run" -eq 1 ] && log "dry run: no changes will be made"

# ---------------------------------------------------------------------------
# 1. Operating-system packages.
# ---------------------------------------------------------------------------
log "installing operating-system packages"
run apt-get update
run apt-get install -y "${BASE_PACKAGES[@]}" ${extra_packages+"${extra_packages[@]}"}

# ---------------------------------------------------------------------------
# 2. Remove distribution Docker packages that conflict with Docker's own.
# ---------------------------------------------------------------------------
installed_conflicts=()
for pkg in "${CONFLICTING_PACKAGES[@]}"; do
  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  case "$status" in
    *"install ok installed"*) installed_conflicts+=("$pkg") ;;
  esac
done
if [ "${#installed_conflicts[@]}" -gt 0 ]; then
  log "removing conflicting packages: ${installed_conflicts[*]}"
  run apt-get remove -y "${installed_conflicts[@]}"
else
  log "no conflicting Docker packages installed"
fi

# ---------------------------------------------------------------------------
# 3. Docker's apt repository and Docker Engine.
# ---------------------------------------------------------------------------
if [ ! -s /etc/apt/keyrings/docker.asc ]; then
  log "adding Docker's signing key"
  run install -m 0755 -d /etc/apt/keyrings
  run curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  run chmod a+r /etc/apt/keyrings/docker.asc
else
  log "Docker signing key already present"
fi

# UBUNTU_CODENAME is what Docker's repository is keyed on; VERSION_CODENAME is
# the fallback for derivatives that do not set it.
# shellcheck source=/dev/null disable=SC1091
codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
[ -n "$codename" ] || die "could not determine the distribution codename"
architecture="$(dpkg --print-architecture)"
log "Docker repository for $codename/$architecture"
if [ "$dry_run" -eq 1 ]; then
  printf '  would write /etc/apt/sources.list.d/docker.sources for %s/%s\n' \
    "$codename" "$architecture"
else
  cat > /etc/apt/sources.list.d/docker.sources <<SOURCES
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
SOURCES
fi

log "installing Docker Engine and the Compose plugin"
run apt-get update
run apt-get install -y "${DOCKER_PACKAGES[@]}"

if [ "$dry_run" -eq 0 ]; then
  docker --version
  docker compose version
  command -v dockerd-rootless-setuptool.sh >/dev/null \
    || die "dockerd-rootless-setuptool.sh not found after installing docker-ce-rootless-extras"
fi

# ---------------------------------------------------------------------------
# 4. nf_tables.
#
# iptables on Ubuntu 24.04 is the iptables-nft front end, so the iptables probe
# in dockerd-rootless-setuptool.sh needs this module. On a host where no
# privileged process has already loaded it, that tool refuses to install.
# ---------------------------------------------------------------------------
log "loading nf_tables and making the load persistent"
run modprobe nf_tables
if [ "$dry_run" -eq 1 ]; then
  printf '  would write /etc/modules-load.d/nf_tables.conf\n'
else
  printf 'nf_tables\n' > /etc/modules-load.d/nf_tables.conf
  lsmod | grep -c '^nf_tables' >/dev/null || die "nf_tables is not loaded"
fi

# ---------------------------------------------------------------------------
# 5. The service account.
# ---------------------------------------------------------------------------
if id "$service_user" >/dev/null 2>&1; then
  log "service account $service_user already exists"
else
  log "creating service account $service_user"
  run useradd --create-home --user-group --shell /bin/bash "$service_user"
fi

if [ "$dry_run" -eq 1 ] && ! id "$service_user" >/dev/null 2>&1; then
  log "dry run: cannot inspect an account that does not exist yet; stopping here"
  exit 0
fi

service_uid="$(id -u "$service_user")"
service_group="$(id -gn "$service_user")"
service_home="$(getent passwd "$service_user" | cut -d: -f6)"
[ -n "$service_home" ] || die "could not determine the home directory of $service_user"
log "uid=$service_uid group=$service_group home=$service_home"

# The service account must not be able to escalate: no sudo, and not in the
# root-equivalent docker group.
privileged="$(id -nG "$service_user" | tr ' ' '\n' | grep -cE '^(sudo|docker)$' || true)"
[ "$privileged" -eq 0 ] \
  || die "$service_user is in the sudo or docker group; remove it before continuing"

# ---------------------------------------------------------------------------
# 6. Subordinate UID and GID ranges for Rootless Docker.
# ---------------------------------------------------------------------------
if grep -cE "^${service_user}:" /etc/subuid >/dev/null 2>&1 \
   && grep -cE "^${service_user}:" /etc/subgid >/dev/null 2>&1; then
  log "subordinate ID ranges already allocated"
else
  range_start="$(
    awk -F: -v candidate="$subid_start" '
      NF == 3 {
        end = $2 + $3
        if (end > candidate) candidate = end
      }
      END {
        block = 65536
        print int((candidate + block - 1) / block) * block
      }
    ' /etc/subuid /etc/subgid
  )"
  range_end="$((range_start + 65535))"
  log "allocating subordinate IDs $range_start-$range_end"
  grep -cE "^${service_user}:" /etc/subuid >/dev/null 2>&1 \
    || run usermod --add-subuids "$range_start-$range_end" "$service_user"
  grep -cE "^${service_user}:" /etc/subgid >/dev/null 2>&1 \
    || run usermod --add-subgids "$range_start-$range_end" "$service_user"
fi

if [ "$dry_run" -eq 0 ]; then
  for map in /etc/subuid /etc/subgid; do
    awk -F: -v user="$service_user" \
      '$1 == user && $3 >= 65536 { found = 1 } END { exit !found }' "$map" \
      || die "$service_user needs at least 65536 subordinate IDs in $map"
    grep -E "^${service_user}:" "$map" | sed "s|^|  $map: |"
  done
  for tool in newuidmap newgidmap slirp4netns; do
    command -v "$tool" >/dev/null || die "$tool not found; the uidmap or slirp4netns package is missing"
  done
  log "Rootless Docker prerequisites present"
fi

# ---------------------------------------------------------------------------
# 7. Workspace directories owned by the service account.
# ---------------------------------------------------------------------------
for spec in ${dirs+"${dirs[@]}"}; do
  mode="${spec%%:*}"
  path="${spec#*:}"
  log "workspace directory $path (mode $mode)"
  run install -d -o "$service_user" -g "$service_group" -m "$mode" "$path"
done

# ---------------------------------------------------------------------------
# 8. The service account's login environment.
# ---------------------------------------------------------------------------
env_path="$service_home/$env_file"
log "writing $env_path"
if [ "$dry_run" -eq 1 ]; then
  printf '  would write %s with:\n' "$env_path"
  for var in ${env_vars+"${env_vars[@]}"}; do
    printf '    export %s\n' "$var"
  done
  printf '    export XDG_RUNTIME_DIR=/run/user/%s\n' "$service_uid"
  printf '    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus\n' "$service_uid"
  printf '    export DOCKER_HOST=unix:///run/user/%s/docker.sock\n' "$service_uid"
else
  {
    for var in ${env_vars+"${env_vars[@]}"}; do
      printf 'export %s\n' "$var"
    done
    printf 'export XDG_RUNTIME_DIR=/run/user/%s\n' "$service_uid"
    printf 'export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus\n' "$service_uid"
    printf 'export DOCKER_HOST=unix:///run/user/%s/docker.sock\n' "$service_uid"
  } > "$env_path"

  profile="$service_home/.profile"
  [ -e "$profile" ] || : > "$profile"
  if ! grep -Fqx ". \"\$HOME/$env_file\"" "$profile"; then
    # $HOME must stay literal in .profile, so it is resolved at login time.
    # shellcheck disable=SC2016
    printf '\n. "$HOME/%s"\n' "$env_file" >> "$profile"
  fi

  chown "$service_user:$service_group" "$env_path" "$profile"
  chmod 0644 "$env_path" "$profile"
fi

# ---------------------------------------------------------------------------
# 9. Hand the Docker daemon over to the service account.
# ---------------------------------------------------------------------------
log "disabling the system-wide Docker daemon"
run systemctl disable --now docker.service docker.socket
run rm -f /var/run/docker.sock

log "enabling a persistent user manager for $service_user"
run loginctl enable-linger "$service_user"
run systemctl start "user@$service_uid.service"

log "installing Rootless Docker as $service_user"
run sudo -iu "$service_user" env \
  XDG_RUNTIME_DIR="/run/user/$service_uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$service_uid/bus" \
  dockerd-rootless-setuptool.sh install

log "enabling the Rootless Docker service for $service_user"
run sudo -iu "$service_user" env \
  XDG_RUNTIME_DIR="/run/user/$service_uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$service_uid/bus" \
  systemctl --user enable --now docker.service

if [ "$dry_run" -eq 0 ]; then
  log "verifying the rootless daemon"
  sudo -iu "$service_user" env \
    XDG_RUNTIME_DIR="/run/user/$service_uid" \
    DOCKER_HOST="unix:///run/user/$service_uid/docker.sock" \
    docker info --format '{{json .SecurityOptions}}' \
    | grep -c rootless >/dev/null \
    || die "the daemon for $service_user does not report the rootless security option"
fi

log "done; continue as the service account with: sudo -iu $service_user"
