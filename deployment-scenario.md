# Bacula Community: deployment scenario

A concrete, buildable design for a single-site Bacula Community backup service:
one backup server, a mixed Linux/Windows estate, file-level restore, offsite
copies, and a disaster-recovery path that does not depend on the thing being
recovered.

Every number here is an assumption you are expected to replace; every mechanism
is implemented by the scripts in this directory.

---

## 1. Scope

**In scope**

- One Bacula Director + Storage Daemon + PostgreSQL catalog on a single host.
- Disk storage (file devices) with a labelled-volume buffer.
- Scheduled full/incremental backups for Linux servers and Windows servers.
- Per-client enrolment in one command, with a generated, self-contained installer.
- Restore drills, catalog dumps, offsite copies, health checks, alerting hooks.
- Disaster recovery of the backup server itself.

**Out of scope (deliberately)**

- Bare-metal recovery. Bacula CE has no BMR; see §8 for the ReaR pairing.
- Tape libraries, NDMP, hypervisor-level snapshots (Enterprise-only in CE).
- Deduplication (not in CE) and storage-side immutability (§10).
- Multi-tenancy, self-service portals, RBAC beyond console ACLs (§12).

The honest summary: this design protects **data and configuration**, and it
assumes hosts can be reinstalled from images or configuration management. If
your RTO for a dead server is measured in minutes and there is no image
pipeline, this is the wrong tool on its own — add ReaR (§8) or an imaging
product for the OS layer.

---

## 2. Why Bacula CE, and what it is not

From the 2026 landscape review in `../research/oss-backup-20261110/`, Bacula
Community is the *catalog and scheduler* half of a backup system: it knows which
hosts exist, which files were captured, where each copy lives, and it can drive
tape. That is a genuinely scarce capability — restic, Borg and Kopia are
repository engines with no inventory and no policy.

It is also the half with the weakest maintenance signal in that review: latest
stable 15.0.3 (2025-03), roughly 19 months without a release, no first-class
GitHub presence, AGPL-3.0 with a single commercial vendor behind it.

This scenario therefore takes three deliberate positions:

1. **Pin the distribution packages** (Debian 12 → 9.6.7, Ubuntu 24.04 → 13.0.4)
   rather than chasing upstream tarballs. They are patched by the distro, they
   install cleanly, and the config below works unchanged on all three versions.
2. **Keep the design boring.** File devices, one catalog, no plugins. Every
   non-standard component is a component you must support alone in 2028.
3. **Pair it, do not stretch it.** Offsite copies get their own device (§10),
   OS recovery gets ReaR (§8), and databases get native dumps that Bacula merely
   picks up (a `pg_dump` file is a better backup than a torn PGDATA directory).

If the estate is Linux-only and tape is not required, the review's
recommendation of Proxmox Backup Server or Bareos is a better fit. This document
assumes a catalog/tape requirement exists.

---

## 3. Target estate

| Item | Assumption | Where it is set |
|---|---|---|
| Linux servers | 40 (Debian 12 / Ubuntu 22.04–24.04) | `bacula-add-client` |
| Windows servers | 12 (2019/2022) | `bacula-add-client --os windows` |
| Protected data | 1.5 TB, ~3 M files | §5 |
| Daily change rate | ~3% (45 GB) | §5 |
| Backup window | 22:30–07:00 local | `conf.d/30-schedules.conf` |
| RPO, file data | 24 h | daily incremental |
| RPO, cold data | 7 days | weekly full |
| RTO, single file | < 10 min | §8 |
| RTO, whole host | 4–8 h (rebuild + restore) | §8, no BMR |
| RTO, backup server | 2 h (catalog dump + config) | §9 |
| Retention | 45 days operational, 13 months monthly | `conf.d/20-pools.conf` |

Scale-up note: the design is single-node until roughly 150 clients or 5 TB, at
which point the catalog host (not the storage) becomes the bottleneck. Beyond
that, split Director/SD onto separate hosts before touching anything else.

---

## 4. Architecture

