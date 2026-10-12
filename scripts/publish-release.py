"""Publish a complete tested distribution in the builder repository.

Creates a builder release tag; never writes to the product repository or
overwrites published releases/assets. Uses the publication job GITHUB_TOKEN.
"""
import base64
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

REPO = 'hyperbricks/hyperbricks-builder'
SOURCE_REPO = 'hyperbricks/hyperbricks'
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
        if method != 'GET' and not parsed.path.startswith('/repos/'+REPO+'/'):
            raise ValueError('Writes outside builder repository are forbidden')
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
        expected={'repository':'https://github.com/'+SOURCE_REPO,'tag':tag,'commit':commit,'os':goos,'arch':arch,'cgo_enabled':'0','archive_sha256':digest}
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
    obj=api.call('https://api.github.com/repos/'+SOURCE_REPO+'/git/ref/tags/'+urllib.parse.quote(tag,safe=''))['object']
    for _ in range(5):
        if obj['type']=='commit': break
        if obj['type']!='tag': raise ValueError('Tag does not reference a commit')
        obj=api.call('https://api.github.com/repos/'+SOURCE_REPO+'/git/tags/'+obj['sha'])['object']
    if obj['type']!='commit' or obj['sha']!=commit: raise ValueError('Release tag moved or does not match tested source')
    comparison=api.call('https://api.github.com/repos/'+SOURCE_REPO+'/compare/'+commit+'...main')
    if comparison['status'] not in ('ahead','identical'): raise ValueError('Source is not reachable from main')

def publish(api, tag, commit, files, builder_commit):
    if not re.fullmatch(r"[0-9a-f]{40}", builder_commit): raise ValueError("Invalid builder commit")
    verify_source(api,tag,commit)
    marker=f'HyperBricks distribution\n\nSource: https://github.com/{SOURCE_REPO}/commit/{commit}\nBuilder commit: `{builder_commit}`\n'
    try:
        obj=api.call('/git/ref/tags/'+urllib.parse.quote(tag,safe=''))['object']
    except urllib.error.HTTPError as error:
        if error.code != 404: raise
        obj={'type':'commit','sha':builder_commit}  # Created by release publication.
    for _ in range(5):
        if obj['type']=='commit': break
        if obj['type']!='tag': raise ValueError('Invalid builder tag')
        obj=api.call('/git/tags/'+obj['sha'])['object']
    if obj['type']!='commit' or obj['sha']!=builder_commit:
        raise ValueError('Builder release tag does not match this workflow commit')
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
        # Verify the read-only product source before creating a builder release tag.
        verify_source(api,tag,commit)
        release=api.call('/releases','POST',{'tag_name':tag,'target_commitish':builder_commit,'name':tag,'body':marker,'draft':True,'prerelease':'-' in tag,'make_latest':'false'})
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

def version_key(tag):
    if not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?', tag):
        raise ValueError('Invalid version file')
    core, separator, pre = tag[1:].partition('-')
    parts = []
    for item in pre.split('.') if separator else []:
        if item.isdigit() and len(item)>1 and item.startswith('0'):
            raise ValueError('Invalid prerelease version')
        parts.append((0, int(item)) if item.isdigit() else (1, item))
    return tuple(map(int, core.split('.'))), not bool(separator), tuple(parts)

def update_version(api, tag):
    """Advance the public pointer only to a complete published builder release."""
    incoming = version_key(tag)
    release = api.call('/releases/tags/'+urllib.parse.quote(tag, safe=''))
    if release['draft'] or release['tag_name'] != tag:
        raise ValueError('Version pointer requires a published release')
    for goos, arch in PLATFORMS:
        name = f'hyperbricks_{tag}_{goos}_{arch}'+('.zip' if goos=='windows' else '.tar.gz')
        for filename in (name, name+'.sha256'):
            assets = [a for a in release['assets'] if a['name']==filename]
            if len(assets)!=1 or assets[0].get('state')!='uploaded' or not re.fullmatch(r'sha256:[0-9a-f]{64}', assets[0].get('digest','')):
                raise ValueError('Version pointer requires complete downloads')
    current = None
    try:
        current = api.call('/contents/version.md?ref=main')
    except urllib.error.HTTPError as error:
        if error.code != 404: raise
    if current is not None:
        text = base64.b64decode(current['content']).decode('utf-8')
        if not text.endswith('\n') or text.count('\n')!=1:
            raise ValueError('Invalid existing version.md')
        if version_key(text[:-1]) >= incoming:
            return  # Never downgrade the published channel.
    data = {'message':'Update published version to '+tag, 'branch':'main',
            'content':base64.b64encode((tag+'\n').encode()).decode()}
    if current is not None: data['sha']=current['sha']
    api.call('/contents/version.md', 'PUT', data)

if __name__=='__main__':
    token=os.environ.get('RELEASE_TOKEN')
    if not token: raise SystemExit('The publication job requires its GITHUB_TOKEN with contents:write on hyperbricks-builder')
    tag=os.environ['RELEASE_TAG'];commit=os.environ['SOURCE_SHA']
    files=validate_artifacts(Path('release-assets'),tag,commit)
    installer_dir=Path('installers')
    for name in ('install.sh','install.ps1'):
        data=(installer_dir/name).read_bytes()
        checksum=f'{sha(data)}  {name}\n'.encode()
        if (installer_dir/(name+'.sha256')).read_bytes()!=checksum: raise SystemExit('Stale installer checksum')
        files[name]=data;files[name+'.sha256']=checksum
    files['SHA256SUMS']=''.join(f'{sha(data)}  {name}\n' for name,data in sorted(files.items())).encode()
    api=GitHub(token)
    result=publish(api,tag,commit,files,os.environ['GITHUB_SHA'])
    update_version(api,tag)
    print('Published verified release:',result['html_url'])
