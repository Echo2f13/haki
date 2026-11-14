# shellcheck shell=bash disable=SC2034
# hardening — the boring, important basics every Proxmox host should have.

MODULE_SUMMARY="Key-only SSH, working update repos, safer network defaults"
MODULE_ABOUT="A fresh Proxmox install points apt at the paid 'enterprise' repository (updates fail
without a subscription) and lets root log in over SSH with a password. This module:

  1. Turns off the enterprise repositories and turns on the free 'no-subscription' one,
     so 'apt update' works and you actually receive security updates.
  2. Makes SSH key-only for root — but only after checking that root has a key and you
     confirm you've logged in with it. The Proxmox web UI and its shell keep working with
     your password, so you can't lock yourself out.
  3. Adds conservative kernel network settings: ignore ICMP redirects and source-routed
     packets, keep SYN cookies on. Nothing that changes routing or breaks VMs.

It does NOT touch the firewall, the web UI, or your network configuration."
MODULE_CHANGES="/etc/apt/sources.list.d/*      enterprise repos disabled, no-subscription repo added
/etc/ssh/sshd_config.d/10-haki-hardening.conf   key-only root login (sshd is reloaded, not restarted)
/etc/sysctl.d/90-haki-hardening.conf            network hardening settings"

SSH_DROPIN=/etc/ssh/sshd_config.d/10-haki-hardening.conf
SYSCTL_FILE=/etc/sysctl.d/90-haki-hardening.conf

codename() { . /etc/os-release; echo "$VERSION_CODENAME"; }
has_root_key() { grep -qE '^(ssh-(ed25519|rsa)|ecdsa-|sk-)' /root/.ssh/authorized_keys 2>/dev/null; }

# --- 1. repositories --------------------------------------------------------------------------
repos_step() {
  step "Package repositories"
  local f changed=0
  # deb822 (.sources, Proxmox 9) files: add "Enabled: no" to enterprise entries.
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -e $f ]] || continue
    grep -q 'enterprise.proxmox.com' "$f" || continue
    if grep -qi '^Enabled: *no' "$f"; then skip "$(basename "$f") already disabled"; continue; fi
    if planning; then plan "disable enterprise repo in $f"; continue; fi
    backup_file "$f"; printf 'Enabled: no\n' >> "$f"; ok "disabled $f"; changed=1
  done
  # one-line (.list, Proxmox 8) files: comment the enterprise lines out.
  for f in /etc/apt/sources.list.d/*.list; do
    [[ -e $f ]] || continue
    grep -qE '^[^#].*enterprise.proxmox.com' "$f" || continue
    if planning; then plan "comment out enterprise repo in $f"; continue; fi
    backup_file "$f"; sed -i -E 's|^([^#].*enterprise\.proxmox\.com.*)|# disabled by haki: \1|' "$f"; ok "disabled $f"; changed=1
  done
  # the free repository
  if grep -rqs 'pve-no-subscription' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    skip "no-subscription repository already configured"
  else
    write_file /etc/apt/sources.list.d/proxmox.sources 0644 <<EOF
# Added by haki: Proxmox VE updates without a subscription.
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $(codename)
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    changed=1
  fi
  if [[ $changed == 1 ]] && ! planning; then
    run "apt update" bash -c 'apt-get update -qq >/dev/null 2>&1' || warn "apt update reported problems: run 'apt update' to see them"
  fi
  return 0
}

# --- 2. SSH -----------------------------------------------------------------------------------
ssh_step() {
  step "SSH: key-only root login"
  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
# Added by haki (module: hardening). Key-only SSH for root.
# The Proxmox web UI and its Shell/console still work with your password.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  if [[ -e $SSH_DROPIN ]] && cmp -s "$tmp" "$SSH_DROPIN"; then skip "already key-only"; rm -f "$tmp"; return 0; fi

  if ! has_root_key; then
    warn "root has no SSH key in /root/.ssh/authorized_keys — leaving password login ON."
    note "Add your public key first (from your PC):  ssh-copy-id root@$(bridge_ip "$HAKI_BRIDGE")"
    note "Then log in with it once, and run: haki install hardening"
    rm -f "$tmp"; return 0
  fi
  if planning; then plan "create $SSH_DROPIN, check it with 'sshd -t', reload sshd"; rm -f "$tmp"; return 0; fi

  echo "    root has $(grep -cE '^(ssh|ecdsa|sk-)' /root/.ssh/authorized_keys) SSH key(s). After this, password logins over SSH stop working."
  echo "    Your current session stays open. Keep it open until you've tested a new key login."
  if ! confirm "Have you already logged in over SSH with one of these keys?"; then
    skip "left SSH unchanged. Test 'ssh -i <your key> root@host' first, then re-run."
    rm -f "$tmp"; return 0
  fi
  install_file "$tmp" "$SSH_DROPIN" 0644; rm -f "$tmp"
  if ! sshd -t; then
    bad "sshd rejected the new config — removing it again"
    rm -f "$SSH_DROPIN"; return 1
  fi
  run "reload sshd (existing sessions stay connected)" systemctl reload ssh
  note "Now open a NEW terminal and check: ssh root@$(bridge_ip "$HAKI_BRIDGE")"
}

# --- 3. sysctl --------------------------------------------------------------------------------
sysctl_step() {
  step "Kernel network settings"
  write_file "$SYSCTL_FILE" 0644 <<'EOF'
# Added by haki (module: hardening). Conservative: nothing here changes routing or forwarding.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
  planning || run "load the settings now" sysctl -q --load "$SYSCTL_FILE"
}

module_install() { repos_step && ssh_step && sysctl_step; }

module_uninstall() {
  remove_file "$SSH_DROPIN"
  planning || { sshd -t && run "reload sshd" systemctl reload ssh; }
  remove_file "$SYSCTL_FILE"
  note "Repositories are left as they are: re-enabling 'enterprise' without a subscription breaks apt."
  note "Your original repo files are in $HAKI_STATE/backups/ if you want them back."
}

# enterprise_enabled: true if any enterprise repo is still active (either file format).
enterprise_enabled() {
  local f
  grep -qsE '^[^#]*enterprise\.proxmox\.com' /etc/apt/sources.list /etc/apt/sources.list.d/*.list && return 0
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -e $f ]] && grep -q enterprise.proxmox.com "$f" && ! grep -qi '^Enabled: *no' "$f" && return 0
  done
  return 1
}

module_status() {
  local rc=0
  if ! enterprise_enabled; then
    ok "enterprise repositories disabled"
  else bad "an enterprise repository is still enabled (apt update will fail without a subscription)"; rc=1; fi
  if grep -rqs pve-no-subscription /etc/apt/sources.list /etc/apt/sources.list.d/; then ok "no-subscription repository configured"
  else bad "no Proxmox update repository configured"; rc=1; fi

  local pa pr
  pa=$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" { print $2 }')
  pr=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" { print $2 }')
  if [[ $pa == no && $pr != yes ]]; then ok "SSH is key-only (passwordauthentication=$pa, permitrootlogin=$pr)"
  elif has_root_key; then bad "SSH still accepts passwords. Fix: haki install hardening"; rc=1
  else bad "SSH accepts passwords and root has no key yet. Add a key: ssh-copy-id root@<host>"; rc=1; fi

  if [[ $(sysctl -n net.ipv4.conf.all.accept_redirects) == 0 && $(sysctl -n net.ipv4.tcp_syncookies) == 1 ]]; then ok "network hardening settings active"
  else bad "network hardening settings not active. Fix: haki install hardening"; rc=1; fi
  return $rc
}
