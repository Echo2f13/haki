# Ask your server from Discord

`discord-bot` adds slash commands to your Discord server. Type one, get the answer, visible
only to you:

| Command | Shows |
|---|---|
| `/status` | Everything at a glance: problems right now, host, guests, site, backup, haki-watch |
| `/alerts` | What's failing and since when; incidents of the last 7 days (outages, power cuts, address changes) |
| `/site` | Your website **checked live**: up, response time, certificate expiry, the deployed commit, Cloudflare Tunnel, the web server VM, other published hostnames |
| `/guests` | Every VM and container: running or not, CPU, memory, uptime, address |
| `/host` | CPU, load, memory, every storage pool, temperatures, failed services, SSD health, versions |
| `/backup` | When the USB backup last ran, what it saved, whether one is due |
| `/ollama` | Models, which is loaded and how much is on the GPU, **checked live** |
| `/notes` | Obsidian sync: CouchDB, Tailscale and which of your devices are online |
| `/help` | The list |

Commands for modules you don't use say so.

## Why it's safe to run

- **Read-only.** There is no command that changes anything. The bot couldn't if it tried:
  it runs as user `haki-bot`, which has no access to Proxmox, in a systemd sandbox (read-only
  system, no privileges, no capabilities, 150 MB memory cap).
- **It never touches the host.** Once a minute `haki-snapshot` (as root) writes what the bot
  may show to `/run/haki-bot/snapshot.json`, readable only by root and `haki-bot`. That file,
  your site and the ollama API are the only things the bot reads.
- **No open port.** It connects out to Discord's gateway, like the Discord app does. Nothing is
  published.
- **Only you.** Answers go to the owner of the Discord application (or `HAKI_BOT_OWNERS`), and
  are *ephemeral*: nobody else in the channel sees them. Others are told no.
- **The token stays put.** Asked with hidden input, saved root-only, handed to the bot by
  systemd (`LoadCredential`). It's not in `haki.conf`, the environment or the logs.

## Set it up

1. **Make the bot** at [discord.com/developers/applications](https://discord.com/developers/applications):
   *New Application* → name it → *Bot* → *Reset Token* → copy. It needs **no** privileged intents
   and **no** permissions. (You can untick *Public Bot* so only you can add it anywhere.)
2. **Install** on the host:
   ```bash
   haki install discord-bot     # asks for the token (hidden), then prints the invite link
   ```
3. **Invite it**: open the link it prints and pick your server. Type `/` in any channel.

Check it from the host:

```bash
haki status discord-bot          # snapshot fresh? connected? in how many servers?
haki discord-bot show site       # any answer, in the terminal
haki discord-bot logs
```

Optional settings (see [config.md](config.md#discord-bot)): `HAKI_BOT_OWNERS`, `HAKI_SITE_REPO`,
`HAKI_NOTES_CT`.

## If something's off

- **Commands don't appear:** the bot registers them when it connects, in every server it's in.
  After inviting it, `systemctl restart haki-discord-bot`. Then reload Discord (Ctrl+R).
- **"This bot only answers its owner":** you're not the application's owner; add your user id
  (Discord → Settings → Advanced → Developer Mode, then right-click yourself → Copy User ID) to
  `HAKI_BOT_OWNERS`.
- **"data from N min ago ⚠ stale":** `systemctl status haki-snapshot.timer`.
- **Change the token** (e.g. after resetting it): `haki discord-bot token`.
- **Remove it:** `haki uninstall discord-bot`, then delete the application in the developer
  portal (that revokes the token).
