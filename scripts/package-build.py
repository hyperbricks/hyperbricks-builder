"""Package a tested native binary, preserving Unix executable permissions."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import zipfile

binary = Path(os.environ['BINARY'])
tag = os.environ['RELEASE_TAG']
goos = os.environ['GOOS']
arch = os.environ['GOARCH']
commit = os.environ['SOURCE_SHA']
out = Path('dist')
out.mkdir(exist_ok=True)
name = f'hyperbricks_{tag}_{goos}_{arch}'
archive = out / (name + ('.zip' if goos == 'windows' else '.tar.gz'))
member = 'hyperbricks.exe' if goos == 'windows' else 'hyperbricks'
if goos == 'windows':
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as handle:
        handle.write(binary, member)
else:
    with tarfile.open(archive, 'w:gz') as handle:
        handle.add(binary, arcname=member)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_name(archive.name + '.sha256').write_text(f'{digest}  {archive.name}\n', encoding='utf-8')
(out / (name + '.json')).write_text(json.dumps({
    'repository': 'https://github.com/hyperbricks/hyperbricks',
    'tag': tag, 'commit': commit, 'os': goos, 'arch': arch,
    'go_version': subprocess.check_output(['go', 'version'], text=True).strip(),
    'cgo_enabled': os.environ['CGO_ENABLED'],
    'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'archive_sha256': digest,
}, indent=2) + '\n', encoding='utf-8')
