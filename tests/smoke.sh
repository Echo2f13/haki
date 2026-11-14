#!/usr/bin/env bash
# Smoke tests that run anywhere: no Proxmox needed, and nothing outside a temp dir is changed.
# The firewall checks write a test /etc/haki/haki.conf, so they only run as root on a throwaway
# CI runner (CI=true) — never on a real host.
#
#   tests/smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export NO_COLOR=1 TERM=dumb
pass=0 fail=0

# t "<name>" <command...>: run it (functions too); on failure show the end of its output.
t() {
  local name=$1 out; shift
  if out=$("$@" 2>&1); then pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else fail=$((fail + 1)); printf '  FAIL  %s\n' "$name"; printf '%s\n' "$out" | tail -15 | sed 's/^/        /'; fi
}
# has <text>: is it in $out?
has() { grep -qF -- "$1" <<<"$out" || { echo "expected to find: $1"; return 1; }; }
modules() { local m; for m in modules/*/; do m=${m%/}; echo "${m#modules/}"; done; }

# --- the haki command -------------------------------------------------------------------------
echo "haki command"
list_has_all() { out=$(./haki list); local m; for m in $(modules); do has "  $m "; done; }
info_ok() { out=$(./haki info "$1"); has "What it changes" && has "haki plan $1"; }
t "version" ./haki version
t "help" ./haki help
t "list shows every module" list_has_all
for m in $(modules); do t "info $m" info_ok "$m"; done
t "an unknown command is refused" bash -c '! ./haki nonsense 2>/dev/null'
if [[ $EUID -ne 0 ]]; then t "plan needs root" bash -c '! ./haki plan watch 2>/dev/null'; fi

# --- every module ------------------------------------------------------------------------------
echo "module API"
module_ok() (
  # shellcheck source=lib/common.sh
  source lib/common.sh; load_config
  # shellcheck disable=SC1090
  source "modules/$1/module.sh"
  local v f
  for v in MODULE_SUMMARY MODULE_ABOUT MODULE_CHANGES; do [[ -n ${!v:-} ]] || { echo "$v is empty"; return 1; }; done
  for f in module_install module_uninstall module_status; do declare -F "$f" >/dev/null || { echo "no $f"; return 1; }; done
)
for m in $(modules); do t "$m" module_ok "$m"; done

# --- ollama-gpu: the VM's first-boot setup ----------------------------------------------------
echo "ollama-gpu: cloud-init"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnlyForCI test@ci\n# a comment\n' > "$TMP/keys"
render() (
  # shellcheck source=lib/common.sh
  source lib/common.sh; load_config; HAKI_ROOT=$ROOT
  # shellcheck source=modules/ollama-gpu/module.sh
  source modules/ollama-gpu/module.sh
  lan_cidr() { echo 192.168.1.0/24; }
  render_user_data "$@" "$TMP/keys"
)
user_data_ok() {
  render 0000:01:00 '192.168.1.240 192.168.1.42' > "$TMP/ud.yaml"
  if grep -n '@[A-Z_]*@' "$TMP/ud.yaml"; then echo "unfilled placeholder"; return 1; fi
  python3 "$ROOT/tests/check-user-data.py" "$TMP/ud.yaml"
}
cpu_only_skips_driver() { out=$(render none 192.168.1.240); has '[ "none" = none ] || ubuntu-drivers install'; }
t "renders valid cloud-init, every placeholder filled" user_data_ok
t "a CPU-only VM skips the driver" cpu_only_skips_driver

# --- customer-net: the firewall ----------------------------------------------------------------
echo "customer-net: firewall rules"
if [[ $EUID -eq 0 && ${CI:-} == true ]] && ! command -v pveversion >/dev/null && command -v nft >/dev/null; then
  mkdir -p /etc/haki
  printf 'HAKI_BRIDGE="vmbr0"\nHAKI_HOST_IP="192.168.1.240"\nHAKI_EDGE_IP="192.168.1.241"\n' > /etc/haki/haki.conf
  printf '20202 10.10.0.102 80\n20203 10.10.0.103 8080\n' > "$TMP/ingress"
  net() { bash modules/customer-net/files/haki-net "$@"; }
  only_edge() {
    out=$(net show "$TMP/ingress")
    has 'iifname "vmbr0" ip saddr 192.168.1.241 ip daddr 192.168.1.240 dnat' && has '20202 : 10.10.0.102 . 80' \
      && has 'ip daddr @private4 drop' && has 'tcp dport 25 drop'
  }
  no_edge_publishes_nothing() {
    printf 'HAKI_BRIDGE="vmbr0"\nHAKI_HOST_IP="192.168.1.240"\n' > /etc/haki/haki.conf
    out=$(net show "$TMP/ingress")
    has "table inet haki" || return 1
    if grep -q dnat <<<"$out"; then echo "published ports must be unreachable without an edge"; return 1; fi
  }
  t "rules are valid nftables (ports published)" net check "$TMP/ingress"
  t "rules are valid nftables (nothing published)" net check /dev/null
  t "only the edge reaches published ports; LAN and mail blocked" only_edge
  t "no edge set: nothing is reachable" no_edge_publishes_nothing
else
  echo "  skip  (they write /etc/haki: only on a CI runner as root; CI runs them)"
fi

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
