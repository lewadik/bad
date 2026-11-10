#!/usr/bin/env bash
# bacula-restore-drill.sh
#
# Proves that a backup can actually be read back. It restores the most recent
# successful job of one client into a scratch directory on the director host and
# reports how many files and bytes came back. A backup that has never been
# restored is a hypothesis, not a backup.
#
# Usage: bacula-restore-drill.sh [--client NAME] [--jobid N] [--dest DIR]
#                                [--prune] [--dry-run] [--keep]
#
#   --client NAME  client to drill (default: the one backed up most recently)
#   --jobid N      drill a specific job instead of the latest full
#   --dest DIR     scratch root (default: /var/tmp/bacula-drill)
#   --prune        delete drill directories older than 30 days afterwards
#   --keep         keep the restored tree (it is kept by default; --prune prunes)
#
# Exit codes: 0 restore verified, 1 usage/precondition, 4 restore failed.

set -Eeuo pipefail

SITE=${SITE:-/etc/bacula/site.env}
CONF=${CONF:-/etc/bacula/bconsole.conf}
LOG=${LOG:-/var/log/bacula/drill.log}

CLIENT=""
JOBID=""
DEST_ROOT=/var/tmp/bacula-drill
PRUNE=0
DRY_RUN=0

while (($#)); do
  case $1 in
    --client) CLIENT=${2:?}; shift 2 ;;
    --jobid)  JOBID=${2:?}; shift 2 ;;
    --dest)   DEST_ROOT=${2:?}; shift 2 ;;
    --prune)  PRUNE=1; shift ;;
    --keep)   PRUNE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -r $SITE ]] || die "$SITE missing — is this a Bacula server built by deploy-bacula-server.sh?"
# shellcheck disable=SC1090
. "$SITE"

if have sudo; then PSQL=(sudo -u bacula psql -qtAX -d "$DB_NAME")
else PSQL=(runuser -u bacula -- psql -qtAX -d "$DB_NAME"); fi
pc() { "${PSQL[@]}" -c "$1" 2>/dev/null || true; }

# --- pick what to drill -----------------------------------------------------
if [[ -z $JOBID ]]; then
  if [[ -z $CLIENT ]]; then
    CLIENT=$(pc "SELECT c.Name FROM Job j JOIN Client c ON c.ClientId=j.ClientId
                 WHERE j.Type='B' AND j.JobStatus IN ('T','W')
                 ORDER BY j.JobTDate DESC LIMIT 1")
    [[ -n $CLIENT ]] || die "no successful backup in the catalog yet"
  fi
  JOBID=$(pc "SELECT j.JobId FROM Job j JOIN Client c ON c.ClientId=j.ClientId
              WHERE c.Name='$CLIENT' AND j.Type='B' AND j.JobStatus IN ('T','W')
              ORDER BY (j.Level='F') DESC, j.JobTDate DESC LIMIT 1")
  [[ -n $JOBID ]] || die "no successful backup for client $CLIENT"
else
  CLIENT=${CLIENT:-$(pc "SELECT c.Name FROM Job j JOIN Client c ON c.ClientId=j.ClientId WHERE j.JobId=$JOBID")}
fi

info "client $CLIENT, jobid $JOBID"
level=$(pc "SELECT Level FROM Job WHERE JobId=$JOBID")
files_in_job=$(pc "SELECT JobFiles FROM Job WHERE JobId=$JOBID")
info "level ${level:-?}, $(( ${files_in_job:-0} )) files in the catalog"

TS=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$DEST_ROOT/$CLIENT/$JOBID-$TS"

if (( DRY_RUN )); then
  info "[dry-run] destination $DEST"
  cat <<EOF
    restore client=$CLIENT jobid=$JOBID where=$DEST
    mark *
    done
    yes
EOF
  exit 0
fi

install -d -m 0755 "$DEST"

# --- run the restore --------------------------------------------------------
# mark * selects every file in the job; done ends selection; yes confirms.
log "Restoring into $DEST"
out=$(
  {
    printf 'restore client=%s jobid=%s where=%s\n' "$CLIENT" "$JOBID" "$DEST"
    printf 'mark *\n'
    printf 'done\n'
    printf 'yes\n'
    printf 'quit\n'
  } | bconsole -c "$CONF" 2>&1
) || true

restore_id=$(printf '%s\n' "$out" | sed -n 's/.*[Jj]ob[Ii][Dd][ =:]\+\([0-9]\+\).*/\1/p' | head -1)
if [[ -z $restore_id ]]; then
  printf '%s\n' "$out" | tail -25 | sed 's/^/      /' >&2
  die "the director did not queue a restore job (is bconsole working?)" 4
fi
info "restore JobId=$restore_id"

deadline=$(( SECONDS + 1800 ))
status=""
while (( SECONDS < deadline )); do
  status=$(pc "SELECT btrim(JobStatus) FROM Job WHERE JobId=$restore_id")
  case $status in
    T|W|E|e|f|A|D) break ;;
  esac
  sleep 5
done

if [[ $status != T && $status != W ]]; then
  printf 'messages jobid=%s\nquit\n' "$restore_id" | bconsole -c "$CONF" -n 2>&1 | tail -25 | sed 's/^/      /' >&2
  die "restore finished with JobStatus=${status:-timeout}" 4
fi

# --- verify ----------------------------------------------------------------
nfiles=$(find "$DEST" -type f 2>/dev/null | wc -l | tr -d ' ')
bytes=$(du -sb "$DEST" 2>/dev/null | awk '{print $1}')
sample=$(find "$DEST" -type f 2>/dev/null | head -3 | sed 's/^/      /')

line=$(printf '%s client=%s jobid=%s restore_jobid=%s status=%s files=%s bytes=%s dest=%s' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CLIENT" "$JOBID" "$restore_id" "$status" \
  "$nfiles" "${bytes:-0}" "$DEST")
(( DRY_RUN )) || printf '%s\n' "$line" >>"$LOG"

log "Result"
info "status $status, $nfiles files, $(( ${bytes:-0} / 1048576 )) MiB restored"
if [[ -n $sample ]]; then printf '%s\n' "$sample"; fi

if (( PRUNE )); then
  log "Pruning drill data older than 30 days"
  find "$DEST_ROOT" -mindepth 1 -maxdepth 3 -mtime +30 -type d -exec rm -rf {} + 2>/dev/null || true
fi

cat <<EOF

$(printf '\033[1;32mRestore verified\033[0m') — $CLIENT, job $JOBID

  restored to   $DEST
  files         $nfiles
  bytes         ${bytes:-0}
  logged        $LOG

Compare a few files against the client if you want the full proof:

  ssh root@$CLIENT 'sha256sum /etc/hosts'
  sha256sum $DEST/etc/hosts
EOF
