import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ['darwin_amd64','darwin_arm64','linux_amd64','linux_arm64','windows_amd64']

@unittest.skipIf(os.name == "nt", "Unix installer; Windows has native PowerShell coverage")
class ShellInstaller(unittest.TestCase):
    def exercise(self, fault=None, explicit=False):
        with tempfile.TemporaryDirectory() as td:
            temp=Path(td); fake=temp/'bin';fake.mkdir(); target=temp/'target';target.mkdir()
            installed=target/'hyperbricks';installed.write_text('old installation')
            tag=os.environ.get('HB_TEST_VERSION', 'v1.3.2-beta'); body=f'#!/bin/sh\nprintf "%s\\n" "{tag}"\n'.encode()
            if os.environ.get('HB_TEST_BINARY'): body=Path(os.environ['HB_TEST_BINARY']).read_bytes()
            buf=io.BytesIO()
            with tarfile.open(fileobj=buf,mode='w:gz') as archive:
                member=tarfile.TarInfo('../hyperbricks' if fault=='traversal' else 'hyperbricks')
                member.size=len(body);member.mode=0o755
                if fault=='symlink': member.type=tarfile.SYMTYPE;member.linkname='/etc/passwd';member.size=0
                archive.addfile(member,io.BytesIO(body) if member.isfile() else None)
            data=buf.getvalue(); blobs={}
            for platform in PLATFORMS:
                name=f'hyperbricks_{tag}_{platform}'+('.zip' if platform.startswith('windows') else '.tar.gz')
                blobs[name]=data;blobs[name+'.sha256']=(hashlib.sha256(data).hexdigest()+'  '+name+'\n').encode()
            for name,blob in blobs.items(): (temp/name).write_bytes(blob)
            if fault=='hash':
                for name in blobs:
                    if name.endswith('.tar.gz'): (temp/name).write_bytes(b'corrupt')
            (temp/'version.md').write_text('bad/version\n' if fault=='version' else tag+'\n')
            curl='''#!/usr/bin/env python3
import os,sys,shutil
from pathlib import Path
args=sys.argv[1:];url=args[-1]
assert 'api.github.com' not in url, 'Installer must not call GitHub API'
if os.environ.get('EXPLICIT') == '1': assert 'version.md' not in url, 'Explicit tag must skip version lookup'
out=args[args.index('--output')+1];headers=args[args.index('--dump-header')+1]
root=Path(os.environ['FIXTURE']);fault=os.environ.get('FAULT','')
if fault=='redirect':
 Path(headers).write_text('HTTP/1.1 302 Found\\r\\nLocation: https://evil.example/payload\\r\\n');print('302',end='');sys.exit(0)
Path(headers).write_text('HTTP/1.1 200 OK\\r\\n')
if fault=='interrupted': sys.exit(18)
name=url.rsplit('/',1)[-1]
shutil.copyfile(root/name,out);print('200',end='')
'''
            (fake/'curl').write_text(curl);(fake/'curl').chmod(0o755)
            env=dict(os.environ,PATH=str(fake)+os.pathsep+os.environ['PATH'],FIXTURE=str(temp),FAULT=fault or '',EXPLICIT='1' if explicit else '0')
            args=['sh',str(ROOT/'installers/install.sh'),'--install-dir',str(target)]
            if explicit: args += ['--version',tag]
            result=subprocess.run(args,env=env,text=True,capture_output=True)
            if fault:
                self.assertNotEqual(result.returncode,0,(fault,result.stdout,result.stderr))
                self.assertEqual(installed.read_text(),'old installation')
            else:
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(installed.read_bytes(),body)
    def test_install(self): self.exercise()
    def test_explicit_tag(self): self.exercise(explicit=True)
    def test_failures_preserve_installation(self):
        for fault in ('hash','traversal','symlink','redirect','interrupted','version'):
            with self.subTest(fault=fault):self.exercise(fault)

if __name__=='__main__':unittest.main()
