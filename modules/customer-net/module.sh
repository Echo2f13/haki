# shellcheck shell=bash
# customer-net — an isolated network for hosting other people's apps on your server.

MODULE_SUMMARY="An isolated network for hosting other people's apps"
MODULE_ABOUT="Want to host a friend's Discord bot or a small website without giving them a way into your
home network? This creates a separate bridge ($HAKI_TENANT_BRIDGE, $HAKI_TENANT_SUBNET) with no
physical port, and a firewall (haki-net, nftables table 'inet haki') around it:

    From a container on it to…                      result
    the internet (web, DNS, APIs, anything)         allowed, NAT'd through the host
    your home LAN, router, any private address      blocked
    the Proxmox host itself (web UI, SSH)           blocked
    other containers on it                          blocked (bridge port isolation)
    outbound mail, port 25                          blocked (no spam from your IP)

Nothing on your LAN or the internet can reach those containers. The one exception is the machine
you name in HAKI_EDGE_IP (your reverse proxy or Cloudflare Tunnel): it reaches a published app
through one port on the host, e.g. $HAKI_HOST_IP:20201 → container port 80. Nothing is exposed to
the internet unless you point your proxy or tunnel at it.

The 'tenant' module creates containers on this network: haki info tenant.

What it changes on the network: it adds a new bridge and applies it with 'ifreload -a' — the
Proxmox-safe way that keeps running VMs plugged in. Your existing bridges are not touched."
MODULE_CHANGES="/etc/network/interfaces.d/haki-customers   the bridge ($HAKI_TENANT_BRIDGE, gateway ${HAKI_TENANT_SUBNET%.0/*}.1)
/usr/local/sbin/haki-net                    builds and loads the firewall
/etc/systemd/system/haki-net.service        loads it at boot, before the bridge comes up
/etc/sysctl.d/90-haki-customer-net.conf     net.ipv4.ip_forward = 1 (the host routes for the bridge)
/etc/haki/ingress.conf                      published ports (host port → container ip and port)
<storage>/snippets/haki-isolate.sh          hookscript that isolates containers from each other
storage.cfg: '$HAKI_SNIPPET_STORAGE' may hold snippets   Proxmox needs this for hookscripts"
MODULE_REQUIRES="a free /24 subnet (default 10.10.0.0/24) that isn't your LAN"
MODULE_COMMANDS="haki customer-net edge [ip]     set the machine allowed to reach published apps (detects HAKI_EDGE_VM)
haki customer-net ports         published ports
haki customer-net check         validate the firewall rules without applying them"

NET_FILE=/etc/network/interfaces.d/haki-customers
SYSCTL_FILE=/etc/sysctl.d/90-haki-customer-net.conf

