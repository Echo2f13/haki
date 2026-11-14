# shellcheck shell=bash
# edge — publish websites through a Cloudflare Tunnel from a small container, with no port forwarding.

MODULE_SUMMARY="Public websites through Cloudflare Tunnel, no port forwarding"
MODULE_ABOUT="Gives your sites a public https address without opening a single port on your router.
It works behind CGNAT and on connections without a public IP.

A small Debian container on your LAN ($HAKI_BRIDGE) runs only cloudflared, which connects out
to Cloudflare. Cloudflare sends visitors of your hostnames down that connection, and the edge
passes each one to the app you chose. You manage it all from the host:

    haki edge login                        connect it to your Cloudflare account (a browser link)
    haki edge add shop.example.com 202     tenant 202's published port, at that address, with https
    haki edge add wiki.example.com http://192.168.1.50:8080     or anything else it can reach
    haki edge list / remove

With 'customer-net', this container becomes the one machine allowed to reach published tenant
ports (HAKI_EDGE_IP). It gets a fixed address, so that never drifts with DHCP.

You need a free Cloudflare account with your domain on it. The login creates a certificate for
that domain inside the container (root-only, never shown, never leaves it)."
MODULE_CHANGES="Container ${HAKI_EDGE_CT:-120} ('haki-edge')             Debian, 256 MB, 0.5 core, fixed LAN address, starts first on boot
  inside it: cloudflared                Cloudflare's package repository, kept updated by unattended-upgrades
  inside it: /etc/cloudflared/          the tunnel config, made by haki from the routes below
/etc/haki/edge-routes.conf              your hostnames and where each one goes
/etc/haki/haki.conf                     HAKI_EDGE_CT, HAKI_EDGE_ADDR (and HAKI_EDGE_IP with customer-net)"
MODULE_REQUIRES="a domain on a (free) Cloudflare account; a free address on your LAN for the container"
MODULE_COMMANDS="haki edge login                      connect to Cloudflare and create the tunnel
haki edge add <hostname> <tenant-id|url>   publish a hostname (adds its DNS record too)
haki edge remove <hostname>          stop publishing it
haki edge list                       hostnames and where they go
haki edge logs                       the tunnel's recent log"

ROUTES=/etc/haki/edge-routes.conf
EDGE_NAME=haki-edge
CF_DIR=/etc/cloudflared
CF_CERT=/root/.cloudflared/cert.pem

# --- helpers ----------------------------------------------------------------------------------
edge_exists() { [[ -n $HAKI_EDGE_CT ]] && pct config "$HAKI_EDGE_CT" 2>/dev/null | grep -qE '^tags:.*\bedge\b'; }
edge_running() { pct status "$HAKI_EDGE_CT" 2>/dev/null | grep -q running; }
in_edge() { pct exec "$HAKI_EDGE_CT" -- env HOME=/root LC_ALL=C "$@"; }
lan_prefix() { ip -4 -o addr show "$HAKI_BRIDGE" | awk '{ split($4, a, "/"); print a[2]; exit }'; }
logged_in() { in_edge test -s "$CF_CERT"; }
tunnel_id() { in_edge sed -n 's/.*"TunnelID":"\([^"]*\)".*/\1/p' "$CF_DIR/tunnel.json" 2>/dev/null; }
route_count() { local n; n=$(grep -cvE '^\s*(#|$)' "$ROUTES" 2>/dev/null || true); echo "${n:-0}"; }
valid_host() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
need_edge() { need_root; edge_exists || die "no edge container yet: haki install edge"; edge_running || die "the edge container (CT $HAKI_EDGE_CT) isn't running: pct start $HAKI_EDGE_CT"; }

# Is this address free on the LAN? (ping, then look for any answer in the neighbour table)
addr_free() {
  ping -c1 -W1 "$1" >/dev/null 2>&1 && return 1
  ! ip neigh show "$1" dev "$HAKI_BRIDGE" | grep -q lladdr
}

# ct_put <path> <mode>: put stdin into the container at <path> when it differs.
ct_put() {
  local path=$1 mode=$2 tmp; tmp=$(mktemp); cat > "$tmp"
  if edge_exists && in_edge cat "$path" 2>/dev/null | cmp -s - "$tmp"; then skip "CT $HAKI_EDGE_CT: $path is up to date"; rm -f "$tmp"; return 0; fi
  if planning; then plan "write $path inside the edge container"; rm -f "$tmp"; return 0; fi
  pct push "$HAKI_EDGE_CT" "$tmp" "$path" --perms "$mode" && ok "CT $HAKI_EDGE_CT: wrote $path"; rm -f "$tmp"
}

