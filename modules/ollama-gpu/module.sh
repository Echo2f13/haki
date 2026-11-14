# shellcheck shell=bash disable=SC2034
# ollama-gpu — a local AI model server on your NVIDIA card, through GPU passthrough to a VM.

MODULE_SUMMARY="Local AI models (ollama) on your NVIDIA GPU, in a VM"
MODULE_ABOUT="Runs ollama — an API for open models like Qwen, Llama and Gemma — in a VM that owns your
NVIDIA graphics card, so models run at GPU speed and your host stays clean.

On the host it gives the card to the VM (GPU passthrough): it finds the card, checks it can be
passed on its own (IOMMU group), and binds it to vfio-pci at boot. That needs one reboot.
Then it creates an Ubuntu VM from the official cloud image; on first boot it installs the
NVIDIA driver and ollama by itself — no installer to click through.

Already have an ollama VM with the GPU (HAKI_OLLAMA_VM)? It's adopted as is: nothing in it is
changed, and the commands below work with it.

ollama's API has no password. VMs made here only accept it from the addresses in
HAKI_OLLAMA_ALLOW (the host is always allowed, for 'watch'); change them with 'haki ollama-gpu allow'.

    haki ollama-gpu models              what's downloaded, and what's loaded on the GPU
    haki ollama-gpu pull qwen2.5:7b     download a model
    haki ollama-gpu bench               tokens per second, and how much of the model fits on the GPU"
MODULE_CHANGES="/etc/modules-load.d/haki-vfio.conf    load vfio at boot (skipped if your card is already on vfio-pci)
/etc/modprobe.d/haki-vfio.conf        give the card to vfio-pci, keep nouveau off it; then update-initramfs
A VM (only if HAKI_OLLAMA_VM is empty)  Ubuntu 24.04 cloud image, q35/UEFI, the GPU, ${HAKI_OLLAMA_CORES} cores (low CPU priority),
                                      ${HAKI_OLLAMA_RAM} MB, ${HAKI_OLLAMA_DISK} GB, starts on boot after your other VMs
<snippets>/haki-ollama-<id>.yaml      its first-boot setup (cloud-init): driver, ollama, firewall, your SSH keys
/var/lib/haki/images/                 the downloaded Ubuntu image (checksum verified)
/etc/haki/haki.conf                   HAKI_OLLAMA_VM, HAKI_OLLAMA_GPU, HAKI_OLLAMA_ALLOW"
MODULE_REQUIRES="an NVIDIA card in its own IOMMU group (VT-d / AMD-Vi on in the BIOS); a reboot the first time"
MODULE_COMMANDS="haki ollama-gpu models                 downloaded and loaded models
haki ollama-gpu pull <model>           download one (e.g. qwen2.5:7b, gemma2:2b)
haki ollama-gpu rm <model>             delete one
haki ollama-gpu bench [model]          speed and GPU fit
haki ollama-gpu gpu                    the card, its driver and passthrough state
haki ollama-gpu allow [ip|cidr] / deny <ip|cidr>    who may use the API"

IMG_DIR=/var/lib/haki/images
IMG_URL=https://cloud-images.ubuntu.com/noble/current
IMG_NAME=noble-server-cloudimg-amd64.img
VFIO_LOAD=/etc/modules-load.d/haki-vfio.conf
VFIO_CONF=/etc/modprobe.d/haki-vfio.conf

