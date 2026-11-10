#!/usr/bin/env bash
# deploy-bacula-server.sh
#
# Installs a single-node Bacula Community server on Debian 12 / Ubuntu 22.04+:
#   Director + Storage Daemon + PostgreSQL catalog + file storage + a working
#   GFS-lite policy for Linux and Windows clients.
#
# Requires the rest of this bundle next to the script (bacula-add-client.sh,
# bacula-client-install.sh, bacula-topup-volumes.sh, bacula-health.sh,
# bacula-restore-drill.sh). Copy the whole directory:
#
#   scp -r bacula/ root@HOST:/root/
#   ssh root@HOST 'bash /root/bacula/deploy-bacula-server.sh'
#
# Re-runnable: existing secrets, catalog and volumes are preserved; configs are
# re-rendered from the flags below.
#
# Options:
#   --dir-name NAME     Director resource name          (default: <host>-dir)
#   --storage DIR       Volume directory                (default: /srv/bacula/volumes)
#   --admin-email ADDR  e-mail alerts (needs a local MTA + bsmtp; optional)
#   --allow-cidr CIDR   client subnet for firewall rules (default: <primary>/24)
#   --offsite DIR       enable a second disk device for copy jobs (optional)
#   --no-tune           do not write the PostgreSQL tuning drop-in
#   --no-label          do not pre-label volumes
#   --dry-run           render into DRY_RUN_ROOT, change nothing on the system
#   -y, --yes           never prompt
#   -h, --help          this text
#
# Exit codes: 0 ok, 1 usage/precondition, 2 install failed, 3 config test failed.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# defaults (all overridable through flags or the environment)
# ----------------------------------------------------------------------------
DIR_NAME="${DIR_NAME:-}"
STORAGE_DIR="${STORAGE_DIR:-/srv/bacula/volumes}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ALLOW_CIDR="${ALLOW_CIDR:-}"
OFFSITE_DIR="${OFFSITE_DIR:-}"
TUNE_POSTGRES="${TUNE_POSTGRES:-1}"
LABEL_VOLUMES="${LABEL_VOLUMES:-1}"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES=0

DB_NAME="bacula"
DB_USER="bacula"
VOL_MAX_FILE="20G"
VOL_MAX_MONTHLY="50G"
VOL_MAX_CATALOG="2G"

CONF_DIR="/etc/bacula"
CONF_D="$CONF_DIR/conf.d"
CLIENTS_D="$CONF_DIR/clients.d"
ENROLL_D="$CONF_DIR/enroll"
WORK_DIR="/var/lib/bacula"
LOG_DIR="/var/log/bacula"
RUN_DIR="/run/bacula"
SECRETS="$CONF_DIR/secrets.env"

SELF_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SELF_DIR=$(cd -- "$(dirname -- "$SELF_PATH")" && pwd)

# ----------------------------------------------------------------------------
# output helpers
# ----------------------------------------------------------------------------
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$SELF_PATH" | sed -n '1,30p'; exit 0; }

# run: the only way the script mutates the system.
run() {
  if (( DRY_RUN )); then
    info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# install_file PATH MODE OWNER  (content on stdin)
install_file() {
  local path=$1 mode=${2:-0640} owner=${3:-root:root}
  local dest=$path tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if (( DRY_RUN )); then
    dest="${DRY_RUN_ROOT}${path}"
    mkdir -p "$(dirname -- "$dest")"
    cp "$tmp" "$dest"
    rm -f "$tmp"
    info "wrote $path (dry-run: $dest)"
    return 0
  fi
  install -d -m 0750 "$(dirname -- "$dest")"
  install -m "$mode" "$tmp" "$dest"
  chown "$owner" "$dest"
  rm -f "$tmp"
  info "wrote $path ($(wc -c <"$dest" | tr -d ' ') bytes)"
}

gen_secret() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-32}"; }

# unit names differ between distributions/builds: try the known spellings
resolve_unit() {
  local u
  for u in "$@"; do
    if systemctl list-unit-files "$u.service" >/dev/null 2>&1 &&
       [[ -n $(systemctl list-unit-files "$u.service" --no-legend 2>/dev/null) ]]; then
      printf '%s' "$u"; return 0
    fi
  done
  return 1
}

# ----------------------------------------------------------------------------
# arguments
# ----------------------------------------------------------------------------
while (($#)); do
  case $1 in
    --dir-name)    DIR_NAME=${2:?}; shift 2 ;;
    --storage)     STORAGE_DIR=${2:?}; shift 2 ;;
    --admin-email) ADMIN_EMAIL=${2:?}; shift 2 ;;
    --allow-cidr)  ALLOW_CIDR=${2:?}; shift 2 ;;
    --offsite)     OFFSITE_DIR=${2:?}; shift 2 ;;
    --no-tune)     TUNE_POSTGRES=0; shift ;;
    --no-label)    LABEL_VOLUMES=0; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     usage ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
done

if (( DRY_RUN )); then
  DRY_RUN_ROOT=${DRY_RUN_ROOT:-$(mktemp -d)}
  info "dry-run root: $DRY_RUN_ROOT"
fi

# ----------------------------------------------------------------------------
# preflight
# ----------------------------------------------------------------------------
log "Preflight"

if (( ! DRY_RUN )) && [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "run as root"
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-unknown}
else
  OS_ID=unknown
fi

