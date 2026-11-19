# shellcheck shell=bash disable=SC2034
# discord-bot — read-only slash commands about this server and your site, in Discord.

MODULE_SUMMARY="Slash commands in Discord: /status, /site, /guests, /host, ... (read-only)"
MODULE_ABOUT="A Discord bot that answers questions about this server. Type a command, get the answer:

  /status   everything at a glance        /host     CPU, RAM, disks, temperatures
  /alerts   what's failing, last 7 days   /guests   VMs and containers
  /site     your website, checked live    /backup   the USB backup
  /ollama   models and GPU, checked live  /notes    Obsidian sync
  /help

It is read-only by design: no command can change anything on the server. It runs as its own
user (haki-bot) with no access to Proxmox. Once a minute haki-snapshot (as root) writes what the
bot may show to /run/haki-bot/snapshot.json; that file, your site and the ollama API are all it
reads. It connects out to Discord, so no port is opened and nothing is published.

Only you get answers (the owner of the Discord application, or HAKI_BOT_OWNERS), and each
answer is visible only to you, even in a shared channel.

The bot token is asked for with hidden input, saved root-only and handed to the bot by systemd.
It is never written to haki.conf, logs or the screen."
MODULE_CHANGES="python3-websockets                              Debian package (the bot's only dependency)
user haki-bot                                   system user the bot runs as, no shell, no home
/usr/local/sbin/haki-snapshot                   collects the data (root, every minute)
/usr/local/sbin/haki-discord-bot                the bot
/etc/systemd/system/haki-snapshot.{service,timer}
/etc/systemd/system/haki-discord-bot.service    sandboxed: read-only system, no privileges
/etc/haki/discord-bot.token (mode 0600)         the bot token (asked for, never shown)"
MODULE_REQUIRES="a Discord application with a bot (free: discord.com/developers/applications)"
MODULE_COMMANDS="haki discord-bot token          set or change the bot token
haki discord-bot invite         the link that adds the bot to your Discord server
haki discord-bot show [cmd]     an answer in the terminal, e.g.: haki discord-bot show site
haki discord-bot logs           the bot's recent log"

TOKEN=/etc/haki/discord-bot.token
BOT=/usr/local/sbin/haki-discord-bot
SNAP=/usr/local/sbin/haki-snapshot
BOT_STATE=/run/haki-discord-bot/state.json

# discord_get <path>: GET from Discord's API as the bot. The token goes to curl on stdin, so it
# never shows up in the process list.
discord_get() {
  [[ -s $TOKEN ]] || return 1
  printf 'header = "Authorization: Bot %s"\n' "$(cat "$TOKEN")" \
    | curl -fsS --max-time 15 -K - -A 'haki (https://github.com/Echo2f13/haki)' "https://discord.com/api/v10$1"
}
app_id() { discord_get /oauth2/applications/@me | perl -MJSON -0e 'print decode_json(<STDIN>)->{id}'; }

module_check() {
  command -v python3 >/dev/null || { bad "python3 is missing (it ships with Proxmox VE; apt install python3)"; return 1; }
  return 0
}

module_install() {
  step "What the bot needs"
  if python3 -c 'import websockets' 2>/dev/null; then skip "python3-websockets is installed"
  else run "install python3-websockets" bash -c 'apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y python3-websockets >/dev/null'; fi
  if id haki-bot &>/dev/null; then skip "user haki-bot exists"
  else run "create system user haki-bot" useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin haki-bot; fi

  step "The data it may show (haki-snapshot, every minute)"
  install_file "$MODULE_DIR/files/haki-snapshot" "$SNAP" 0755
  write_file /etc/systemd/system/haki-snapshot.service 0644 <<'EOF'
[Unit]
Description=haki-snapshot: collect what the Discord bot shows
After=pve-guests.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/haki-snapshot
TimeoutStartSec=60
Nice=10
EOF
  write_file /etc/systemd/system/haki-snapshot.timer 0644 <<'EOF'
[Unit]
Description=Collect the haki snapshot every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

  step "The bot"
  install_file "$MODULE_DIR/files/haki-discord-bot" "$BOT" 0755
  write_file /etc/systemd/system/haki-discord-bot.service 0644 <<EOF
[Unit]
Description=haki-discord-bot: read-only slash commands about this server
After=network-online.target haki-snapshot.timer
Wants=network-online.target
ConditionPathExists=$TOKEN

[Service]
User=haki-bot
Group=haki-bot
ExecStart=$BOT
LoadCredential=token:$TOKEN
EnvironmentFile=-/etc/haki/haki.conf
RuntimeDirectory=haki-discord-bot
Restart=always
RestartSec=30
# Sandbox: it reads a snapshot and talks to Discord; it needs nothing else.
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
UMask=0077
MemoryMax=150M
TasksMax=32

[Install]
WantedBy=multi-user.target
EOF

  step "Bot token"
  if [[ -s $TOKEN ]]; then skip "already set (change it with: haki discord-bot token)"
  elif planning; then plan "ask for the bot token and save it to $TOKEN (mode 0600)"
  else module_cmd_token || true; fi

  if planning; then
    plan "enable haki-snapshot.timer and haki-discord-bot.service"
  else
    run "enable the snapshot timer" bash -c 'systemctl daemon-reload && systemctl enable --now haki-snapshot.timer >/dev/null 2>&1 && systemctl start haki-snapshot.service'
    if [[ -s $TOKEN ]]; then
      run "start the bot" bash -c 'systemctl enable haki-discord-bot.service >/dev/null 2>&1 && systemctl restart haki-discord-bot.service'
      note "Add it to your Discord server: haki discord-bot invite. Then type / in any channel."
    else
      note "The bot starts once it has a token: haki discord-bot token"
    fi
  fi
}

