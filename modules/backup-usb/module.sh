# shellcheck shell=bash disable=SC2034
# backup-usb — plug in a USB drive, every guest gets backed up, the drive unmounts itself.

MODULE_SUMMARY="Plug in a USB drive → everything is backed up → safe to unplug"
MODULE_ABOUT="Backups you actually do: plugging in a chosen USB drive starts a backup of every VM and
container plus the host's config. When it's done the drive is unmounted, so you just unplug it.

  • Keeps the newest 4 backups of each guest on the drive (HAKI_BACKUP_KEEP) and never lets
    the drive drop below 150 GB free (HAKI_BACKUP_MIN_FREE_GB).
  • Only ever writes inside a 'Server' folder on that drive, and only on the drive you picked
    (matched by its filesystem UUID). Other drives you plug in are ignored.
  • Status at the top of Proxmox → Datacenter → Notes: running / last OK / FAILED / OVERDUE
    after 7 days (HAKI_BACKUP_DUE_DAYS). The panel doesn't refresh itself — click away and back.
  • With the 'watch' module: Discord cards for started / finished — safe to unplug / FAILED
    (with the reason, e.g. 'the drive disconnected during the backup').
  • Plugged in again within 12 hours of a good backup → skipped. After a failed one → retried.

Uses Proxmox's own vzdump (snapshot mode, zstd), so guests keep running and the backups
restore with the normal Proxmox tools (qmrestore / pct restore, or the web UI)."
MODULE_REQUIRES="a USB drive (exFAT, ext4 or NTFS) — 'haki backup-usb pick' chooses it"
MODULE_CHANGES="/etc/haki/haki.conf                          HAKI_BACKUP_UUID = the drive you pick
/usr/local/sbin/haki-usb-backup               the backup script
/etc/udev/rules.d/99-haki-usb-backup.rules    'this drive was plugged in' → start a backup
/etc/systemd/system/haki-usb-backup.service   the backup job (low CPU/disk priority)
/etc/systemd/system/haki-backup-status.*      daily refresh of the Notes status line
Datacenter and node Notes                     one status line at the top (your text is kept)"
MODULE_COMMANDS="haki backup-usb pick       choose the backup drive (lists USB drives, prepares 'Server/')
haki backup-usb run        back up now (drive attached), even if one ran recently
haki backup-usb list       backups currently on the drive
haki backup-usb restore    how to restore a guest, step by step"

RULE=/etc/udev/rules.d/99-haki-usb-backup.rules
MNT=/mnt/haki-usb-backup

module_check() {
  if [[ -z $HAKI_BACKUP_UUID ]]; then
    bad "no backup drive chosen yet."
    note "Plug the drive in and run: haki backup-usb pick"
    return 1
  fi
}

module_install() {
  step "Backup script"
  install_file "$MODULE_DIR/files/haki-usb-backup" /usr/local/sbin/haki-usb-backup 0755

  step "Start a backup when drive $HAKI_BACKUP_UUID is plugged in"
  write_file "$RULE" 0644 <<EOF
# Added by haki (module: backup-usb). Plugging in the chosen backup drive starts a backup.
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="$HAKI_BACKUP_UUID", TAG+="systemd", ENV{SYSTEMD_WANTS}+="haki-usb-backup.service"
EOF
  write_file /etc/systemd/system/haki-usb-backup.service 0644 <<'EOF'
[Unit]
Description=haki: back up every guest to the USB backup drive
After=pve-cluster.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/haki-usb-backup
TimeoutStartSec=6h
Nice=10
IOSchedulingClass=idle
EOF
  write_file /etc/systemd/system/haki-backup-status.service 0644 <<'EOF'
[Unit]
Description=haki: refresh the USB backup status in Notes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/haki-usb-backup --status
EOF
  write_file /etc/systemd/system/haki-backup-status.timer 0644 <<'EOF'
[Unit]
Description=haki: daily USB backup status check

[Timer]
OnCalendar=*-*-* 09:00
OnBootSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if planning; then plan "reload udev and systemd, enable the daily status timer, write the Notes status line"; return 0; fi
  run "reload udev rules" udevadm control --reload
  run "enable the daily status timer" bash -c 'systemctl daemon-reload && systemctl enable --now haki-backup-status.timer >/dev/null 2>&1'
  run "write the status line to Notes" /usr/local/sbin/haki-usb-backup --status
  note "Test it: plug the drive in (or run: haki backup-usb run) and watch Datacenter → Notes."
}

