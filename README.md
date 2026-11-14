# haki

**Safe defaults and small building blocks for a home Proxmox server.**

This is the setup I run on my own home server. It hosts my website, a Discord bot for a friend,
a local AI model on an old GPU and my notes — from a single PC in my house, behind a connection
with no public IP. Everything here was written because something actually broke: power cuts that
nobody noticed, a "fix" for a flaky network card that silently unplugged every VM, backups I kept
forgetting to make, alerts that cried wolf.

`haki` packages those fixes so you can pick the ones you want. You're welcome to use any of it,
copy it, change it, or just read it for ideas. It's MIT licensed.

```bash
git clone https://github.com/Echo2f13/haki.git /opt/haki
cd /opt/haki
./haki doctor          # look at this host, change nothing
./haki init            # detect your network, save /etc/haki/haki.conf
./haki plan hardening watch
./haki install hardening watch
```

That's the 5-minute version: working updates, key-only SSH, and a Discord channel that tells you
when something is wrong — and why.

## What you get

| Module | What it does |
|---|---|
| [`hardening`](modules/hardening/module.sh) | Free update repository instead of the paid one (so `apt update` works), key-only SSH for root — with a lockout check — and conservative kernel network settings. |
| [`watch`](modules/watch/module.sh) | Checks every 2 minutes and posts **explained** alerts to Discord: DOWN only after two failed checks, RECOVERED with the downtime, "server back online — it was a power cut", and a daily report. |
| [`backup-usb`](modules/backup-usb/module.sh) | Plug in a USB drive → every VM and container is backed up → the drive unmounts → unplug. Status in Proxmox Notes and Discord. |
| [`nic-watchdog`](modules/nic-watchdog/module.sh) | Brings the host's network back when the router stops answering, without unplugging your VMs. |

**Hosting other people's apps** — a friend's Discord bot, a small site, a side project:

| Module | What it does |
|---|---|
| [`customer-net`](modules/customer-net/module.sh) | A separate network for guests you host. They get the internet and nothing else: not your LAN, not the host, not each other, no outbound mail. Only your reverse proxy / tunnel can reach a published app. |
| [`tenant`](modules/tenant/module.sh) | `haki tenant new 202 priya-shop small` → an isolated container with its own IP and CPU/RAM/disk limits, starting on boot. Plus `list`, `publish`, `shell` and `remove`. |
| [`edge`](modules/edge/module.sh) | Public https addresses with **no port forwarding**, behind CGNAT too: a tiny container runs a Cloudflare Tunnel. `haki edge add shop.example.com 202` publishes a tenant, DNS record included. |

See [docs/hosting.md](docs/hosting.md).

**Local AI** — open models on an old graphics card, for yourself or your apps:

| Module | What it does |
|---|---|
| [`ollama-gpu`](modules/ollama-gpu/module.sh) | Passes your NVIDIA card to a VM that installs its own driver and [ollama](https://ollama.com) on first boot. The API only answers the addresses you allow. Already have one? It's adopted as is. `haki ollama-gpu pull`, `models`, `bench` (tokens/s, how much fits on the GPU). See [docs/ollama.md](docs/ollama.md). |

Coming next: Obsidian sync over Tailscale (`notes-sync`).

## How it works

- **One command, many small modules.** `haki list` shows them; `haki info <module>` explains
  what one does, why, exactly which files it touches, and its commands.
- **Plan before you change anything.** `haki plan <module>` prints every file and service a module
  would create or change, and changes nothing. `haki install` shows the same plan and asks first.
- **Safe to re-run.** Installing again only changes what's different. `haki update` pulls the
  latest version and re-applies the modules you installed.
- **Everything is undoable.** Every file haki replaces is copied to
  `/var/lib/haki/backups/<time>/` first, and `haki uninstall <module>` removes what it added.
- **Your settings, not mine.** Nothing about my house is hard-coded. `haki init` detects your
  bridge, IP and router, and you can edit `/etc/haki/haki.conf` any time.
- **Secrets stay secret.** The Discord webhook is typed in hidden and stored root-only
  (`/etc/haki/alerts.env`, mode 600). Nothing is ever exposed to the internet by a module.

## Commands

```text
haki doctor                  check the host: Proxmox version, network, disks, SSH keys
haki init                    detect your network and save /etc/haki/haki.conf
haki                         the host at a glance: Proxmox, load, guests, modules, backups
haki list                    all modules and whether they're installed
haki info <module>           what it does, why, what it changes, its commands
haki plan <module>...        dry run — list every change, apply nothing
haki install <module>...     install or update (shows the plan, asks first)
haki uninstall <module>      remove it (backups are kept)
haki status [module]         is it working? with a hint when it isn't
haki <module> <command>      e.g. haki watch test · haki backup-usb pick · haki backup-usb run
haki update                  pull the latest haki and re-apply installed modules
```

Add `--yes` to accept defaults without questions (safety checks still apply).

## Requirements

- Proxmox VE 8 or 9, run as root on the host (SSH, or Datacenter → your node → Shell).
- `git` to clone it (`apt install git`). Nothing else to install.
- For alerts: a Discord channel webhook. For backups: a USB drive.

## Is it safe?

I run every module here on my own server, and it's written to be careful: it plans first, backs
up what it replaces, won't turn off SSH passwords until you've proven your key works, and leaves
your existing network alone: only `customer-net` adds a bridge and a firewall of its own, and
`ollama-gpu` asks for a reboot before a graphics card changes hands. But it runs as root on your hypervisor,
so read `haki plan` before you `haki install`, and keep a way to reach the console (the Proxmox
web UI, or a screen and keyboard). See [docs/safety.md](docs/safety.md).

## Docs

- [Getting started](docs/getting-started.md) — a fresh Proxmox install to alerts in Discord
- [Configuration](docs/config.md) — every setting in `/etc/haki/haki.conf`
- [Safety](docs/safety.md) — what haki will and won't do, and how to undo it
- [Hosting other people's apps](docs/hosting.md) — customer-net, tenant and edge, step by step
- [Local AI on your GPU](docs/ollama.md) — ollama-gpu: passthrough, models, benchmarks
- [Writing a module](docs/writing-modules.md) — add your own building block

## License

[MIT](LICENSE). Use it for anything. If it saves you a lost weekend, that's thanks enough —
and issues and pull requests are welcome.