render_config() {
  local id=$1
  echo "# Made by haki from $ROUTES on the Proxmox host. Change routes with: haki edge add/remove"
  echo "tunnel: $id"
  echo "credentials-file: $CF_DIR/tunnel.json"
  echo "metrics: 127.0.0.1:20241"
  echo "no-autoupdate: true"
  echo "ingress:"
  awk 'NF == 2 && $1 !~ /^#/ { printf "  - hostname: %s\n    service: %s\n", $1, $2 }' "$ROUTES" 2>/dev/null
  echo "  - service: http_status:404"
}

# Write the tunnel config from the routes, check it, and restart cloudflared. Returns 1 if invalid.
apply_routes() {
  local id; id=$(tunnel_id)
  [[ -n $id ]] || { skip "not connected to Cloudflare yet (haki edge login); routes will apply then"; return 0; }
  render_config "$id" | ct_put "$CF_DIR/config.yml" 0644
  planning && return 0
  in_edge cloudflared tunnel --config "$CF_DIR/config.yml" ingress validate >/dev/null 2>&1 || { bad "cloudflared rejected the config"; return 1; }
  in_edge systemctl enable cloudflared.service >/dev/null 2>&1
  in_edge systemctl restart cloudflared.service && ok "tunnel restarted with $(route_count) route(s)"
}

# Connections the tunnel holds to Cloudflare (0 = down), from cloudflared's local /ready.
tunnel_connections() {
  in_edge bash -c 'exec 3<>/dev/tcp/127.0.0.1/20241 && printf "GET /ready HTTP/1.0\r\n\r\n" >&3 && cat <&3' 2>/dev/null \
    | sed -n 's/.*"readyConnections":\([0-9]*\).*/\1/p'
}

