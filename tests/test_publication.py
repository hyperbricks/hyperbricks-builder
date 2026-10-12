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
        if path.startswith('/git/ref/'):return {'object':{'type':'commit','sha':'a'*40}}
        if path.startswith('/compare/'):return {'status':'identical'}
        if path.startswith('/releases?'):
            return [{'tag_name':'v1.0.0-beta','draft':False}] if self.published else []
        if path=='/releases' and method=='POST':
            return {'id':1,'assets':[],'upload_url':'https://uploads.github.com/repos/hyperbricks/hyperbricks/releases/1/assets{?name,label}'}
        if path.startswith('https://uploads.'):
            from urllib.parse import parse_qs,urlparse
            name=parse_qs(urlparse(path).query)['name'][0]
            asset={'name':name,'size':len(data),'state':'uploaded','digest':'sha256:'+('0'*64 if self.broken else pub.sha(data))}
            self.assets.append(asset);return asset
        if method=='PATCH':return {'html_url':'fixture'}
        if path=='/releases/1':return {'assets':self.assets}
        raise AssertionError(path)

class Publication(unittest.TestCase):
    def test_publish_after_verified_uploads(self):
        api=FakeAPI();pub.publish(api,'v1.0.0-beta','a'*40,{'a':b'one','b':b'two'})
        self.assertEqual(api.calls[-1],('/releases/1','PATCH'))
    def test_bad_upload_stays_draft(self):
        api=FakeAPI(broken=True)
        with self.assertRaises(ValueError):pub.publish(api,'v1.0.0-beta','a'*40,{'a':b'one'})
        self.assertFalse(any(method=='PATCH' for _,method in api.calls))
    def test_published_release_is_not_modified(self):
        api=FakeAPI(published=True)
        with self.assertRaises(ValueError):pub.publish(api,'v1.0.0-beta','a'*40,{'a':b'one'})
        self.assertTrue(all(method=='GET' for _,method in api.calls))
    def test_moved_tag_is_rejected(self):
        api=FakeAPI()
        with self.assertRaises(ValueError):pub.publish(api,'v1.0.0-beta','b'*40,{'a':b'one'})
        self.assertTrue(all(method=='GET' for _,method in api.calls))

if __name__=='__main__':unittest.main()
