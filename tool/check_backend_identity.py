"""Fail if another Supabase backend (e.g. Flixvault's or Puffle's project) or a partner key enters SkyKeep's source.

SkyKeep talks to Flixvault only through the FLIXVAULT_FEED_URL / FLIXVAULT_PARTNER_KEY secrets (or the private
settings row), never through addresses or keys in the repository.  Usage: python3 tool/check_backend_identity.py
"""
from pathlib import Path
import re
import subprocess

OWN = b'vzeehoissxdutmxdezjf'
ALLOWED = {OWN, b'placeholder'}          # CI build placeholder in .github/workflows/admin.yml
root = Path(__file__).resolve().parent.parent
fail = []
for name in filter(None, subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')):
    p = root / name
    if not p.is_file():
        continue
    data = p.read_bytes().lower()
    for ref in set(re.findall(rb'([a-z0-9-]+)\.supabase\.(?:co|in)\b', data)):
        if ref not in ALLOWED:
            fail.append(f'{name}: other Supabase project {ref.decode()}')
    if re.search(rb'x-partner-key["\']?\s*[:=]\s*["\'][a-z0-9_-]{16,}', data):
        fail.append(f'{name}: partner key in source')
assert not fail, 'Backend identity check failed:\n' + '\n'.join(fail)
print('SkyKeep backend identity checks passed.')
