# Configuration

haki keeps settings in **`/etc/haki/haki.conf`** — a plain shell file of `KEY="value"` lines.
`haki init` writes the network settings; modules add their own (for example
`haki backup-usb pick` adds `HAKI_BACKUP_UUID`). Edit it with any editor, then run
`haki install <module>` again for modules that copy settings into files (like the backup trigger).
Scripts that run on a timer (haki-watch, the backup script) read it every time, so most changes
take effect on their next run.

## Network — `haki init`

| Setting | Default | Meaning |
|---|---|---|
| `HAKI_BRIDGE` | detected (`vmbr0`) | The bridge your router is on. Guests are looked up here. |
| `HAKI_HOST_IP` | detected | The host's IP on that bridge (used in hints). |
| `HAKI_GATEWAY` | detected | Your router. `nic-watchdog` pings it. Empty = use the default route. |

## watch

| Setting | Default | Meaning |
|---|---|---|
| `HAKI_SITE_URL` | empty | A public URL to check from the host, e.g. `https://example.com/`. Empty = no site check. |
| `HAKI_EDGE_VM` | empty | VM id of your reverse proxy / tunnel VM, so site alerts name it. |
| `HAKI_OLLAMA_VM` | empty | VM id running ollama; its API is checked (found by MAC, so DHCP is fine). |
| `HAKI_OLLAMA_PORT` | `11434` | ollama's port. |
| `HAKI_REPORT_HOUR` | `9` | Daily report is sent on the first check after this hour. |
| `HAKI_CONFIRM_RUNS` | `2` | Failed checks in a row before a DOWN alert (checks are 2 min apart). |

Other files:

- `/etc/haki/alerts.env` — `HAKI_DISCORD_WEBHOOK=…` (mode 600). Set with `haki watch webhook`.
- `/etc/haki/services.conf` — services inside containers to check, one `<ctid> <unit>` per line:
  ```
  201 my-discord-bot
  110 couchdb
  ```

## backup-usb

| Setting | Default | Meaning |
|---|---|---|
| `HAKI_BACKUP_UUID` | — | Filesystem UUID of the backup drive. Set by `haki backup-usb pick`. |
| `HAKI_BACKUP_KEEP` | `4` | Backups kept per guest on the drive. |
| `HAKI_BACKUP_MIN_FREE_GB` | `150` | Refuse to start if the drive has less free space than this. |
| `HAKI_BACKUP_DUE_DAYS` | `7` | After this many days without a backup, Notes and `watch` say OVERDUE. |

After changing `HAKI_BACKUP_UUID` by hand, run `haki install backup-usb` so the plug-in trigger
matches the new drive.
