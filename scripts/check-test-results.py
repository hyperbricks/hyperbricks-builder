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
    output = {}
    failures = []
    for line in Path(path).read_text(encoding='utf-8').splitlines():
        event = json.loads(line)
        name = event.get('Test', event.get('Package', 'unknown'))
        if event.get('Action') == 'output':
            output.setdefault(name, []).append(event.get('Output', ''))
        if event.get('Action') == 'fail':
            failures.append(name)
        if event.get('Action') == 'pass' and event.get('Package') == 'github.com/hyperbricks/hyperbricks/cmd/hyperbricks':
            passed.add(event.get('Test'))
    if failures:
        details = ['Go tests failed: ' + name + '\n' + ''.join(output.get(name, [])[-30:]) for name in failures]
        raise ValueError('\n'.join(details))
    missing = required - passed
    if missing:
        raise ValueError('Required tests did not pass: ' + ', '.join(sorted(missing)))


if __name__ == '__main__':
    try:
        verify(sys.argv[1], windows=sys.argv[2] == 'windows')
    except ValueError as error:
        message = str(error).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::error title=HyperBricks test failure::' + message)
        raise SystemExit(1)
    print('Required process and cache tests passed.')
