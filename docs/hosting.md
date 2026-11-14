# Hosting other people's apps

I host a friend's Discord bot on my home server. The worry with that is obvious: their code runs
in my house, on my network. These two modules are how I make that boring:

- **`customer-net`** — a separate network for guests you host, walled off from everything you own.
- **`tenant`** — one command to create a container on it, with limits, starting on boot.
- **`edge`** — public https addresses for them through a Cloudflare Tunnel: no port forwarding,
  works behind CGNAT. Optional; any reverse proxy you already run works too.

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

Tenants are only reachable from one machine, `HAKI_EDGE_IP`: the one that faces the internet.

### With the edge module (Cloudflare Tunnel)

You need a domain on a free Cloudflare account, and one free address on your LAN — outside your
router's DHCP range — for a small container.

```bash
haki plan edge
haki install edge                          # asks for the address; creates CT 120 'haki-edge'
haki edge login                            # prints a link: log in, pick your domain
haki edge add priya.example.com 202        # DNS record + tunnel route → tenant 202's port
```

`https://priya.example.com` now serves tenant 202's port 80, with Cloudflare's certificate. No port
is opened on your router, and it works behind CGNAT. The edge container becomes `HAKI_EDGE_IP`
by itself, and because its address is fixed it never drifts.

```bash
haki edge list                             # hostnames and where they go
haki edge add wiki.example.com http://192.168.1.50:8080    # anything else it can reach
haki edge remove priya.example.com
haki status edge                           # container up, tunnel connected
haki edge logs
```

If the hostname already has a DNS record, Cloudflare refuses to replace it: delete the old
record in Cloudflare → DNS first. `haki tenant remove` also unpublishes that tenant's hostnames.
`watch` alerts you when the tunnel loses its connection.

### With your own reverse proxy or tunnel

Tell haki which machine it is:

```bash
haki customer-net edge          # finds HAKI_EDGE_VM's address, or asks for one
```

Then point it at the host port, e.g. in a Cloudflare Tunnel `config.yml` (above the catch-all):

```yaml
  - hostname: priya.example.com
    service: http://<host-ip>:20202
```

Give that machine a fixed address (a DHCP reservation). If it moves anyway, `watch` warns you,
and `haki customer-net edge` fixes it.

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
