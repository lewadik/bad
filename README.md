# Bacula Community deployment bundle

A single-host Bacula Community backup server plus one-command client onboarding,
built for a mixed Linux/Windows estate. Everything here is plain Bash and
PowerShell, no external dependencies beyond the distribution packages.

- **Design and rationale:** [deployment-scenario.md](deployment-scenario.md)
- **Server install:** `deploy-bacula-server.sh`
- **Client onboarding:** `bacula-add-client.sh` → bundle → `bacula-client-install.sh`

## Requirements

| | |
|---|---|
| Server OS | Debian 12, Ubuntu 22.04/24.04 (systemd, apt) |
| Server resources | 4 vCPU, 8 GB RAM, 20 GB for the catalog + data disk for volumes |
| Client OS | Debian/Ubuntu (apt), RHEL/Rocky/Alma 8–9 (dnf + EPEL), Windows 2019/2022 |
| Access | root on the server; root SSH on Linux clients only if you use `--push` |
| Network | director → client 9102/tcp, client → server 9103/tcp |

The package versions differ by distribution (Debian 12 → Bacula 9.6.7,
Ubuntu 24.04 → 13.0.4). The configuration here is version-neutral across those
ranges. Check yours with:

```bash
apt-cache policy bacula-director-pgsql
```

## Quickstart

```bash
# 1. copy the bundle to the server and run it
scp -r bacula/ root@bacula01:/root/
ssh root@bacula01 'bash /root/bacula/deploy-bacula-server.sh'

# 2. register a client and print its installer
bacula-add-client web01 10.0.0.21

# 3. install the file daemon on the client
scp /etc/bacula/enroll/web01-install.sh root@10.0.0.21:/root/
ssh root@10.0.0.21 'bash /root/web01-install.sh'

# 4. prove the whole path with a real backup
bacula-add-client web01 --test
```

Step 4 waits for the job to finish and reports files/bytes from the catalog. If
it returns `job T`, you have a working backup. Nothing else in this bundle
matters until that passes.

Prefer to look before you leap:

```bash
bash deploy-bacula-server.sh --dry-run     # renders every file into a temp root
bash bacula-add-client.sh web01 10.0.0.21 --dry-run
bash bacula-client-install.sh --dry-run --client web01 \
     --director-name bacula01-dir --director bacula01.example.com --password x
```

## What the server install creates

```
/etc/bacula/
  bacula-dir.conf          director (includes the fragments below)
  bacula-sd.conf           storage daemon + file device
  bacula-fd.conf           the server's own file daemon
  bconsole.conf            0600, console password
  secrets.env              0600, source of truth for re-renders
  site.env                 site facts used by the helper scripts
  conf.d/10-storage.conf   LocalDisk (+ OffsiteDisk with --offsite)
  conf.d/15-server-client.conf
  conf.d/20-pools.conf     File / Monthly / Catalog (45 d / 400 d / 120 d)
  conf.d/30-schedules.conf weekly full, daily incremental, catalog dump
  conf.d/40-filesets.conf  LinuxServer, WindowsServer, BaculaServer, Catalog
  conf.d/50-jobdefs.conf   four JobDefs (Linux/Windows × daily/monthly)
  conf.d/60-jobs.conf      server self-backup + catalog job
  conf.d/70-console.conf
  conf.d/90-messages.conf
  clients.conf             generated include list — never edit by hand
  clients.d/<name>.conf    one file per client (Client + 2 Jobs)
  enroll/                  generated installers, 0700
/usr/local/sbin/
  bacula-add-client         bacula-client-install
  bacula-topup-volumes      bacula-health        bacula-restore-drill
  bacula-catalog-dump.sh
/etc/systemd/system/
  bacula-topup.{service,timer}    daily 03:15 — keep volumes labelled
  bacula-health.{service,timer}   daily 07:00 — exit 0/1/2
  bacula-drill.{service,timer}    monthly, installed but disabled
```

Re-running the deploy script preserves secrets, the catalog and existing
volumes; it re-renders configuration from the flags and restarts the daemons.

## Client onboarding

### Linux

```bash
bacula-add-client db02 10.0.0.22                       # shared LinuxServer fileset
bacula-add-client app03 10.0.0.23 --include /srv/app   # private fileset
bacula-add-client web01 --push                         # scp+ssh the bundle now
bacula-add-client web01 --test                         # full job, wait, report
bacula-add-client --list
bacula-add-client web01 --remove                       # keeps catalog history
```

`--include` accepts a comma-separated list or repeats. `--force` rotates the
password (re-run the bundle afterwards).

### Windows

```bash
bacula-add-client fs01 10.0.0.31 --os windows
```

