"""Produce the source/relink companion for binaries containing LGPL EasyTier."""
import json
import os
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def package():
    metadata = json.loads(subprocess.check_output([
        'cargo', 'metadata', '--locked', '--format-version', '1', '--manifest-path', str(ROOT / 'rust/Cargo.toml')],
        cwd=ROOT, text=True))
    upstream = next(item for item in metadata['packages'] if item['name'] == 'easytier')
    source = Path(upstream['manifest_path']).parent.parent
    output = ROOT / 'build/release-assets/bridge-p2p-corresponding-source.tar.gz'
    output.parent.mkdir(parents=True, exist_ok=True)
    paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    # New reviewed wrapper files are included before their first commit too.
    wrapper = ROOT / 'third_party/bridge-p2p'
    snapshot = json.loads((wrapper / 'source.json').read_text(encoding='utf-8'))
    for name in [*snapshot['sha256'], 'source.json']:
        path = wrapper / name
        if not path.resolve().is_relative_to(wrapper.resolve()):
            raise ValueError('Shared source must remain within the wrapper directory')
        paths.append(path.relative_to(ROOT).as_posix())
    paths += ['scripts/package_p2p_source.py']
    with tarfile.open(output, 'w:gz') as archive:
        for name in sorted(set(paths) - {''}):
            path = ROOT / name
            if path.is_file():
                archive.add(path, arcname='bridge-mobile/' + name)
        for path in source.rglob('*'):
            if path.is_file() and '.git' not in path.relative_to(source).parts:
                archive.add(path, arcname='easytier/' + path.relative_to(source).as_posix())
    print('P2P corresponding source:', output)
    return output


if __name__ == '__main__':
    package()