```
                       management network (admin SSH, bconsole)
                                     |
   +---------------------------------|-----------------------------------+
   |  bacula01 (Debian 12, 4 vCPU, 8 GB, 2 disks)                        |
   |                                                                     |
   |   bacula-dir :9101  <--- PostgreSQL 16 (catalog, local socket)      |
   |        |                                                            |
   |        |  schedules jobs, records file attributes                   |
   |        v                                                            |
   |   bacula-sd  :9103  ---> /srv/bacula/volumes   (File device)        |
   |        ^                     \--- File-0001..N, Monthly-0001..N     |
   |        |                     \--- Catalog-0001..N (catalog dumps)   |
   |        |                                                            |
   |   bacula-fd  :9102  (the server backs itself up)                    |
   +---------|-----------------------------------------------------------+
             |   data channel: client FD -> SD :9103
             |
   +---------|------------------+     +-----------------------------+
   | Linux servers (40)         |     | Windows servers (12)        |
   | bacula-fd :9102            |     | bacula-fd :9102 (service)   |
   +----------------------------+     +-----------------------------+
```

| Component | Listens | Who connects | Firewall rule |
|---|---|---|---|
| Director | 9101/tcp | bconsole (admins) | management subnet only |
| Storage Daemon | 9103/tcp | every file daemon | client subnets |
| File Daemon | 9102/tcp | the director | director IP only |
| PostgreSQL | unix socket | director, `pg_dump` | none (no TCP needed) |

Two consequences worth stating out loud:

- **The data does not flow through the director.** Each file daemon opens a
  connection to the storage daemon. A saturated director link slows scheduling,
  not throughput.
- **Clients need no route to each other**, only to the SD port. That keeps the
  firewall story simple and is why the SD address in `10-storage.conf` must be
  resolvable from every client.

---

## 5. Sizing

### 5.1 Storage (no deduplication)

Bacula CE stores every byte it reads. Plan for a multiple of the protected data,
not a fraction of it:

| Pool | Contents | Volumes kept | Raw size |
|---|---|---|---|
| `File` | weekly fulls + dailies, 45-day retention | ~6 fulls + 45 incrementals | 6 × 1.5 TB + 45 × 45 GB ≈ **11 TB** |
| `Monthly` | monthly full, 400-day retention | 13 | 13 × 1.5 TB ≈ **19.5 TB** |
| `Catalog` | nightly catalog dump, 120 days | ~4 | < 1 GB |
| **Total** | | | **≈ 31 TB** |

Add 20% headroom for volume fragmentation and the label buffer → **38 TB
usable**. That is the real cost of "no dedup"; the same estate on a
deduplicating target is 3–5 TB. Do not let a vendor comparison hide this line.

With GZIP compression enabled per FileSet (`Compression = GZIP6`), text-heavy
estates see 1.4–1.8×; already-compressed data sees nothing and costs CPU. Leave
compression off until you have measured one full job.

### 5.2 Catalog

Bacula's own guidance: file records are ~80% of the catalog. For 3 M files with
a 45-day/400-day retention mix (roughly 12 M file records live at steady state):

| Resource | Value |
|---|---|
| Database size | 4–6 GB including indexes |
| Disk for PostgreSQL | 40 GB (WAL, autovacuum bloat, dumps) |
| RAM | 8 GB host; 1–2 GB `shared_buffers` |
| vCPU | 4 (insert throughput is the limit, not CPU count) |

The deploy script writes a tuning drop-in (`conf.d/60-bacula.conf` under the
PostgreSQL config directory) with these proportions derived from host RAM.

### 5.3 Window and throughput

1.5 TB full at an effective 100 MB/s over 1 GbE ≈ **4.2 h**; at 250 MB/s over
2.5 GbE ≈ **1.7 h**. The default window is 22:30–07:00 (8.5 h) with the full
starting at 02:00 — enough for 1 GbE with 2× margin, which is what you want on
the night a full runs long.

Six incremental nights at 45 GB each are ~8 min at the same rate; the binding
constraint is the weekly full, not the dailies.

---

## 6. Backup policy

| Job | Schedule | Level | Pool | Retention |
|---|---|---|---|---|
| `<client>-daily` | Sun 02:00 | Full | `File` | 45 days (volume) |
| `<client>-daily` | Mon–Sat 22:30 | Incremental | `File` | 45 days |
| `<client>-monthly` | 1st, 04:00 | Full | `Monthly` | 400 days |
| `Server-self-daily` | as above | Full/Incremental | `File` | 45 days |
| `Catalog-daily` | daily 21:00 | Full | `Catalog` | 120 days |