Copy `bacula-client-install.ps1`, `fs01-install.ps1` and the Bacula Win64
installer to `C:\Temp`, then in an elevated PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Temp\fs01-install.ps1 `
           -InstallerPath C:\Temp\bacula-15.0.3-win64.exe
```

The wrapper carries the client name, director and password; the generic script
installs, writes the config, restarts the service and scopes the firewall rule
to the director's IP.

## Day-2 commands

| Task | Command |
|---|---|
| Console | `bconsole -c /etc/bacula/bconsole.conf` |
| Health (exit 0/1/2) | `bacula-health` · `bacula-health --json` · `bacula-health --mail ops@example.com` |
| Run a job now | `echo 'run job=web01-daily level=Full yes' \| bconsole -c /etc/bacula/bconsole.conf -n` |
| Job history | `bconsole` → `list jobs client=web01` |
| Why did it fail | `bconsole` → `messages jobid=1234` |
| Restore drill | `bacula-restore-drill --client web01` |
| Top up volumes | `bacula-topup-volumes` · `bacula-topup-volumes --dry-run` |
| Reload after config edit | `echo reload \| bconsole -c /etc/bacula/bconsole.conf -n` |
| Logs | `journalctl -u bacula-director -f` · `/var/log/bacula/` |
| Catalog dump (manual) | `PGDATABASE=bacula sudo -u bacula /usr/local/sbin/bacula-catalog-dump.sh` |

## Scripts

| Script | Runs on | Purpose |
|---|---|---|
| `deploy-bacula-server.sh` | server | install and configure director, SD, catalog, policy, timers |
| `bacula-add-client.sh` | server | register a client, emit its bundle, optional `--test`/`--push` |
| `bacula-client-install.sh` | client | install/configure the Linux file daemon |
| `bacula-client-install.ps1` | client | install/configure the Windows file daemon |
| `bacula-topup-volumes.sh` | server | keep N labelled volumes per pool |
| `bacula-health.sh` | server | daemons, catalog, failures, staleness, space |
| `bacula-restore-drill.sh` | server | restore a real job and report the outcome |

All of them support `--help`, and `--dry-run` where a dry run makes sense.

## Verification after the install

```bash
systemctl is-active bacula-director bacula-sd bacula-fd
bacula-health
bconsole -c /etc/bacula/bconsole.conf <<< $'status director\nstatus storage=LocalDisk\nquit'
ls -l /srv/bacula/volumes | head
```

Expected: three active units, `status: ok`, a volume list with `File-0001...`,
and a catalog dump in `/var/lib/bacula/bacula.sql` after the first `Catalog-daily`
run at 21:00 (or run it manually).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `deploy` stops at "config test failed" | directive not supported by your Bacula version | the parser prints file:line — adjust `conf.d/*` and re-run |
| Job waits forever, "no volume available" | pool buffer empty | `bacula-topup-volumes` |
| `status client` says "Failed to connect" | firewall, FD down, or address wrong | `ss -ltn \| grep 9102` on the client; check ufw/firewalld |
| "Authorization key rejected" | FD password mismatch | `bacula-add-client <name> --force`, re-run the bundle |
| Catalog errors after upgrade | schema version | `dpkg-reconfigure bacula-director-pgsql`, check `Version` table |
| `bacula-dir` won't start after edit | include or syntax error | `bacula-dir -t -c /etc/bacula/bacula-dir.conf` |
| Windows FD not listening | service or firewall | `Get-Service bacula-fd`, `Get-NetFirewallRule 'Bacula File Daemon*'` |
| Restore drill times out | job is huge, or bconsole blocked | drill a smaller client; check `messages jobid=<restore id>` |

## Uninstall

```bash
# clients
bash bacula-client-install.sh --uninstall        # stops the service, removes the config

# server
systemctl disable --now bacula-director bacula-sd bacula-fd
systemctl disable --now bacula-topup.timer bacula-health.timer bacula-drill.timer
apt-get purge bacula-director-pgsql bacula-sd bacula-client bacula-console
# volumes and the catalog are kept: /srv/bacula/volumes, /etc/bacula, database bacula
```

## Security notes

- Configs are `0640 root:bacula`, `bconsole.conf` and `secrets.env` are `0600`.
- The catalog uses a local socket with peer auth; there is no database password
  on the wire and none in `pg_hba`.
- Enrolment bundles contain the file daemon password: `0700`, and `shred -u`
  after use (`--push` does it for you).
- Backups contain `/etc/bacula`, i.e. the credentials. If the volume disk leaves
  the building, encrypt it (LUKS) — see deployment-scenario.md §10.
- TLS is not enabled by default; deployment-scenario.md §11 has the two-phase
  rollout.