module_uninstall() {
  if planning; then plan "stop and disable haki-discord-bot.service and haki-snapshot.timer"
  else systemctl disable --now haki-discord-bot.service haki-snapshot.timer >/dev/null 2>&1; fi
  remove_file /etc/systemd/system/haki-discord-bot.service
  remove_file /etc/systemd/system/haki-snapshot.timer
  remove_file /etc/systemd/system/haki-snapshot.service
  remove_file "$BOT"
  remove_file "$SNAP"
  planning || { systemctl daemon-reload; rm -rf /run/haki-bot; }
  note "Kept: $TOKEN, user haki-bot and python3-websockets. To revoke the bot, reset its token in the"
  note "Discord developer portal; then: rm $TOKEN; userdel haki-bot"
}

module_status() {
  local rc=0 age
  if systemctl is-active -q haki-snapshot.timer; then
    age=$(( $(date +%s) - $(stat -c %Y /run/haki-bot/snapshot.json 2>/dev/null || echo 0) ))
    if (( age < 180 )); then ok "snapshot is fresh (${age}s old)"; else bad "snapshot is ${age}s old: journalctl -u haki-snapshot"; rc=1; fi
  else bad "haki-snapshot.timer isn't running. Fix: haki install discord-bot"; rc=1; fi
  if [[ ! -s $TOKEN ]]; then warn "no bot token yet: haki discord-bot token"; return 1; fi
  if ! systemctl is-active -q haki-discord-bot.service; then bad "the bot isn't running: haki discord-bot logs"; return 1; fi
  if [[ -r $BOT_STATE ]] && perl -MJSON -0e 'exit !decode_json(<>)->{connected}' "$BOT_STATE"; then
    ok "$(perl -MJSON -0e '$s = decode_json(<>); printf "connected to Discord as %s, in %d server(s)", $s->{user}, $s->{guilds}' "$BOT_STATE")"
    perl -MJSON -0e '$s = decode_json(<>); exit !$s->{guilds}' "$BOT_STATE" || warn "it isn't in any server yet: haki discord-bot invite"
  else
    bad "running, but not connected to Discord: haki discord-bot logs"; rc=1
  fi
  return $rc
}

# --- module commands --------------------------------------------------------------------------
module_cmd_token() {
  need_root
  echo "  Make a bot: discord.com/developers/applications → New Application → Bot → Reset Token → Copy."
  echo "  It needs no privileged intents and no permissions. The token is a password for the bot:"
  echo "  it's saved root-only in $TOKEN and never shown."
  [[ -t 0 ]] || { warn "not an interactive terminal; skipping the token question"; return 1; }
  local t; read -r -s -p "  Paste the bot token (input hidden; Enter to skip): " t; echo
  [[ -z $t ]] && { skip "no token set; add it later with: haki discord-bot token"; return 0; }
  [[ $t =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || { bad "that doesn't look like a bot token; nothing saved"; return 1; }
  mkdir -p /etc/haki
  ( umask 077; backup_file "$TOKEN"; printf '%s\n' "$t" > "$TOKEN.new"; mv "$TOKEN.new" "$TOKEN"; chmod 600 "$TOKEN" )
  unset t
  local name
  if name=$(discord_get /users/@me | perl -MJSON -0e 'print decode_json(<STDIN>)->{username}'); then ok "token works: the bot is '$name'"
  else bad "Discord didn't accept that token (saved anyway; set another with: haki discord-bot token)"; return 1; fi
  if systemctl cat haki-discord-bot.service &>/dev/null; then
    systemctl enable haki-discord-bot.service >/dev/null 2>&1; systemctl restart haki-discord-bot.service && ok "bot restarted with the new token"
  fi
  module_cmd_invite
}

module_cmd_invite() {
  need_root
  local id; id=$(app_id) || die "couldn't ask Discord for the application (is the token set? haki discord-bot token)"
  echo "  Open this link and pick your server (it asks for no permissions):"
  echo "    https://discord.com/oauth2/authorize?client_id=$id&scope=bot+applications.commands&permissions=0"
}

module_cmd_show() {
  [[ -x $BOT ]] || die "not installed: haki install discord-bot"
  local c=${1:-status}
  [[ $c =~ ^(status|alerts|site|guests|host|backup|ollama|notes|help)$ ]] || die "unknown: $c (status alerts site guests host backup ollama notes help)"
  "$BOT" --render "$c" --text
}

module_cmd_logs() { journalctl -u haki-discord-bot -u haki-snapshot -n "${1:-40}" --no-pager -o short-iso; }