Design notes:

- **Full and incremental share a pool** so a base full is never pruned out from
  under its incrementals. 45 days comfortably covers the longest chain (a
  monthly full resets it on the 1st) plus a week of slack.
- **The monthly full duplicates work on the 1st if it is a Sunday.** Two fulls
  that night, ~3 TB of writes. Accepted: it keeps the schedule readable and the
  monthly pool is what you hand to audit. If that is unacceptable, move the
  monthly job to `day=2` or drop it and extend `File` retention to a year.
- **Priorities**: catalog 5 (first), dailies 10, monthly 20 (last). A slow
  monthly full must never delay the catalog dump.
- **Bootstrap files** (`/var/lib/bacula/<client>.bsr`) are written per job. They
  are the "where is this job on which volume" map used when the catalog is gone.

---

## 7. Client onboarding

The workflow is deliberately two commands on the server and one on the client:

```
# on the backup server
bacula-add-client web01 10.0.0.21
#   -> writes /etc/bacula/clients.d/web01.conf (Client + 2 Jobs)
#   -> regenerates clients.conf, validates with bacula-dir -t, reloads the director
#   -> emits /etc/bacula/enroll/web01-install.sh (name, director, password baked in)

scp /etc/bacula/enroll/web01-install.sh root@10.0.0.21:/root/
ssh root@10.0.0.21 'bash /root/web01-install.sh'

# back on the server, prove it
bacula-add-client web01 --test
```

Why a bundle instead of `curl | bash`: the bundle carries the credential and is
written `0700`, so there is no unauthenticated endpoint to defend and no
credential in shell history. `--push` does the scp+ssh for you when the server
has root SSH trust to the client; `--test` queues a real full backup and waits
for the catalog to report the outcome, which is the only check that proves the
whole path works.

Conventions that pay off later:

- Names are lowercase `[a-z0-9-]`, ≤ 32 chars, and match the hostname —
  `<name>-daily` and `<name>-monthly` are then predictable in `bconsole`.
- One client record per host. Do not reuse names after decommissioning: the
  catalog keeps history under that name, and `--remove` deliberately does not
  purge it.
- `--include` creates a private FileSet when a host has data outside the shared
  set (an application directory on a data disk, for example). Use it sparingly;
  forty bespoke FileSets are forty things to review every year.

### Linux specifics

The installer detects apt/dnf, installs `bacula-client`, writes
`/etc/bacula/bacula-fd.conf`, runs `bacula-fd -t`, starts the service, opens
9102 to the director only (ufw, firewalld, or a printed hint), and checks that
the port is listening.

### Windows clients

Windows has no package-manager shortcut, so `bacula-add-client --os windows`
emits a wrapper plus the generic installer:

```
C:\Temp\bacula-client-install.ps1     # generic, from the bundle
C:\Temp\fs01-install.ps1              # wrapper: name, director, password
C:\Temp\bacula-<version>-win64.exe    # from bacula.org
```

Run elevated:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Temp\fs01-install.ps1 `
           -InstallerPath C:\Temp\bacula-15.0.3-win64.exe
```

The script installs silently (`/S` for the NSIS build, `msiexec /qn` for an
MSI), writes the config as ASCII/CRLF (no BOM — the Windows FD dislikes one),
restarts the service, adds an inbound rule scoped to the director's IP, and
prints the service state.

**Open files are the real Windows risk.** A file-level backup of a live SQL
Server `.mdf`, an Exchange `.edb` or an Outlook `.pst` is not transactionally
consistent. Bacula CE gives you a file copy, not an application-consistent
snapshot. The pattern that works:

1. Native dump to a staging path (`BACKUP DATABASE ... TO DISK`, `pg_dump`,
   `mysqldump`).
2. Let Bacula back up the dump file.
3. Delete the staging file after the job (`RunAfterJob`).

Do not enable VSS and assume it solved this; test the restore of a database
before you put it on the schedule.

---

## 8. Restore matrix and drills