module_uninstall() {
  planning || systemctl disable --now haki-backup-status.timer >/dev/null 2>&1
  remove_file "$RULE"
  remove_file /etc/systemd/system/haki-backup-status.timer
  remove_file /etc/systemd/system/haki-backup-status.service
  remove_file /etc/systemd/system/haki-usb-backup.service
  remove_file /usr/local/sbin/haki-usb-backup
  planning || { systemctl daemon-reload; udevadm control --reload; }
  note "Your backups on the drive are untouched."
}

module_status() {
  local rc=0 last age
  if [[ -n $HAKI_BACKUP_UUID ]]; then ok "backup drive: UUID $HAKI_BACKUP_UUID"
  else bad "no drive chosen. Fix: haki backup-usb pick"; return 1; fi
  if [[ -e /dev/disk/by-uuid/$HAKI_BACKUP_UUID ]]; then ok "drive is plugged in"; else skip "drive not plugged in (normal between backups)"; fi
  if [[ -e $RULE ]]; then ok "plug-in trigger installed"; else bad "plug-in trigger missing. Fix: haki install backup-usb"; rc=1; fi
  if [[ -s /var/lib/haki-backup/last-success ]]; then
    last=$(cat /var/lib/haki-backup/last-success); age=$(( ($(date +%s) - last) / 86400 ))
    if (( age < HAKI_BACKUP_DUE_DAYS )); then ok "last good backup: $(date -d "@$last" '+%d %b %H:%M') ($age d ago)"
    else bad "last good backup was $age days ago — plug the drive in"; rc=1; fi
  else warn "no backup has run yet — plug the drive in"; fi
  if [[ -s /var/lib/haki-backup/last-failure && -s /var/lib/haki-backup/last-success ]] \
     && (( $(cat /var/lib/haki-backup/last-failure) > $(cat /var/lib/haki-backup/last-success) )); then
    bad "the most recent attempt FAILED ($(date -d "@$(cat /var/lib/haki-backup/last-failure)" '+%d %b %H:%M')). Details: journalctl -u haki-usb-backup -n 80"; rc=1
  fi
  return $rc
}

