import importlib.util
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('publisher',ROOT/'scripts/publish-release.py')
pub=importlib.util.module_from_spec(spec);spec.loader.exec_module(pub)

class FakeAPI:
    def __init__(self, published=False, broken=False):
        self.calls=[];self.assets=[];self.published=published;self.broken=broken
    def call(self,path,method='GET',data=None,binary=False):
        self.calls.append((path,method))
        if method != 'GET':
            assert not path.startswith('https://api.github.com/repos/hyperbricks/hyperbricks/'), 'Product writes forbidden'
        if '/git/ref/' in path:return {'object':{'type':'commit','sha':('c' if path.startswith('/') else 'a')*40}}
        if '/compare/' in path:return {'status':'identical'}
        if path.startswith('/releases?'):
            return [{'tag_name':'v1.0.0-beta','draft':False}] if self.published else []
        if path=='/releases' and method=='POST':
            assert data['target_commitish'] == 'c'*40
            return {'id':1,'assets':[],'upload_url':'https://uploads.github.com/repos/hyperbricks/hyperbricks-builder/releases/1/assets{?name,label}'}
        if path.startswith('https://uploads.'):
            from urllib.parse import parse_qs,urlparse
            name=parse_qs(urlparse(path).query)['name'][0]
            asset={'name':name,'size':len(data),'state':'uploaded','digest':'sha256:'+('0'*64 if self.broken else pub.sha(data))}
            self.assets.append(asset);return asset
        if method=='PATCH':return {'html_url':'fixture'}
        if path=='/releases/1':return {'assets':self.assets}
        raise AssertionError(path)

class Packaging(unittest.TestCase):
    def test_windows_newlines_do_not_change_checksums(self):
        import os
        import runpy
        import tempfile
        from unittest.mock import patch
        def windows_write_text(path, data, *args, **kwargs):
            with path.open('w', encoding=kwargs.get('encoding', 'utf-8'), newline='\r\n') as handle:
                return handle.write(data)
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            try:
                os.chdir(directory)
                Path('fixture').write_bytes(b'native binary fixture')
                for goos, arch in pub.PLATFORMS:
                    with patch.dict(os.environ, dict(BINARY='fixture', RELEASE_TAG='v1.0.0-beta',
                            GOOS=goos, GOARCH=arch, SOURCE_SHA='a'*40, CGO_ENABLED='0')), \
                         patch.object(Path, 'write_text', windows_write_text), \
                         patch('subprocess.check_output', return_value='go version fixture'):
                        runpy.run_path(str(ROOT/'scripts/package-build.py'))
                files = pub.validate_artifacts(Path('dist'), 'v1.0.0-beta', 'a'*40)
                self.assertEqual(len(files), 15)
                for name, data in files.items():
                    if name.endswith('.sha256'):
                        self.assertNotIn(b'\r', data)
                checksum = next(Path('dist').glob('*.sha256'))
                checksum.write_bytes(b'0'*64 + checksum.read_bytes()[64:])
                with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
                    pub.validate_artifacts(Path('dist'), 'v1.0.0-beta', 'a'*40)
            finally:
                os.chdir(previous)

class Publication(unittest.TestCase):
    def test_publish_after_verified_uploads(self):
        api=FakeAPI();pub.publish(api,'v1.0.0-beta','a'*40,{'a':b'one','b':b'two'},'c'*40)
        self.assertEqual(api.calls[-1],('/releases/1','PATCH'))
    def test_bad_upload_stays_draft(self):
        api=FakeAPI(broken=True)
        with self.assertRaises(ValueError):pub.publish(api,'v1.0.0-beta','a'*40,{'a':b'one'},'c'*40)
        self.assertFalse(any(method=='PATCH' for _,method in api.calls))
    def test_published_release_is_not_modified(self):
        api=FakeAPI(published=True)
        with self.assertRaises(ValueError):pub.publish(api,'v1.0.0-beta','a'*40,{'a':b'one'},'c'*40)
        self.assertTrue(all(method=='GET' for _,method in api.calls))
    def test_product_write_is_rejected(self):
        api=pub.GitHub('unused')
        with self.assertRaises(ValueError):
            api.call('https://api.github.com/repos/hyperbricks/hyperbricks/releases','POST',{})

    def test_moved_tag_is_rejected(self):
        api=FakeAPI()
        with self.assertRaises(ValueError):pub.publish(api,'v1.0.0-beta','b'*40,{'a':b'one'},'c'*40)
        self.assertTrue(all(method=='GET' for _,method in api.calls))


class VersionPointer(unittest.TestCase):
    def api(self, current='v1.0.0-beta', draft=False, incomplete=False):
        import base64
        class API:
            def __init__(self): self.writes=[]
            def call(self,path,method='GET',data=None):
                if method=='PUT': self.writes.append((path,data)); return {}
                if path.startswith('/contents/'):
                    return {'sha':'file-sha','content':base64.b64encode((current+'\n').encode()).decode()}
                assets=[]
                for os_name,arch in pub.PLATFORMS:
                    name=f'hyperbricks_v1.1.0-beta_{os_name}_{arch}'+('.zip' if os_name=='windows' else '.tar.gz')
                    for filename in (name,name+'.sha256'):
                        assets.append({'name':filename,'state':'uploaded','digest':'sha256:'+'a'*64})
                if incomplete: assets.pop()
                return {'tag_name':'v1.1.0-beta','draft':draft,'assets':assets}
        return API()
    def test_complete_release_advances_pointer(self):
        import base64
        api=self.api();pub.update_version(api,'v1.1.0-beta')
        path,data=api.writes[0]
        self.assertEqual(path,'/contents/version.md')
        self.assertEqual(data['branch'],'main')
        self.assertEqual(data['sha'],'file-sha')
        self.assertEqual(base64.b64decode(data['content']),b'v1.1.0-beta\n')
    def test_never_downgrades_or_rewrites_same_version(self):
        for current in ('v2.0.0','v1.1.0','v1.1.0-beta'):
            api=self.api(current=current);pub.update_version(api,'v1.1.0-beta')
            self.assertEqual(api.writes,[])
    def test_draft_and_incomplete_releases_cannot_advance(self):
        for flags in ({'draft':True},{'incomplete':True}):
            api=self.api(**flags)
            with self.assertRaises(ValueError):pub.update_version(api,'v1.1.0-beta')
            self.assertEqual(api.writes,[])
    def test_semver_ordering(self):
        self.assertGreater(pub.version_key('v1.1.0-beta.10'),pub.version_key('v1.1.0-beta.2'))
        self.assertGreater(pub.version_key('v1.1.0'),pub.version_key('v1.1.0-beta.10'))

if __name__=='__main__':unittest.main()
