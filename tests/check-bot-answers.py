"""Render every discord-bot command from tests/fixtures/snapshot.json (called by tests/smoke.sh).

Checks each answer is a valid Discord embed within Discord's limits, and spot-checks content.
"""
import json
import subprocess
import sys

BOT, SNAP = sys.argv[1], sys.argv[2]
CMDS = ['status', 'alerts', 'site', 'guests', 'host', 'backup', 'ollama', 'notes', 'help']


def render(cmd):
    out = subprocess.run([sys.executable, BOT, '--render', cmd, '--snapshot', SNAP, '--offline'],
                         capture_output=True, text=True, timeout=30, check=True).stdout
    return json.loads(out)


answers = {}
for c in CMDS:
    e = answers[c] = render(c)
    assert 'failed' not in e['title'], f'/{c}: {e}'
    assert len(e['title']) <= 256 and len(e.get('description', '')) <= 4096, c
    fields = e.get('fields', [])
    assert len(fields) <= 25, c
    for f in fields:
        assert f['name'] and f['value'] and len(f['name']) <= 256 and len(f['value']) <= 1024, (c, f)
    total = len(e['title']) + len(e.get('description', '')) + sum(len(f['name']) + len(f['value']) for f in fields) \
        + len(e.get('footer', {}).get('text', ''))
    assert total <= 6000, f'/{c} is {total} characters (Discord allows 6000)'

assert answers['status']['title'].startswith('🔴 1 problem'), answers['status']['title']
assert 'Container 202' in answers['status']['description']
assert '3 of 4 running' in answers['guests']['title']
assert 'CT 202 shop** (stopped)' in answers['guests']['description'], answers['guests']['description']
assert any('shop.example.com' in f['value'] for f in answers['site']['fields'])
assert 'one-off blip' in json.dumps(answers['alerts'], ensure_ascii=False)
assert '/backup' in answers['help']['description']

# The terminal view turns Discord's timestamps into readable text.
text = subprocess.run([sys.executable, BOT, '--render', 'alerts', '--snapshot', SNAP, '--offline', '--text'],
                      capture_output=True, text=True, timeout=30, check=True).stdout
assert '<t:' not in text and '**' not in text, text

# No snapshot at all: a clear message, not a crash.
e = json.loads(subprocess.run([sys.executable, BOT, '--render', 'status', '--snapshot', '/nonexistent', '--offline'],
                              capture_output=True, text=True, timeout=30, check=True).stdout)
assert e['title'] == 'No data yet', e
print('bot answers ok')
