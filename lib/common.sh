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
# The palette: sumi ink on paper. Four warm greys for text and the logo, one vermilion accent
# (the colour of a hanko seal), and muted status colours that stay readable on dark and light
# terminals. Truecolor by default; 256 colours on Apple Terminal or with HAKI_COLOR=256; the basic
# 8 on the Linux console; none when output isn't a terminal or NO_COLOR is set (no-color.org).
_rgb() { printf '\e[38;2;%d;%d;%dm' "0x${1:0:2}" "0x${1:2:2}" "0x${1:4:2}"; }
if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
  C_B=$'\e[1m' C_0=$'\e[0m'
  if [[ ${TERM:-} == linux ]]; then
    C_INK1=$'\e[97m' C_INK2=$'\e[37m' C_INK3=$'\e[90m' C_INK4=$'\e[90m'
    C_ACC=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_RED=$'\e[91m' C_SEAL=$'\e[97;41m'
    C_LOGO1=$C_INK1 C_LOGO2=$C_INK1 C_LOGO3=$C_INK2 C_LOGO4=$C_INK2
  elif [[ ${HAKI_COLOR:-} == 256 || ${TERM_PROGRAM:-} == Apple_Terminal ]]; then
    C_INK1=$'\e[38;5;255m' C_INK2=$'\e[38;5;250m' C_INK3=$'\e[38;5;244m' C_INK4=$'\e[38;5;239m'
    C_ACC=$'\e[38;5;167m' C_GRN=$'\e[38;5;108m' C_YEL=$'\e[38;5;179m' C_RED=$'\e[38;5;168m'
    C_SEAL=$'\e[38;5;230;48;5;160m'
    C_LOGO1=$'\e[38;5;255m' C_LOGO2=$'\e[38;5;252m' C_LOGO3=$'\e[38;5;248m' C_LOGO4=$'\e[38;5;245m'
  else
    C_INK1=$(_rgb ECE8E1) C_INK2=$(_rgb B9B3AA) C_INK3=$(_rgb 85807A) C_INK4=$(_rgb 55524E)
    C_ACC=$(_rgb E25A3A) C_GRN=$(_rgb 93B874) C_YEL=$(_rgb E2A644) C_RED=$(_rgb D64561)
    C_SEAL=$'\e[38;2;246;238;227;48;2;206;66;43m'
    # the logo gets a brighter ramp than text, so the faint dry-brush tail still reads
    C_LOGO1=$(_rgb ECE8E1) C_LOGO2=$(_rgb D4CEC5) C_LOGO3=$(_rgb ADA79E) C_LOGO4=$(_rgb 8C867E)
  fi
else
  C_B='' C_0='' C_INK1='' C_INK2='' C_INK3='' C_INK4='' C_ACC='' C_GRN='' C_YEL='' C_RED='' C_SEAL=''
  C_LOGO1='' C_LOGO2='' C_LOGO3='' C_LOGO4=''
fi
C_DIM=$C_INK3

title() { printf '\n%s━━%s %s%s%s\n' "$C_ACC" "$C_0" "$C_B" "$*" "$C_0"; }
step()  { printf '%s▸%s %s%s%s\n' "$C_ACC" "$C_0" "$C_B" "$*" "$C_0"; }
ok()    { printf '  %s✓%s %s\n' "$C_GRN" "$C_0" "$*"; }
skip()  { printf '  %s· %s%s\n' "$C_INK3" "$*" "$C_0"; }
warn()  { printf '  %s!%s %s\n' "$C_YEL" "$C_0" "$*" >&2; }
bad()   { printf '  %s✗%s %s\n' "$C_RED" "$C_0" "$*"; }
note()  { printf '    %s%s%s\n' "$C_INK3" "$*" "$C_0"; }
plan()  { printf '  %s+%s %s\n' "$C_ACC" "$C_0" "$*"; }   # a change that would be made
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
  HAKI_TENANT_BRIDGE=vmbr1 HAKI_TENANT_SUBNET=10.10.0.0/24 HAKI_EDGE_IP='' HAKI_SNIPPET_STORAGE=local
  HAKI_TENANT_IDS=201-250 HAKI_TENANT_STORAGE='' HAKI_TENANT_TEMPLATE='' HAKI_TENANT_DNS="1.1.1.1 9.9.9.9"
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