cn_prefix()  { printf '%s' "${HAKI_TENANT_SUBNET%.0/24}"; }
cn_gateway() { printf '%s.1' "$(cn_prefix)"; }
snippet_dir() {
  local p; p=$(pvesh get "/storage/$HAKI_SNIPPET_STORAGE" --output-format json 2>/dev/null \
               | perl -MJSON -0e 'my $s = decode_json(<STDIN>); print $s->{path} // ""')
  [[ -n $p ]] && printf '%s/snippets' "$p"
}
# guests (VMs or containers) with a NIC on the customer bridge
bridge_users() { grep -lE "^net[0-9]+:.*bridge=$HAKI_TENANT_BRIDGE(,|$)" /etc/pve/lxc/*.conf /etc/pve/qemu-server/*.conf 2>/dev/null | sed -E 's#.*/([0-9]+)\.conf#\1#'; }

module_check() {
  local rc=0
  [[ $HAKI_TENANT_SUBNET =~ ^([0-9]{1,3}\.){3}0/24$ ]] \
    || { bad "HAKI_TENANT_SUBNET must be a /24 ending in .0/24 (now: $HAKI_TENANT_SUBNET)"; rc=1; }
  grep -qE '^\s*source\s+/etc/network/interfaces\.d/\*' /etc/network/interfaces \
    || { bad "/etc/network/interfaces doesn't include interfaces.d."; note "Add this line at the end of it: source /etc/network/interfaces.d/*"; rc=1; }
  if grep -qE "^\s*(auto|iface)\s+$HAKI_TENANT_BRIDGE\b" /etc/network/interfaces; then
    bad "$HAKI_TENANT_BRIDGE is already defined in /etc/network/interfaces."
    note "Pick another name: set HAKI_TENANT_BRIDGE=\"vmbr9\" (for example) in /etc/haki/haki.conf"; rc=1
  fi
  local lan; lan=$(bridge_ip "$HAKI_BRIDGE")
  [[ -n $lan && ${lan%.*} == "$(cn_prefix)" ]] \
    && { bad "$HAKI_TENANT_SUBNET overlaps your LAN ($lan). Set another HAKI_TENANT_SUBNET."; rc=1; }
  if ip -4 -o addr show | grep -v " $HAKI_TENANT_BRIDGE " | grep -q " $(cn_prefix)\."; then
    bad "another interface already uses $(cn_prefix).x. Set another HAKI_TENANT_SUBNET."; rc=1
  fi
  [[ -n $(snippet_dir) ]] || { bad "storage '$HAKI_SNIPPET_STORAGE' isn't a directory storage. Set HAKI_SNIPPET_STORAGE."; rc=1; }
  return $rc
}

module_install() {
  step "Routing for the customer network"
  write_file "$SYSCTL_FILE" 0644 <<'EOF'
# Added by haki (module: customer-net). The host routes traffic for the customer bridge.
net.ipv4.ip_forward = 1
EOF
  planning || run "turn on forwarding now" sysctl -q --load "$SYSCTL_FILE"

  step "Firewall (haki-net)"
  install_file "$MODULE_DIR/files/haki-net" /usr/local/sbin/haki-net 0755
  write_file /etc/systemd/system/haki-net.service 0644 <<'EOF'
[Unit]
Description=haki: customer network firewall and NAT (haki-net)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/haki-net apply

[Install]
WantedBy=multi-user.target
EOF
  if planning; then plan "enable haki-net.service and load the rules"
  else
    run "load the rules" bash -c 'systemctl daemon-reload && systemctl enable haki-net.service >/dev/null 2>&1 && systemctl restart haki-net.service'
  fi
  [[ -n $HAKI_EDGE_IP ]] || note "No HAKI_EDGE_IP yet, so published apps aren't reachable. Later: haki customer-net edge"

  step "Keep containers apart (hookscript)"
  local content dir
  content=$(pvesh get "/storage/$HAKI_SNIPPET_STORAGE" --output-format json | perl -MJSON -0e 'print decode_json(<STDIN>)->{content}')
  if [[ ,$content, == *,snippets,* ]]; then skip "storage '$HAKI_SNIPPET_STORAGE' already allows snippets"
  elif planning; then plan "allow snippets on storage '$HAKI_SNIPPET_STORAGE' (content: $content,snippets)"
  else run "allow snippets on storage '$HAKI_SNIPPET_STORAGE'" pvesm set "$HAKI_SNIPPET_STORAGE" --content "$content,snippets"; fi
  dir=$(snippet_dir)
  install_file "$MODULE_DIR/files/haki-isolate.sh" "$dir/haki-isolate.sh" 0755

  step "The bridge ($HAKI_TENANT_BRIDGE, $HAKI_TENANT_SUBNET)"
  write_file "$NET_FILE" 0644 <<EOF
# Added by haki (module: customer-net): the customer network. No physical port; the host NATs
# it to the internet and haki-net keeps it away from the LAN, the host and each other.
auto $HAKI_TENANT_BRIDGE
iface $HAKI_TENANT_BRIDGE inet static
	address $(cn_gateway)/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0
EOF
  if planning; then plan "apply it with 'ifreload -a' (running VMs stay plugged in)"; return 0; fi
  if ip -4 -o addr show dev "$HAKI_TENANT_BRIDGE" 2>/dev/null | grep -q " $(cn_gateway)/"; then
    skip "$HAKI_TENANT_BRIDGE is already up"
  else
    run "bring up $HAKI_TENANT_BRIDGE (ifreload -a)" ifreload -a
  fi
}

module_uninstall() {
  local users; users=$(bridge_users | tr '\n' ' ')
  if [[ -n $users ]]; then
    bad "guests still use $HAKI_TENANT_BRIDGE: $users"
    note "Remove them first (haki tenant remove <id>), or move them to another bridge."
    return 1
  fi
  if ! planning; then
    systemctl disable --now haki-net.service >/dev/null 2>&1
    nft delete table inet haki 2>/dev/null && ok "firewall rules unloaded"
  else plan "unload the firewall rules"; fi
  remove_file /etc/systemd/system/haki-net.service
  remove_file /usr/local/sbin/haki-net
  remove_file "$NET_FILE"
  if planning; then plan "remove $HAKI_TENANT_BRIDGE (ifreload -a)"
  else ifreload -a; ip link show "$HAKI_TENANT_BRIDGE" >/dev/null 2>&1 && ip link del "$HAKI_TENANT_BRIDGE"; ok "removed $HAKI_TENANT_BRIDGE"; fi
  remove_file "$(snippet_dir)/haki-isolate.sh"
  remove_file "$SYSCTL_FILE"
  note "IP forwarding stays on until the next reboot. Published ports are kept in /etc/haki/ingress.conf."
  planning || systemctl daemon-reload
}

module_status() {
  local rc=0 n
  if nft list table inet haki >/dev/null 2>&1; then ok "firewall loaded (nftables table inet haki)"
  else bad "firewall not loaded — the network is NOT isolated. Fix: haki-net check && haki-net apply"; rc=1; fi
  if ip -4 -o addr show dev "$HAKI_TENANT_BRIDGE" 2>/dev/null | grep -q " $(cn_gateway)/"; then ok "$HAKI_TENANT_BRIDGE up ($(cn_gateway)/24)"
  else bad "$HAKI_TENANT_BRIDGE is not up. Fix: ifreload -a"; rc=1; fi
  [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]] && ok "forwarding on" || { bad "forwarding off — containers have no internet. Fix: sysctl -w net.ipv4.ip_forward=1"; rc=1; }
  [[ -x $(snippet_dir)/haki-isolate.sh ]] && ok "isolation hookscript installed" || { bad "hookscript missing. Fix: haki install customer-net"; rc=1; }
  local ports
  n=$(bridge_users | wc -l); ports=$(grep -cvE '^\s*(#|$)' /etc/haki/ingress.conf 2>/dev/null || true)
  ok "$n guest(s) on $HAKI_TENANT_BRIDGE, ${ports:-0} published port(s)"
  local id
  for id in $(bridge_users); do
    grep -q '^hookscript:.*haki-isolate.sh' "/etc/pve/lxc/$id.conf" "/etc/pve/qemu-server/$id.conf" 2>/dev/null \
      || { warn "guest $id is on $HAKI_TENANT_BRIDGE without the isolation hookscript: it can reach other containers."; note "Fix: pct set $id --hookscript $HAKI_SNIPPET_STORAGE:snippets/haki-isolate.sh, then restart it"; }
  done
  if [[ -z $HAKI_EDGE_IP ]]; then skip "no edge machine set: published apps aren't reachable (haki customer-net edge)"
  else
    local cur; cur=$(edge_vm_ip)
    if [[ -n $cur && $cur != "$HAKI_EDGE_IP" ]]; then
      warn "the edge VM ($HAKI_EDGE_VM) is now at $cur, but published apps only accept $HAKI_EDGE_IP."
      note "Fix: haki customer-net edge $cur"
    else ok "published apps accept traffic from $HAKI_EDGE_IP${HAKI_EDGE_VM:+ (VM $HAKI_EDGE_VM)}"; fi
  fi
  return $rc
}

