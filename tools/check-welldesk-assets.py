"""Fail before compilation if a fresh Git import omitted UI artwork."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
required = {
    'res/icon.png', 'res/icon.ico', 'res/tray-icon.ico',
    'libs/portable/src/res/label.png',
    'flutter/windows/runner/resources/app_icon.ico',
}
for source in (root / 'flutter/lib').rglob('*.dart'):
    for asset in re.findall(r'''["'](assets/[^"'\n]+\.(?:svg|png|ttf))["']''', source.read_text()):
        if '$' not in asset:
            required.add('flutter/' + asset)
missing = sorted(path for path in required if not (root / path).is_file())
if missing:
    print('Missing WellDesk resources:\n' + '\n'.join(missing), file=sys.stderr)
    sys.exit(1)
print(f'OK: {len(required)} required UI resources present')
