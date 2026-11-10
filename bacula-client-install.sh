#!/usr/bin/env bash
# bacula-client-install.sh
#
# Installs and enrols a Bacula Community File Daemon on a Linux host
# (Debian/Ubuntu apt, RHEL/Rocky/Alma dnf-yum).
#
# Two ways to run it:
#
#   1. Bundled — bacula-add-client.sh writes <name>-install.sh with the client
#      name, director and password already baked in:
#         scp <dir>/web01-install.sh root@web01:/root/
#         ssh root@web01 'bash /root/web01-install.sh'
#      No arguments needed, nothing to mistype.
#
#   2. Standalone, with the values printed by `bacula-add-client.sh`:
#         ./bacula-client-install.sh --client web01 \
#              --director-name bacula01-dir --director bacula01.example.com \
#              --password 'SECRET'
#
# Options:
#   --client NAME         FileDaemon name; must equal the Client resource
#   --director-name NAME  Director resource name
#   --director ADDRESS    Director address, used for the firewall rule
#   --password SECRET     Password from the Client resource
#   --port N              File daemon port (default 9102)
#   --no-firewall         leave the host firewall alone
#   --uninstall           stop the daemon and remove the config written here
#   --dry-run             render the config to stdout, change nothing
#   -h, --help            this text
#
# Exit codes: 0 ok, 1 usage/precondition, 2 install or service failure.

# ==== BAKE BLOCK (rewritten by bacula-add-client.sh) ====
CLIENT_NAME="${CLIENT_NAME:-}"
DIRECTOR_NAME="${DIRECTOR_NAME:-}"
DIRECTOR_ADDR="${DIRECTOR_ADDR:-}"
FD_PASSWORD="${FD_PASSWORD:-}"
CLIENT_OS="${CLIENT_OS:-linux}"
# ==== BODY ====

set -Eeuo pipefail

FD_PORT=${FD_PORT:-9102}
DO_FIREWALL=1
DRY_RUN=0
UNINSTALL=0
CONF=/etc/bacula/bacula-fd.conf

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while (($#)); do
  case $1 in
    --client)        CLIENT_NAME=${2:?}; shift 2 ;;
    --director-name) DIRECTOR_NAME=${2:?}; shift 2 ;;
    --director)      DIRECTOR_ADDR=${2:?}; shift 2 ;;
    --password)      FD_PASSWORD=${2:?}; shift 2 ;;
    --port)          FD_PORT=${2:?}; shift 2 ;;
    --no-firewall)   DO_FIREWALL=0; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage ;;
    *)               die "unknown option: $1 (try --help)" ;;
  esac
done

[[ -n $CLIENT_NAME   ]] || die "--client is required (or use the bundle from bacula-add-client.sh)"
[[ -n $DIRECTOR_NAME ]] || DIRECTOR_NAME="${CLIENT_NAME%-*}-dir"
[[ -n $DIRECTOR_ADDR ]] || die "--director is required (the director's hostname or IP)"
[[ $CLIENT_NAME =~ ^[a-z0-9][a-z0-9.-]{0,62}$ ]] || die "invalid --client: use lowercase letters, digits, dot and dash"
[[ $FD_PORT =~ ^[0-9]+$ ]] || die "--port must be numeric"

if (( UNINSTALL )); then
  (( EUID == 0 )) || die "--uninstall needs root"
  log "Removing the file daemon configuration"
  systemctl disable --now bacula-fd 2>/dev/null || true
  if [[ -f $CONF ]]; then
    rm -f "$CONF"
    info "removed $CONF"
  fi
  if [[ -f $CONF.orig ]]; then
    mv "$CONF.orig" "$CONF"
    info "restored $CONF.orig"
  fi
  warn "the Client resource on the director is still there: bacula-add-client --remove $CLIENT_NAME"
  exit 0
fi

if (( ! DRY_RUN )); then
  (( EUID == 0 )) || die "run as root"
  [[ -n $FD_PASSWORD ]] || die "--password is required"
fi

# ----------------------------------------------------------------------------
log "Preflight"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-unknown}; OS_VER=${VERSION_ID:-?}
else
  OS_ID=unknown; OS_VER=?
fi
info "host $CLIENT_NAME, $OS_ID $OS_VER, $(uname -m)"

if (( ! DRY_RUN )); then
  if have apt-get; then PKG_MGR=apt
  elif have dnf;   then PKG_MGR=dnf
  elif have yum;   then PKG_MGR=yum
  else die "no supported package manager (apt/dnf/yum)"
  fi
fi

if [[ -d /var/lib/bacula ]]; then
  WORK_DIR=/var/lib/bacula
elif [[ -d /var/spool/bacula ]]; then
  WORK_DIR=/var/spool/bacula
else
  WORK_DIR=/var/lib/bacula
fi
PID_DIR=/run/bacula

# ----------------------------------------------------------------------------
log "Installing the file daemon"

if (( DRY_RUN )); then
  info "[dry-run] would install package bacula-client"