# --- module commands --------------------------------------------------------------------------
module_cmd_pick() {
  title "Choose the backup drive"
  echo "  Plug the drive in first. Only partitions on USB disks are listed."
  echo
  # Filesystems on USB disks (partitions, or a filesystem on the whole disk), tab-separated.
  local rows=() line i=0 dev fs uuid size label
  while IFS= read -r line; do rows+=("$line"); done < <(
    lsblk -J -p -o NAME,TRAN,TYPE,FSTYPE,UUID,SIZE,LABEL | perl -MJSON -0e '
      sub walk { my ($d, $usb) = @_;
        $usb ||= ($d->{tran} // "") eq "usb";
        print join("\t", map { $_ // "" } @$d{qw(name fstype uuid size label)}), "\n" if $usb && $d->{uuid};
        walk($_, $usb) for @{ $d->{children} // [] } }
      walk($_, 0) for @{ decode_json(<STDIN>)->{blockdevices} }')
  [[ ${#rows[@]} -gt 0 ]] || die "no USB drive with a filesystem found. Plug it in and try again ('lsblk -f' shows all disks)."
  printf '    %-3s %-12s %-7s %-12s %-8s %s\n' "#" DEVICE FS UUID SIZE LABEL
  for line in "${rows[@]}"; do
    i=$((i + 1)); IFS=$'\t' read -r dev fs uuid size label <<< "$line"
    printf '    %-3s %-12s %-7s %-12s %-8s %s\n' "$i" "$dev" "$fs" "$uuid" "$size" "$label"
  done
  echo
  ask "Which one is the backup drive? (number)" "1"
  [[ $REPLY =~ ^[0-9]+$ && $REPLY -ge 1 && $REPLY -le ${#rows[@]} ]] || die "no such number"
  IFS=$'\t' read -r dev fs uuid size label <<< "${rows[$((REPLY - 1))]}"
  echo "  Using $dev ($fs, $size, UUID $uuid)."

  # The script only writes inside <drive>/Server — create it if missing.
  mkdir -p "$MNT"
  local mounted_here=0
  if ! mountpoint -q "$MNT"; then mount -o noatime "UUID=$uuid" "$MNT" || die "could not mount $dev"; mounted_here=1; fi
  if [[ -d $MNT/Server ]]; then ok "found the 'Server' folder on the drive"
  else
    echo "  The drive has no 'Server' folder. haki only writes inside that folder."
    if confirm "Create $dev:/Server now? (nothing else on the drive is touched)"; then mkdir "$MNT/Server" && ok "created Server/"
    else warn "not created — backups will refuse to run until it exists"; fi
  fi
  df -h --output=avail,size "$MNT" | tail -1 | awk '{ print "    free: " $1 " of " $2 }'
  (( mounted_here )) && { sync; umount "$MNT"; }

  conf_set HAKI_BACKUP_UUID "$uuid"
  ok "saved HAKI_BACKUP_UUID=$uuid in $HAKI_CONF"
  echo; echo "  Next: ${C_B}haki install backup-usb${C_0}"
}

module_cmd_run() {
  [[ -e /dev/disk/by-uuid/$HAKI_BACKUP_UUID ]] || die "the backup drive (UUID $HAKI_BACKUP_UUID) isn't plugged in."
  echo "  Starting a backup now. Follow it with: journalctl -fu haki-usb-backup-now"
  systemd-run --unit=haki-usb-backup-now --collect -p Nice=10 -p IOSchedulingClass=idle /usr/local/sbin/haki-usb-backup --now
}

module_cmd_list() {
  [[ -e /dev/disk/by-uuid/$HAKI_BACKUP_UUID ]] || die "the backup drive isn't plugged in."
  mkdir -p "$MNT"; local here=0
  mountpoint -q "$MNT" || { mount -o ro "UUID=$HAKI_BACKUP_UUID" "$MNT" && here=1; }
  ls -lh --time-style='+%d %b %H:%M' "$MNT/Server/proxmox/" 2>/dev/null | awk 'NR > 1 && $NF !~ /\.log$/ { printf "    %-8s %s %s %s  %s\n", $5, $6, $7, $8, $9 }'
  df -h --output=avail "$MNT" | tail -1 | awk '{ print "    free on drive: " $1 }'
  (( here )) && umount "$MNT"; return 0
}

module_cmd_restore() {
  cat <<EOF
  ${C_B}Restoring a guest from the USB drive${C_0}

  1. Plug the drive in. If a backup starts, let it finish (it skips if one ran in the last 12 h).
  2. Mount it read-only and list the backups:
       mount -o ro UUID=$HAKI_BACKUP_UUID $MNT && ls $MNT/Server/proxmox/
  3. Restore — to a NEW id first if you want to compare (e.g. 9100), or over the original:
       VM:         qmrestore $MNT/Server/proxmox/vzdump-qemu-<id>-<date>.vma.zst <new-id> --storage local-lvm
       container:  pct restore <new-id> $MNT/Server/proxmox/vzdump-lxc-<id>-<date>.tar.zst --storage local-lvm
     Add --force to overwrite the existing guest with that id (it is replaced!).
  4. Unmount:  umount $MNT

  Host settings (network, /etc/pve, scripts) are in host-config-<date>.tar.gz on the drive.
EOF
}
