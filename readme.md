# drive-monitor

A single Bash script that monitors **drive health (SMART)** and **array health (ZFS + mdadm)**
on Linux servers and sends **Pushover** notifications when something isn't right.

It keeps state between runs so it can tell the difference between a *new* problem, the
*same* ongoing problem, and a *recovery* — and it won't spam you.

## What it watches

- **SMART drives** (`smartctl`)
  - Overall health = FAILED
  - Critical attributes > 0: `Reallocated_Sector_Ct`, `Current_Pending_Sector`, `Offline_Uncorrectable`
  - NVMe wear: `Percentage Used >= 90%`, `Available Spare <= 10%`
  - Non-empty SMART error logs
  - Correct per-device `-d` type via `smartctl --scan-open` (HBAs, SATA bridges, NVMe)
- **ZFS pools** (`zpool`) — auto-discovers **all** pools
  - Unhealthy state (`zpool status -x`) + recovery "all clear"
  - Optional scrub/resilver start & finish notifications
- **mdadm arrays** (`mdadm` + `/proc/mdstat`)
  - Degraded / failed / faulty / inactive arrays, failed-device counts
  - Optional resync / recovery / check / reshape start & finish notifications

Each module is **auto-skipped** if its tool isn't installed, so the same script runs
anywhere.

## Alerting behavior (stateful)

- **New or changed problem** → immediate alert (high priority).
- **Same ongoing problem** → re-alerted at most once per `COOLDOWN_SECONDS` (default 6h).
- **Recovery** (problem → healthy) → one info "all clear".
- **Maintenance activity** (scrub/resilver/resync/check/reshape) → optional one-time
  start/finish info notifications (toggleable per type).

State lives in `STATE_DIR` (default `/var/lib/drive-monitor`); a run log is written to
`LOGFILE` (default `/var/log/drive-monitor.log`) and to syslog via `logger`.

## Requirements

- Root privileges (SMART/array data needs it)
- `curl`, plus whichever subsystems you use: `smartmontools`, `zfsutils-linux`, `mdadm`

```bash
sudo apt-get install -y curl smartmontools   # add zfsutils-linux / mdadm as needed
```

- A Pushover account (User Key + Application Token)

## Install

```bash
sudo install -m 0755 drive-monitor.sh /usr/local/sbin/drive-monitor.sh

sudo cp drive-monitor.env.example /etc/drive-monitor.env
sudo nano /etc/drive-monitor.env          # set PO_TOKEN and PO_UK
sudo chown root:root /etc/drive-monitor.env
sudo chmod 600 /etc/drive-monitor.env
```

## Test once

```bash
sudo /usr/local/sbin/drive-monitor.sh
sudo tail -n 40 /var/log/drive-monitor.log
```

No problems → no alerts; the log shows `OK:` lines for each subject. If Pushover isn't
configured, alerts are logged (`WARN: ... Would have sent`) instead of sent, so it never
fails silently.

## Cron (hourly)

```bash
sudo crontab -e
```

```cron
0 * * * * /usr/local/sbin/drive-monitor.sh >/dev/null 2>&1
```

The script sources `/etc/drive-monitor.env` itself, so no need to source it in cron.

## Configuration

All settings live in `/etc/drive-monitor.env` — see `drive-monitor.env.example` for the
full annotated list. Highlights:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PO_TOKEN`, `PO_UK` | empty | Pushover app token + user key (required to send) |
| `COOLDOWN_SECONDS` | `21600` | Reminder interval for the same ongoing problem |
| `ENABLE_SMART` / `ENABLE_ZFS` / `ENABLE_MDADM` | `1` | Per-module toggles |
| `PO_PRIORITY_ALARM` / `PO_PRIORITY_INFO` | `1` / `-1` | Pushover priorities |
| `NOTIFY_SCRUB_*` / `NOTIFY_RESILVER_*` / `NOTIFY_MD_SYNC_*` | `1` | Activity notifications |
| `SMART_NVME_PCT_USED_MAX` / `SMART_NVME_SPARE_MIN` | `90` / `10` | NVMe wear thresholds |

## Notes

- Run as **root**; USB/SATA bridges and HBAs are supported for SMART.
- `cksum` is used to build problem signatures (change detection), not for security.
- Replaces the earlier separate `smart_pushover.sh` and `zpool-monitor.sh` scripts.
