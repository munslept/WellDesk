"""Fail before compilation if a fresh Git import omitted UI artwork."""
from pathlib import Path
import base64
import re
import sys

root = Path(__file__).resolve().parents[1]
required = {
    'res/icon.png', 'res/icon.ico', 'res/tray-icon.ico',
    'libs/portable/src/res/label.png',
    'flutter/windows/runner/resources/app_icon.ico',
}
for source in (root / 'flutter/lib').rglob('*.dart'):
    for asset in re.findall(r'''["'](assets/[^"'\n]+\.(?:svg|png|ttf))["']''', source.read_text(encoding="utf-8")):
        if '$' not in asset:
            required.add('flutter/' + asset)
missing = sorted(path for path in required if not (root / path).is_file())
if missing:
    print('Missing WellDesk resources:\n' + '\n'.join(missing), file=sys.stderr)
    sys.exit(1)
documented = re.search(r'^- Key: ([A-Za-z0-9+/=]+)\.$',
                       (root / 'README_WELLDESK_RU.md').read_text(encoding='utf-8'), re.M)
configured = re.search(r'\("key", "([A-Za-z0-9+/=]+)"\)',
                       (root / 'libs/hbb_common/src/config.rs').read_text(encoding='utf-8'))
if not documented or not configured or configured.group(1) != documented.group(1) or len(base64.b64decode(configured.group(1))) != 32:
    print('WellDesk client key differs from the documented server key', file=sys.stderr)
    sys.exit(1)
print(f'OK: {len(required)} required UI resources present')
