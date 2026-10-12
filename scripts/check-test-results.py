"""Require real passing tests, not just a successful invocation with no tests."""
import json
import sys
from pathlib import Path


def verify(path, windows=False):
    required = {
        'TestRuntimeProcessLifecycle',
        'TestRuntimeProcessRejectsInvalidPID',
        'TestResponseCacheNamespaceOwnershipAndShutdown',
    }
    if windows:
        required.add('TestWindowsRuntimeTerminatesChildProcesses')
    passed = set()
    for line in Path(path).read_text(encoding='utf-8').splitlines():
        event = json.loads(line)
        if event.get('Action') == 'fail':
            raise ValueError('Go tests failed: ' + event.get('Test', event.get('Package', 'unknown')))
        if event.get('Action') == 'pass' and event.get('Package') == 'github.com/hyperbricks/hyperbricks/cmd/hyperbricks':
            passed.add(event.get('Test'))
    missing = required - passed
    if missing:
        raise ValueError('Required tests did not pass: ' + ', '.join(sorted(missing)))


if __name__ == '__main__':
    verify(sys.argv[1], windows=sys.argv[2] == 'windows')
    print('Required process and cache tests passed.')