# --- the card ---------------------------------------------------------------------------------
# PCI slot of the GPU (0000:01:00): HAKI_OLLAMA_GPU, or the first NVIDIA display device. "none" = CPU only.
gpu_slot() {
  if [[ -n $HAKI_OLLAMA_GPU ]]; then echo "$HAKI_OLLAMA_GPU"; return; fi
  lspci -Dn 2>/dev/null | awk '$2 ~ /^03(00|02):$/ && $3 ~ /^10de:/ { print substr($1, 1, length($1) - 2); exit }'
}
gpu_funcs()  { local s f; s=$(gpu_slot); for f in /sys/bus/pci/devices/"$s".[0-7]; do [[ -e $f ]] && echo "${f##*/}"; done; }
gpu_ids()    { local f; for f in $(gpu_funcs); do printf '%s:%s\n' "$(sed 's/^0x//' "/sys/bus/pci/devices/$f/vendor")" "$(sed 's/^0x//' "/sys/bus/pci/devices/$f/device")"; done | paste -sd,; }
gpu_name()   { lspci -s "$(gpu_slot).0" 2>/dev/null | sed 's/^[^ ]* [^:]*: //'; }
func_driver(){ basename "$(readlink "/sys/bus/pci/devices/$1/driver" 2>/dev/null)" 2>/dev/null; }
gpu_on_vfio(){ local f; for f in $(gpu_funcs); do [[ $(func_driver "$f") == vfio-pci ]] || return 1; done; }
# Devices sharing the card's IOMMU group, other than the card itself and PCI bridges.
group_others() {
  local d s; s=$(gpu_slot)
  for d in "/sys/bus/pci/devices/$s.0/iommu_group/devices/"*; do
    [[ -e $d ]] || continue; d=${d##*/}
    [[ $d == "$s".* ]] && continue
    [[ $(cat "/sys/bus/pci/devices/$d/class") == 0x0604* ]] && continue
    echo "$d"
  done
}
pinned_kernel() { proxmox-boot-tool kernel list 2>/dev/null | awk '/^Pinned kernel:/ { getline; print; exit }'; }

# --- the VM -----------------------------------------------------------------------------------
vm_exists()   { [[ -n $HAKI_OLLAMA_VM ]] && qm status "$HAKI_OLLAMA_VM" &>/dev/null; }
vm_has_gpu()  { qm config "$HAKI_OLLAMA_VM" 2>/dev/null | grep -qE "^hostpci[0-9]+: (0000:)?${1#0000:}"; }
vm_running()  { qm status "$HAKI_OLLAMA_VM" 2>/dev/null | grep -q running; }
has_agent()   { qm guest cmd "$HAKI_OLLAMA_VM" ping &>/dev/null; }
valid_model() { [[ $1 =~ ^[A-Za-z0-9._:/-]+$ ]] || die "'$1' isn't a model name like gemma2:2b"; }
in_vm()       { qm guest exec "$HAKI_OLLAMA_VM" --timeout 60 -- "$@" 2>/dev/null | perl -MJSON -0e '
                  my $r = decode_json(<STDIN>); print $r->{"out-data"} // ""; print STDERR $r->{"err-data"} // ""; exit($r->{exitcode} // 1)'; }
lan_cidr()    { ip route show dev "$HAKI_BRIDGE" scope link proto kernel | awk '{ print $1; exit }'; }
snippet_dir() { echo "$(pvesh get "/storage/$HAKI_SNIPPET_STORAGE" --output-format json 2>/dev/null | perl -MJSON -0e 'print decode_json(<STDIN>)->{path} // ""')/snippets"; }

# The VM's address: HAKI_OLLAMA_ADDR, the guest agent's answer, or its MAC in the neighbour table.
vm_ip() {
  [[ -n $HAKI_OLLAMA_ADDR ]] && { echo "$HAKI_OLLAMA_ADDR"; return; }
  local mac ip
  mac=$(qm config "$HAKI_OLLAMA_VM" 2>/dev/null | sed -n 's/^net0: [a-z0-9]*=\([0-9A-Fa-f:]\{17\}\),.*/\1/p' | tr 'A-F' 'a-f')
  [[ -n $mac ]] || return 0
  ip=$(ip -4 neigh show dev "$HAKI_BRIDGE" | awk -v m="$mac" 'tolower($3) == m && $0 !~ /FAILED/ { print $1; exit }')
  if [[ -z $ip ]] && ! has_agent; then   # not in the neighbour table yet: ping the LAN once to fill it
    local net i; net=$(bridge_ip "$HAKI_BRIDGE"); net=${net%.*}
    for i in $(seq 1 254); do ping -c1 -W1 "$net.$i" &>/dev/null & done; wait
    ip=$(ip -4 neigh show dev "$HAKI_BRIDGE" | awk -v m="$mac" 'tolower($3) == m && $0 !~ /FAILED/ { print $1; exit }')
  fi
  if [[ -z $ip ]] && has_agent; then
    ip=$(qm agent "$HAKI_OLLAMA_VM" network-get-interfaces 2>/dev/null | perl -MJSON -0e '
      for my $i (@{ decode_json(<STDIN>) }) { for (@{ $i->{"ip-addresses"} // [] }) {
        if ($_->{"ip-address-type"} eq "ipv4" && $_->{"ip-address"} !~ /^127\./) { print $_->{"ip-address"}; exit } } }')
  fi
  echo "$ip"
}
api() { local ip; ip=$(vm_ip); [[ -n $ip ]] || return 1; curl -fsS --max-time "${API_TIMEOUT:-10}" "$@" "http://$ip:$HAKI_OLLAMA_PORT$API_PATH"; }
api_get() { API_PATH=$1 api; }
need_api() {
  need_root; vm_exists || die "no ollama VM (HAKI_OLLAMA_VM). Set it up: haki install ollama-gpu"
  vm_running || die "VM $HAKI_OLLAMA_VM isn't running: qm start $HAKI_OLLAMA_VM"
  api_get /api/version >/dev/null || die "ollama doesn't answer on $(vm_ip):$HAKI_OLLAMA_PORT (first boot can take 10 minutes: haki status ollama-gpu)"
}

# render_user_data <gpu slot|none> <allowed addresses> <authorized_keys file>: the VM's cloud-init.
render_user_data() {
  local gpu=$1 allow=$2 keys ufw='' a
  keys=$(grep -E '^(ssh|ecdsa|sk-)' "$3" | sed 's/^/      - /')
  [[ -n $keys ]] || die "no SSH public keys in $3"
  for a in $allow; do ufw+="  - ufw allow from $a to any port $HAKI_OLLAMA_PORT proto tcp comment 'haki: ollama API'"$'\n'; done
  KEYS=$keys UFW=${ufw%$'\n'} PORT=$HAKI_OLLAMA_PORT LAN=$(lan_cidr) GPU=$gpu perl -pe '
      s/\@HOSTNAME\@/ollama/g; s/\@PORT\@/$ENV{PORT}/g; s/\@LAN\@/$ENV{LAN}/g; s/\@GPU\@/$ENV{GPU}/g;
      $_ = "$ENV{KEYS}\n" if /^\@SSH_KEYS\@$/; $_ = "$ENV{UFW}\n" if /^\@UFW_ALLOW\@$/;' \
    "$HAKI_ROOT/modules/ollama-gpu/files/user-data.yaml"
}

# --- module -----------------------------------------------------------------------------------
module_check() {
  local s; s=$(gpu_slot)
  if [[ $s == none ]]; then return 0; fi
  [[ -n $s ]] || { bad "no NVIDIA graphics card found (lspci). Set HAKI_OLLAMA_GPU to its PCI address, or 'none' for CPU only."; return 1; }
  [[ -e /sys/bus/pci/devices/$s.0 ]] || { bad "no PCI device at $s.0 (HAKI_OLLAMA_GPU)"; return 1; }
  if [[ -z $(ls /sys/kernel/iommu_groups 2>/dev/null) ]]; then
    bad "IOMMU is off, so the card can't be passed to a VM."
    note "Turn on VT-d (Intel) or AMD-Vi/IOMMU in the BIOS; on older kernels also add intel_iommu=on to the kernel command line."
    return 1
  fi
  local others; others=$(group_others)
  if [[ -n $others ]]; then
    bad "the card shares its IOMMU group with other devices, so it can't be passed on its own:"
    local d; for d in $others; do note "$(lspci -s "$d")"; done
    note "Try another PCIe slot, or look for an ACS option in the BIOS."
    return 1
  fi
  if vm_exists && ! vm_has_gpu "$s"; then
    bad "VM $HAKI_OLLAMA_VM (HAKI_OLLAMA_VM) doesn't have the card. Add it (qm set $HAKI_OLLAMA_VM --hostpci0 $s,pcie=1) or empty HAKI_OLLAMA_VM to create a new VM."
    return 1
  fi
  if [[ -n $HAKI_OLLAMA_VM ]] && ! vm_exists; then
    bad "VM $HAKI_OLLAMA_VM (HAKI_OLLAMA_VM) doesn't exist. Empty HAKI_OLLAMA_VM to create one."; return 1
  fi
  return 0
}

module_install() {
  local s; s=$(gpu_slot)
  if [[ $s != none ]]; then
    step "Give $(gpu_name) to VMs (passthrough)"
    note "$s: $(gpu_ids) — IOMMU group $(basename "$(readlink "/sys/bus/pci/devices/$s.0/iommu_group")"), nothing else in it"
    if gpu_on_vfio; then
      skip "the card is already on vfio-pci; your existing passthrough setup is kept"
    else
      if [[ $(cat "/sys/bus/pci/devices/$s.0/boot_vga" 2>/dev/null) == 1 ]]; then
        warn "This card is your host's screen. After the reboot the host's own screen stays dark"
        note "(the web UI and SSH are unaffected). That's normal for a headless server."
      fi
      write_file "$VFIO_LOAD" 0644 <<'EOF'
# Added by haki (module: ollama-gpu). Load vfio at boot, for GPU passthrough.
vfio
vfio_iommu_type1
vfio_pci
EOF
      write_file "$VFIO_CONF" 0644 <<EOF
# Added by haki (module: ollama-gpu). $(gpu_name) ($s) belongs to vfio-pci, for passthrough.
options vfio-pci ids=$(gpu_ids)
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidiafb pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
      run "update the initramfs" update-initramfs -u -k all || die "update-initramfs failed"
      if ! planning; then
        title "Reboot needed"
        echo "  The card switches to vfio-pci at the next boot. Reboot (web UI → $(hostname) → Reboot),"
        echo "  then run 'haki install ollama-gpu' again to create the VM."
        return 0
      fi
      note "(after the reboot, running install again creates the VM:)"
    fi
  fi

  step "The ollama VM"
  if vm_exists; then
    skip "VM $HAKI_OLLAMA_VM ($(qm config "$HAKI_OLLAMA_VM" | awk '/^name:/ { print $2 }')) has the card; adopted as is"
    has_agent || note "It has no guest agent, so 'allow' / 'deny' print commands for you to run inside it."
  else
    create_vm "$s" || return 1
  fi
  [[ $s == none || -n $HAKI_OLLAMA_GPU ]] || conf_set HAKI_OLLAMA_GPU "$s"
}

create_vm() {
  local s=$1 id addr allow storage
  if planning; then id=${HAKI_OLLAMA_VM:-$(pvesh get /cluster/nextid)}
  else ask "VM id" "$(pvesh get /cluster/nextid)"; id=$REPLY; fi
  [[ $id =~ ^[0-9]+$ ]] || die "'$id' is not a VM id"
  storage=$(pick_storage)
  [[ -s /root/.ssh/authorized_keys ]] || die "root has no SSH keys (/root/.ssh/authorized_keys); the VM would have no way in"
  addr=$HAKI_OLLAMA_ADDR
  if [[ -z $addr ]] && ! planning; then
    note "A fixed address keeps it findable; empty = DHCP (fine with a reservation on the router)."
    ask "Address for the VM (empty for DHCP)" ""; addr=$REPLY
  fi
  if [[ -n $addr ]]; then
    [[ $addr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "'$addr' is not an IPv4 address"
    ping -c1 -W1 "$addr" &>/dev/null && die "something already answers at $addr"
  fi
  allow=$HAKI_OLLAMA_ALLOW
  if [[ -z $allow ]] && ! planning; then
    note "ollama has no password. Which addresses may use its API? (the host is always allowed)"
    ask "Allowed addresses or ranges, space separated" "$HAKI_HOST_IP"; allow=$REPLY
  fi
  allow=$(printf '%s\n' $HAKI_HOST_IP $allow | awk '!seen[$0]++' | paste -sd' ')

  if planning; then
    plan "download and verify the Ubuntu 24.04 cloud image into $IMG_DIR"
    plan "create VM $id 'ollama': ${HAKI_OLLAMA_CORES} cores (low priority), ${HAKI_OLLAMA_RAM} MB, ${HAKI_OLLAMA_DISK} GB on $storage, ${addr:-DHCP}, $( [[ $s == none ]] && echo "no GPU (CPU only)" || echo "GPU $s")"
    plan "first boot (about 10 min): NVIDIA driver, ollama, firewall allowing $allow (+ SSH from $(lan_cidr))"
    plan "set HAKI_OLLAMA_VM, HAKI_OLLAMA_ALLOW${addr:+, HAKI_OLLAMA_ADDR} in $HAKI_CONF"
    return 0
  fi
  if qm status "$id" &>/dev/null || pct status "$id" &>/dev/null; then die "id $id is already used by a guest"; fi
  if [[ $s != none ]]; then gpu_on_vfio || die "the card isn't on vfio-pci yet. Reboot first."; fi

  step "Ubuntu cloud image"
  mkdir -p "$IMG_DIR"
  local sums; sums=$(curl -fsS --max-time 30 "$IMG_URL/SHA256SUMS") || die "couldn't fetch the image checksums"
  local want; want=$(awk -v f="*$IMG_NAME" '$2 == f || $2 == substr(f, 2) { print $1 }' <<<"$sums")
  [[ -n $want ]] || die "no checksum for $IMG_NAME"
  if [[ -f $IMG_DIR/$IMG_NAME ]] && sha256sum "$IMG_DIR/$IMG_NAME" | grep -q "^$want "; then skip "$IMG_NAME is current"
  else
    run "download $IMG_NAME" curl -fL --progress-bar -o "$IMG_DIR/$IMG_NAME.part" "$IMG_URL/$IMG_NAME" || die "download failed"
    sha256sum "$IMG_DIR/$IMG_NAME.part" | grep -q "^$want " || { rm -f "$IMG_DIR/$IMG_NAME.part"; die "checksum mismatch; download discarded"; }
    mv "$IMG_DIR/$IMG_NAME.part" "$IMG_DIR/$IMG_NAME"; ok "checksum verified"
  fi

  step "First-boot setup"
  local snip; snip="$(snippet_dir)/haki-ollama-$id.yaml"
  local content; content=$(pvesh get "/storage/$HAKI_SNIPPET_STORAGE" --output-format json | perl -MJSON -0e 'print decode_json(<STDIN>)->{content}')
  [[ ,$content, == *,snippets,* ]] || run "allow snippets on storage '$HAKI_SNIPPET_STORAGE'" pvesm set "$HAKI_SNIPPET_STORAGE" --content "$content,snippets"
  mkdir -p "$(dirname "$snip")"
  render_user_data "$s" "$allow" /root/.ssh/authorized_keys | write_file "$snip" 0600

  step "Create VM $id"
  local gpu=() net=ip=dhcp
  [[ $s == none ]] || gpu=(--hostpci0 "$s,pcie=1")
  [[ -n $addr ]] && net="ip=$addr/${HAKI_LAN_PREFIX:-$(lan_cidr | cut -d/ -f2)},gw=$HAKI_GATEWAY"
  run "create VM $id (ollama)" qm create "$id" --name ollama --ostype l26 --machine q35 --bios ovmf \
    --efidisk0 "$storage:0,efitype=4m,pre-enrolled-keys=0" --cpu host --cores "$HAKI_OLLAMA_CORES" --cpuunits 50 \
    --memory "$HAKI_OLLAMA_RAM" --balloon 0 --scsihw virtio-scsi-single \
    --virtio0 "$storage:0,import-from=$IMG_DIR/$IMG_NAME,iothread=1" \
    --ide2 "$storage:cloudinit" --cicustom "user=$HAKI_SNIPPET_STORAGE:snippets/haki-ollama-$id.yaml" --ipconfig0 "$net" \
    --nameserver "$HAKI_TENANT_DNS" --net0 "virtio,bridge=$HAKI_BRIDGE,firewall=1" --agent enabled=1 \
    --serial0 socket --vga std "${gpu[@]}" --boot order=virtio0 \
    --onboot 1 --startup order=3,up=30 --tags "haki;llm" \
    --description "haki **ollama-gpu**: ollama on $( [[ $s == none ]] && echo "the CPU" || gpu_name ). API: port $HAKI_OLLAMA_PORT, allowed from $allow" \
    || die "qm create failed"
  run "grow its disk to ${HAKI_OLLAMA_DISK} GB" qm disk resize "$id" virtio0 "${HAKI_OLLAMA_DISK}G"
  conf_set HAKI_OLLAMA_VM "$id"; conf_set HAKI_OLLAMA_ALLOW "$allow"; [[ -z $addr ]] || conf_set HAKI_OLLAMA_ADDR "$addr"
  run "start it" qm start "$id"
  title "Setting itself up"
  echo "  First boot installs the NVIDIA driver and ollama, then reboots: about 10 minutes."
  echo "  Follow along:  haki status ollama-gpu      Then:  haki ollama-gpu pull gemma2:2b"
}

module_uninstall() {
  local s; s=$(gpu_slot)
  if vm_exists && [[ $s != none ]] && vm_has_gpu "$s"; then
    warn "VM $HAKI_OLLAMA_VM still uses the card; keeping the passthrough settings (it couldn't start without them)."
    note "The VM itself is never deleted by haki. Remove it yourself if you want: qm destroy $HAKI_OLLAMA_VM"
  elif [[ -e $VFIO_CONF || -e $VFIO_LOAD ]]; then
    remove_file "$VFIO_CONF"; remove_file "$VFIO_LOAD"
    run "update the initramfs" update-initramfs -u -k all
    note "The card returns to the host after the next reboot."
  fi
  if [[ -n $HAKI_OLLAMA_VM ]] && ! vm_exists; then remove_file "$(snippet_dir)/haki-ollama-$HAKI_OLLAMA_VM.yaml"; fi
}

module_status() {
  local rc=0 s; s=$(gpu_slot)
  if [[ $s != none ]]; then
    if gpu_on_vfio; then ok "$(gpu_name) is reserved for VMs (vfio-pci)"
    else bad "$(gpu_name) isn't on vfio-pci (driver: $(func_driver "$s.0")) — the VM can't start with it. Fix: haki install ollama-gpu, then reboot"; rc=1; fi
    local pin; pin=$(pinned_kernel)
    [[ -z $pin || $pin == "$(uname -r)" ]] || warn "running kernel $(uname -r), but $pin is pinned — reboot into the pinned one"
  fi
  if ! vm_exists; then bad "no ollama VM yet. Fix: haki install ollama-gpu"; return 1; fi
  if ! vm_running; then bad "VM $HAKI_OLLAMA_VM is $(qm status "$HAKI_OLLAMA_VM" | awk '{ print $2 }'). Fix: qm start $HAKI_OLLAMA_VM"; return 1; fi
  local v ip; ip=$(vm_ip)
  if v=$(API_TIMEOUT=5 api_get /api/version 2>/dev/null); then
    ok "ollama $(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' <<<"$v") answers at $ip:$HAKI_OLLAMA_PORT"
  elif has_agent && in_vm cloud-init status 2>/dev/null | grep -q running; then
    skip "VM $HAKI_OLLAMA_VM is still setting itself up (first boot: driver + ollama, ~10 min)"; return 0
  else bad "ollama doesn't answer at ${ip:-?}:$HAKI_OLLAMA_PORT. Look inside: journalctl -u ollama"; return 1; fi
  local n; n=$(api_get /api/tags | perl -MJSON -0e 'print scalar @{ decode_json(<STDIN>)->{models} }' 2>/dev/null)
  ok "${n:-0} model(s) downloaded (haki ollama-gpu models)"
  if has_agent && in_vm ufw status 2>/dev/null | grep -q 'Status: active'; then
    ok "API allowed only from: $(in_vm ufw status | awk -v p="$HAKI_OLLAMA_PORT" '$1 == p "/tcp" { print $3 }' | paste -sd' ')"
  else
    warn "haki can't see a firewall in VM $HAKI_OLLAMA_VM: assume anyone on your LAN can use the API. See: haki ollama-gpu allow"
  fi
  return $rc
}

# --- commands ---------------------------------------------------------------------------------
module_cmd_models() {
  need_api
  local loaded; loaded=$(api_get /api/ps)
  printf "\n  ${C_B}%-30s %-9s %-8s %s${C_0}\n" MODEL SIZE QUANT LOADED
  api_get /api/tags | LOADED=$loaded perl -MJSON -0e '
    my %l = map { $_->{name} => $_ } @{ decode_json($ENV{LOADED})->{models} };
    for my $m (sort { $a->{name} cmp $b->{name} } @{ decode_json(<STDIN>)->{models} }) {
      my $x = $l{$m->{name}}; my $on = "";
      $on = sprintf "%d%% on GPU", 100 * $x->{size_vram} / $x->{size} if $x && $x->{size};
      printf "  %-30s %-9s %-8s %s\n", $m->{name}, sprintf("%.1f GB", $m->{size} / 1e9), $m->{details}{quantization_level} // "", $on }'
  echo
}

module_cmd_pull() {
  [[ -n ${1:-} ]] || die "usage: haki ollama-gpu pull <model>   e.g. gemma2:2b, qwen2.5:7b (see ollama.com/library)"
  valid_model "$1"; need_api
  step "Downloading $1"
  API_TIMEOUT=7200 API_PATH=/api/pull api -N -X POST -d "{\"model\":\"$1\"}" | perl -MJSON -ne '
    $| = 1; my $d = eval { decode_json($_) } or next;
    if ($d->{error}) { print "\n"; print STDERR "  error: $d->{error}\n"; exit 1 }
    if ($d->{total}) { printf "\r  %-28s %5.1f%% of %.1f GB", $d->{status} =~ s/pulling //r, 100 * ($d->{completed} // 0) / $d->{total}, $d->{total} / 1e9 }
    else { printf "\r  %-60s", $d->{status} }
    END { print "\n" }' || die "pull failed"
  ok "$1 is ready. Try: haki ollama-gpu bench $1"
}

module_cmd_rm() {
  [[ -n ${1:-} ]] || die "usage: haki ollama-gpu rm <model>"
  valid_model "$1"; need_api
  confirm "Delete $1 from the VM?" || { skip "kept"; return 0; }
  API_PATH=/api/delete api -X DELETE -d "{\"model\":\"$1\"}" >/dev/null || die "couldn't delete $1 (see: haki ollama-gpu models)"
  ok "deleted $1"
}

module_cmd_bench() {
  need_api
  local m=${1:-}
  [[ -n $m ]] || m=$(api_get /api/tags | perl -MJSON -0e 'my @m = sort { $a->{size} <=> $b->{size} } @{ decode_json(<STDIN>)->{models} }; print $m[0]{name} // ""')
  [[ -n $m ]] || die "no models yet: haki ollama-gpu pull gemma2:2b"
  valid_model "$m"
  step "Benchmark: $m (up to 128 tokens)"
  local r; r=$(API_TIMEOUT=600 API_PATH=/api/generate api -X POST -d "{\"model\":\"$m\",\"prompt\":\"Explain in one paragraph why the sky is blue.\",\"stream\":false,\"options\":{\"num_predict\":128,\"temperature\":0}}") \
    || die "the model didn't answer (does it fit in the VM's RAM? haki ollama-gpu models)"
  local ps; ps=$(api_get /api/ps)
  R=$r PS=$ps M=$m perl -MJSON -e '
    my $r = decode_json($ENV{R}); my ($x) = grep { $_->{name} eq $ENV{M} } @{ decode_json($ENV{PS})->{models} };
    printf "  speed     %.1f tokens/s  (%d tokens in %.1f s; loading took %.1f s)\n",
      $r->{eval_count} / ($r->{eval_duration} / 1e9), $r->{eval_count}, $r->{eval_duration} / 1e9, ($r->{load_duration} // 0) / 1e9;
    if ($x && $x->{size}) {
      my $p = 100 * $x->{size_vram} / $x->{size};
      printf "  memory    %.1f GB, %.0f%% of it on the GPU (%.1f GB VRAM)%s\n", $x->{size} / 1e9, $p, $x->{size_vram} / 1e9,
        $p >= 99 ? "" : $p > 0 ? " — the rest runs on the CPU, which is slower" : " — none: check the driver (haki ollama-gpu gpu)";
    }'
}

module_cmd_gpu() {
  need_root
  local s; s=$(gpu_slot)
  [[ $s == none ]] && { echo "  No GPU (HAKI_OLLAMA_GPU=none): models run on the CPU."; return 0; }
  echo "  card      $(gpu_name)"
  echo "  slot      $s  ids $(gpu_ids)  IOMMU group $(basename "$(readlink "/sys/bus/pci/devices/$s.0/iommu_group")")"
  local f; for f in $(gpu_funcs); do echo "  $f  driver: $(func_driver "$f")"; done
  echo "  kernel    $(uname -r)  (pinned: $(pinned_kernel || true))"
  if vm_exists && vm_running && has_agent; then
    echo "  in VM $HAKI_OLLAMA_VM:"; in_vm nvidia-smi --query-gpu=driver_version,memory.used,memory.total,temperature.gpu,utilization.gpu --format=csv | sed 's/^/    /'
  elif vm_exists; then echo "  (VM $HAKI_OLLAMA_VM has no guest agent; run nvidia-smi inside it to see the driver)"; fi
}

module_cmd_allow() {
  need_root; vm_exists || die "no ollama VM (HAKI_OLLAMA_VM)"
  local a=${1:-}
  if ! has_agent; then
    echo "  VM $HAKI_OLLAMA_VM has no guest agent, so run these inside it (sudo) to allow only chosen addresses:"
    echo "    sudo ufw allow from $(lan_cidr) to any port 22 proto tcp"
    echo "    sudo ufw allow from $HAKI_HOST_IP to any port $HAKI_OLLAMA_PORT proto tcp      # the host (watch)"
    echo "    sudo ufw allow from ${a:-<your PC>} to any port $HAKI_OLLAMA_PORT proto tcp"
    echo "    sudo ufw default deny incoming && sudo ufw --force enable"
    echo "  Optional, so haki can manage it next time: sudo apt install qemu-guest-agent; then on the host:"
    echo "    qm set $HAKI_OLLAMA_VM --agent enabled=1   (takes effect after the VM is shut down and started)"
    return 0
  fi
  if [[ -z $a ]]; then in_vm ufw status | sed 's/^/  /'; return 0; fi
  [[ $a =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || die "'$a' isn't an IPv4 address or range"
  in_vm ufw allow from "$a" to any port "$HAKI_OLLAMA_PORT" proto tcp comment 'haki: ollama API' >/dev/null || die "ufw refused"
  conf_set HAKI_OLLAMA_ALLOW "$(printf '%s\n' $HAKI_OLLAMA_ALLOW "$a" | awk 'NF && !seen[$0]++' | paste -sd' ')"
  ok "$a may use the API"
}

module_cmd_deny() {
  need_root; vm_exists || die "no ollama VM (HAKI_OLLAMA_VM)"
  local a=${1:-}; [[ -n $a ]] || die "usage: haki ollama-gpu deny <ip|cidr>"
  [[ $a != "$HAKI_HOST_IP" ]] || die "the host must stay allowed (watch checks the API from it)"
  has_agent || die "VM $HAKI_OLLAMA_VM has no guest agent; inside it run: sudo ufw delete allow from $a to any port $HAKI_OLLAMA_PORT proto tcp"
  in_vm ufw delete allow from "$a" to any port "$HAKI_OLLAMA_PORT" proto tcp >/dev/null || die "no such rule (haki ollama-gpu allow shows them)"
  conf_set HAKI_OLLAMA_ALLOW "$(printf '%s\n' $HAKI_OLLAMA_ALLOW | grep -vxF "$a" | paste -sd' ')"
  ok "$a can no longer use the API"
}
