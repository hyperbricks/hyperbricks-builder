import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('checks', ROOT / 'scripts/check-test-results.py')
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class TagSelection(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('commit', '--allow-empty', '-m', 'Main fixture')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.path), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def select(self):
        return subprocess.run(['bash', str(ROOT / 'scripts/latest-tag.sh'), str(self.path)], capture_output=True, text=True)

    def test_version_order_and_annotated_tags(self):
        self.git('tag', 'v1.9.0')
        self.git('tag', '-a', 'v1.10.0-beta', '-m', 'Beta fixture')
        self.assertEqual(self.select().stdout.strip(), 'v1.10.0-beta')
        self.git('tag', 'v1.10.0')
        self.assertEqual(self.select().stdout.strip(), 'v1.10.0')

    def test_newer_tag_outside_main_is_excluded(self):
        self.git('tag', 'v1.3.2-beta')
        self.git('checkout', '-b', 'other')
        self.git('commit', '--allow-empty', '-m', 'Other fixture')
        self.git('tag', 'v99.0.0')
        self.git('checkout', 'main')
        self.assertEqual(self.select().stdout.strip(), 'v1.3.2-beta')

    def test_no_valid_tag_fails(self):
        self.git('tag', 'preview')
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


class RequiredTests(unittest.TestCase):
    def test_windows_tree_test_must_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'results.jsonl'
            names = ['TestRuntimeProcessLifecycle', 'TestRuntimeProcessRejectsInvalidPID',
                     'TestResponseCacheNamespaceOwnershipAndShutdown']
            records = [dict(Action='pass', Test=n, Package='github.com/hyperbricks/hyperbricks/cmd/hyperbricks') for n in names]
            path.write_text('\n'.join(json.dumps(r) for r in records))
            checks.verify(path)
            with self.assertRaisesRegex(ValueError, 'TestWindowsRuntimeTerminatesChildProcesses'):
                checks.verify(path, windows=True)
            records.append(dict(Action='skip', Test='TestWindowsRuntimeTerminatesChildProcesses'))
            path.write_text('\n'.join(json.dumps(r) for r in records))
            with self.assertRaises(ValueError):
                checks.verify(path, windows=True)
            records[-1] = dict(Action='pass', Test='TestWindowsRuntimeTerminatesChildProcesses', Package='github.com/hyperbricks/hyperbricks/cmd/hyperbricks')
            path.write_text('\n'.join(json.dumps(r) for r in records))
            checks.verify(path, windows=True)
            records.append(dict(Action='fail', Package='github.com/hyperbricks/hyperbricks/cmd/hyperbricks'))
            path.write_text('\n'.join(json.dumps(r) for r in records))
            with self.assertRaises(ValueError):
                checks.verify(path, windows=True)


if __name__ == '__main__':
    unittest.main()
