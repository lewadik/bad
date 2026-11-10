#!/usr/bin/env bash
# ci/verify.sh
#
# One command that proves this bundle still works — without touching a real
# server. Used by CI (.gitea/workflows/ci.yml) on every push; runnable by hand:
#
#   bash ci/verify.sh
#
# What it proves, in order:
#   1. shell sources parse (bash -n), no CRLF, shebang intact, shellcheck if present
#   2. the CLI contract holds: --help exits 0, unknown flags are rejected,
#      every script is still documented in README.md
#   3. deploy-bacula-server.sh --dry-run renders a complete /etc/bacula tree
#      (plain mode and --offsite mode) with the expected structure
#   4. bacula-add-client.sh --dry-run onboards Linux/Windows/private-fileset
#      clients against the rendered site.env, and rejects invalid names
#   5. bacula-client-install.sh --dry-run renders a valid FileDaemon config and
#      the enrolment-bundle assembly contract (# ==== BODY ==== marker) holds
#   6. the Windows installer parses (pwsh, if present) and keeps its param contract
#
# Exit codes: 0 all checks passed, 1 at least one check failed.
#
# Policy notes:
#   - Nothing here needs root or a live Bacula; everything runs on --dry-run.
#   - File-mode assertions (0600) run only on Linux; Git Bash/Windows cannot
#     represent them, so they are reported as skipped there, not passed.
#   - shellcheck, when installed, fails the build on errors only (-S error):
#     the repo already carries inline `# shellcheck disable=` hints, so warnings
#     are printed but not fatal. Tighten later if the tree is warning-clean.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 9

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

n=0 passed=0 failed=0 skipped=0
declare -a FAILED=()

ok()   { n=$((n+1)); passed=$((passed+1)); printf 'ok    %2d  %s\n' "$n" "$*"; }
fail() { n=$((n+1)); failed=$((failed+1)); FAILED+=("$*"); printf 'FAIL  %2d  %s\n' "$n" "$*"; }
skip() { n=$((n+1)); skipped=$((skipped+1)); printf 'skip  %2d  %s\n' "$n" "$*"; }
detail() { printf '          %s\n' "$*"; }
section() { printf '\n---- %s ----\n' "$*"; }

# Redact password values before ever echoing a config line into a log.
redact() { sed -E 's/(Password[^=]*=).*/\1<redacted>/Ig'; }

SERVER_SCRIPTS="deploy-bacula-server.sh bacula-add-client.sh bacula-client-install.sh bacula-topup-volumes.sh bacula-health.sh bacula-restore-drill.sh"

# ============================================================================
section "1. shell sources"

for f in $SERVER_SCRIPTS; do
  if bash -n "$f" 2>"$TMP/syn.err"; then
    ok "bash -n $f"
  else
    fail "bash -n $f"
    detail "$(head -3 "$TMP/syn.err")"
  fi
done

crlf_bad=()
for f in $SERVER_SCRIPTS ci/verify.sh; do
  if grep -q $'\r' "$f"; then crlf_bad+=("$f"); fi
