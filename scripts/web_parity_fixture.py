"""Actual desktop HTTP handler with isolated files and synthetic coding clients.

No installed coding client is contacted. All writable state is below the
explicit temporary directory supplied by the FFI test.
"""
import argparse
import json
from pathlib import Path
import sys
import subprocess
import threading
import time


SID = '11111111-1111-4111-8111-111111111111'
WSL = 'wsl-claude:' + 'a' * 32


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desktop', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.desktop.resolve()))
    from bridge.api.httpd import GatewayServer
    from bridge.features.auth.auth import password_record
    from bridge.features.workspace.workspace import operate

    root = args.directory.resolve()
    root.mkdir(parents=True, exist_ok=True)
    project = root / 'project'
    project.mkdir(exist_ok=True)
    (project / 'hello.txt').write_text('Hello 世界\nline two\n', encoding='utf-8', newline='')
    (project / 'large.bin').write_bytes(bytes(range(256)) * (20_000))
    (project / 'folder').mkdir(exist_ok=True)
    (project / 'folder' / '中文.txt').write_text('内容', encoding='utf-8')
    def git(*fields):
        subprocess.run(['git', *fields], cwd=project, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    git('-c', 'init.templateDir=', 'init', '-b', 'fixture-main')
    for key, value in [('user.name', 'Fixture'), ('user.email', 'fixture@example.invalid'), ('commit.gpgsign', 'false'), ('core.hooksPath', str(root / 'no-hooks')), ('core.autocrlf', 'false')]:
        git('config', '--local', key, value)
    git('add', '.')
    git('commit', '-m', 'Fixture baseline')
    calls = []
    (root / 'account-state.txt').write_text('account-one', encoding='utf-8')
    class Accounts:
        def public(self):
            current = (root / 'account-state.txt').read_text(encoding='utf-8')
            return {'managementRevision': current, 'activeId': current, 'accounts': []}
    class WslAccounts:
        def environments(self, provider):
            assert provider == 'claude'
            return {'provider': provider, 'environments': [{'id': WSL, 'running': True, 'enabled': True, 'label': 'Fixture WSL'}]}
        def read(self, provider, entry):
            assert provider == 'claude' and entry == WSL
            return {'provider': provider, 'entry': entry, 'identity': 'wsl-one', 'available': True, 'accounts': [{'id': 'api-one', 'kind': 'api'}], 'activeId': 'native', 'capabilities': {'switch': True, 'models': True}}
        def change(self, body, desktop):
            assert desktop is False and body['entry'] == WSL and body['provider'] == 'claude'
            calls.append({'wsl': body['action']})
            if body['action'] == 'models': return {'provider': 'claude', 'entry': WSL, 'models': [{'id': 'fixture'}]}
            assert body['action'] == 'switch' and body['expectedIdentity'] == 'wsl-one'
            return {**self.read('claude', WSL), 'activeId': body['id']}

    class SyntheticBridge:
        accounts = Accounts()
        wsl_accounts = WslAccounts()
        host_errors = []
        hosts = type('Hosts', (), {'hosts': lambda self: {}})()
        closed = threading.Event()
        def for_host(self, host):
            if host != 'local': raise KeyError(host)
            return self
        def timeline_read(self, identifier, mode=None, **kwargs):
            if identifier != SID: raise KeyError(identifier)
            if mode == 'detail':
                text = '完整内容 ' * 12_000
                offset = kwargs['offset']; end = min(offset + 4096, len(text))
                return {'key': kwargs['cursor'].split('.', 1)[1], 'version': 'v1', 'offset': offset,
                        'text': text[offset:end], 'next': end if end < len(text) else None}
            return {'epoch': 'native-fixture', 'sequence': 1, 'rows': [
                {'key': 'row', 'role': 'assistant', 'text': 'Complete content', 'version': 'v1'}],
                'before': None, 'hasMore': False, 'meta': {'id': SID, 'host': 'local',
                'title': 'Native contract', 'cwd': str(project), 'status': 'idle', 'connected': True,
                'draftAccountIdentity': 'synthetic-account', 'requests': [],
                'access': {'canSend': True, 'canApprove': True, 'canChangeModel': True}}}
        def workspace(self, identifier, action, body):
            if identifier != SID: raise KeyError(identifier)
            return operate(project, action, body)
        def terminal(self, identifier, owner, action, body):
            calls.append({'terminal': action, 'body': body})
            if action == 'complete':
                return {'replaceStart': 4, 'replaceEnd': 6,
                        'candidates': [{'label': 'folder/', 'insertText': 'folder/'}]}
            return {'id': body['id'], 'running': action != 'close', 'cursor': 0, 'output': '', 'mode': 'pty'}
        def side_chat(self, identifier, owner, action, body):
            calls.append({'side_chat': action, 'body': body})
            return {'chats': []} if action == 'list' else {'id': SID, 'host': 'local'}
        def projects(self, **kwargs):
            if (root / 'delay-projects').exists():
                (root / 'reading-projects').touch()
                time.sleep(.4)
            return [{'key': 'project', 'name': 'Fixture', 'cwd': str(project), 'host': 'local', 'type': 'cli', 'environment': 'cli|local'}]
        def project_environments(self):
            return [{'key': 'cli|local', 'host': 'local', 'type': 'cli', 'name': 'Synthetic CLI'}]
        def creation_models(self, project=None, **kwargs):
            return {'models': [{'id': 'fixture', 'isDefault': True, 'efforts': ['high'], 'defaultEffort': 'high'}], 'cache': {'identity': 'fixture-models'}}
        def create_chat(self, project, title, request, **kwargs):
            calls.append({'create': kwargs})
            return {'id': SID, 'host': 'local', 'status': 'accepted'}
        def project_directories(self, host, path, hidden, name, identity):
            return {'path': str(project), 'parent': None, 'roots': [], 'directories': []}
        def register_project(self, path, create, host, **kwargs):
            assert Path(path).resolve() == project
            assert create is False and host == 'local'
            (root / 'registered').write_text(str(len([c for c in calls if 'register' in c]) + 1), encoding='utf-8')
            calls.append({'register': path})
            return self.projects()[0]

    config = {'auth': {'mode': 'password', 'username': 'fixture', **password_record('fixture-only')}, 'origins': []}
    server = GatewayServer(('127.0.0.1', 0), SyntheticBridge(), config, args.desktop / 'web')
    class SyntheticClients:
        def navigation_clients(self): return ['codex']
        def clients_status(self): return {'clients': [{'id': 'codex', 'family': 'codex', 'enabled': True, 'connected': True}, {'id': 'claude', 'family': 'claude', 'enabled': True, 'connected': True, 'entries': [{'id': WSL}]}]}
        def require_enabled(self, provider):
            if provider != 'codex': raise ValueError('Unknown synthetic client')
        def close(self): pass
    server.desktop_sessions = SyntheticClients()
    server.notifications = type('Notifications', (), {'lock': threading.RLock(), 'data_dir': root})()
    server.transfer_directory = root
    origin = f'http://127.0.0.1:{server.server_address[1]}'
    server.origins.add(origin); server.hosts.add(origin.removeprefix('http://'))
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    print(json.dumps({'origin': origin, 'session': SID, 'project': str(project)}), flush=True)
    try:
        for line in sys.stdin:
            if line.strip() == 'stop': break
    finally:
        server.shutdown(); server.server_close()
        (root / 'calls.json').write_text(json.dumps(calls), encoding='utf-8')


if __name__ == '__main__':
    main()
