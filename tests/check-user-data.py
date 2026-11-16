"""Check the cloud-init file ollama-gpu renders (called by tests/smoke.sh)."""
import sys

import yaml

path = sys.argv[1]
with open(path) as f:
    assert f.readline().strip() == "#cloud-config", "first line must be #cloud-config"
with open(path) as f:
    d = yaml.safe_load(f)

user = d["users"][0]
assert user["ssh_authorized_keys"] == ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnlyForCI test@ci"], user
assert user["lock_passwd"] is True and d["ssh_pwauth"] is False, "no passwords"

# A stray ": " in a command turns it into a mapping; cloud-init then rejects the whole file.
bad = [c for c in d["runcmd"] if not isinstance(c, str)]
assert not bad, f"every runcmd entry must be a plain string, got: {bad}"
assert all(isinstance(p, str) for p in d["packages"]), d["packages"]
cmds = d["runcmd"]
api = [c for c in cmds if "port 11434" in c]
assert len(api) == 2 and "192.168.1.240" in api[0] and "192.168.1.42" in api[1], api


def first(word):
    return next(i for i, c in enumerate(cmds) if word in c)


assert first("ufw --force enable") < first("ollama.com/install.sh"), "firewall must be up before ollama listens"
assert first("ubuntu-drivers") < first("ollama.com/install.sh"), "driver must come before ollama"
assert first("ollama.com/install.sh") < first("systemctl enable ollama"), "ollama must be enabled after it's installed"
print("cloud-init ok")
