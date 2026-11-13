# shellcheck shell=bash
# `haki` with no arguments: the host at a glance, in the style of neofetch.
#
# The mark is an ensō (円相), the circle drawn in one brush stroke, with a vermilion seal reading
# 覇気 (haki). Ink density is shaded with four warm greys, so it reads like sumi ink on paper.

HAKI_LOGO=(
  '           ░░▒▒▒▒▒'
  '       ▒▓██████████▓░'
  '     ▒██████████████░'
  '   ▒██████▓▒░'
  '  ▒█████▒               ░░'
  ' ░█████░                 ▒'
  ' ▒████▒                  ░▒'
  ' ▒████▒                 ░░▒'
  ' ░█████                ░▒▓▒░'
  '  ▒█████░             ▒▓▓▒▒'
  '   ░██████▒░      ░▒▓▓▓▓▓▒'
  '     ▒█████████████████▓░'
  '       ░▒▓██████████▓▒░'
  '            ░░░░░░'
)
HAKI_LOGO_W=30          # columns the logo occupies (the seal sits inside this box)
HAKI_SEAL_ROW=11        # the seal's top row and column within the logo
HAKI_SEAL_COL=26

# ink-shade one logo line: █ ▓ ▒ ░ → darkest to faintest ink
_ink() {
  local s=$1
  s=${s//█/${C_LOGO1}█}; s=${s//▓/${C_LOGO2}▓}; s=${s//▒/${C_LOGO3}▒}; s=${s//░/${C_LOGO4}░}
  printf '%s%s' "$s" "$C_0"
}

# a bar of $3 cells, $1 of $2 filled
_bar() {
  local used=$1 total=$2 w=${3:-14} n i out=''
  (( total > 0 )) || total=1
  n=$(( (used * w + total / 2) / total )); (( n > w )) && n=$w
  out+=$C_ACC; for ((i = 0; i < n; i++)); do out+='━'; done
  out+=$C_INK4; for ((i = n; i < w; i++)); do out+='━'; done
  printf '%s%s' "$out" "$C_0"
}

# "3 days" / "5 hours" / "12 min" since a unix time
_ago() {
  local d=$(( $(date +%s) - $1 ))
  if   (( d < 3600 ));  then echo "$(( d / 60 )) min ago"
  elif (( d < 86400 )); then echo "$(( d / 3600 )) h ago"
  else local n=$(( d / 86400 )); echo "$n day$( (( n == 1 )) || echo s) ago"; fi
}

_fetch_lines() {
  local user host
  user=$(id -un); host=$(hostname -s)
  INFO=("${C_ACC}${C_B}${user}${C_0}${C_INK3}@${C_0}${C_B}${host}${C_0}")
  local rule; printf -v rule '%*s' $(( ${#user} + ${#host} + 1 )) ''; INFO+=("${C_INK4}${rule// /─}${C_0}")

  _kv() { INFO+=("${C_ACC}$(printf '%-9s' "$1")${C_0}$2"); }

  local pve kern
  pve=$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([^/]*\)/.*|\1|p')
  kern=$(uname -r)
  if [[ -n $pve ]]; then _kv proxmox "VE $pve ${C_INK3}·${C_0} kernel $kern"; else _kv kernel "$kern"; fi

  _kv uptime "$(uptime -p | sed 's/^up //; s/, [0-9]* minutes\{0,1\}$//; s/ minutes\{0,1\}/ min/')"

  local cpu
  cpu=$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo \
        | sed -E 's/\((R|TM|tm)\)//g; s/ CPU//; s/ @.*//; s/ [0-9]+-Core Processor//; s/  +/ /g')
  _kv cpu "${cpu:-unknown} ${C_INK3}×${C_0} $(nproc)"

  local mt ma mu
  mt=$(awk '/^MemTotal/ { print $2 }' /proc/meminfo); ma=$(awk '/^MemAvailable/ { print $2 }' /proc/meminfo)
  mu=$(( mt - ma ))
  _kv memory "$(_bar "$mu" "$mt")  $(awk -v u="$mu" -v t="$mt" 'BEGIN { printf "%.1f / %.1f GiB", u/1048576, t/1048576 }')"

  local ds dt du
  read -r dt du < <(df -B1G --output=size,used / | tail -1)
  ds=$(df --output=pcent / | tail -1 | tr -d ' %')
  _kv disk "$(_bar "$du" "$dt")  ${ds}% of ${dt} GiB ${C_INK3}(/dev/$(root_disk))${C_0}"

  if command -v qm >/dev/null && [[ $EUID -eq 0 ]]; then
    local vr vs cr cs
    vr=$(qm list 2>/dev/null | awk 'NR > 1 && $3 == "running"' | wc -l)
    vs=$(qm list 2>/dev/null | awk 'NR > 1 && $3 != "running"' | wc -l)
    cr=$(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running"' | wc -l)
    cs=$(pct list 2>/dev/null | awk 'NR > 1 && $2 != "running"' | wc -l)
    local g="$(( vr + vs )) VMs ${C_INK3}·${C_0} $(( cr + cs )) containers ${C_INK3}·${C_0} "
    if (( vs + cs == 0 )); then g+="${C_GRN}all running${C_0}"
    else g+="$(( vr + cr )) running, ${C_YEL}$(( vs + cs )) stopped${C_0}"; fi
    _kv guests "$g"
  fi

  local br ip gw
  br=$(default_bridge); ip=$(bridge_ip "${br:-$HAKI_BRIDGE}"); gw=$(default_gateway)
  _kv network "${br:-?} ${C_INK3}·${C_0} ${ip:-no address} ${C_INK3}→${C_0} ${gw:-no route}"

  local m mods=''
  for m in $(module_names); do
    if module_installed "$m"; then mods+="${C_GRN}●${C_0} $m  "; else mods+="${C_INK4}○ $m${C_0}  "; fi
  done
  _kv modules "$mods"

  local bs=/var/lib/haki-backup ls lf
  if [[ -s $bs/last-success || -s $bs/last-failure ]]; then
    ls=$(cat "$bs/last-success" 2>/dev/null || echo 0); lf=$(cat "$bs/last-failure" 2>/dev/null || echo 0)
    if (( lf > ls )); then _kv backup "${C_RED}✗ failed $(_ago "$lf")${C_0}${C_INK3} · last good: $( (( ls )) && _ago "$ls" || echo never)${C_0}"
    elif (( $(date +%s) - ls > ${HAKI_BACKUP_DUE_DAYS:-7} * 86400 )); then _kv backup "${C_YEL}! overdue${C_0} ${C_INK3}·${C_0} last $(_ago "$ls")"
    else _kv backup "${C_GRN}✓${C_0} $(_ago "$ls")"; fi
  fi

  if [[ -r $HAKI_ETC/alerts.env ]] && grep -q '^HAKI_DISCORD_WEBHOOK=.' "$HAKI_ETC/alerts.env" 2>/dev/null; then
    if systemctl is-active -q haki-watch.timer 2>/dev/null; then _kv alerts "${C_GRN}●${C_0} Discord ${C_INK3}· checks every 2 min${C_0}"
    else _kv alerts "${C_YEL}○${C_0} Discord webhook set, checks not running ${C_INK3}(haki install watch)${C_0}"; fi
  fi

  # the palette, like neofetch's colour strip: four inks, then the accents (only when in colour)
  if [[ -n $C_ACC ]]; then
    local sw='' c
    for c in "$C_INK1" "$C_INK2" "$C_INK3" "$C_INK4" "$C_ACC" "$C_GRN" "$C_YEL" "$C_RED"; do sw+="${c}███"; done
    INFO+=("" "${sw}${C_0}")
  fi
}

cmd_fetch() {
  load_config
  local INFO=() i n row pad logo=1 cols
  _fetch_lines

  # The logo needs a UTF-8 terminal and room: 30 for the mark, 4 of gap, ~56 for the facts.
  cols=$(tput cols 2>/dev/null || echo 100)
  [[ $(locale charmap 2>/dev/null) == UTF-8 && $cols -ge 92 && -t 1 ]] || logo=0

  echo
  if (( ! logo )); then
    for row in "${INFO[@]}"; do printf '  %s\n' "$row"; done
  else
    local LC_ALL=C.UTF-8
    n=$(( ${#HAKI_LOGO[@]} > ${#INFO[@]} ? ${#HAKI_LOGO[@]} : ${#INFO[@]} ))
    for ((i = 0; i < n; i++)); do
      row=${HAKI_LOGO[i]:-}
      if (( i == HAKI_SEAL_ROW || i == HAKI_SEAL_ROW + 1 )); then
        # stamp the seal: 覇 over 気, white on vermilion, like a hanko in the corner of a painting
        local ch=覇; (( i == HAKI_SEAL_ROW + 1 )) && ch=気
        printf -v pad '%*s' $(( HAKI_SEAL_COL - ${#row} > 0 ? HAKI_SEAL_COL - ${#row} : 0 )) ''
        printf '  %s%s%s %s %s%s' "$(_ink "${row:0:HAKI_SEAL_COL}")" "$pad" "$C_SEAL" "$ch" "$C_0" ""
      else
        printf -v pad '%*s' $(( HAKI_LOGO_W - ${#row} )) ''
        printf '  %s%s' "$(_ink "$row")" "$pad"
      fi
      printf '    %s\n' "${INFO[i]:-}"
    done
  fi
  echo
  printf '  %shaki %s%s  %s·%s  %shaki help%s for everything, %shaki status%s to check on it\n\n' \
    "$C_INK3" "$HAKI_VERSION" "$C_0" "$C_INK4" "$C_0" "$C_B" "$C_0" "$C_B" "$C_0"
}