| Target | Covered by Bacula CE | Method | RTO (est.) |
|---|---|---|---|
| Single file | Yes | `restore` → `mark` → `done` | < 10 min |
| Directory / project | Yes | `restore` with `where=` | 10–60 min |
| Whole host, file data | Yes | restore to `/` on a rebuilt OS | 2–6 h |
| Whole host, OS + boot | **No** | ReaR image, or reinstall from config mgmt | 1–4 h extra |
| PostgreSQL / MySQL | Indirect | native dump restored by the DBA | 30 min–2 h |
| Volume contents after catalog loss | Yes | `bls` / `bextract` on the volume file | 1–3 h |
| Catalog itself | Yes | `pg_restore` of the nightly dump | < 30 min |

**Drills are part of the deployment, not a nice-to-have.** `bacula-restore-drill`
restores the latest successful job of a client into `/var/tmp/bacula-drill/<client>/`
and reports file count, bytes and status; the timer is installed but disabled.

Cadence:

| Frequency | Drill | Owner |
|---|---|---|
| Weekly | `bacula-health` shows green; one file restored by hand | ops |
| Monthly | `bacula-restore-drill --client <rotating>`; record the result | ops |
| Quarterly | Full DR rehearsal: restore the catalog, then a whole host | backup owner |
| Yearly | Restore from the *offsite* copy, not the primary | backup owner |

A backup that has never been restored is a hypothesis. The quarterly rehearsal
is what turns it into a fact, and the drill log (`/var/log/bacula/drill.log`)
is the evidence you show an auditor.

---

## 9. Disaster recovery of the backup server

The kit that must survive the server:

| Item | Location | Why |
|---|---|---|
| Catalog dump | `/var/lib/bacula/bacula.sql` (in pool `Catalog`) | names, paths, volumes, job history |
| Config + secrets | `/etc/bacula/` (in FileSet `BaculaServer`) | client passwords, pool layout, console access |
| Bootstrap files | `/var/lib/bacula/*.bsr` (same FileSet) | which volume holds which job |
| The volumes themselves | `/srv/bacula/volumes` | the actual bytes |

Rebuild procedure:

1. Provision a host with the same major distro release; install the bundle.
2. Recover `/etc/bacula/` — from the last `BaculaServer` job (`bextract` on the
   volume file if the catalog is gone), or from configuration management if you
   keep these files there too.
3. Recreate the empty database, then `psql -d bacula -f bacula.sql`.
4. Attach the old volume directory (or restore it from the offsite copy).
5. `systemctl start bacula-sd bacula-director`, then
   `bconsole → status director` and `list volumes`.
6. Restore one file to prove the catalog matches the volumes on disk.

If `/etc/bacula` is lost *and* no copy exists, the client records are gone; every
client must be re-enrolled with a new password (`bacula-add-client --force` plus
a fresh bundle). That is a 40-host afternoon, and it is why the `BaculaServer`
FileSet includes `/etc/bacula` and why the secrets file is documented as
sensitive-but-backed-up.

---

## 10. Offsite and immutability

Two separate problems, often confused:

**Copy off the box.** The deploy script can add a second device
(`--offsite /mnt/offsite/volumes`). Then either:

- a Copy job (`Type = Copy`, `Selection Type = PoolUncopiedJobs`) — elegant,
  writes only jobs that have no copy yet. Verify the directive set against your
  build with `bacula-dir -t` before trusting it; the syntax moved between 9.x
  and 13.x; or
- the boring, version-proof route: re-run the full to the offsite pool on a
  schedule, from cron on the director:

  ```bash
  # every Saturday, after the primary full
  for c in $(bconsole -c /etc/bacula/bconsole.conf -n <<<"list clients" ...); do
    echo "run job=$c-daily level=Full storage=OffsiteDisk pool=Offsite yes" |
      bconsole -c /etc/bacula/bconsole.conf -n
  done
  ```

  Crude, twice the volume writes, and completely unambiguous. Pick it if you
  value sleep over elegance.

**Immutability is not a Bacula feature.** File-device volumes are files: root on
the backup server can delete them, and so can ransomware that reaches that
server. Real protection lives in the storage layer:

| Option | Protects against | Cost |
|---|---|---|
| Removable disk rotated off-site weekly | server compromise, ransomware | manual handling; RPO = rotation interval |
| Second server, `borg`/`restic` to S3 with Object Lock (compliance mode) | server compromise, insider, ransomware | storage + a second tool; retention is irreversible |
| Tape WORM | everything except tape loss | drive + media + handling |
| `chattr +i` on volume files | accidents, not root | none, but trivially reversible by root |

