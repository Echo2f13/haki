# shellcheck shell=bash
# tenant — create and manage containers for other people's apps on the customer network.

MODULE_SUMMARY="Create, publish and remove containers for other people's apps"
MODULE_ABOUT="One command per job for hosting someone's app on the isolated customer network
(module 'customer-net'): a Discord bot, a small website, an API.

    haki tenant new 202 priya-shop small    a Debian container with its own IP, CPU/RAM/disk
                                            limits, isolated from your LAN and other tenants,
                                            starts on boot
    haki tenant list                        who's running, their plan, IP, RAM and published port
    haki tenant publish 202                 let your reverse proxy / tunnel reach its port 80
    haki tenant shell 202                   a root shell inside it, to set up their app
    haki tenant remove 202                  delete it (asks you to type its name)

Container N gets IP $(printf '%s' "${HAKI_TENANT_SUBNET%.0/24}").(101 + N - ${HAKI_TENANT_IDS%-*}) and, when published, host port 20000+N.
Containers are unprivileged and can't see your other guests. Their backups are made by
'backup-usb' like everything else.

Plans (CPU cap / RAM / disk) live in /etc/haki/plans.conf — edit them to suit your hardware."
MODULE_CHANGES="/etc/haki/plans.conf    the plans you sell or give away (created once, then yours to edit)
Containers you create   only when you run 'haki tenant new' (never by installing this module)"
MODULE_REQUIRES="the customer-net module"
MODULE_COMMANDS="haki tenant new <id> <name> [plan] [--private]   create one (--private: don't publish port 80)
haki tenant list                                 every tenant with plan, IP, status, RAM, port
haki tenant shell <id>                           root shell inside it
haki tenant publish <id> [port]                  publish its port (default 80) to your edge machine
haki tenant unpublish <id>                       stop publishing it
haki tenant remove <id>                          delete the container (type its name to confirm)
haki tenant plans                                show the plans"

PLANS=/etc/haki/plans.conf

module_check() {
  module_installed customer-net || { bad "install the customer network first: haki install customer-net"; return 1; }
}

module_install() {
  if [[ -e $PLANS ]]; then skip "$PLANS exists (kept as is)"
  else
    write_file "$PLANS" 0644 <<'EOF'
# haki tenant plans. One per line:  <name> <cores> <cpu cap> <RAM MB> <swap MB> <disk GB>
# "cpu cap" is how much of a core it may use in total (0.5 = half a core), however many cores it sees.
nano    1  0.25   256  128   5
small   1  0.5    512  256  10
medium  2  1     1024  512  20
EOF
  fi
}

module_uninstall() {
  note "Your tenants' containers are not touched. Remove one with: haki tenant remove <id>"
  skip "$PLANS kept"
}

module_status() {
  local ids rc=0 id st
  ids=$(tenant_ids)
  if [[ -z $ids ]]; then skip "no tenants yet. Create one: haki tenant new ${HAKI_TENANT_IDS%-*} <name> small"; return 0; fi
  for id in $ids; do
    st=$(pct status "$id" | awk '{ print $2 }')
    if [[ $st == running ]]; then ok "CT $id $(tenant_name "$id") running"
    elif pct config "$id" | grep -q '^onboot: 1'; then bad "CT $id $(tenant_name "$id") is $st. Fix: pct start $id"; rc=1
    else skip "CT $id $(tenant_name "$id") is $st (not set to start on boot)"; fi
  done
  return $rc
}

# --- helpers ----------------------------------------------------------------------------------
tenant_ids()   { pct list 2>/dev/null | awk 'NR > 1 { print $1 }' | while read -r id; do pct config "$id" | grep -qE '^tags:.*\bcustomer\b' && echo "$id"; done; }
tenant_name()  { pct config "$1" | awk '/^hostname:/ { print $2 }'; }
tenant_plan()  { pct config "$1" | sed -n 's/^tags:.*plan-\([a-z0-9-]*\).*/\1/p'; }
id_lo() { echo "${HAKI_TENANT_IDS%-*}"; }
id_hi() { echo "${HAKI_TENANT_IDS#*-}"; }
tenant_ip()    { echo "${HAKI_TENANT_SUBNET%.0/24}.$(( 101 + $1 - $(id_lo) ))"; }
host_port()    { echo $(( 20000 + $1 )); }
is_tenant()    { pct config "$1" 2>/dev/null | grep -qE '^tags:.*\bcustomer\b'; }
need_tenant()  { [[ ${1:-} =~ ^[0-9]+$ ]] || die "which tenant? e.g. haki tenant ${FUNCNAME[1]#module_cmd_} $(id_lo)"; is_tenant "$1" || die "CT $1 isn't a haki tenant (see: haki tenant list)"; }

plan_line() { awk -v p="$1" '$1 == p && $1 !~ /^#/ { print; exit }' "$PLANS" 2>/dev/null; }

