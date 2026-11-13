# Writing a module

A module is a folder in `modules/` with a `module.sh` that sets a few variables and defines a few
functions. The `haki` command finds it automatically — no registration needed.

```
modules/my-thing/
├── module.sh        required
└── files/           optional: scripts and templates the module installs
```

## module.sh

```bash
# shellcheck shell=bash
MODULE_SUMMARY="One line for 'haki list'"
MODULE_ABOUT="A few paragraphs for 'haki info': what it does, why you'd want it,
and when you shouldn't install it."
MODULE_CHANGES="/usr/local/sbin/my-thing          what each file is for
/etc/systemd/system/my-thing.service"
MODULE_REQUIRES="optional: what the user needs first"
MODULE_COMMANDS="haki my-thing hello    what it does"   # optional

module_check() {        # optional: return 1 (with a hint) if it can't be installed yet
  [[ -n $HAKI_SOMETHING ]] || { bad "set HAKI_SOMETHING first"; return 1; }
}

module_install() {      # required — also used for `haki plan`, so only change things via helpers
  step "The script"
  install_file "$MODULE_DIR/files/my-thing" /usr/local/sbin/my-thing 0755
  write_file /etc/systemd/system/my-thing.service 0644 <<'EOF'
[Service]
ExecStart=/usr/local/sbin/my-thing
EOF
  if planning; then plan "enable my-thing.service"; return 0; fi
  run "enable it" systemctl enable --now my-thing.service
}

module_uninstall() {    # required — remove what install added
  planning || systemctl disable --now my-thing.service
  remove_file /etc/systemd/system/my-thing.service
  remove_file /usr/local/sbin/my-thing
}

module_status() {       # required — print ✓/✗ lines; return 1 if something is wrong
  systemctl is-active -q my-thing.service && ok "running" || { bad "not running. Fix: haki install my-thing"; return 1; }
}

module_cmd_hello() {    # optional: becomes `haki my-thing hello`
  echo "hello"
}
```

## The rules

1. **Change the system only through the helpers** — `install_file`, `write_file`, `remove_file`,
   `run`, `conf_set`. They print the change, back up what they replace, and do nothing in plan mode.
   If you must do something else, guard it: `if planning; then plan "what"; else …; fi`.
2. **Idempotent.** Running install twice must be harmless.
3. **Explain.** Every `bad` line should end with what to do (`Fix: …`). `MODULE_ABOUT` says *why*.
4. **No secrets in the repo**, and never print them. Ask with `read -s`, store root-only.
5. **Nothing public by default.** A module never opens a port or creates a public hostname unless
   that is its whole purpose and `haki info` says so loudly.
6. **No lockouts.** Anything touching SSH, the network or the firewall needs a check that the user
   can still get in, and a way back.

Helpers available (from `lib/common.sh`): `step ok skip warn bad note plan die`, `ask` / `confirm`,
`planning`, `install_file`, `write_file`, `remove_file`, `run`, `backup_file`, `conf_set`,
`default_bridge`, `default_gateway`, `bridge_ip`, `root_disk`, and all `HAKI_*` settings.
