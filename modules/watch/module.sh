# shellcheck shell=bash
# watch — health checks every 2 minutes, explained alerts in Discord.

MODULE_SUMMARY="Health checks every 2 min, clear alerts in Discord, daily report"
MODULE_ABOUT="Installs haki-watch, which checks the host and its guests every 2 minutes and posts
colour-coded cards to a Discord channel:

  🔴 DOWN        only after 2 failed checks in a row, so a one-off blip never wakes you up
  🟠 STILL DOWN  a reminder every 12 hours while it stays broken
  🟢 RECOVERED   back to normal, with how long it was down
  🔌 ONLINE      after a reboot: how long the server was off, and whether it was a clean
                 shutdown or a power cut / crash
  📋 DAILY       once a day: every guest, RAM, disks, incidents and blips of the last 24 h

It checks: home internet; your website (optional); guests set to start on boot — running,
plugged into the bridge, answering on the LAN (found by MAC, so DHCP changes don't break it);
an ollama API (optional); container services you list; host disk, storage pool, RAM, failed
services and disk SMART health. Every card says what is wrong and what to do about it.
Cards that can't be sent (internet down) are queued and sent later, marked as late.

Without a Discord webhook it still runs; 'haki watch status' shows the results."
MODULE_CHANGES="/usr/local/sbin/haki-watch                        the checker
/etc/systemd/system/haki-watch.{service,timer}    runs it every 2 minutes
/etc/haki/alerts.env (mode 0600)                  your Discord webhook (asked for, never shown)
/etc/haki/services.conf                           container services to check (you edit it)
/var/lib/haki-watch/                              check state, queue and event log"
MODULE_COMMANDS="haki watch test              send a test card to Discord
haki watch report            send the daily report now
haki watch status            every check's state and the last 24 h, in the terminal
haki watch webhook           set or change the Discord webhook
haki watch run               run all checks once now"

ALERTS=/etc/haki/alerts.env
SERVICES=/etc/haki/services.conf

module_install() {
  step "The checker"
  install_file "$MODULE_DIR/files/haki-watch" /usr/local/sbin/haki-watch 0755

  step "Run every 2 minutes"
  write_file /etc/systemd/system/haki-watch.service 0644 <<'EOF'
[Unit]
Description=haki-watch: health checks and Discord alerts
After=pve-guests.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/haki-watch
TimeoutStartSec=5min
EOF
  write_file /etc/systemd/system/haki-watch.timer 0644 <<'EOF'
[Unit]
Description=Run haki-watch every 2 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

  step "Services inside containers to check"
  if [[ -e $SERVICES ]]; then skip "$SERVICES exists (kept as is)"
  else
    write_file "$SERVICES" 0644 <<'EOF'
# Services haki-watch checks inside containers: <container id> <systemd unit>
# Example:
# 201 my-discord-bot
EOF
  fi

  step "Discord webhook"
  if grep -qs '^HAKI_DISCORD_WEBHOOK=https' "$ALERTS"; then skip "already set (change it with: haki watch webhook)"
  elif planning; then plan "ask for a Discord webhook and save it to $ALERTS (mode 0600)"
  else module_cmd_webhook || true; fi

  if ! planning; then
    run "enable the timer" bash -c 'systemctl daemon-reload && systemctl enable --now haki-watch.timer >/dev/null 2>&1'
    run "run the first check" systemctl start haki-watch.service
    note "See the results: haki watch status"
  else
    plan "enable haki-watch.timer and run a first check"
  fi
}

module_uninstall() {
  planning || systemctl disable --now haki-watch.timer >/dev/null 2>&1
  planning && plan "stop and disable haki-watch.timer"
  remove_file /etc/systemd/system/haki-watch.timer
  remove_file /etc/systemd/system/haki-watch.service
  remove_file /usr/local/sbin/haki-watch
  planning || systemctl daemon-reload
  note "Kept: $ALERTS, $SERVICES and /var/lib/haki-watch (delete them by hand if you want)."
}

module_status() {
  local rc=0 last
  if systemctl is-active -q haki-watch.timer; then ok "timer active (every 2 minutes)"
  else bad "timer not running. Fix: haki install watch"; rc=1; fi
  last=$(systemctl show -P ExecMainExitTimestamp haki-watch.service)
  if [[ -n $last ]]; then ok "last run: $last"; else warn "hasn't run yet"; fi
  if grep -qs '^HAKI_DISCORD_WEBHOOK=https' "$ALERTS"; then ok "Discord webhook set"
  else warn "no Discord webhook: alerts only show in 'haki watch status'. Add one: haki watch webhook"; fi
  if [[ -x /usr/local/sbin/haki-watch ]]; then
    local failing; failing=$(/usr/local/sbin/haki-watch --status | awk 'NR > 1 && NF >= 2 && $2 != "ok" && $1 ~ /^[a-z]/' | grep -vE '^(queued|VM |last)' || true)
    if [[ -z $failing ]]; then ok "all checks passing"; else bad "failing checks:"; printf '%s\n' "$failing" | sed 's/^/      /'; rc=1; fi
  fi
  return $rc
}

# --- module commands --------------------------------------------------------------------------
module_cmd_webhook() {
  echo "  Alerts go to a Discord channel through a webhook:"
  echo "    Discord → your server → channel → Edit Channel → Integrations → Webhooks → New Webhook → Copy URL"
  echo "  The URL is a secret (anyone with it can post). It's saved root-only in $ALERTS and never printed."
  local url
  if [[ ! -t 0 ]]; then warn "not an interactive terminal; skipping the webhook question"; return 1; fi
  read -r -s -p "  Paste the webhook URL (input hidden; Enter to skip): " url; echo
  [[ -z $url ]] && { skip "no webhook set — add one later with: haki watch webhook"; return 0; }
  [[ $url == https://discord.com/api/webhooks/* || $url == https://discordapp.com/api/webhooks/* ]] \
    || { bad "that doesn't look like a Discord webhook URL; nothing saved"; return 1; }
  mkdir -p /etc/haki
  ( umask 077; backup_file "$ALERTS"
    { grep -vs '^HAKI_DISCORD_WEBHOOK=' "$ALERTS"; printf 'HAKI_DISCORD_WEBHOOK=%s\n' "$url"; } > "$ALERTS.new"
    mv "$ALERTS.new" "$ALERTS"; chmod 600 "$ALERTS" )
  ok "webhook saved to $ALERTS (0600)"
  [[ -x /usr/local/sbin/haki-watch ]] && /usr/local/sbin/haki-watch --test >/dev/null && ok "sent a test card — check the channel"
}
module_cmd_test()   { /usr/local/sbin/haki-watch --test; }
module_cmd_report() { /usr/local/sbin/haki-watch --report; }
module_cmd_status() { /usr/local/sbin/haki-watch --status; }
module_cmd_run()    { systemctl start haki-watch.service && /usr/local/sbin/haki-watch --status; }