else
  case ${PKG_MGR:-none} in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y --no-install-recommends bacula-client ca-certificates
      ;;
    dnf|yum)
      # RHEL family: bacula-client comes from EPEL on 8/9.
      if ! rpm -q epel-release >/dev/null 2>&1 && have dnf; then
        dnf install -y epel-release || warn "could not install epel-release; bacula-client may be missing"
      fi
      "$PKG_MGR" install -y bacula-client
      ;;
  esac
  have bacula-fd || die "bacula-fd was not installed" 2
fi

# ----------------------------------------------------------------------------
log "Writing $CONF"

if (( DRY_RUN )); then
  cat <<EOF
FileDaemon {
  Name = $CLIENT_NAME
  FDport = $FD_PORT
  WorkingDirectory = $WORK_DIR
  PidDirectory = $PID_DIR
  Maximum Concurrent Jobs = 2
}

Director {
  Name = $DIRECTOR_NAME
  Password = "$FD_PASSWORD"
}

Messages {
  Name = "Standard"
  director = $DIRECTOR_NAME = all, !skipped, !restored
}
EOF
  info "[dry-run] nothing written"
  exit 0
fi

install -d -m 0755 /etc/bacula
install -d -m 0750 -o bacula -g bacula "$WORK_DIR" 2>/dev/null || true
install -d -m 0750 -o bacula -g bacula "$PID_DIR" 2>/dev/null || true

if [[ -f $CONF && ! -f $CONF.orig ]]; then
  cp -a "$CONF" "$CONF.orig"
  info "kept the original config as $CONF.orig"
fi

umask 077
cat >"$CONF" <<EOF
#
# Bacula File Daemon — written by bacula-client-install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Client resource on the director: $CLIENT_NAME
#
FileDaemon {
  Name = $CLIENT_NAME
  FDport = $FD_PORT
  WorkingDirectory = $WORK_DIR
  PidDirectory = $PID_DIR
  Maximum Concurrent Jobs = 2
}

Director {
  Name = $DIRECTOR_NAME
  Password = "$FD_PASSWORD"
}

Messages {
  Name = "Standard"
  director = $DIRECTOR_NAME = all, !skipped, !restored
}
EOF
chown root:bacula "$CONF" 2>/dev/null || chown root:root "$CONF"
chmod 0640 "$CONF"
info "wrote $CONF (0640 root:bacula)"

# ----------------------------------------------------------------------------
log "Validating and starting"

if ! out=$(bacula-fd -t -c "$CONF" 2>&1); then
  printf '%s\n' "$out" >&2
  die "config test failed — the client was not started" 2
fi
info "bacula-fd -t: OK"

systemctl daemon-reload
systemctl enable bacula-fd >/dev/null 2>&1 || true
if ! systemctl restart bacula-fd; then
  journalctl -u bacula-fd --no-pager -n 20 >&2 || true
  die "bacula-fd failed to start" 2
fi
sleep 1
systemctl is-active --quiet bacula-fd || die "bacula-fd is not active" 2
info "bacula-fd: active (port $FD_PORT)"

# ----------------------------------------------------------------------------
if (( DO_FIREWALL )); then
  log "Firewall"
  DIR_IP=$DIRECTOR_ADDR
  if have getent; then
    resolved=$(getent ahostsv4 "$DIRECTOR_ADDR" 2>/dev/null | awk 'NR==1{print $1}') || true
    if [[ -n ${resolved:-} ]]; then DIR_IP=$resolved; fi
  fi

  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow from "$DIR_IP" to any port "$FD_PORT" proto tcp comment 'bacula fd' >/dev/null
    info "ufw: allowed $DIR_IP -> $FD_PORT/tcp"
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$DIR_IP port port=$FD_PORT protocol=tcp accept" >/dev/null
    firewall-cmd --reload >/dev/null
    info "firewalld: allowed $DIR_IP -> $FD_PORT/tcp"
  else
    info "no active host firewall — make sure $DIR_IP can reach $FD_PORT/tcp"
  fi

  if have getenforce && [[ $(getenforce) == Enforcing ]] && have semanage; then
    if ! semanage port -l 2>/dev/null | grep -q "bacula_port_t.*$FD_PORT"; then
      semanage port -a -t bacula_port_t -p tcp "$FD_PORT" 2>/dev/null ||
        warn "SELinux: add port $FD_PORT to bacula_port_t manually"
    fi
  fi
fi

# ----------------------------------------------------------------------------
log "Result"
if have ss; then
  ss -ltn 2>/dev/null | grep -E "[:.]${FD_PORT}[[:space:]]" | sed 's/^/    /' || warn "nothing listening on $FD_PORT"
fi

cat <<EOF

$(printf '\033[1;32mFile daemon ready\033[0m') on $(hostname -s 2>/dev/null || hostname)

  name        $CLIENT_NAME
  director    $DIRECTOR_NAME at $DIRECTOR_ADDR
  port        $FD_PORT
  config      $CONF
  service     systemctl status bacula-fd
  logs        journalctl -u bacula-fd -n 50

Next: on the director run a first backup and wait for the result:

  bacula-add-client $CLIENT_NAME --test

If this host was installed from a bundle, delete the bundle now — it contains
the file daemon password:

  shred -u "\$0"
EOF
