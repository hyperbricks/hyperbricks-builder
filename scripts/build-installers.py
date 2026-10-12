"""Build the self-contained shell installer and its verification hashes."""
from pathlib import Path
import hashlib
import sys
root = Path(__file__).resolve().parents[1]
folder = root / 'installers'
shell = (folder / 'install.template.sh').read_text()
outputs = {folder / 'install.sh': shell.encode()}
if (folder / 'install.ps1').exists():
    outputs[folder / 'install.ps1.sha256'] = (hashlib.sha256((folder / 'install.ps1').read_bytes()).hexdigest() + '  install.ps1\n').encode()
outputs[folder / 'install.sh.sha256'] = (hashlib.sha256(shell.encode()).hexdigest() + '  install.sh\n').encode()
for path, data in outputs.items():
    if '--check' in sys.argv:
        if not path.exists() or path.read_bytes() != data:
            raise SystemExit(f'Stale installer: {path.name}')
    else:
        path.write_bytes(data)
