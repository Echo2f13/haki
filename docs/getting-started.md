# Getting started

From a fresh Proxmox install to working updates, key-only SSH and alerts in Discord.
About 5 minutes. Everything runs as **root on the Proxmox host**.

## 0. Open a shell on the host

Either SSH in from your PC (`ssh root@<host-ip>`), or open **Datacenter → your node → Shell**
in the Proxmox web UI. The web UI shell is a good choice the first time: it keeps working even
if something goes wrong with SSH.

## 1. Get haki

```bash
apt install -y git          # if it isn't there yet
git clone https://github.com/Echo2f13/haki.git /opt/haki
cd /opt/haki
```

## 2. Look before you change anything

```bash
./haki doctor
```

This only reads: Proxmox version, CPU/RAM, which bridge and router you use, your root disk, whether
root has an SSH key, and whether the host can reach the internet. Read the `!` lines — they tell you
what to sort out first.

## 3. Describe your host

```bash
./haki init
```

haki detects your LAN bridge (usually `vmbr0`), the host's IP and your router, and asks for an
optional website address to check. Press Enter to accept each value. It saves them to
`/etc/haki/haki.conf` and offers to put `haki` on your PATH, so from now on you can type `haki`
from anywhere.

## 4. Add your SSH key (if `doctor` said root has none)

On **your PC**, not the server:

```bash
ssh-keygen -t ed25519            # only if you don't have a key yet; press Enter for defaults
ssh-copy-id root@<host-ip>       # asks for the root password one last time
ssh root@<host-ip>               # must log you in WITHOUT a password
```

Only continue once that last command works.

## 5. See the plan, then install

```bash
haki plan hardening watch
```

Read the list: every `+` line is a file or service that would change. Nothing has changed yet.

```bash
haki install hardening watch
```

You'll be asked:

- to confirm each module's changes,
- whether you've logged in with your SSH key (answer honestly — if not, SSH is left alone),
- for a Discord webhook (Discord → your server → a channel → Edit Channel → Integrations →
  Webhooks → New Webhook → Copy URL). Typing is hidden. Press Enter to skip; add it later with
  `haki watch webhook`.

A test card appears in Discord, and after a minute the first checks have run.

## 6. Check it

```bash
haki status
```

Every line should be ✓. If not, the line says what to do.

**Before you close your current SSH session**, open a new one from your PC to confirm key login
works: `ssh root@<host-ip>`.

## Next

- Backups: plug in a USB drive, then `haki backup-usb pick` and `haki install backup-usb`.
- Flaky network card? `haki info nic-watchdog`.
- Tell `watch` about a website, an ollama VM, or services inside containers: see
  [config.md](config.md).