if (( ! DRY_RUN )); then
  case "$OS_ID" in
    debian|ubuntu) ;;
    *) die "this script targets Debian/Ubuntu (found: $OS_ID). Use the package steps in README.md for RHEL." ;;
  esac
  have apt-get || die "apt-get not found"
  have systemctl || die "systemd not found — this script assumes a systemd host"
fi

for f in bacula-add-client.sh bacula-client-install.sh bacula-topup-volumes.sh \
         bacula-health.sh bacula-restore-drill.sh; do
  [[ -f "$SELF_DIR/$f" ]] || die "missing $f next to this script — copy the whole bacula/ directory"
done

HOST_SHORT=$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z' || hostname | tr 'A-Z' 'a-z')
DIR_NAME=${DIR_NAME:-"${HOST_SHORT}-dir"}
[[ "$DIR_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid --dir-name (allowed: A-Z a-z 0-9 . _ -)"
SERVER_CLIENT="${HOST_SHORT}-fd"
SD_NAME="${HOST_SHORT}-sd"

# The director tells clients which address to use for the storage daemon and
# its own identity, so it must be a name the clients can resolve.
DIR_ADDR=${DIR_ADDR:-$(hostname -f 2>/dev/null || hostname)}
[[ -n $DIR_ADDR ]] || die "cannot determine the director FQDN; set DIR_ADDR"

if (( ! DRY_RUN )); then
  if [[ -z $ALLOW_CIDR ]]; then
    primary_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
    ALLOW_CIDR=${primary_ip:+$(printf '%s' "$primary_ip" | awk -F. '{print $1"."$2"."$3".0/24"}')}
    ALLOW_CIDR=${ALLOW_CIDR:-127.0.0.1/32}
  fi
  info "director: $DIR_NAME ($DIR_ADDR), clients allowed from $ALLOW_CIDR"

  # Ports must be free on a first install; on a re-run our own daemons hold them.
  if ! systemctl is-active --quiet bacula-director 2>/dev/null; then
    busy=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(9101|9102|9103)$' || true)
    [[ -z $busy ]] || die "ports 9101-9103 already in use: $(printf '%s ' $busy)"
  fi

  mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 2048)
  mem_mb=${mem_mb:-2048}
  [[ $mem_mb -ge 1800 ]] || warn "only ${mem_mb}MB RAM; the catalog and PostgreSQL will be tight for a large estate"

  avail_kb=$(df -Pk "$(dirname -- "$STORAGE_DIR")" 2>/dev/null | awk 'NR==2{print $4}') || true
  avail_gb=$(( ${avail_kb:-0} / 1048576 ))
  info "free space on $(dirname -- "$STORAGE_DIR"): ${avail_gb}G"
  [[ $avail_gb -ge 20 ]] || warn "less than 20G free where volumes will live"
  if [[ $(df -P --output=target "$(dirname -- "$STORAGE_DIR")" 2>/dev/null | tail -1) == "/" ]]; then
    warn "volumes will sit on the root filesystem — a dedicated disk is strongly recommended"
  fi
fi

# ----------------------------------------------------------------------------
# packages
# ----------------------------------------------------------------------------
log "Installing packages"

if (( ! DRY_RUN )); then
  export DEBIAN_FRONTEND=noninteractive

  # dbconfig-common creates the catalog during the package install. Preseed the
  # answers it would otherwise prompt for; the bootstrap below repairs anything
  # it decides differently, so a wrong template name is not fatal.
  if [[ -z ${DB_PASS:-} && -f $SECRETS ]]; then
    # shellcheck disable=SC1090
    . "$SECRETS"
  fi
  DB_PASS=${DB_PASS:-$(gen_secret 24)}

  debconf-set-selections <<EOF
bacula-director-pgsql bacula-director-pgsql/dbconfig-install boolean true
bacula-director-pgsql bacula-director-pgsql/dbconfig-upgrade boolean true
bacula-director-pgsql bacula-director-pgsql/upgrade-backup boolean true
bacula-director-pgsql bacula-director-pgsql/pgsql/admin-user string postgres
bacula-director-pgsql bacula-director-pgsql/pgsql/authmethod-admin select peer
bacula-director-pgsql bacula-director-pgsql/pgsql/method select unix socket
bacula-director-pgsql bacula-director-pgsql/dbname string $DB_NAME
bacula-director-pgsql bacula-director-pgsql/dbuser string $DB_USER
bacula-director-pgsql bacula-director-pgsql/dbpass password $DB_PASS
EOF

  run apt-get update -qq
  run apt-get install -y --no-install-recommends \
      postgresql postgresql-client \
      bacula-director-pgsql bacula-sd bacula-client bacula-console \
      openssl ca-certificates
else
  DB_PASS=${DB_PASS:-dryrun}
fi

DIR_UNIT=$(resolve_unit bacula-director bacula-dir 2>/dev/null || printf 'bacula-director')
SD_UNIT=$(resolve_unit bacula-sd 2>/dev/null || printf 'bacula-sd')
FD_UNIT=$(resolve_unit bacula-fd 2>/dev/null || printf 'bacula-fd')

BACULA_DIR_BIN=$(command -v bacula-dir 2>/dev/null || printf '/usr/sbin/bacula-dir')
BACULA_SD_BIN=$(command -v bacula-sd 2>/dev/null || printf '/usr/sbin/bacula-sd')
BACULA_FD_BIN=$(command -v bacula-fd 2>/dev/null || printf '/usr/sbin/bacula-fd')
BCONSOLE_BIN=$(command -v bconsole 2>/dev/null || printf '/usr/bin/bconsole')

# ----------------------------------------------------------------------------
# directories, secrets
# ----------------------------------------------------------------------------
log "Creating directories and secrets"

run install -d -m 0750 -o bacula -g bacula "$WORK_DIR" "$LOG_DIR" "$STORAGE_DIR"
run install -d -m 0750 -o bacula -g bacula -d "$RUN_DIR"
run install -d -m 0750 -o root   -g bacula "$CONF_DIR" "$CONF_D" "$CLIENTS_D"
run install -d -m 0700 -o root   -g root   "$ENROLL_D"

if [[ -f $SECRETS ]]; then
  # shellcheck disable=SC1090
  . "$SECRETS"
  info "reusing existing secrets from $SECRETS"
fi
DIR_PASSWORD=${DIR_PASSWORD:-$(gen_secret 32)}
SD_PASSWORD=${SD_PASSWORD:-$(gen_secret 32)}
CONSOLE_PASSWORD=${CONSOLE_PASSWORD:-$(gen_secret 32)}
SERVER_FD_PASSWORD=${SERVER_FD_PASSWORD:-$(gen_secret 32)}
DB_PASS=${DB_PASS:-$(gen_secret 24)}

install_file "$SECRETS" 0600 root:root <<EOF
# Bacula deployment secrets — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source of truth for re-rendering configs. Keep out of backups you ship offsite
# in clear text; the catalog dump and these files are as sensitive as the data.
DIR_PASSWORD=$DIR_PASSWORD
SD_PASSWORD=$SD_PASSWORD
CONSOLE_PASSWORD=$CONSOLE_PASSWORD
SERVER_FD_PASSWORD=$SERVER_FD_PASSWORD
DB_PASS=$DB_PASS
EOF

install_file "$CONF_DIR/site.env" 0640 root:bacula <<EOF
# Site facts shared by the helper scripts. Generated by deploy-bacula-server.sh.
DIR_NAME=$DIR_NAME
DIR_ADDR=$DIR_ADDR
SERVER_CLIENT=$SERVER_CLIENT
SD_NAME=$SD_NAME
DB_NAME=$DB_NAME
STORAGE_DIR=$STORAGE_DIR
OFFSITE_DIR=$OFFSITE_DIR
EOF

# ----------------------------------------------------------------------------
# catalog
# ----------------------------------------------------------------------------
log "Preparing the PostgreSQL catalog"

if (( ! DRY_RUN )); then
  systemctl enable --now postgresql >/dev/null 2>&1 || true

  psql_admin() { sudo -u postgres psql -v ON_ERROR_STOP=1 -qtAX "$@"; }
  psql_cat()   { sudo -u bacula psql -v ON_ERROR_STOP=1 -qtAX -d "$DB_NAME" "$@"; }

  if ! psql_admin -c "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -qx 1; then
    psql_admin -c "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS'" >/dev/null
    info "created role $DB_USER"
  else
    psql_admin -c "ALTER ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS'" >/dev/null
  fi

  if ! psql_admin -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -qx 1; then
    run sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
    info "created database $DB_NAME"
  fi

  # Socket + peer auth: the daemons and pg_dump run as OS user "bacula", which
  # matches the role name, so no password file is needed anywhere. Prepending
  # wins over any rule dbconfig-common may have added below.
  HBA_FILE=$(psql_admin -c "SHOW hba_file")
  if [[ -f $HBA_FILE ]] && ! grep -q '^# bacula-deploy' "$HBA_FILE"; then
    tmp_hba=$(mktemp)
    {
      printf '# bacula-deploy: catalog owner over the local socket\n'
      printf 'local\t%s\t%s\tpeer\n' "$DB_NAME" "$DB_USER"
      cat "$HBA_FILE"
    } >"$tmp_hba"
    install -m 0640 -o postgres -g postgres "$tmp_hba" "$HBA_FILE"
    rm -f "$tmp_hba"
  fi
  psql_admin -c "SELECT pg_reload_conf()" >/dev/null || warn "could not reload pg_hba.conf"

  HAVE_SCHEMA=$(psql_admin -d "$DB_NAME" -c \
    "SELECT 1 FROM information_schema.tables WHERE table_name='version'" || true)

  if [[ $HAVE_SCHEMA != 1 ]]; then
    info "catalog schema missing — loading it"
    loaded=0
    for script in /usr/share/bacula-director/make_postgresql_tables \
                  /usr/lib/bacula/make_postgresql_tables; do
      if [[ -f $script ]]; then
        # Run as the catalog owner so every table is owned by "bacula".
        if run sudo -u "$DB_USER" bash "$script" >/dev/null 2>&1; then loaded=1; break; fi
      fi
    done
    if [[ $loaded -eq 0 ]]; then
      warn "packaged schema script not usable — asking dbconfig-common to rebuild"
      run dpkg-reconfigure -f noninteractive bacula-director-pgsql || true
    fi
    HAVE_SCHEMA=$(psql_admin -d "$DB_NAME" -c \
      "SELECT 1 FROM information_schema.tables WHERE table_name='version'" || true)
    [[ $HAVE_SCHEMA == 1 ]] || die "catalog schema could not be created. Manual path:
  sudo -u postgres createdb -O bacula bacula
  sudo -u bacula psql -d bacula -f /usr/share/bacula-director/make_postgresql_tables" 2
  fi

  grants="GRANT ALL ON SCHEMA public TO $DB_USER;
          GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
          GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;"
  psql_admin -d "$DB_NAME" -c "$grants" >/dev/null || warn "could not top up catalog grants"

  psql_cat -c 'SELECT 1' >/dev/null || die "cannot connect to the catalog as $DB_USER (socket/peer auth)"
  info "catalog reachable as $DB_USER@$DB_NAME ($(psql_cat -c 'SELECT version FROM Version LIMIT 1'))"

  # PostgreSQL tuning drop-in. Scoped to this cluster and reversible by deleting
  # the file; conf.d is included by the Debian/Ubuntu postgresql.conf.
  if (( TUNE_POSTGRES )); then
    pg_ver=$(ls -1 /etc/postgresql 2>/dev/null | sort -V | tail -1)
    pg_conf_d="/etc/postgresql/${pg_ver}/main/conf.d"
    if [[ -n $pg_ver && -d $pg_conf_d ]]; then
      shared=$(( mem_mb / 4 ))
      if (( shared > 2048 )); then shared=2048; fi
      cache=$(( mem_mb / 2 ))
      maint=$(( mem_mb / 20 ))
      if (( maint > 512 )); then maint=512; fi
      if (( maint < 64 )); then maint=64; fi
      install_file "$pg_conf_d/60-bacula.conf" 0644 postgres:postgres <<EOF
# Bacula catalog tuning — written by deploy-bacula-server.sh
# ~80% of a Bacula catalog is File rows; batch inserts and autovacuum dominate.
shared_buffers = ${shared}MB
effective_cache_size = ${cache}MB
work_mem = 16MB
maintenance_work_mem = ${maint}MB
max_wal_size = 4GB
checkpoint_timeout = 15min
default_statistics_target = 250
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
EOF
      run systemctl reload postgresql || true
    else
      warn "could not locate conf.d — skipping PostgreSQL tuning"
    fi
  fi
fi

# ----------------------------------------------------------------------------
# configuration
# ----------------------------------------------------------------------------
log "Rendering Bacula configuration"

QUERY_LINE=""
if [[ -f $CONF_DIR/query.sql ]]; then
  QUERY_LINE="  QueryFile = \"$CONF_DIR/query.sql\""
fi

MAIL_LINES=""
BSMTP=""
for cand in /usr/sbin/bsmtp /usr/lib/bacula/bsmtp /usr/bin/bsmtp; do
  if [[ -x $cand ]]; then BSMTP=$cand; break; fi
done
if [[ -n $ADMIN_EMAIL ]]; then
  if [[ -n $BSMTP ]]; then
    MAIL_LINES=$(cat <<EOF
  mailcommand = "$BSMTP -h localhost -f 'Bacula <bacula@$DIR_ADDR>' -s 'Bacula: %t %e of %c %l' %r"
  mail = $ADMIN_EMAIL = all, !skipped, !saved
EOF
)
  else
    warn "bsmtp not found — e-mail alerts disabled (install bacula-common-* / a local MTA)"
  fi
fi

install_file "$CONF_DIR/bacula-dir.conf" 0640 root:bacula <<EOF
#
# Bacula Director — generated by deploy-bacula-server.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Edit the fragments under conf.d/ or re-run the deploy script; this file is
# regenerated. Reload after a change:  bconsole -c /etc/bacula/bconsole.conf
#                                      *reload
#
Director {
  Name = $DIR_NAME
  DIRport = 9101
  Address = $DIR_ADDR
  Password = "$DIR_PASSWORD"
$QUERY_LINE
  WorkingDirectory = $WORK_DIR
  PidDirectory = $RUN_DIR
  Maximum Concurrent Jobs = 20
  Heartbeat Interval = 60
}

Catalog {
  Name = MyCatalog
  dbname = "$DB_NAME"
  dbuser = "$DB_USER"
  dbpassword = "$DB_PASS"
}

@$CONF_D/10-storage.conf
@$CONF_D/15-server-client.conf
@$CONF_D/20-pools.conf
@$CONF_D/30-schedules.conf
@$CONF_D/40-filesets.conf
@$CONF_D/50-jobdefs.conf
@$CONF_D/60-jobs.conf
@$CONF_D/70-console.conf
@$CONF_DIR/clients.conf
@$CONF_D/90-messages.conf
EOF

install_file "$CONF_D/10-storage.conf" 0640 root:bacula <<EOF
Storage {
  Name = "LocalDisk"
  Address = $DIR_ADDR
  SDPort = 9103
  Password = "$SD_PASSWORD"
  Device = "FileStorage"
  Media Type = "File"
  Maximum Concurrent Jobs = 6
}
EOF

if [[ -n $OFFSITE_DIR ]]; then
  install_file "$CONF_D/11-storage-offsite.conf" 0640 root:bacula <<EOF

Storage {
  Name = "OffsiteDisk"
  Address = $DIR_ADDR
  SDPort = 9103
  Password = "$SD_PASSWORD"
  Device = "OffsiteStorage"
  Media Type = "File"
  Maximum Concurrent Jobs = 2
}
EOF
  # keep the include list honest: 10-storage.conf is loaded before this file
  grep -q '11-storage-offsite.conf' "$CONF_DIR/bacula-dir.conf" 2>/dev/null || {
    if (( DRY_RUN )); then
      printf '@%s/11-storage-offsite.conf\n' "$CONF_D" >>"${DRY_RUN_ROOT}${CONF_DIR}/bacula-dir.conf"
    else
      sed -i "\\|^@$CONF_D/10-storage.conf|a @$CONF_D/11-storage-offsite.conf" "$CONF_DIR/bacula-dir.conf"
    fi
  }
fi

install_file "$CONF_D/15-server-client.conf" 0640 root:bacula <<EOF
# The backup server backs itself up through its own file daemon.
Client {
  Name = "$SERVER_CLIENT"
  Address = 127.0.0.1
  FDPort = 9102
  Catalog = "MyCatalog"
  Password = "$SERVER_FD_PASSWORD"
  File Retention = 60 days
  Job Retention = 6 months
  AutoPrune = yes
  Maximum Concurrent Jobs = 2
}
EOF

install_file "$CONF_D/20-pools.conf" 0640 root:bacula <<EOF
# Short-term pool: 45 days covers the longest incremental chain (a monthly
# full resets it on the 1st) plus one cycle of slack.
Pool {
  Name = "File"
  Pool Type = Backup
  Recycle = yes
  AutoPrune = yes
  Volume Retention = 45 days
  Maximum Volume Bytes = $VOL_MAX_FILE
  Maximum Volumes = 500
  Label Format = "File-"
}

# Long-term pool: monthly fulls, kept just over a year.
Pool {
  Name = "Monthly"
  Pool Type = Backup
  Recycle = yes
  AutoPrune = yes
  Volume Retention = 400 days
  Maximum Volume Bytes = $VOL_MAX_MONTHLY
  Maximum Volumes = 200
  Label Format = "Monthly-"
}

# Catalog dumps are small and precious: they are what makes a bare-metal
# disaster recovery of the backup server itself possible.
Pool {
  Name = "Catalog"
  Pool Type = Backup
  Recycle = yes
  AutoPrune = yes
  Volume Retention = 120 days
  Maximum Volume Bytes = $VOL_MAX_CATALOG
  Maximum Volumes = 60
  Label Format = "Catalog-"
}
EOF

if [[ -z $OFFSITE_DIR ]]; then
  # keep re-runs idempotent when the offsite device is removed
  for stale in "$CONF_D/11-storage-offsite.conf" "$CONF_D/21-pool-offsite.conf"; do
    if [[ -f $stale ]]; then
      rm -f "$stale"
      info "removed stale $stale"
    fi
  done
  if (( ! DRY_RUN )) && [[ -f $CONF_DIR/bacula-dir.conf ]]; then
    sed -i '\|^@/etc/bacula/conf.d/11-storage-offsite.conf|d' "$CONF_DIR/bacula-dir.conf"
  fi
fi

if [[ -n $OFFSITE_DIR ]]; then
  install_file "$CONF_D/21-pool-offsite.conf" 0640 root:bacula <<EOF

Pool {
  Name = "Offsite"
  Pool Type = Backup
  Recycle = yes
  AutoPrune = yes
  Volume Retention = 400 days
  Maximum Volume Bytes = $VOL_MAX_MONTHLY
  Maximum Volumes = 200
  Label Format = "Offsite-"
}
EOF
fi

install_file "$CONF_D/30-schedules.conf" 0640 root:bacula <<EOF
# One full per week, incrementals the rest of the week. Both levels live in the
# same pool so the incremental chain always has its base volume next to it.
Schedule {
  Name = "ClientCycle"
  Run = Level=Full sun at 02:00
  Run = Level=Incremental mon-sat at 22:30
}

# Monthly full at 04:00 on the 1st. If the 1st is a Sunday you get a second full
# that day; it is cheap insurance and it is documented in the runbook.
Schedule {
  Name = "MonthlyCycle"
  Run = Level=Full day=1 at 04:00
}

Schedule {
  Name = "CatalogCycle"
  Run = Level=Full daily at 21:00
}
EOF

install_file "$CONF_D/40-filesets.conf" 0640 root:bacula <<EOF
# Data, not operating systems: Bacula CE has no bare-metal recovery, so OS and
# application binaries are rebuilt from images/config management and Bacula
# restores state. See deployment-scenario.md, "Restore matrix".
FileSet {
  Name = "LinuxServer"
  Include {
    Options { Signature = SHA256 }
    File = /etc
    File = /root
    File = /home
    File = /opt
    File = /srv
    File = /usr/local
    File = /var/spool/cron
    File = /var/lib
    File = /boot
  }
  Exclude {
    File = /var/lib/bacula
    File = /var/lib/postgresql
    File = /var/lib/mysql
    File = /var/lib/docker
    File = /var/lib/containers
    File = /var/lib/lxcfs
    File = /var/cache
    File = /var/tmp
    File = /proc
    File = /sys
    File = /dev
    File = /run
    File = /tmp
    File = /snap
    File = /lost+found
    File = /swapfile
  }
}

FileSet {
  Name = "WindowsServer"
  Include {
    Options { Signature = SHA256; IgnoreCase = yes }
    File = "C:/Users"
    File = "C:/ProgramData"
    File = "C:/inetpub"
    File = "C:/Shares"
  }
  Exclude {
    File = "C:/Users/*/AppData/Local/Temp"
    File = "C:/Users/*/AppData/Local/Microsoft/Windows/INetCache"
    File = "C:/Users/*/AppData/Local/Microsoft/Windows/Explorer"
    File = "C:/Windows/Temp"
    File = "C:/\$Recycle.Bin"
    File = "C:/System Volume Information"
    File = "C:/pagefile.sys"
    File = "C:/hiberfil.sys"
    File = "C:/swapfile.sys"
  }
}

FileSet {
  Name = "BaculaServer"
  Include {
    Options { Signature = SHA256 }
    File = /etc
    File = /root
    File = /usr/local
    File = /var/lib/bacula
    File = /var/log/bacula
  }
  Exclude {
    File = /var/lib/bacula/storage
    File = /etc/bacula/enroll
  }
}

FileSet {
  Name = "Catalog"
  Include {
    Options { Signature = SHA256 }
    File = $WORK_DIR/bacula.sql
  }
}
EOF

install_file "$CONF_D/50-jobdefs.conf" 0640 root:bacula <<EOF
JobDefs {
  Name = "LinuxClient"
  Type = Backup
  Level = Incremental
  Client = "$SERVER_CLIENT"
  FileSet = "LinuxServer"
  Schedule = "ClientCycle"
  Storage = "LocalDisk"
  Pool = "File"
  Messages = "Standard"
  Priority = 10
  Maximum Concurrent Jobs = 2
  Max Run Time = 28800
  Write Bootstrap = "$WORK_DIR/%c.bsr"
}

JobDefs {
  Name = "LinuxClientMonthly"
  Type = Backup
  Level = Full
  Client = "$SERVER_CLIENT"
  FileSet = "LinuxServer"
  Schedule = "MonthlyCycle"
  Storage = "LocalDisk"
  Pool = "Monthly"
  Messages = "Standard"
  Priority = 20
  Maximum Concurrent Jobs = 2
  Max Run Time = 28800
  Write Bootstrap = "$WORK_DIR/%c.bsr"
}

JobDefs {
  Name = "WindowsClient"
  Type = Backup
  Level = Incremental
  Client = "$SERVER_CLIENT"
  FileSet = "WindowsServer"
  Schedule = "ClientCycle"
  Storage = "LocalDisk"
  Pool = "File"
  Messages = "Standard"
  Priority = 10
  Maximum Concurrent Jobs = 2
  Max Run Time = 28800
  Write Bootstrap = "$WORK_DIR/%c.bsr"
}

JobDefs {
  Name = "WindowsClientMonthly"
  Type = Backup
  Level = Full
  Client = "$SERVER_CLIENT"
  FileSet = "WindowsServer"
  Schedule = "MonthlyCycle"
  Storage = "LocalDisk"
  Pool = "Monthly"
  Messages = "Standard"
  Priority = 20
  Maximum Concurrent Jobs = 2
  Max Run Time = 28800
  Write Bootstrap = "$WORK_DIR/%c.bsr"
}
EOF

install_file "$CONF_D/60-jobs.conf" 0640 root:bacula <<EOF
Job {
  Name = "Server-self-daily"
  JobDefs = "LinuxClient"
  Client = "$SERVER_CLIENT"
  FileSet = "BaculaServer"
}

Job {
  Name = "Server-self-monthly"
  JobDefs = "LinuxClientMonthly"
  Client = "$SERVER_CLIENT"
  FileSet = "BaculaServer"
}

# Dumps the catalog to $WORK_DIR/bacula.sql first, then backs that file up.
# Together with $WORK_DIR/%c.bsr this is the entire disaster recovery kit.
Job {
  Name = "Catalog-daily"
  Type = Backup
  Level = Full
  Client = "$SERVER_CLIENT"
  FileSet = "Catalog"
  Schedule = "CatalogCycle"
  Storage = "LocalDisk"
  Pool = "Catalog"
  Messages = "Standard"
  Priority = 5
  RunBeforeJob = "/usr/bin/env PGDATABASE=$DB_NAME /usr/local/sbin/bacula-catalog-dump.sh"
}
EOF

install_file "$CONF_D/70-console.conf" 0640 root:bacula <<EOF
# Unrestricted console. bconsole is only reachable from the management network
# (see the firewall step) and needs this password.
Console {
  Name = "admin"
  Password = "$CONSOLE_PASSWORD"
}
EOF

install_file "$CONF_D/90-messages.conf" 0640 root:bacula <<EOF
Messages {
  Name = "Standard"
  console = all, !skipped, !saved
  append = "$LOG_DIR/bacula.log" = all, !skipped
  catalog = all
$MAIL_LINES
}
EOF

install_file "$CONF_DIR/clients.conf" 0640 root:bacula <<'EOF'
# Generated by bacula-add-client.sh — one include line per client.
# Do not edit: run bacula-add-client.sh / --remove instead.
EOF

install_file "$CONF_DIR/bacula-sd.conf" 0640 root:bacula <<EOF
#
# Bacula Storage Daemon — generated by deploy-bacula-server.sh
#
Storage {
  Name = $SD_NAME
  SDPort = 9103
  WorkingDirectory = $WORK_DIR
  Pid Directory = $RUN_DIR
  Maximum Concurrent Jobs = 8
}

Director {
  Name = $DIR_NAME
  Password = "$SD_PASSWORD"
}

Device {
  Name = "FileStorage"
  Media Type = "File"
  Archive Device = $STORAGE_DIR
  LabelMedia = yes
  Random Access = yes
  AutomaticMount = yes
  RemovableMedia = no
  AlwaysOpen = no
  Maximum Concurrent Jobs = 6
}
EOF

if [[ -n $OFFSITE_DIR ]]; then
  install_file "$CONF_DIR/bacula-sd-offsite.conf" 0640 root:bacula <<EOF

Device {
  Name = "OffsiteStorage"
  Media Type = "File"
  Archive Device = $OFFSITE_DIR
  LabelMedia = yes
  Random Access = yes
  AutomaticMount = yes
  RemovableMedia = yes
  AlwaysOpen = no
  Maximum Concurrent Jobs = 2
}
EOF
  # The SD reads one file; append the second device defensively.
  if (( DRY_RUN )); then
    cat "${DRY_RUN_ROOT}${CONF_DIR}/bacula-sd-offsite.conf" >>"${DRY_RUN_ROOT}${CONF_DIR}/bacula-sd.conf"
    rm -f "${DRY_RUN_ROOT}${CONF_DIR}/bacula-sd-offsite.conf"
  else
    cat "$CONF_DIR/bacula-sd-offsite.conf" >>"$CONF_DIR/bacula-sd.conf"
    rm -f "$CONF_DIR/bacula-sd-offsite.conf"
  fi
fi

install_file "$CONF_DIR/bacula-sd.conf.tail" 0640 root:bacula <<EOF

Messages {
  Name = "Standard"
  director = $DIR_NAME = all, !skipped, !saved
  append = "$LOG_DIR/bacula-sd.log" = all, !skipped
}
EOF
if (( DRY_RUN )); then
  cat "${DRY_RUN_ROOT}${CONF_DIR}/bacula-sd.conf.tail" >>"${DRY_RUN_ROOT}${CONF_DIR}/bacula-sd.conf"
  rm -f "${DRY_RUN_ROOT}${CONF_DIR}/bacula-sd.conf.tail"
else
  cat "$CONF_DIR/bacula-sd.conf.tail" >>"$CONF_DIR/bacula-sd.conf"
  rm -f "$CONF_DIR/bacula-sd.conf.tail"
fi

install_file "$CONF_DIR/bacula-fd.conf" 0640 root:bacula <<EOF
#
# File Daemon on the backup server itself — generated by deploy-bacula-server.sh
#
FileDaemon {
  Name = $SERVER_CLIENT
  FDport = 9102
  WorkingDirectory = $WORK_DIR
  PidDirectory = $RUN_DIR
  Maximum Concurrent Jobs = 4
}

Director {
  Name = $DIR_NAME
  Password = "$SERVER_FD_PASSWORD"
}

Messages {
  Name = "Standard"
  director = $DIR_NAME = all, !skipped, !restored
}
EOF

install_file "$CONF_DIR/bconsole.conf" 0600 root:root <<EOF
Director {
  Name = $DIR_NAME
  DIRport = 9101
  address = 127.0.0.1
  Password = "$CONSOLE_PASSWORD"
}
EOF

if [[ -n $OFFSITE_DIR ]]; then
  run install -d -m 0750 -o bacula -g bacula "$OFFSITE_DIR"
fi

# ----------------------------------------------------------------------------
# helper scripts, units, logrotate
# ----------------------------------------------------------------------------
log "Installing helper scripts and timers"

for f in bacula-add-client.sh bacula-client-install.sh bacula-topup-volumes.sh \
         bacula-health.sh bacula-restore-drill.sh; do
  run install -m 0755 -o root -g root "$SELF_DIR/$f" "/usr/local/sbin/$f"
  # both spellings on PATH: bacula-add-client.sh and bacula-add-client
  run ln -sfn "/usr/local/sbin/$f" "/usr/local/sbin/${f%.sh}"
done
if [[ -f $SELF_DIR/bacula-client-install.ps1 ]]; then
  run install -m 0644 -o root -g root "$SELF_DIR/bacula-client-install.ps1" \
      /usr/local/sbin/bacula-client-install.ps1
fi

install_file /usr/local/sbin/bacula-catalog-dump.sh 0750 root:root <<'EOF'
#!/bin/sh
# Dump the Bacula catalog for disaster recovery. Runs as the director's user, so
# peer authentication over the local socket does the rest: no password file.
set -eu
out=${OUT:-/var/lib/bacula/bacula.sql}
umask 077
pg_dump --no-owner --clean --if-exists > "$out.tmp"
mv "$out.tmp" "$out"
EOF

install_file /etc/logrotate.d/bacula 0644 root:root <<EOF
$LOG_DIR/*.log {
  weekly
  rotate 8
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF

# Bacula needs /run/bacula after every reboot; do not rely on the distribution
# unit to create it.
for u in "$DIR_UNIT" "$SD_UNIT" "$FD_UNIT"; do
  install_file "/etc/systemd/system/${u}.service.d/10-runtime-dir.conf" 0644 root:root <<EOF
[Service]
RuntimeDirectory=bacula
RuntimeDirectoryMode=0750
EOF
done

for unit in bacula-topup bacula-health bacula-drill; do
  case $unit in
    bacula-topup)  script=bacula-topup-volumes.sh; when="*-*-* 03:15:00"; desc="top up spare volumes" ;;
    bacula-health) script=bacula-health.sh;        when="*-*-* 07:00:00"; desc="check backup health" ;;
    bacula-drill)  script=bacula-restore-drill.sh; when="*-*-01 06:00:00"; desc="monthly restore drill" ;;
  esac
  install_file "/etc/systemd/system/${unit}.service" 0644 root:root <<EOF2
[Unit]
Description=Bacula: $desc
After=bacula-director.service postgresql.service
Wants=bacula-director.service

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/${script%.sh}
EOF2
  install_file "/etc/systemd/system/${unit}.timer" 0644 root:root <<EOF2
[Unit]
Description=Bacula: $desc (timer)

[Timer]
OnCalendar=$when
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF2
done

# ----------------------------------------------------------------------------
# validate, enable, start
# ----------------------------------------------------------------------------
log "Validating configuration"

if (( DRY_RUN )); then
  info "[dry-run] skipping daemon config tests"
else  for pair in "$BACULA_DIR_BIN:$CONF_DIR/bacula-dir.conf" \
              "$BACULA_SD_BIN:$CONF_DIR/bacula-sd.conf" \
              "$BACULA_FD_BIN:$CONF_DIR/bacula-fd.conf"; do
    bin=${pair%%:*}; conf=${pair#*:}
    if ! out=$(sudo -u bacula "$bin" -t -c "$conf" 2>&1); then
      printf '%s\n' "$out" >&2
      die "config test failed for $conf" 3
    fi
    info "$(basename "$bin") -t: OK"
  done
fi

log "Enabling services"

run systemctl daemon-reload
run systemctl enable "$DIR_UNIT" "$SD_UNIT" "$FD_UNIT" >/dev/null 2>&1 || true
run systemctl restart "$SD_UNIT" "$FD_UNIT" "$DIR_UNIT" || die "could not start Bacula services" 2
sleep 3   # let the director bind 9101 before the console talks to it
run systemctl enable --now bacula-topup.timer bacula-health.timer >/dev/null 2>&1 || true
# The drill timer is installed but left off: a monthly restore writes into
# /var/tmp and is best enabled once you have picked a client rotation.
run systemctl disable bacula-drill.timer >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# firewall
# ----------------------------------------------------------------------------
if (( ! DRY_RUN )); then
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    info "ufw is active — allowing 9101/tcp and 9103/tcp from $ALLOW_CIDR"
    run ufw allow from "$ALLOW_CIDR" to any port 9101 proto tcp comment 'bacula director' >/dev/null
    run ufw allow from "$ALLOW_CIDR" to any port 9103 proto tcp comment 'bacula storage' >/dev/null
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    info "firewalld is active — opening 9101/tcp and 9103/tcp from $ALLOW_CIDR"
    run firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$ALLOW_CIDR port port=9101 protocol=tcp accept" >/dev/null
    run firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$ALLOW_CIDR port port=9103 protocol=tcp accept" >/dev/null
    run firewall-cmd --reload >/dev/null
  else
    info "no active host firewall detected — publish 9101 and 9103 to $ALLOW_CIDR only"
  fi
fi

# ----------------------------------------------------------------------------
# volumes
# ----------------------------------------------------------------------------
if (( LABEL_VOLUMES )); then
  log "Pre-labelling volumes"
  if (( DRY_RUN )); then
    info "[dry-run] bacula-topup-volumes.sh --dry-run"
  else
    if ! /usr/local/sbin/bacula-topup-volumes; then
      warn "volume labelling reported problems — the first job may wait for a volume;
      run: /usr/local/sbin/bacula-topup-volumes"
    fi
  fi
fi

# ----------------------------------------------------------------------------
# smoke test
# ----------------------------------------------------------------------------
log "Smoke test"

if (( DRY_RUN )); then
  info "[dry-run] would run: bconsole status director / status storage=LocalDisk / status client"
else
  for cmd in "status director" "status storage=LocalDisk" "status client=$SERVER_CLIENT"; do
    if out=$(printf '%s\nquit\n' "$cmd" | "$BCONSOLE_BIN" -c "$CONF_DIR/bconsole.conf" -n 2>&1); then
      info "$cmd: ok"
    else
      warn "$cmd failed:"
      printf '%s\n' "$out" | sed 's/^/      /' >&2
    fi
  done
fi

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32mBacula server ready\033[0m')

  director      $DIR_NAME  ($DIR_ADDR:9101)
  storage       LocalDisk  ($STORAGE_DIR:9103)
  catalog       $DB_NAME on local PostgreSQL (socket + peer auth)
  secrets       $SECRETS (0600)
  console       bconsole -c /etc/bacula/bconsole.conf
  logs          journalctl -u $DIR_UNIT -f   |   $LOG_DIR/

Next steps
  1. Add the first client (Linux):
       bacula-add-client web01 10.0.0.21
       # prints an scp+ssh one-liner; run it on the client, then:
       bacula-add-client web01 --test

  2. Add a Windows client:
       bacula-add-client fs01 10.0.0.31 --os windows
       # prints a PowerShell bootstrap for bacula-client-install.ps1

  3. Watch the first night:
       bacula-health            # cron-friendly: exit 0 ok / 1 warn / 2 critical

  4. Offsite copy (optional, needs a second disk):
       re-run with --offsite /mnt/offsite/volumes, then define a Copy job
       (see deployment-scenario.md, "Offsite and immutability")

  5. Restore drill, on demand:
       bacula-restore-drill --client web01
       # monthly timer is installed but off: systemctl enable --now bacula-drill.timer

  TLS is not configured by this script. The runbook in deployment-scenario.md,
  "Transport security", has the exact directives for a two-phase rollout.
EOF

if (( DRY_RUN )); then
  printf '\nRendered tree: %s\n' "$DRY_RUN_ROOT"
  find "$DRY_RUN_ROOT" -type f | sort | sed 's/^/  /'
fi