# --- commands ---------------------------------------------------------------------------------
module_cmd_new() {
  local private=0 a args=()
  for a in "$@"; do [[ $a == --private ]] && private=1 || args+=("$a"); done
  set -- "${args[@]+"${args[@]}"}"
  [[ $# -ge 2 ]] || die "usage: haki tenant new <id $(id_lo)-$(id_hi)> <name> [plan] [--private]"
  local id=$1 name=$2 plan=${3:-small}
  need_root; module_installed customer-net || die "install the customer network first: haki install customer-net"
  [[ $id =~ ^[0-9]+$ ]] && (( id >= $(id_lo) && id <= $(id_hi) )) || die "id must be $(id_lo)-$(id_hi) (HAKI_TENANT_IDS)"
  (( $(id_hi) - $(id_lo) < 150 )) || die "HAKI_TENANT_IDS spans more than 150 ids; the /24 can't fit them"
  [[ $name =~ ^[a-z0-9][a-z0-9-]{1,29}$ ]] || die "name: 2-30 lowercase letters, digits and dashes (it becomes the hostname)"
  if pct status "$id" &>/dev/null || qm status "$id" &>/dev/null; then die "id $id is already used by a guest"; fi
  local p; p=$(plan_line "$plan"); [[ -n $p ]] || die "no plan '$plan' in $PLANS. Plans: $(awk '$1 !~ /^#/ && NF { printf "%s ", $1 }' "$PLANS")"
  local cores cap mem swap disk; read -r _ cores cap mem swap disk <<<"$p"
  local ip port storage tmpl
  ip=$(tenant_ip "$id"); port=$(host_port "$id"); storage=$(pick_storage); tmpl=$(pick_template)
  [[ -n $storage ]] || die "no storage for containers found. Set HAKI_TENANT_STORAGE."
  [[ -n $tmpl ]] || die "couldn't find a Debian template. Set HAKI_TENANT_TEMPLATE (see: pveam available)."

  title "New tenant: $name (CT $id)"
  note "plan $plan: $cores core(s) capped at $cap, ${mem} MB RAM (+${swap} MB swap), ${disk} GB on $storage"
  note "network: $ip on $HAKI_TENANT_BRIDGE — internet only; no LAN, no host, no other tenants, no mail (25)"
  note "system: $tmpl, unprivileged, starts on boot"
  if (( private )); then note "not published (--private)"
  else note "published: $HAKI_HOST_IP:$port → $ip:80, reachable only from ${HAKI_EDGE_IP:-your edge machine (not set yet: haki customer-net edge)}"; fi
  confirm "Create it?" || { skip "nothing created"; return 0; }

  if ! pveam list "$HAKI_SNIPPET_STORAGE" | grep -q "$tmpl"; then
    run "download $tmpl (from Proxmox)" pveam download "$HAKI_SNIPPET_STORAGE" "$tmpl" || die "download failed"
  fi
  run "create the container" pct create "$id" "$HAKI_SNIPPET_STORAGE:vztmpl/$tmpl" \
    --hostname "$name" --ostype debian --unprivileged 1 --features nesting=1 \
    --cores "$cores" --cpulimit "$cap" --memory "$mem" --swap "$swap" \
    --rootfs "$storage:$disk" \
    --net0 "name=eth0,bridge=$HAKI_TENANT_BRIDGE,ip=$ip/24,gw=${HAKI_TENANT_SUBNET%.0/24}.1,firewall=0" \
    --nameserver "$HAKI_TENANT_DNS" \
    --hookscript "$HAKI_SNIPPET_STORAGE:snippets/haki-isolate.sh" \
    --tags "haki;customer;plan-$plan" \
    --description "haki tenant **$name** — plan $plan — $ip$( (( private )) || echo " — published on $HAKI_HOST_IP:$port")" \
    --onboot 1 --start 1 || die "pct create failed (nothing else was changed)"
  # The customer network is IPv4-only; prefer IPv4 so apps don't stall trying IPv6 first.
  run "prefer IPv4 inside it" pct exec "$id" -- sh -c 'echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf
    echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99haki-ipv4'
  (( private )) || run "publish port 80 as $HAKI_HOST_IP:$port" /usr/local/sbin/haki-net add "$port" "$ip" 80

  title "Ready"
  echo "  Shell inside it:    haki tenant shell $id     (or: pct enter $id)"
  echo "  Install their app:  apt update && apt install -y <what it needs>, then a systemd service"
  if (( ! private )) && module_installed edge; then
    echo "  Give it a hostname: haki edge add $name.<your domain> $id"
  elif (( ! private )); then
    echo "  Give it a hostname: point your tunnel / reverse proxy at http://$HAKI_HOST_IP:$port"
    echo "                      e.g. cloudflared config.yml:  - hostname: $name.example.com"
    echo "                                                      service: http://$HAKI_HOST_IP:$port"
  fi
}

module_cmd_list() {
  need_root
  local ids id; ids=$(tenant_ids)
  [[ -n $ids ]] || { echo "No tenants yet. Create one: haki tenant new $(id_lo) <name> small"; return 0; }
  printf "\n  ${C_B}%-5s %-18s %-8s %-13s %-9s %-15s %s${C_0}\n" ID NAME PLAN IP STATUS RAM PUBLISHED
  for id in $ids; do
    local st ip mem pub
    st=$(pct status "$id" | awk '{ print $2 }')
    ip=$(pct config "$id" | sed -n 's/^net0:.*ip=\([0-9.]*\).*/\1/p')
    mem="-"
    if [[ $st == running ]]; then
      mem=$(pvesh get "/nodes/$(hostname)/lxc/$id/status/current" --output-format json 2>/dev/null \
            | perl -MJSON -0e 'my $s = decode_json(<STDIN>); printf "%d / %d MB", $s->{mem} / 1048576, $s->{maxmem} / 1048576')
    fi
    pub=$(awk -v ip="$ip" '$2 == ip { printf "%s:%s→%s ", "'"$HAKI_HOST_IP"'", $1, $3 }' /etc/haki/ingress.conf 2>/dev/null)
    local col=$C_YEL; [[ $st == running ]] && col=$C_GRN
    printf -v st '%s%-9s%s' "$col" "$st" "$C_0"   # pad before colouring, so columns line up
    printf "  %-5s %-18s %-8s %-13s %s %-15s %s\n" "$id" "$(tenant_name "$id")" "$(tenant_plan "$id")" "$ip" "$st" "$mem" "${pub:-${C_INK3}private${C_0}}"
  done
  echo
}

module_cmd_shell() { need_root; need_tenant "${1:-}"; exec pct enter "$1"; }

module_cmd_publish() {
  need_root; need_tenant "${1:-}"
  local id=$1 cport=${2:-80} ip
  [[ $cport =~ ^[0-9]+$ ]] || die "port must be a number"
  ip=$(pct config "$id" | sed -n 's/^net0:.*ip=\([0-9.]*\).*/\1/p')
  /usr/local/sbin/haki-net add "$(host_port "$id")" "$ip" "$cport"
  ok "published: $HAKI_HOST_IP:$(host_port "$id") → $ip:$cport"
  [[ -n $HAKI_EDGE_IP ]] || warn "no edge machine set yet, so nothing can reach it: haki customer-net edge"
}

module_cmd_unpublish() {
  need_root; need_tenant "${1:-}"
  /usr/local/sbin/haki-net remove "$(host_port "$1")"
  ok "CT $1 is no longer published"
  local h; h=$(awk -v u="http://$HAKI_HOST_IP:$(host_port "$1")" '$2 == u { printf "%s ", $1 }' /etc/haki/edge-routes.conf 2>/dev/null)
  [[ -z $h ]] || note "These hostnames now show an error page: $h(haki edge remove <hostname>)"
}

module_cmd_remove() {
  need_root; need_tenant "${1:-}"
  local id=$1 name; name=$(tenant_name "$id")
  title "Remove tenant $name (CT $id)"
  warn "This deletes the container and its disk for good. Backups on your USB drive are kept."
  [[ -t 0 ]] || die "run this in a terminal: it asks you to type the tenant's name"
  local typed; read -r -p "  Type '$name' to delete it: " typed
  [[ $typed == "$name" ]] || { skip "names don't match; nothing deleted"; return 0; }
  run "stop it" pct stop "$id" || true
  run "delete it" pct destroy "$id" --purge 1 || die "pct destroy failed"
  local h
  for h in $(awk -v u="http://$HAKI_HOST_IP:$(host_port "$id")" '$2 == u { print $1 }' /etc/haki/edge-routes.conf 2>/dev/null); do
    run "stop publishing https://$h" "$HAKI_ROOT/haki" edge remove "$h" || true
  done
  if grep -q "^$(host_port "$id") " /etc/haki/ingress.conf 2>/dev/null; then
    run "unpublish its port" /usr/local/sbin/haki-net remove "$(host_port "$id")"
  fi
  ok "$name removed"
}

module_cmd_plans() {
  [[ -r $PLANS ]] || die "no $PLANS yet: haki install tenant"
  printf "\n  ${C_B}%-8s %-6s %-8s %-8s %-8s %s${C_0}\n" PLAN CORES "CPU CAP" RAM SWAP DISK
  awk '$1 !~ /^#/ && NF >= 6 { printf "  %-8s %-6s %-8s %-8s %-8s %s\n", $1, $2, $3, $4 " MB", $5 " MB", $6 " GB" }' "$PLANS"
  echo; note "Edit $PLANS to change them. Existing tenants keep their size (change one with: pct set <id> --memory …)."
}
