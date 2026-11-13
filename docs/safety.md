# Safety

haki runs as root on your hypervisor. Here is exactly how careful it tries to be, and how to undo
anything it did.

## What haki always does

- **Plans first.** `haki plan <module>` lists every change and makes none. `haki install` shows the
  same list and waits for your yes.
- **Backs up before it overwrites or deletes.** Every replaced or removed file is copied to
  `/var/lib/haki/backups/<date-time>/<original path>` first.
- **Only changes what differs.** Re-running an install leaves identical files alone.
- **Records what's installed** in `/var/lib/haki/modules/`, so `haki update` re-applies only those.

## Lockout protection

- `hardening` turns off SSH password login **only if** root already has a key in
  `/root/.ssh/authorized_keys` **and** you confirm you've logged in with it. It validates the new
  config with `sshd -t` and *reloads* sshd, so your open session stays connected. If validation
  fails, the change is removed again.
- The Proxmox web UI and its Shell/console are never touched — they keep working with your
  password, so you always have a way back in.
- None of the current modules change `/etc/network/interfaces`, the Proxmox firewall, or anything
  that could cut the host off the network.

## What haki never does

- Expose anything to the internet. No port forwarding, no public hostnames, no opened ports.
- Store secrets in the repo. Your webhook lives in `/etc/haki/alerts.env` (mode 600) and is never
  printed.
- Delete your data. `backup-usb` only writes inside a `Server` folder on the one drive you picked
  (matched by UUID) and only prunes backup files it created itself.

## Undoing things

```bash
haki uninstall <module>                  # removes what the module installed
ls /var/lib/haki/backups/                # every file haki replaced, by date
cp -a /var/lib/haki/backups/<time>/etc/ssh/sshd_config.d/... /etc/ssh/sshd_config.d/   # put one back
```

`hardening` leaves the repository change in place on uninstall: re-enabling the enterprise
repository without a subscription breaks `apt update`. Your original repo files are in the backups.

## If you do lock yourself out of SSH

Open the Proxmox web UI → your node → **Shell** (password login works there), then:

```bash
rm /etc/ssh/sshd_config.d/10-haki-hardening.conf && systemctl reload ssh
```