# The edge VM's current LAN address, found by its MAC (works with DHCP). Empty if unknown.
edge_vm_ip() {
  [[ -n $HAKI_EDGE_VM ]] && command -v qm >/dev/null || return 0
  local mac ip
  mac=$(qm config "$HAKI_EDGE_VM" 2>/dev/null | sed -n 's/^net0: [a-z0-9]*=\([0-9A-Fa-f:]\{17\}\),.*/\1/p' | tr 'A-F' 'a-f')
  [[ -n $mac ]] || return 0
  ip=$(ip neigh show dev "$HAKI_BRIDGE" | awk -v m="$mac" 'tolower($3) == m && $1 ~ /\./ { print $1; exit }')
  if [[ -z $ip ]]; then   # not in the neighbour table yet: ping the LAN once to fill it
    local lan; lan=$(bridge_ip "$HAKI_BRIDGE"); lan=${lan%.*}
    [[ -n $lan ]] && { for i in $(seq 1 254); do ping -c1 -W1 "$lan.$i" >/dev/null 2>&1 & done; wait; }
    ip=$(ip neigh show dev "$HAKI_BRIDGE" | awk -v m="$mac" 'tolower($3) == m && $1 ~ /\./ { print $1; exit }')
  fi
  printf '%s' "$ip"
}

module_cmd_edge() {
  local ip=${1:-}
  if [[ -z $ip ]]; then
    if [[ -n $HAKI_EDGE_VM ]]; then
      step "Looking for VM $HAKI_EDGE_VM on $HAKI_BRIDGE"
      ip=$(edge_vm_ip)
      [[ -n $ip ]] && ok "VM $HAKI_EDGE_VM is at $ip" || warn "couldn't find VM $HAKI_EDGE_VM's address (is it running?)"
    fi
    ask "Address allowed to reach published apps (your reverse proxy / tunnel machine)" "${ip:-$HAKI_EDGE_IP}"
    ip=$REPLY
  fi
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "'$ip' is not an IPv4 address"
  [[ $ip == "$HAKI_EDGE_IP" ]] && { skip "HAKI_EDGE_IP is already $ip"; return 0; }
  conf_set HAKI_EDGE_IP "$ip"; ok "HAKI_EDGE_IP=$ip"
  if [[ -x /usr/local/sbin/haki-net ]]; then run "reload the firewall" /usr/local/sbin/haki-net apply; fi
  note "Tip: give that machine a fixed address (DHCP reservation) so this doesn't change again."
}
module_cmd_ports() { /usr/local/sbin/haki-net list; echo; note "format: <host port> <container ip> <container port>. Reachable only from $(/usr/local/sbin/haki-net edge)"; }
module_cmd_check() { /usr/local/sbin/haki-net check; }
