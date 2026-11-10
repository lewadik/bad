#!/usr/bin/env bash
# bacula-health.sh
#
# One command that answers "is my backup service actually working?" — daemons,
# catalog, failed jobs, stale clients, volume buffer, free space.
#
# Designed for monitoring: exit 0 = ok, 1 = warning, 2 = critical. Run by a
# systemd timer once a day; point your monitoring at it with --json.
#
# Usage: bacula-health.sh [--max-age-hours N] [--json] [--quiet] [--mail ADDR]
#
# Exit codes: 0 ok, 1 warning, 2 critical.

set -Eeuo pipefail

SITE=${SITE:-/etc/bacula/site.env}
MAX_AGE_H=36
JSON=0
QUIET=0
MAIL_TO=""

while (($#)); do
  case $1 in
    --max-age-hours) MAX_AGE_H=${2:?}; shift 2 ;;
    --json)   JSON=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    --mail)   MAIL_TO=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -r $SITE ]] || { echo "ERROR: $SITE missing" >&2; exit 2; }
# shellcheck disable=SC1090
. "$SITE"
[[ -n ${DB_NAME:-} ]] || DB_NAME=bacula

have() { command -v "$1" >/dev/null 2>&1; }
if have sudo; then PSQL=(sudo -u bacula psql -qtAX -d "$DB_NAME")
else PSQL=(runuser -u bacula -- psql -qtAX -d "$DB_NAME"); fi
pc() { "${PSQL[@]}" -c "$1" 2>/dev/null || true; }

worst=0
declare -a LINES=() JSONS=()
add() { # add STATUS NAME DETAIL
  local st=$1 name=$2 detail=$3
  case $st in
    CRIT) if (( worst < 2 )); then worst=2; fi ;;
    WARN) if (( worst < 1 )); then worst=1; fi ;;
  esac
  LINES+=("$(printf '[%-4s] %-16s %s' "$st" "$name" "$detail")")
  JSONS+=("$(printf '{"name":"%s","status":"%s","detail":"%s"}' "$name" \
            "$(printf '%s' "$st" | tr 'A-Z' 'a-z')" "$(printf '%s' "$detail" | tr -d '"\\\\')")")
}

# --- daemons ----------------------------------------------------------------
for pair in "director:bacula-director" "storage:bacula-sd" "file daemon:bacula-fd"; do
  name=${pair%%:*}; unit=${pair#*:}
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    add OK "$name" "$unit active"
  else
    add CRIT "$name" "$unit is not active — systemctl status $unit"
  fi
done

# --- catalog ----------------------------------------------------------------
ver=$(pc "SELECT version FROM Version LIMIT 1")
if [[ -z $ver ]]; then
  add CRIT catalog "cannot read the catalog (Version table)"
else
  jobs=$(pc "SELECT count(*) FROM Job")
  clients=$(pc "SELECT count(*) FROM Client")
  add OK catalog "db $DB_NAME, schema $ver, $jobs jobs, $clients clients"
fi

# --- failed jobs ------------------------------------------------------------
failed=$(pc "SELECT count(*) FROM Job WHERE JobStatus IN ('E','e','f','A')
             AND JobTDate > extract(epoch from now())::bigint - 86400")
failed=${failed:-0}
if [[ $failed -gt 0 ]]; then
  detail="$failed failed/cancelled in 24h: $(pc "SELECT string_agg(Name || '#' || JobId, ', ' ORDER BY JobId DESC)
    FROM (SELECT Name, JobId FROM Job WHERE JobStatus IN ('E','e','f','A')
          AND JobTDate > extract(epoch from now())::bigint - 86400
          ORDER BY JobId DESC LIMIT 5) s")"
  add CRIT "failed jobs" "$detail"
else
  add OK "failed jobs" "none in the last 24h"
fi

# --- stale clients ----------------------------------------------------------
now=$(date +%s)
stale=()
new=()
while IFS='|' read -r cname last count; do
  if [[ -z $cname ]]; then continue; fi
  if [[ ${count:-0} -eq 0 || ${last:-0} -eq 0 ]]; then
    new+=("$cname")
    continue
  fi
  age_h=$(( (now - last) / 3600 ))
  if (( age_h > MAX_AGE_H )); then
    stale+=("$cname(${age_h}h)")
  fi
done < <(pc "SELECT c.Name, COALESCE(max(j.JobTDate),0), count(j.JobId)
             FROM Client c
             LEFT JOIN Job j ON j.ClientId = c.ClientId AND j.Type='B' AND j.JobStatus IN ('T','W')
             GROUP BY c.Name ORDER BY c.Name")

if ((${#stale[@]})); then
  add WARN "stale clients" "${#stale[@]} without a successful backup in ${MAX_AGE_H}h: ${stale[*]}"
elif ((${#new[@]})); then
  add OK "stale clients" "none (${#new[@]} client(s) never backed up: ${new[*]})"
else
  add OK "stale clients" "every client ran within ${MAX_AGE_H}h"
fi

# --- volumes ----------------------------------------------------------------
vols=$(pc "SELECT string_agg(VolStatus || ':' || n, ' ' ORDER BY VolStatus)
           FROM (SELECT VolStatus, count(*) AS n FROM Media GROUP BY VolStatus) s")
vols=${vols:-none}
err=$(pc "SELECT count(*) FROM Media WHERE VolStatus='Error'")
if [[ ${err:-0} -gt 0 ]]; then
  add CRIT volumes "$err error volume(s); status: $vols"
else
  add OK volumes "$vols"
fi

appendable=$(pc "SELECT count(*) FROM Media m JOIN Pool p ON p.PoolId=m.PoolId
                 WHERE p.Name='File' AND m.VolStatus IN ('Append','Recycle')")
if [[ ${appendable:-0} -eq 0 ]]; then
  add WARN "volume buffer" "no Append/Recycle volume in pool File — run bacula-topup-volumes"
else
  add OK "volume buffer" "$appendable appendable volume(s) in pool File"
fi

# --- space ------------------------------------------------------------------
if [[ -d ${STORAGE_DIR:-/srv/bacula/volumes} ]]; then
  read -r avail total < <(df -Pk "$STORAGE_DIR" | awk 'NR==2{print $4, $2}') || true
  avail=${avail:-0}; total=${total:-1}
  pct=$(( ${avail:-0} * 100 / ${total:-1} ))
  if (( pct < 10 )); then
    add CRIT "free space" "${pct}% left on $STORAGE_DIR"
  elif (( pct < 20 )); then
    add WARN "free space" "${pct}% left on $STORAGE_DIR"
  else
    add OK "free space" "${pct}% left on $STORAGE_DIR"
  fi
fi

# --- report -----------------------------------------------------------------
status=ok
if (( worst == 1 )); then status=warning; fi
if (( worst == 2 )); then status=critical; fi

if (( JSON )); then
  printf '{"status":"%s","checks":[%s]}\n' "$status" "$(IFS=,; printf '%s' "${JSONS[*]}")"
else
  printf 'Bacula health — %s — %s\n\n' "$(hostname -f 2>/dev/null || hostname)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for line in "${LINES[@]}"; do printf '%s\n' "$line"; done
  printf '\nstatus: %s\n' "$status"
fi

if [[ -n $MAIL_TO ]] && (( worst > 0 )); then
  if have mail; then
    { for line in "${LINES[@]}"; do printf '%s\n' "$line"; done; } |
      mail -s "Bacula $status on $(hostname -s)" "$MAIL_TO"
  else
    printf 'WARNING: --mail requested but no mail command\n' >&2
  fi
fi

exit $worst
