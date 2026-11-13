# shellcheck shell=bash
# nic-watchdog — recover the host's network if the router stops answering, without unplugging VMs.

MODULE_SUMMARY="Recover the host's network when the router stops answering"
MODULE_ABOUT="For hosts whose network card or router sometimes drops the link and doesn't recover.
After boot it waits 2 minutes, then pings your router every 30 seconds. After 3 misses in a row
it runs 'ifreload -a' to re-apply the network config.

Why not just restart networking? 'systemctl restart networking' rebuilds the bridge and leaves
every running VM unplugged from it: they keep running but are silently offline until someone
re-attaches them. That exact mistake took a site down; this module exists so you don't repeat it.

Skip this module if your network has never dropped — it's a fix for flaky hardware."
MODULE_CHANGES="/usr/local/sbin/haki-nic-watchdog                the watchdog loop
/etc/systemd/system/haki-nic-watchdog.service    starts it at boot, restarts it if it dies"
MODULE_COMMANDS="haki nic-watchdog log    what it has done recently"

module_check() {
  local u
  for u in nic-watchdog.service network-watchdog.service; do
    if systemctl cat "$u" >/dev/null 2>&1; then
      warn "$u already exists on this host. If it restarts networking, disable it first:"
      note "systemctl disable --now $u"
    fi
  done
  return 0
}

module_install() {
  install_file "$MODULE_DIR/files/haki-nic-watchdog" /usr/local/sbin/haki-nic-watchdog 0755
  write_file /etc/systemd/system/haki-nic-watchdog.service 0644 <<'EOF'
[Unit]
Description=haki: recover the host network if the router stops answering (ifreload, keeps VMs plugged in)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/haki-nic-watchdog
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  if planning; then plan "enable and (re)start haki-nic-watchdog.service"; return 0; fi
  run "enable and start it" bash -c 'systemctl daemon-reload && systemctl enable haki-nic-watchdog.service >/dev/null 2>&1 && systemctl restart haki-nic-watchdog.service'
  note "It starts checking 2 minutes from now. Router: ${HAKI_GATEWAY:-auto-detected from the default route}"
}

module_uninstall() {
  planning || systemctl disable --now haki-nic-watchdog.service >/dev/null 2>&1
  remove_file /etc/systemd/system/haki-nic-watchdog.service
  remove_file /usr/local/sbin/haki-nic-watchdog
  planning || systemctl daemon-reload
}

module_status() {
  if systemctl is-active -q haki-nic-watchdog.service; then ok "running (router: ${HAKI_GATEWAY:-auto})"
  else bad "not running. Fix: haki install nic-watchdog"; return 1; fi
  local n; n=$(journalctl -u haki-nic-watchdog --since -7d -o cat 2>/dev/null | grep -c 'running ifreload')
  if (( n > 0 )); then warn "recovered the network $n time(s) in the last 7 days (haki nic-watchdog log)"
  else ok "no network drops in the last 7 days"; fi
}

module_cmd_log() { journalctl -u haki-nic-watchdog --since -14d --no-pager -o short | tail -40; }
