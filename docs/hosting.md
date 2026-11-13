# Hosting other people's apps

I host a friend's Discord bot on my home server. The worry with that is obvious: their code runs
in my house, on my network. These two modules are how I make that boring:

- **`customer-net`** — a separate network for guests you host, walled off from everything you own.
- **`tenant`** — one command to create a container on it, with limits, starting on boot.

## What a tenant can and can't reach

| From a tenant container to… | |
|---|---|
| The internet (web, DNS, APIs, Discord, package mirrors) | allowed |
| Your home LAN, router, NAS, printer — any private address | **blocked** |
| The Proxmox host (web UI, SSH) | **blocked** |
| Other tenants | **blocked** (bridge port isolation) |
| Outbound mail, port 25 | **blocked** — nobody sends spam from your IP |

And the other way round: nothing on your LAN or the internet can reach a tenant, except the one
machine you choose (your reverse proxy or Cloudflare Tunnel), through one port per app.

## Set up the network (once)

```bash
haki plan customer-net      # read it: a new bridge, a firewall, IP forwarding, a hookscript
haki install customer-net
haki install tenant
```

The defaults use bridge `vmbr1` and `10.10.0.0/24`. If either is taken on your host, set
`HAKI_TENANT_BRIDGE` / `HAKI_TENANT_SUBNET` in `/etc/haki/haki.conf` first ([config.md](config.md)).

Adding the bridge applies the network config with `ifreload -a`, which is the Proxmox-safe way:
your running VMs stay connected. Your existing bridges aren't changed.

## Create a tenant

```bash
haki tenant plans                       # nano / small / medium — edit /etc/haki/plans.conf
haki tenant new 202 priya-shop small
```

It shows exactly what it will create and asks first. You get a Debian container:

- IP `10.10.0.102` (id 201 → .101, 202 → .102, …), DNS 1.1.1.1 / 9.9.9.9
- 1 core capped at half a core, 512 MB RAM, 10 GB disk (plan `small`)
- unprivileged, starts on boot, tagged `customer` in the Proxmox UI
- published as host port `20202` → its port 80 (use `--private` for bots and workers that don't
  serve anything)

Then set up their app:

```bash
haki tenant shell 202
apt update && apt install -y nodejs npm git     # whatever it needs
# … clone it, then add a systemd service so it starts on boot
```

## Give a website a public address

Tenants are only reachable from the machine in `HAKI_EDGE_IP`. Set it once:

```bash
haki customer-net edge          # finds HAKI_EDGE_VM's address, or asks for one
```

Then point your reverse proxy or tunnel at the host port. With Cloudflare Tunnel, in the
tunnel's `config.yml` (above the final catch-all rule):

```yaml
  - hostname: priya.example.com
    service: http://<host-ip>:20202
```

and `cloudflared tunnel route dns <tunnel> priya.example.com`, then restart cloudflared. No port is
opened on your router.

Give the edge machine a fixed address (a DHCP reservation). If it moves anyway, `watch` warns
you, and `haki customer-net edge` fixes it.

## Day to day

```bash
haki tenant list                 # plan, IP, running?, RAM used, published port
haki status customer-net         # firewall loaded, bridge up, every tenant isolated
haki tenant publish 202 8080     # publish a different port
haki tenant unpublish 202
haki tenant remove 202           # asks you to type the name; USB backups are kept
```

If you install `backup-usb`, tenants are backed up with everything else.

## What this doesn't do (yet)

- **Bandwidth limits.** A tenant can use your whole upload. Pick tenants you trust not to.
- **IPv6.** The tenant network is IPv4-only; containers are told to prefer IPv4.
- **Per-tenant logins.** You manage the containers; tenants don't get Proxmox accounts.