done
if ((${#crlf_bad[@]} == 0)); then
  ok "no CRLF line endings in shell scripts"
else
  fail "no CRLF line endings in shell scripts"
  for f in "${crlf_bad[@]}"; do detail "$f contains CRLF"; done
fi

shebang_bad=()
for f in $SERVER_SCRIPTS; do
  head -1 "$f" | grep -q '^#!/usr/bin/env bash$' || shebang_bad+=("$f")
done
if ((${#shebang_bad[@]} == 0)); then
  ok "every script starts with #!/usr/bin/env bash"
else
  fail "every script starts with #!/usr/bin/env bash"
  for f in "${shebang_bad[@]}"; do detail "$f has a wrong or missing shebang"; done
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error $SERVER_SCRIPTS 2>"$TMP/sc.err"; then
    ok "shellcheck (-S error) clean"
  else
    fail "shellcheck (-S error) clean"
    detail "$(head -5 "$TMP/sc.err")"
  fi
else
  skip "shellcheck not installed on this runner (skipped, not passed)"
fi

# ============================================================================
section "2. CLI contract (--help / unknown flags / docs drift)"

for f in $SERVER_SCRIPTS; do
  if bash "$f" --help >"$TMP/help.out" 2>&1 && [[ -s $TMP/help.out ]]; then
    ok "$f --help exits 0 with usage text"
  else
    fail "$f --help exits 0 with usage text"
    detail "exit=$? output bytes=$(wc -c <"$TMP/help.out")"
  fi
done

for f in $SERVER_SCRIPTS; do
  # unknown flags must be rejected, not silently ignored
  if bash "$f" --definitely-not-an-option >/dev/null 2>&1; then
    fail "$f rejects unknown flags"
    detail "exit=0 but a typo'd flag must fail"
  else
    ok "$f rejects unknown flags (exit ${PIPESTATUS[0]:-nonzero})"
  fi
done

doc_missing=()
for f in $SERVER_SCRIPTS; do
  grep -q "$f" README.md || doc_missing+=("$f")
done
if ((${#doc_missing[@]} == 0)); then
  ok "README.md documents every script"
else
  fail "README.md documents every script"
  for f in "${doc_missing[@]}"; do detail "$f is not mentioned in README.md"; done
fi

# ============================================================================
section "3. server render: deploy-bacula-server.sh --dry-run"

RENDER="$TMP/render1"
export DRY_RUN_ROOT="$RENDER"
if bash ./deploy-bacula-server.sh --dry-run --dir-name ci-dir >"$TMP/render1.out" 2>&1; then
  ok "deploy-bacula-server.sh --dry-run exits 0"
else
  fail "deploy-bacula-server.sh --dry-run exits 0"
  detail "last output lines:"
  tail -5 "$TMP/render1.out" | redact | while IFS= read -r l; do detail "$l"; done
fi

REQUIRED_FILES=(
  etc/bacula/bacula-dir.conf
  etc/bacula/bacula-sd.conf
  etc/bacula/bacula-fd.conf
  etc/bacula/bconsole.conf
  etc/bacula/clients.conf
  etc/bacula/secrets.env
  etc/bacula/site.env
  etc/bacula/conf.d/10-storage.conf
  etc/bacula/conf.d/15-server-client.conf
  etc/bacula/conf.d/20-pools.conf
  etc/bacula/conf.d/30-schedules.conf
  etc/bacula/conf.d/40-filesets.conf
  etc/bacula/conf.d/50-jobdefs.conf
  etc/bacula/conf.d/60-jobs.conf
  etc/bacula/conf.d/70-console.conf
  etc/bacula/conf.d/90-messages.conf
  etc/logrotate.d/bacula
  etc/systemd/system/bacula-topup.service
  etc/systemd/system/bacula-topup.timer
  etc/systemd/system/bacula-health.service
  etc/systemd/system/bacula-health.timer
  etc/systemd/system/bacula-drill.service
  etc/systemd/system/bacula-drill.timer
  usr/local/sbin/bacula-catalog-dump.sh
)
missing=()
for rel in "${REQUIRED_FILES[@]}"; do
  [[ -s $RENDER/$rel ]] || missing+=("$rel")
done
if ((${#missing[@]} == 0)); then
  ok "dry-run renders all ${#REQUIRED_FILES[@]} required files"
else
  fail "dry-run renders all ${#REQUIRED_FILES[@]} required files"
  for rel in "${missing[@]}"; do detail "missing or empty: $rel"; done
fi

includes=$(grep -c 'conf.d' "$RENDER/etc/bacula/bacula-dir.conf" 2>/dev/null || echo 0)
if (( includes >= 10 )); then
  ok "bacula-dir.conf includes the conf.d fragments ($includes includes)"
else
  fail "bacula-dir.conf includes the conf.d fragments"
  detail "found only $includes includes, expected >= 10"
fi

frag_bad=()
for frag in "$RENDER"/etc/bacula/conf.d/*.conf; do
  grep -q 'Name *=' "$frag" || frag_bad+=("$(basename "$frag")")
done
if ((${#frag_bad[@]} == 0)); then
  ok "every conf.d fragment defines a named resource"
else
  fail "every conf.d fragment defines a named resource"
  for f in "${frag_bad[@]}"; do detail "$f has no Name = directive"; done
fi

if grep -q 'Director {' "$RENDER/etc/bacula/bconsole.conf" \
   && grep -Eq '^  Password *= *.+' "$RENDER/etc/bacula/bconsole.conf"; then
  ok "bconsole.conf has a Director block with a non-empty password"
else
  fail "bconsole.conf has a Director block with a non-empty password"
fi

site_ok=1
for key in DIR_NAME DIR_ADDR SERVER_CLIENT SD_NAME DB_NAME STORAGE_DIR; do
  grep -q "^$key=" "$RENDER/etc/bacula/site.env" || { site_ok=0; detail "site.env missing $key"; }
done
if (( site_ok )); then
  ok "site.env carries the facts the helper scripts rely on"
else
  fail "site.env carries the facts the helper scripts rely on"
fi

if [[ -s $RENDER/etc/bacula/secrets.env ]]; then
  ok "secrets.env is generated and non-empty"
else
  fail "secrets.env is generated and non-empty"
fi

if [[ $OSTYPE == linux* ]]; then
  mode_secrets=$(stat -c '%a' "$RENDER/etc/bacula/secrets.env")
  mode_console=$(stat -c '%a' "$RENDER/etc/bacula/bconsole.conf")
  if [[ $mode_secrets == 600 && $mode_console == 600 ]]; then
    ok "secrets.env and bconsole.conf are written 0600"
  else
    fail "secrets.env and bconsole.conf are written 0600"
    detail "got secrets.env=$mode_secrets bconsole.conf=$mode_console, want 600/600"
  fi
else
  skip "file-mode assertions (0600) need a Linux filesystem; skipped here"
fi
unset DRY_RUN_ROOT

# --offsite: second device + pool fragments must render and be merged
RENDER2="$TMP/render2"
export DRY_RUN_ROOT="$RENDER2"
if bash ./deploy-bacula-server.sh --dry-run --dir-name ci-dir --offsite "$RENDER2/offsite" >"$TMP/render2.out" 2>&1; then
  ok "deploy-bacula-server.sh --dry-run --offsite exits 0"
else
  fail "deploy-bacula-server.sh --dry-run --offsite exits 0"
  tail -5 "$TMP/render2.out" | redact | while IFS= read -r l; do detail "$l"; done
fi
unset DRY_RUN_ROOT

offsite_ok=1
[[ -s $RENDER2/etc/bacula/conf.d/11-storage-offsite.conf ]] || { offsite_ok=0; detail "missing conf.d/11-storage-offsite.conf"; }
[[ -s $RENDER2/etc/bacula/conf.d/21-pool-offsite.conf ]]    || { offsite_ok=0; detail "missing conf.d/21-pool-offsite.conf"; }
grep -qi 'offsite' "$RENDER2/etc/bacula/bacula-sd.conf"     || { offsite_ok=0; detail "offsite device was not merged into bacula-sd.conf"; }
if (( offsite_ok )); then
  ok "--offsite renders and merges its storage/pool fragments"
else
  fail "--offsite renders and merges its storage/pool fragments"
fi

# ============================================================================
section "4. client onboarding: bacula-add-client.sh --dry-run"

export CONF_DIR="$RENDER/etc/bacula"
export SITE_FILE="$CONF_DIR/site.env"

out=$(bash ./bacula-add-client.sh web01 10.0.0.21 --dry-run 2>&1); rc=$?
lin_ok=1
[[ $rc -eq 0 ]]                || { lin_ok=0; detail "linux dry-run exited $rc"; }
grep -q  'Name = "web01"'   <<<"$out" || { lin_ok=0; detail 'missing Name = "web01"'; }
grep -q  'Address = "10.0.0.21"' <<<"$out" || { lin_ok=0; detail 'missing Address = "10.0.0.21"'; }
grep -q  'JobDefs = "LinuxClient"' <<<"$out" || { lin_ok=0; detail 'missing JobDefs = "LinuxClient"'; }
grep -q  'web01-daily'      <<<"$out" || { lin_ok=0; detail "missing web01-daily job"; }
grep -q  'web01-monthly'    <<<"$out" || { lin_ok=0; detail "missing web01-monthly job"; }
if (( lin_ok )); then ok "linux client renders Client + daily/monthly jobs"; else fail "linux client renders Client + daily/monthly jobs"; fi

out=$(bash ./bacula-add-client.sh fs01 --os windows --dry-run 2>&1); rc=$?
win_ok=1
[[ $rc -eq 0 ]] || { win_ok=0; detail "windows dry-run exited $rc"; }
grep -q 'JobDefs = "WindowsClient"'         <<<"$out" || { win_ok=0; detail 'missing JobDefs = "WindowsClient"'; }
grep -q 'JobDefs = "WindowsClientMonthly"'  <<<"$out" || { win_ok=0; detail 'missing JobDefs = "WindowsClientMonthly"'; }
if (( win_ok )); then ok "windows client uses the Windows jobdefs"; else fail "windows client uses the Windows jobdefs"; fi

out=$(bash ./bacula-add-client.sh app03 10.0.0.23 --include /srv/app --dry-run 2>&1); rc=$?
inc_ok=1
[[ $rc -eq 0 ]] || { inc_ok=0; detail "--include dry-run exited $rc"; }
grep -q 'File = "/srv/app"'   <<<"$out" || { inc_ok=0; detail 'missing File = "/srv/app"'; }
grep -q 'FileSet = "app03-fs"' <<<"$out" || { inc_ok=0; detail 'missing private FileSet app03-fs'; }
if (( inc_ok )); then ok "--include builds a private FileSet"; else fail "--include builds a private FileSet"; fi

if bash ./bacula-add-client.sh Bad_Name --dry-run >/dev/null 2>&1; then
  fail "invalid client names are rejected"
  detail "Bad_Name was accepted"
else
  ok "invalid client names are rejected"
fi
unset CONF_DIR SITE_FILE

# ============================================================================
section "5. client installer: bacula-client-install.sh --dry-run"

out=$(bash ./bacula-client-install.sh --dry-run --client web01 \
        --director-name ci-dir --director bacula01.example.com \
        --password ci-only-placeholder 2>&1); rc=$?
fd_ok=1
[[ $rc -eq 0 ]] || { fd_ok=0; detail "installer dry-run exited $rc"; }
grep -q 'FileDaemon {'  <<<"$out" || { fd_ok=0; detail "missing FileDaemon block"; }
grep -qi 'FDport *= *9102' <<<"$out" || { fd_ok=0; detail "missing FDport 9102"; }
grep -q 'Name = ci-dir' <<<"$out" || { fd_ok=0; detail "missing Director name ci-dir"; }
grep -q 'Messages {'    <<<"$out" || { fd_ok=0; detail "missing Messages block"; }
if (( fd_ok )); then ok "installer dry-run renders a complete FileDaemon config"; else fail "installer dry-run renders a complete FileDaemon config"; fi

if grep -q '^# ==== BODY ====$' bacula-client-install.sh; then
  ok "client installer keeps its bundle-assembly BODY marker"
else
  fail "client installer keeps its bundle-assembly BODY marker"
  detail "bacula-add-client.sh assembles enrolment bundles from everything after this line"
fi

if sed -n '/^# ==== BODY ====$/,$p' bacula-client-install.sh >"$TMP/body.sh" && bash -n "$TMP/body.sh" 2>/dev/null; then
  ok "the installer body parses standalone"
else
  fail "the installer body parses standalone"
fi

# simulate exactly what bacula-add-client.sh writes into an enrolment bundle
{
  printf '#!/usr/bin/env bash\n'
  printf 'CLIENT_NAME=web01\nDIRECTOR_NAME=ci-dir\nDIRECTOR_ADDR=bacula01.example.com\nFD_PASSWORD=x\nCLIENT_OS=linux\n'
  sed -n '/^# ==== BODY ====$/,$p' bacula-client-install.sh
} >"$TMP/bundle.sh"
if bash -n "$TMP/bundle.sh" 2>/dev/null && grep -q 'set -Eeuo pipefail' "$TMP/bundle.sh"; then
  ok "assembled enrolment bundle parses and keeps set -Eeuo pipefail"
else
  fail "assembled enrolment bundle parses and keeps set -Eeuo pipefail"
fi

# ============================================================================
section "6. Windows installer: bacula-client-install.ps1"

ps_param_ok=1
for token in ClientName DirectorName DirectorAddress Password InstallerPath; do
  grep -q "$token" bacula-client-install.ps1 || { ps_param_ok=0; detail "ps1 is missing $token"; }
done
if (( ps_param_ok )); then ok "ps1 keeps the param contract the generated bootstrap relies on"; else fail "ps1 keeps the param contract the generated bootstrap relies on"; fi

if command -v pwsh >/dev/null 2>&1; then
  cat >"$TMP/psparse.ps1" <<'PARSE'
param([string]$Path)
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count) { $errors | ForEach-Object { Write-Output ("line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }; exit 1 }
exit 0
PARSE
  if pwsh -NoProfile -File "$TMP/psparse.ps1" -Path "$PWD/bacula-client-install.ps1" >"$TMP/ps.err"; then
    ok "pwsh parses bacula-client-install.ps1"
  else
    fail "pwsh parses bacula-client-install.ps1"
    detail "$(head -3 "$TMP/ps.err")"
  fi
else
  skip "pwsh not installed on this runner (skipped, not passed)"
fi

# ============================================================================
section "summary"

printf '\nchecks: %d  passed: %d  failed: %d  skipped: %d\n' "$n" "$passed" "$failed" "$skipped"
if (( failed )); then
  printf '\nfailed checks:\n'
  for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
printf 'all checks passed\n'
exit 0