# --- module -----------------------------------------------------------------------------------
module_check() {
  [[ -n $HAKI_GATEWAY ]] || { bad "HAKI_GATEWAY isn't set (run: haki init)"; return 1; }
  if [[ -n $HAKI_EDGE_CT ]] && ! edge_exists && { pct status "$HAKI_EDGE_CT" &>/dev/null || qm status "$HAKI_EDGE_CT" &>/dev/null; }; then
    bad "id $HAKI_EDGE_CT (HAKI_EDGE_CT) is used by another guest. Pick a free one in $HAKI_CONF."; return 1
  fi
  [[ -z $HAKI_EDGE_ADDR || $HAKI_EDGE_ADDR =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { bad "HAKI_EDGE_ADDR='$HAKI_EDGE_ADDR' is not an IPv4 address"; return 1; }
  return 0
}

module_install() {
  step "The edge container"
  local id=${HAKI_EDGE_CT:-120} addr=$HAKI_EDGE_ADDR
  if edge_exists; then skip "CT $HAKI_EDGE_CT ($EDGE_NAME) exists at $addr"
  else
    if [[ -z $HAKI_EDGE_CT ]]; then ask "Container id for the edge" "$id"; id=$REPLY; fi
    [[ $id =~ ^[0-9]+$ ]] || die "'$id' is not a container id"
    if pct status "$id" &>/dev/null || qm status "$id" &>/dev/null; then die "id $id is already used by a guest; choose another"; fi
    if [[ -z $addr ]]; then
      note "It needs a fixed address on your LAN that nothing else uses — outside your router's DHCP range"
      note "(or reserve it on the router). Your host is $HAKI_HOST_IP, the router $HAKI_GATEWAY."
      if planning; then addr="<asked at install>"; else ask "Address for the edge container" ""; addr=$REPLY; fi
    fi
    if [[ $addr == "<asked at install>" ]]; then
      plan "create CT $id '$EDGE_NAME' on $HAKI_BRIDGE at a fixed address (asked at install): 1 core capped at 0.5, 256 MB, 4 GB, starts first on boot"
      plan "set HAKI_EDGE_CT and HAKI_EDGE_ADDR in $HAKI_CONF"
    else
      [[ $addr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "the edge container needs an address (set HAKI_EDGE_ADDR in $HAKI_CONF, or answer the question)"
      [[ $addr != "$HAKI_HOST_IP" && $addr != "$HAKI_GATEWAY" ]] || die "$addr is the host or the router"
      ip route get "$addr" 2>/dev/null | grep -q "dev $HAKI_BRIDGE" && ! ip route get "$addr" | grep -q ' via ' \
        || die "$addr isn't on your LAN ($HAKI_BRIDGE)"
      addr_free "$addr" || die "something already answers at $addr. Pick a free address."
      local storage tmpl; storage=$(pick_storage); tmpl=$(pick_template)
      [[ -n $storage && -n $tmpl ]] || die "no container storage or Debian template found (see HAKI_TENANT_STORAGE / HAKI_TENANT_TEMPLATE)"
      if planning; then
        plan "create CT $id '$EDGE_NAME' at $addr/$(lan_prefix) on $HAKI_BRIDGE: 1 core capped at 0.5, 256 MB, 4 GB on $storage, starts first on boot"
      else
        pveam list "$HAKI_SNIPPET_STORAGE" | grep -q "$tmpl" || run "download $tmpl" pveam download "$HAKI_SNIPPET_STORAGE" "$tmpl" || die "download failed"
        run "create CT $id ($EDGE_NAME, $addr)" pct create "$id" "$HAKI_SNIPPET_STORAGE:vztmpl/$tmpl" \
          --hostname "$EDGE_NAME" --ostype debian --unprivileged 1 --features nesting=1 \
          --cores 1 --cpulimit 0.5 --memory 256 --swap 128 --rootfs "$storage:4" \
          --net0 "name=eth0,bridge=$HAKI_BRIDGE,ip=$addr/$(lan_prefix),gw=$HAKI_GATEWAY,firewall=0" \
          --nameserver "$HAKI_TENANT_DNS" --tags "haki;edge" \
          --description "haki **edge**: Cloudflare Tunnel (cloudflared). Managed from the host: haki edge" \
          --onboot 1 --startup order=1 --start 1 || die "pct create failed (nothing else was changed)"
      fi
      conf_set HAKI_EDGE_CT "$id"; conf_set HAKI_EDGE_ADDR "$addr"
    fi
  fi

  step "cloudflared inside it"
  if ! planning && edge_exists && in_edge test -x /usr/bin/cloudflared; then skip "cloudflared installed ($(in_edge cloudflared --version 2>/dev/null | awk '{ print $3 }'))"
  elif planning; then plan "install cloudflared from pkg.cloudflare.com, and unattended-upgrades to keep it updated"
  else
    run "turn off SSH inside it (you manage it from the host)" in_edge systemctl disable --now -q ssh.socket ssh.service || true
    run "install cloudflared (Cloudflare's apt repository)" in_edge bash -ec '
      export DEBIAN_FRONTEND=noninteractive
      apt-get -qq update && apt-get -qq install -y curl ca-certificates >/dev/null
      curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg -o /usr/share/keyrings/cloudflare-public-v2.gpg
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
        > /etc/apt/sources.list.d/cloudflared.list
      apt-get -qq update && apt-get -qq install -y cloudflared unattended-upgrades >/dev/null' \
      || die "couldn't install cloudflared (does the container have internet? pct enter $HAKI_EDGE_CT)"
  fi
  ct_put /etc/apt/apt.conf.d/52haki-cloudflared 0644 <<'EOF'
// haki: let unattended-upgrades update cloudflared too (Debian security updates are on by default).
Unattended-Upgrade::Origins-Pattern { "origin=cloudflared"; };
EOF
  ct_put /etc/systemd/system/cloudflared.service 0644 <<EOF
[Unit]
Description=Cloudflare Tunnel (haki edge)
After=network-online.target
Wants=network-online.target
ConditionPathExists=$CF_DIR/config.yml

[Service]
ExecStart=/usr/bin/cloudflared --no-autoupdate --config $CF_DIR/config.yml tunnel run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  planning || in_edge systemctl daemon-reload

  step "Routes"
  if [[ -e $ROUTES ]]; then skip "$ROUTES exists"
  else write_file "$ROUTES" 0644 <<'EOF'
# haki edge routes: <hostname> <where it goes>. Managed with: haki edge add / remove
EOF
  fi
  if ! planning && edge_exists && logged_in; then apply_routes || true; fi

  if module_installed customer-net; then
    step "Published tenant ports"
    local new=${HAKI_EDGE_ADDR:-$addr}
    if [[ $HAKI_EDGE_IP == "$new" ]]; then skip "HAKI_EDGE_IP is already $new"
    else
      [[ -n $HAKI_EDGE_IP ]] && note "Until now they accepted $HAKI_EDGE_IP; from now on only the edge container."
      conf_set HAKI_EDGE_IP "$new"
      if planning; then plan "reload the customer firewall (haki-net apply)"; else run "reload the customer firewall" /usr/local/sbin/haki-net apply; fi
    fi
  fi

  if ! planning && ! logged_in; then
    title "Next: connect it to Cloudflare"
    echo "  haki edge login        opens a link: log in, pick your domain, done"
  fi
}

module_uninstall() {
  if ! edge_exists; then skip "no edge container"; remove_file "$ROUTES"; return 0; fi
  if planning; then plan "delete CT $HAKI_EDGE_CT ($EDGE_NAME) and its disk"; plan "remove $ROUTES"; return 0; fi
  warn "This deletes the edge container: every hostname below stops working."
  grep -vsE '^\s*(#|$)' "$ROUTES" | sed 's/^/      /'
  [[ -t 0 ]] || die "run this in a terminal: it asks you to type '$EDGE_NAME'"
  local typed; read -r -p "  Type '$EDGE_NAME' to delete it: " typed
  [[ $typed == "$EDGE_NAME" ]] || die "names don't match; nothing removed"
  local tid; tid=$(tunnel_id)
  run "stop it" pct stop "$HAKI_EDGE_CT" || true
  run "delete it" pct destroy "$HAKI_EDGE_CT" --purge 1 || die "pct destroy failed"
  remove_file "$ROUTES"
  note "The tunnel ${tid:+($tid) }and its DNS records stay in your Cloudflare account:"
  note "delete them under Zero Trust → Networks → Tunnels, and DNS → Records."
  [[ $HAKI_EDGE_IP == "$HAKI_EDGE_ADDR" ]] && note "Published tenant ports now reach nothing. Point them elsewhere: haki customer-net edge"
}

module_status() {
  local rc=0 n
  if ! edge_exists; then bad "no edge container. Fix: haki install edge"; return 1; fi
  if ! edge_running; then bad "CT $HAKI_EDGE_CT ($EDGE_NAME) is stopped. Fix: pct start $HAKI_EDGE_CT"; return 1; fi
  ok "CT $HAKI_EDGE_CT ($EDGE_NAME) running at $HAKI_EDGE_ADDR"
  if ! logged_in; then warn "not connected to Cloudflare yet. Next: haki edge login"; return 0; fi
  local i; for i in 1 2 3 4 5; do   # just after a restart cloudflared needs a few seconds to connect
    n=$(tunnel_connections); [[ ${n:-0} -gt 0 ]] && break; sleep 2
  done
  if [[ ${n:-0} -gt 0 ]]; then ok "tunnel connected ($n connections to Cloudflare)"
  elif in_edge systemctl is-active -q cloudflared.service; then bad "cloudflared runs but has no connection to Cloudflare. See: haki edge logs"; rc=1
  else bad "cloudflared isn't running. Fix: haki edge logs, then pct exec $HAKI_EDGE_CT -- systemctl restart cloudflared"; rc=1; fi
  ok "$(route_count) hostname(s) published (haki edge list)"
  if module_installed customer-net && [[ $HAKI_EDGE_IP != "$HAKI_EDGE_ADDR" ]]; then
    warn "published tenant ports accept $HAKI_EDGE_IP, not this edge ($HAKI_EDGE_ADDR). Fix: haki customer-net edge $HAKI_EDGE_ADDR"
  fi
  return $rc
}

# --- commands ---------------------------------------------------------------------------------
module_cmd_login() {
  need_edge
  if logged_in; then skip "already connected to Cloudflare (certificate in CT $HAKI_EDGE_CT:$CF_CERT)"
  else
    step "Connect to Cloudflare"
    echo "  Open the link below, log in, pick the domain your sites will use, and click Authorize."
    echo "  Each link works for about 9 minutes; this waits here until you've done it."
    local try
    for try in 1 2 3; do
      (( try > 1 )) && warn "that link expired — here's a fresh one ($try of 3)"
      in_edge cloudflared tunnel login 2>&1 | grep --line-buffered -E '^https://' | sed -u 's/^/  /' || true
      logged_in && break
    done
    logged_in || die "not connected (no link was authorized). Run haki edge login again when you're ready."
    in_edge chmod 600 "$CF_CERT"; ok "connected; certificate saved inside the container (root-only)"
  fi
  if [[ -n $(tunnel_id) ]]; then skip "tunnel '$HAKI_EDGE_TUNNEL' ready ($(tunnel_id))"
  else
    in_edge mkdir -p "$CF_DIR"
    if in_edge cloudflared tunnel create --credentials-file "$CF_DIR/tunnel.json" "$HAKI_EDGE_TUNNEL" >/dev/null 2>&1; then
      ok "created tunnel '$HAKI_EDGE_TUNNEL' ($(tunnel_id))"
    elif in_edge cloudflared tunnel token --cred-file "$CF_DIR/tunnel.json" "$HAKI_EDGE_TUNNEL" >/dev/null 2>&1; then
      ok "reusing your existing tunnel '$HAKI_EDGE_TUNNEL' ($(tunnel_id))"
    else die "couldn't create the tunnel '$HAKI_EDGE_TUNNEL' (see: pct exec $HAKI_EDGE_CT -- cloudflared tunnel list)"; fi
    in_edge chmod 600 "$CF_DIR/tunnel.json"
  fi
  apply_routes || die "the tunnel config is invalid; check $ROUTES"
  ok "ready. Publish something: haki edge add <hostname> <tenant-id|url>"
}

module_cmd_add() {
  [[ $# -eq 2 ]] || die "usage: haki edge add <hostname> <tenant-id|url>   e.g. haki edge add shop.example.com 202"
  need_edge; logged_in || die "connect to Cloudflare first: haki edge login"
  local host=${1,,} target=$2 url
  valid_host "$host" || die "'$1' isn't a hostname like shop.example.com"
  grep -q "^$host " "$ROUTES" 2>/dev/null && die "$host is already published (haki edge list)"
  if [[ $target =~ ^[0-9]+$ ]]; then
    local port=$((20000 + target))
    grep -q "^$port " /etc/haki/ingress.conf 2>/dev/null || die "tenant $target isn't published. First: haki tenant publish $target"
    url="http://$HAKI_HOST_IP:$port"
  elif [[ $target =~ ^https?://[^[:space:]]+$ ]]; then url=$target
  else die "where should $host go? A tenant id (202) or a URL (http://192.168.1.50:8080)"; fi

  step "Publish $host → $url"
  local out
  if out=$(in_edge cloudflared tunnel route dns "$HAKI_EDGE_TUNNEL" "$host" 2>&1); then ok "DNS: $host → tunnel '$HAKI_EDGE_TUNNEL'"
  else
    bad "Cloudflare refused the DNS record for $host:"; echo "$out" | grep -iE 'err|exist' | tail -2 | sed 's/^/      /'
    note "If $host already has a DNS record, delete it in Cloudflare → DNS → Records, then try again."
    note "The domain must be the one you picked at login."
    return 1
  fi
  echo "$host $url" >> "$ROUTES"
  if ! apply_routes; then sed -i "/^$host /d" "$ROUTES"; apply_routes || true; die "route not added"; fi
  ok "https://$host is live (give DNS a minute)"
}

module_cmd_remove() {
  [[ $# -eq 1 ]] || die "usage: haki edge remove <hostname>"
  need_edge
  local host=${1,,}
  grep -q "^$host " "$ROUTES" 2>/dev/null || die "$host isn't published (haki edge list)"
  backup_file "$ROUTES"; sed -i "/^$host /d" "$ROUTES"
  apply_routes || die "couldn't apply the change"
  ok "$host is no longer published (visitors get a 404)"
  note "Its DNS record still points at the tunnel; delete it in Cloudflare → DNS → Records if you like."
}

module_cmd_list() {
  local rows; rows=$(grep -vsE '^\s*(#|$)' "$ROUTES")
  [[ -n $rows ]] || { echo "No hostnames yet. Add one: haki edge add <hostname> <tenant-id|url>"; return 0; }
  printf "\n  ${C_B}%-34s %s${C_0}\n" HOSTNAME "GOES TO"
  awk '{ printf "  %-34s %s\n", "https://" $1, $2 }' <<<"$rows"; echo
}

module_cmd_logs() { need_edge; in_edge journalctl -u cloudflared.service -n "${1:-40}" --no-pager; }
