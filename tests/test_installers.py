import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ['darwin_amd64','darwin_arm64','linux_amd64','linux_arm64','windows_amd64']

def release(tag, blobs=None):
    assets=[]
    for platform in PLATFORMS:
        name=f'hyperbricks_{tag}_{platform}' + ('.zip' if platform.startswith('windows') else '.tar.gz')
        for filename in (name,name+'.sha256'):
            content=(blobs or {}).get(filename,b'fixture')
            assets.append(dict(name=filename,state='uploaded',digest='sha256:'+hashlib.sha256(content).hexdigest()))
    return dict(tag_name=tag,draft=False,assets=assets)

class InstallerSelection(unittest.TestCase):
    def select(self, releases, wanted=''):
        return subprocess.run(['awk','-v','platform=darwin_arm64','-v',f'wanted={wanted}','-f',str(ROOT/'installers/releases.awk')],input=json.dumps(releases),text=True,capture_output=True)

    def test_semver_complete_and_explicit(self):
        versions=['v1.9.0','v1.10.0-beta.2','v1.10.0-beta.10','v1.10.0']
        rows=[release(v) for v in versions]
        self.assertTrue(self.select(rows).stdout.startswith('v1.10.0 '))
        self.assertTrue(self.select(rows[:-1]).stdout.startswith('v1.10.0-beta.10 '))
        rows[-1]['assets'].pop()
        self.assertTrue(self.select(rows).stdout.startswith('v1.10.0-beta.10 '))
        self.assertNotEqual(self.select(rows,'v1.10.0').returncode,0)
        rows[2]['draft']=True
        self.assertTrue(self.select(rows).stdout.startswith('v1.10.0-beta.2 '))
        self.assertTrue(self.select(rows,'v1.9.0').stdout.startswith('v1.9.0 '))
        self.assertNotEqual(self.select(rows,'v9.0.0').returncode,0)

    def test_bad_json_and_tags(self):
        for tag in ('../../bad','v01.2.3','v1.2.3-beta.01','v1.2.3-beta..1'):
            self.assertNotEqual(self.select([release(tag)]).returncode,0,tag)
        result=subprocess.run(['awk','-f',str(ROOT/'installers/releases.awk')],input='[{"tag_name":',text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)

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
            metadata=release(tag,blobs)
            for name,blob in blobs.items(): (temp/name).write_bytes(blob)
            if fault=='hash':
                for name in blobs:
                    if name.endswith('.tar.gz'): (temp/name).write_bytes(b'corrupt')
            (temp/'metadata').write_text(json.dumps([metadata]))
            (temp/'release').write_text(json.dumps(metadata))
            curl='''#!/usr/bin/env python3
import os,sys,shutil
from pathlib import Path
args=sys.argv[1:];url=args[-1];out=args[args.index('--output')+1];headers=args[args.index('--dump-header')+1]
root=Path(os.environ['FIXTURE']);fault=os.environ.get('FAULT','')
if fault=='redirect':
 Path(headers).write_text('HTTP/1.1 302 Found\\r\\nLocation: https://evil.example/payload\\r\\n');print('302',end='');sys.exit(0)
Path(headers).write_text('HTTP/1.1 200 OK\\r\\n')
if fault=='interrupted': sys.exit(18)
name='metadata' if '?per_page=' in url else ('release' if '/releases/tags/' in url else url.rsplit('/',1)[-1])
shutil.copyfile(root/name,out);print('200',end='')
'''
            (fake/'curl').write_text(curl);(fake/'curl').chmod(0o755)
            env=dict(os.environ,PATH=str(fake)+os.pathsep+os.environ['PATH'],FIXTURE=str(temp),FAULT=fault or '')
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
        for fault in ('hash','traversal','symlink','redirect','interrupted'):
            with self.subTest(fault=fault):self.exercise(fault)

if __name__=='__main__':unittest.main()
