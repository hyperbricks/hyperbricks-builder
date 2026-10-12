"""Publish a complete tested distribution to an existing HyperBricks tag.

Never creates tags or overwrites published releases/assets. Requires a token
scoped to contents:write on hyperbricks/hyperbricks, supplied only to this job.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import tarfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPO = 'hyperbricks/hyperbricks'
PLATFORMS = [('darwin','amd64'),('darwin','arm64'),('linux','amd64'),('linux','arm64'),('windows','amd64')]

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('Unexpected GitHub API redirect')

class GitHub:
    def __init__(self, token):
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())
    def call(self, path, method='GET', data=None, binary=False):
        url = path if path.startswith('https:') else f'https://api.github.com/repos/{REPO}{path}'
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != 'https' or parsed.hostname not in ('api.github.com','uploads.github.com') or parsed.username or parsed.port not in (None,443):
            raise ValueError('Unexpected API origin')
        headers={'Authorization':'Bearer '+self.token, 'Accept':'application/vnd.github+json',
                 'X-GitHub-Api-Version':'2022-11-28','User-Agent':'hyperbricks-builder'}
        if data is not None:
            headers['Content-Type']='application/octet-stream' if binary else 'application/json'
            if not binary: data=json.dumps(data).encode()
        with self.opener.open(urllib.request.Request(url,data=data,method=method,headers=headers),timeout=120) as response:
            return json.load(response)

def sha(data): return hashlib.sha256(data).hexdigest()

def validate_artifacts(directory, tag, commit):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', tag): raise ValueError('Invalid release tag')
    if not re.fullmatch(r'[0-9a-f]{40}',commit): raise ValueError('Invalid source SHA')
    files={}
    for goos,arch in PLATFORMS:
        base=f'hyperbricks_{tag}_{goos}_{arch}'
        name=base+('.zip' if goos=='windows' else '.tar.gz')
        for filename in (name,name+'.sha256',base+'.json'):
            path=directory/filename
            if path.is_symlink() or not path.is_file(): raise ValueError('Missing regular artifact: '+filename)
            files[filename]=path.read_bytes()
        digest=sha(files[name])
        if files[name+'.sha256'] != f'{digest}  {name}\n'.encode(): raise ValueError('Checksum mismatch: '+name)
        metadata=json.loads(files[base+'.json'])
        expected={'repository':'https://github.com/'+REPO,'tag':tag,'commit':commit,'os':goos,'arch':arch,'cgo_enabled':'0','archive_sha256':digest}
        if any(metadata.get(k)!=v for k,v in expected.items()): raise ValueError('Source metadata mismatch: '+name)
        member='hyperbricks.exe' if goos=='windows' else 'hyperbricks'
        if goos=='windows':
            with zipfile.ZipFile(io.BytesIO(files[name])) as z:
                if z.namelist()!=[member]: raise ValueError('Unsafe ZIP members')
                mode=(z.infolist()[0].external_attr >> 16) & 0o170000
                if mode not in (0,0o100000): raise ValueError('Non-regular ZIP member')
                binary=z.read(member)
        else:
            with tarfile.open(fileobj=io.BytesIO(files[name]),mode='r:gz') as t:
                members=t.getmembers()
                if len(members)!=1 or members[0].name!=member or not members[0].isfile(): raise ValueError('Unsafe tar members')
                binary=t.extractfile(members[0]).read()
        if sha(binary)!=metadata.get('binary_sha256'): raise ValueError('Binary checksum mismatch')
    return files

def verify_source(api, tag, commit):
    obj=api.call('/git/ref/tags/'+urllib.parse.quote(tag,safe=''))['object']
    for _ in range(5):
        if obj['type']=='commit': break
        if obj['type']!='tag': raise ValueError('Tag does not reference a commit')
        obj=api.call('/git/tags/'+obj['sha'])['object']
    if obj['type']!='commit' or obj['sha']!=commit: raise ValueError('Release tag moved or does not match tested source')
    comparison=api.call('/compare/'+commit+'...main')
    if comparison['status'] not in ('ahead','identical'): raise ValueError('Source is not reachable from main')

def publish(api, tag, commit, files):
    verify_source(api,tag,commit)
    marker=f'HyperBricks distribution\n\nSource commit: `{commit}`\n'
    existing=None
    for page in range(1,1001):
        releases=api.call(f'/releases?per_page=100&page={page}')
        matches=[r for r in releases if r['tag_name']==tag]
        if matches: existing=matches[0];break
        if len(releases)<100: break
    else: raise ValueError('Release listing too large')
    if existing:
        if not existing['draft']: raise ValueError('Release already published; refusing to overwrite')
        if existing.get('body')!=marker: raise ValueError('Existing draft has different provenance; refusing to modify')
        release=existing
    else:
        # Verify an existing tag immediately before creation. No tag creation path.
        verify_source(api,tag,commit)
        release=api.call('/releases','POST',{'tag_name':tag,'target_commitish':commit,'name':tag,'body':marker,'draft':True,'prerelease':'-' in tag,'make_latest':'false'})
    release_id=release['id']
    assets={a['name']:a for a in release.get('assets',[])}
    if set(assets)-set(files): raise ValueError('Unexpected assets in draft')
    upload=release['upload_url'].split('{',1)[0]
    for name,data in files.items():
        if name in assets:
            asset=assets[name]
        else:
            asset=api.call(upload+'?name='+urllib.parse.quote(name,safe=''),'POST',data,binary=True)
        if asset.get('digest')!='sha256:'+sha(data) or asset.get('size')!=len(data) or asset.get('state')!='uploaded':
            raise ValueError('Uploaded asset verification failed: '+name)
    verified=api.call(f'/releases/{release_id}')
    actual={a['name']:a for a in verified['assets']}
    if set(actual)!=set(files): raise ValueError('Incomplete draft release')
    for name,data in files.items():
        if actual[name].get('digest')!='sha256:'+sha(data) or actual[name].get('size')!=len(data): raise ValueError('Final digest mismatch')
    verify_source(api,tag,commit)
    return api.call(f'/releases/{release_id}','PATCH',{'draft':False,'make_latest':'false'})

if __name__=='__main__':
    token=os.environ.get('RELEASE_TOKEN')
    if not token: raise SystemExit('Configure RELEASE_TOKEN with contents:write for hyperbricks/hyperbricks before publishing')
    tag=os.environ['RELEASE_TAG'];commit=os.environ['SOURCE_SHA']
    files=validate_artifacts(Path('release-assets'),tag,commit)
    installer_dir=Path('installers')
    for name in ('install.sh','install.ps1'):
        data=(installer_dir/name).read_bytes()
        checksum=f'{sha(data)}  {name}\n'.encode()
        if (installer_dir/(name+'.sha256')).read_bytes()!=checksum: raise SystemExit('Stale installer checksum')
        files[name]=data;files[name+'.sha256']=checksum
    files['SHA256SUMS']=''.join(f'{sha(data)}  {name}\n' for name,data in sorted(files.items())).encode()
    result=publish(GitHub(token),tag,commit,files)
    print('Published verified release:',result['html_url'])