The practical minimum for this scenario: **a weekly removable disk that leaves
the building**, plus the monthly pool kept on it. Object-lock S3 via restic is
the better answer if you can accept a second tool and irreversible retention —
that is the recommendation in the landscape review, and it does not contradict
using Bacula here: Bacula is the catalog, restic is the immutability layer.

Encryption: Bacula CE can encrypt on the client (`PKI Signatures`,
`Encrypt = yes` in the FileSet options) but key management is entirely yours,
and a lost key is a lost backup. The cheaper control is physical: keep volumes
on an encrypted disk (LUKS) and treat the offsite disk the same way.

---

## 11. Transport security

Out of the box this deployment speaks Bacula's native protocol, unencrypted, on
the assumption that the backup network is a trusted VLAN. That assumption fails
in cloud VPCs and flat office networks, so plan TLS as a two-phase rollout.

Phase 1 — enable, do not require (both ends, all resources):

```
TLS Enable = yes
TLS Require = no
TLS CA Cert File = /etc/bacula/tls/ca.crt
TLS Cert File    = /etc/bacula/tls/<host>.crt
TLS Key File     = /etc/bacula/tls/<host>.key
```

Add the same four lines to every `Director`, `Client`, `Storage` and `Console`
resource, restart everything, and confirm in the logs that sessions negotiated
TLS. Phase 2 — flip `TLS Require = yes` on the director first, then on clients as
they are touched by routine maintenance.

Certificates: one CA, one cert per host, CN = the resource name (Bacula checks
the CN against the resource name, not the DNS name). A five-line `openssl`
recipe is enough; do not build a PKI for 52 hosts.

Verification: `bacula-dir -t` validates directive names, but only a real session
proves the handshake. Test with one client before rolling out.

---

## 12. Access control and hardening

| Control | Setting |
|---|---|
| Console | One `Console` resource with a 32-char password; `bconsole.conf` is `0600 root` |
| Console access | localhost only in `bconsole.conf`; remote admins use SSH port forwarding |
| Director port | 9101 reachable from the management subnet only |
| Client port | 9102 open to the director IP only (the installers do this) |
| Secrets | `/etc/bacula/secrets.env` `0600 root`; configs `0640 root:bacula` |
| DB access | unix socket + peer auth as OS user `bacula`; no password in `pg_hba` |
| Enrolment bundles | `/etc/bacula/enroll` `0700 root`; shred after use |
| sudo | `bacula` runs daemons; admins use `sudo bconsole` |

For multiple operators, add one `Console` resource per person with `CommandACL`
limited to `run, restore, status, list, messages, cancel` and no `delete`,
`purge` or `configure`. Bacula ACLs are coarse but they do stop `delete volume`
in the wrong hands.

---

## 13. Operations runbook

**Daily (automated):** `bacula-health.timer` at 07:00 → exit 0/1/2.

**Daily (human, 5 minutes):**

```bash
bacula-health                 # or: bacula-health --json | jq
bconsole -c /etc/bacula/bconsole.conf
  * status director
  * list jobs            # anything not "T" or "W" in the last 24 h?
  * messages
```

**Weekly:** check `df -h /srv/bacula/volumes` against §5.1; confirm the topup
timer ran (`systemctl list-timers bacula-*`); restore one file by hand.

**Monthly:** `bacula-restore-drill --client <rotate through clients>`; review
`/var/log/bacula/drill.log`; prune `clients.d` entries for decommissioned hosts
(`bacula-add-client --remove <name>`).

**Quarterly:** full DR rehearsal (§9), volume inventory audit
(`list volumes`, confirm the offsite set matches), review retention against the
data protection policy.

**On a failed job:**

```bash
bconsole → messages jobid=<id>       # the actual error
bconsole → status client=<name>      # is the FD reachable?
ss -ltn | grep 9102                  # on the client
journalctl -u bacula-fd -n 50        # on the client
```

Common causes, in order of frequency: client firewalled after a rebuild; FD
password rotated on one side only (`bacula-add-client --force` + re-run the
bundle); volume pool exhausted (`bacula-topup-volumes`); disk full.

