# shellcheck shell=bash
# Shared helpers for the haki command and its modules. Sourced, never run directly.
#
# Every change a module makes goes through install_file / write_file / remove_file / run.
# With HAKI_PLAN=1 those only describe what they would do, so `haki plan <module>` shows the
# exact list of changes without touching the system.

HAKI_ETC=/etc/haki
HAKI_CONF=$HAKI_ETC/haki.conf
HAKI_STATE=/var/lib/haki
HAKI_PLAN=${HAKI_PLAN:-0}
HAKI_YES=${HAKI_YES:-0}
HAKI_STAMP=$(date +%Y%m%d-%H%M%S)

# --- output ---------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_B=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[34m' C_0=$'\e[0m'
else
  C_B='' C_DIM='' C_RED='' C_GRN='' C_YEL='' C_BLU='' C_0=''
fi
title() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }
step()  { printf '%s==>%s %s\n' "$C_BLU" "$C_0" "$*"; }
ok()    { printf '  %s✓%s %s\n' "$C_GRN" "$C_0" "$*"; }
skip()  { printf '  %s·%s %s\n' "$C_DIM" "$C_0" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YEL" "$C_0" "$*" >&2; }
bad()   { printf '  %s✗%s %s\n' "$C_RED" "$C_0" "$*"; }
note()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_0"; }
plan()  { printf '  %s+%s %s\n' "$C_YEL" "$C_0" "$*"; }   # a change that would be made
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_0" "$*" >&2; exit 1; }

planning() { [[ $HAKI_PLAN == 1 ]]; }

# --- environment ------------------------------------------------------------------------------
need_root() { [[ $EUID -eq 0 ]] || die "run this as root on the Proxmox host (sudo -i, or the web UI shell)."; }
need_pve()  {
  command -v pveversion >/dev/null || die "this doesn't look like a Proxmox VE host (no pveversion)."
  local v; v=$(pveversion | sed -n 's|^pve-manager/\([0-9]*\).*|\1|p')
  [[ ${v:-0} -ge 8 ]] || die "haki needs Proxmox VE 8 or newer (found: $(pveversion))."
}

# --- config -----------------------------------------------------------------------------------
# Defaults first, then /etc/haki/haki.conf overrides them.
load_config() {
  HAKI_BRIDGE=vmbr0 HAKI_HOST_IP='' HAKI_GATEWAY='' HAKI_SITE_URL=''
  HAKI_EDGE_VM='' HAKI_OLLAMA_VM='' HAKI_OLLAMA_PORT=11434
  HAKI_REPORT_HOUR=9 HAKI_CONFIRM_RUNS=2
  HAKI_BACKUP_UUID='' HAKI_BACKUP_KEEP=4 HAKI_BACKUP_MIN_FREE_GB=150 HAKI_BACKUP_DUE_DAYS=7
  # shellcheck disable=SC1090
  [[ -r $HAKI_CONF ]] && source "$HAKI_CONF"
  return 0
}

# conf_set KEY VALUE: create or update one line in haki.conf (keeps comments and order).
conf_set() {
  local key=$1 val=$2
  if planning; then plan "set $key=\"$val\" in $HAKI_CONF"; return; fi
  mkdir -p "$HAKI_ETC"; touch "$HAKI_CONF"
  if grep -q "^$key=" "$HAKI_CONF"; then
    KEY=$key VAL=$val perl -i -pe 's/^\Q$ENV{KEY}\E=.*/$ENV{KEY}="$ENV{VAL}"/' "$HAKI_CONF"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$HAKI_CONF"
  fi
  printf -v "$key" '%s' "$val"
}

# --- questions --------------------------------------------------------------------------------
# ask "Question" "default" -> $REPLY. With --yes the default is taken.
ask() {
  local q=$1 def=${2:-}
  if [[ $HAKI_YES == 1 || ! -t 0 ]]; then REPLY=$def; printf '  %s %s[%s]%s\n' "$q" "$C_DIM" "$def" "$C_0"; return; fi
  read -r -p "  $q ${def:+[$def] }" REPLY
  REPLY=${REPLY:-$def}
}
# confirm "Question" -> 0 for yes. Default is no; --yes answers yes.
confirm() {
  [[ $HAKI_YES == 1 ]] && return 0
  [[ -t 0 ]] || return 1
  local a; read -r -p "  $1 [y/N] " a
  [[ $a == [yY] || $a == [yY][eE][sS] ]]
}

# --- changes ----------------------------------------------------------------------------------
# Every file haki replaces or removes is copied to /var/lib/haki/backups/<time>/<original path>.
backup_file() {
  local f=$1 dest
  [[ -e $f ]] || return 0
  dest="$HAKI_STATE/backups/$HAKI_STAMP$f"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
}

# install_file <source> <dest> [mode]: copy if different; back up what it replaces.
install_file() {
  local src=$1 dest=$2 mode=${3:-0644}
  if [[ -e $dest ]] && cmp -s "$src" "$dest"; then skip "$dest (already up to date)"; return 0; fi
  local verb=create; [[ -e $dest ]] && verb=update
  if planning; then plan "$verb $dest"; return 0; fi
  backup_file "$dest"
  install -D -m "$mode" "$src" "$dest"
  ok "${verb}d $dest"
}

# write_file <dest> <mode> <<'EOF' ... : like install_file, from stdin.
write_file() {
  local dest=$1 mode=${2:-0644} tmp
  tmp=$(mktemp); cat > "$tmp"
  install_file "$tmp" "$dest" "$mode"; local rc=$?
  rm -f "$tmp"; return $rc
}

remove_file() {
  local f=$1
  [[ -e $f ]] || { skip "$f (not present)"; return 0; }
  if planning; then plan "remove $f"; return 0; fi
  backup_file "$f"; rm -f "$f"; ok "removed $f (backup kept)"
}

# run "what it does" command...: run a command, or describe it in plan mode.
run() {
  local what=$1; shift
  if planning; then plan "$what"; return 0; fi
  if "$@"; then ok "$what"; else bad "$what failed: $*"; return 1; fi
}

# --- module state -----------------------------------------------------------------------------
module_installed() { [[ -e $HAKI_STATE/modules/$1 ]]; }
mark_installed()   { planning && return 0; mkdir -p "$HAKI_STATE/modules"; date '+%F %T' > "$HAKI_STATE/modules/$1"; }
mark_removed()     { planning && return 0; rm -f "$HAKI_STATE/modules/$1"; }

# --- small facts about the host ---------------------------------------------------------------
default_bridge()  { ip route show default | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'; }
default_gateway() { ip route show default | awk '{ print $3; exit }'; }
bridge_ip()       { ip -4 -o addr show "$1" 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }'; }
root_disk()       { lsblk -sno NAME,TYPE "$(findmnt -no SOURCE /)" 2>/dev/null | awk '$2 == "disk" { gsub(/[^a-z0-9]/, "", $1); print $1; exit }'; }
