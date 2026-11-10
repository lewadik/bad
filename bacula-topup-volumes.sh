#!/usr/bin/env bash
# bacula-topup-volumes.sh
#
# Keeps a buffer of labelled volumes in every pool. Bacula does not create a
# volume on demand: a job that runs out of Append volumes stops and waits for an
# operator. This script tops the buffer back up, so that never happens at 02:00.
#
# Installed as a daily timer by deploy-bacula-server.sh; safe to run by hand.
#
# Usage: bacula-topup-volumes.sh [--pool NAME] [--target N] [--dry-run] [--quiet]
#
# Exit codes: 0 all pools satisfied, 1 at least one volume could not be labelled.

set -Eeuo pipefail

CONF=${CONF:-/etc/bacula/bconsole.conf}
SITE=${SITE:-/etc/bacula/site.env}

DRY_RUN=0
QUIET=0
ONLY_POOL=""
TARGET_OVERRIDE=""

while (($#)); do
  case $1 in
    --pool)   ONLY_POOL=${2:?}; shift 2 ;;
    --target) TARGET_OVERRIDE=${2:?}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    -h|--help) sed -n '2,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

log()  { (( QUIET )) || printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { (( QUIET )) || printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -r $SITE ]] || die "$SITE missing — is this a Bacula server built by deploy-bacula-server.sh?"
# shellcheck disable=SC1090
. "$SITE"

if have sudo; then PSQL=(sudo -u bacula psql -qtAX -d "$DB_NAME")
else PSQL=(runuser -u bacula -- psql -qtAX -d "$DB_NAME"); fi
pc() { "${PSQL[@]}" -c "$1"; }

# pool:target:prefix:storage — must match conf.d/20-pools.conf and 10-storage.conf
POOLS=(
  "File:8:File-:LocalDisk"
  "Monthly:6:Monthly-:LocalDisk"
  "Catalog:4:Catalog-:LocalDisk"
)
if [[ -n ${OFFSITE_DIR:-} ]]; then
  POOLS+=("Offsite:4:Offsite-:OffsiteDisk")
fi

failures=0
summary=()

label_volume() { # label_volume <pool> <storage> <name>
  local pool=$1 storage=$2 vol=$3 out
  if (( DRY_RUN )); then
    info "[dry-run] label storage=$storage pool=$pool volume=$vol"
    return 0
  fi
  out=$(printf 'label storage=%s pool=%s volume=%s\nquit\n' "$storage" "$pool" "$vol" |
        bconsole -c "$CONF" -n 2>&1) || true
  if [[ $(pc "SELECT count(*) FROM Media WHERE Media='$vol'") == 1 ]]; then
    return 0
  fi
  warn "could not label $vol in pool $pool:"
  printf '%s\n' "$out" | tail -5 | sed 's/^/      /' >&2
  return 1
}

for spec in "${POOLS[@]}"; do
  IFS=: read -r pool target prefix storage <<<"$spec"
  if [[ -n $ONLY_POOL && $ONLY_POOL != "$pool" ]]; then continue; fi
  if [[ -n $TARGET_OVERRIDE ]]; then target=$TARGET_OVERRIDE; fi

  if [[ $(pc "SELECT count(*) FROM Pool WHERE Name='$pool'") != 1 ]]; then
    warn "pool $pool is not in the catalog — skipping"
    failures=$((failures + 1))
    continue
  fi

  existing=$(pc "SELECT count(*) FROM Media m JOIN Pool p ON p.PoolId=m.PoolId WHERE p.Name='$pool'")
  existing=${existing:-0}
  labelled=0
  for ((i = 1; i <= target; i++)); do
    vol=$(printf '%s%04d' "$prefix" "$i")
    if [[ $(pc "SELECT count(*) FROM Media WHERE Media='$vol'") == 1 ]]; then continue; fi
    if label_volume "$pool" "$storage" "$vol"; then
      labelled=$((labelled + 1))
    else
      failures=$((failures + 1))
      break
    fi
  done

  existing=$((existing + labelled))
  summary+=("$(printf '%-8s %2d/%2d volumes' "$pool" "$existing" "$target")")
  info "pool $pool: ${existing}/${target} labelled, $labelled new"
done

log "Summary"
for line in "${summary[@]}"; do info "$line"; done

if (( failures )); then
  warn "$failures problem(s) — a job may wait for a volume. Check: bconsole -> list volumes"
  exit 1
fi
(( QUIET )) || info "all pools have a full buffer"
exit 0