**Adding capacity:** add a volume to the pool, not a new pool. Pools are
retention policy; volumes are capacity.

---

## 14. Monitoring and alerting

`bacula-health` is the single entry point. Exit codes map to monitoring states:

| Exit | Meaning | Page? |
|---|---|---|
| 0 | daemons up, no failures, clients fresh, space fine | no |
| 1 | stale client, low space, no appendable volume | ticket |
| 2 | daemon down, failed jobs, catalog unreachable, <10% space | page |

`--json` emits one object for Prometheus textfile, Zabbix or a webhook:

```json
{"status":"warning","checks":[{"name":"stale clients","status":"warn","detail":"1 without a successful backup in 36h: db02(41h)"}]}
```

Alert on: status != ok for 2 consecutive checks; any job in `E`/`f` state;
catalog dump older than 26 h; free space < 20%.

Do **not** alert on "backup completed" — it is noise. Alert on "no successful
backup for N hours", which is the only signal that matters.

---

## 15. Risks and limits

| Risk | Impact | Mitigation |
|---|---|---|
| No deduplication | ~20× storage multiplier (§5.1) | budget for it; compress text data; do not promise dedup ratios |
| No BMR in CE | host rebuild is manual | ReaR images, or config management + documented rebuild |
| Maintenance cadence (19 months since 15.0.3) | unpatched bugs, no upstream fixes | pin distro packages; track Debian/Ubuntu security updates; keep an exit plan |
| Single PostgreSQL | catalog loss stops scheduling | nightly dumps + §9 rehearsal; local NVMe; monitoring |
| Single director/SD host | outage = no backups | acceptable for RPO 24 h; the DR kit rebuilds in ~2 h |
| File device, not tape | no WORM, no off-site by default | §10 rotation; tape if compliance demands |
| Windows open files | inconsistent application data | native dumps first (§7) |
| Mixing FD/DIR versions | subtle protocol failures | keep clients within one major version of the server |
| `list clients` / Copy-job syntax drift between 9.x and 13/15 | runbook commands fail | verify on the installed version; the scripts avoid version-specific syntax |

Exit plan: the catalog is plain SQL and the volumes are plain files with a
documented format. `bextract` reads volumes without a catalog, so a migration to
Bareos (schema-compatible) or a rebuild on restic is a project, not a rescue.

---

## 16. Rollout plan

| Phase | Work | Acceptance |
|---|---|---|
| 0 | Server build (`deploy-bacula-server.sh`), volume labelling, health timer | `bconsole status director/storage/client` all OK; first catalog dump exists |
| 1 | 3 pilot clients (one Linux web, one Linux DB, one Windows file server) | 3 nightly jobs green for a week; one file restored per client |
| 2 | Remaining Linux servers in batches of 10 | no failed job for 5 nights; window respected |
| 3 | Windows servers | per-host restore of a share tested; application dumps in place |
| 4 | Offsite device + copy/rotation | one restore from the offsite copy succeeds |
| 5 | TLS rollout (§11), console ACLs (§12) | handshake verified on all clients; `bacula-dir -t` clean |
| 6 | DR rehearsal (§9) | catalog + one host restored inside the RTO table |

Do not skip phase 1's restore test. A pilot that only proves backups complete
proves nothing about the thing you bought.

---

## Appendix A — files

| File | Purpose |
|---|---|
| `deploy-bacula-server.sh` | server install, catalog, policy, helpers, timers |
| `bacula-add-client.sh` | register a client, emit its installer, optional test |
| `bacula-client-install.sh` | Linux file daemon install (also the bundle body) |
| `bacula-client-install.ps1` | Windows file daemon install |
| `bacula-topup-volumes.sh` | keep the labelled-volume buffer full |
| `bacula-health.sh` | one-command health check, monitoring-friendly |
| `bacula-restore-drill.sh` | restore a real job and report the result |
| `README.md` | quickstart and day-2 command reference |

## Appendix B — ports

| Port | Protocol | Service | Direction |
|---|---|---|---|
| 9101 | TCP | Director | admin → server |
| 9102 | TCP | File Daemon | server → client |
| 9103 | TCP | Storage Daemon | client → server |
| 5432 | unix socket | PostgreSQL | local only |
