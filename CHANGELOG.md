# Changelog

## 0.2.0 — 2026-11-15

**Hosting other people's apps**
- `customer-net`: an isolated bridge for guests you host — internet only; no LAN, host, other
  guests or outbound mail. Only your edge machine reaches published ports.
- `tenant`: `haki tenant new <id> <name> <plan>` creates a limited, isolated container; plus
  `list`, `publish`, `shell` and a remove that asks you to type the name.
- `edge`: public https hostnames through a Cloudflare Tunnel from a small container with a fixed
  address — no port forwarding, works behind CGNAT. `haki edge add <host> <tenant|url>`.

**Local AI**
- `ollama-gpu`: passes an NVIDIA card to a VM that installs its own driver and ollama on first
  boot, with a firewall in front of the API. Adopts an existing ollama VM as is.
  `models`, `pull`, `bench`, `allow` / `deny`.

**Fixes**
- `watch`: alert footers showed `Â·` instead of `·`; a moved edge no longer claims sites are down
  when nothing is published; a new check for the edge tunnel.
- Plans no longer list steps that would be skipped.

**Safety**
- CI runs ShellCheck and smoke tests on every push, including the customer firewall rules as
  real nftables. (Before this release the checks had never passed.)
- Installed scripts are executable in git, not only once installed.
- `haki-net show` prints the firewall rules it would load.

## 0.1.0 — 2026-11-13

First release: `hardening`, `watch`, `backup-usb`, `nic-watchdog`, and the `haki` command
(`doctor`, `init`, `plan`, `install`, `status`, `update`).
