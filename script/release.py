#!/usr/bin/env python3
"""Advance one durable GitHub draft release through Apple notarization."""
import argparse, hashlib, html, json, os, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
REPO = 'robin-liquidium/redmi-buds-bar'
OUT = ROOT / 'outputs'
OUT.mkdir(exist_ok=True)

def run(*args, capture=False, input=None):
    result = subprocess.run([str(a) for a in args], check=True, text=True, input=input,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None

def gh(*args, **kwargs):
    return run('gh', *args, **kwargs)

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def release(tag):
    # GitHub's by-tag endpoint omits drafts, even when their tag already exists.
    pages = json.loads(gh('api', '--paginate', '--slurp', f'repos/{REPO}/releases?per_page=100', capture=True))
    for page in pages:
        for item in page:
            if item['tag_name'] == tag:
                return item
    raise LookupError(f'No release for {tag}')

def upload(tag, path):
    gh('release', 'upload', tag, str(path), '--clobber', '-R', REPO)

def download(tag, name, expected=None):
    gh('release', 'download', tag, '--pattern', name, '--dir', OUT, '--clobber', '-R', REPO)
    path = OUT / name
    if expected and digest(path) != expected:
        raise RuntimeError(f'Checksum mismatch: {name}')
    return path

def save(tag, state):
    path = OUT / 'release-state.json'
    path.write_text(json.dumps(state, indent=2) + '\n')
    upload(tag, path)

def notary(*args):
    return json.loads(run('xcrun', 'notarytool', *args, '--key', os.environ['NOTARY_KEY_PATH'],
                          '--key-id', os.environ['APP_STORE_CONNECT_KEY_ID'],
                          '--issuer', os.environ['APP_STORE_CONNECT_ISSUER_ID'],
                          '--output-format', 'json', capture=True))

def submit(tag, state, phase, path):
    # Persist intent first. An ambiguous submission must be reconciled by ID, never blindly retried.
    state['phase'] = phase + '_submitting'
    state[phase + '_sha256'] = digest(path)
    state[phase + '_filename'] = path.name
    save(tag, state)
    response = notary('submit', path)
    state[phase + '_submission_id'] = response['id']
    state['phase'] = phase + '_pending'
    save(tag, state)

def accepted(tag, state, phase):
    response = notary('info', state[phase + '_submission_id'])
    print(f"{phase} notarization: {response['status']}", flush=True)
    if response['status'] == 'In Progress':
        return False
    if response['status'] != 'Accepted':
        state['phase'] = phase + '_rejected'
        save(tag, state)
        raise RuntimeError(f"Apple rejected {phase}; inspect notarytool log for {state[phase + '_submission_id']}")
    return True

def advance(tag):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('Expected vMAJOR.MINOR.PATCH')
    metadata = json.loads((ROOT / 'release.json').read_text())
    if tag != 'v' + metadata['version']:
        raise ValueError('Tag and release.json version differ')
    commit = run('git', 'rev-parse', 'HEAD', capture=True)
    if run('git', 'rev-list', '-n', '1', tag, capture=True) != commit:
        raise ValueError('Checkout must match release tag')
    run('git', 'fetch', 'origin', 'main')
    run('git', 'merge-base', '--is-ancestor', commit, 'origin/main')
    try:
        current = release(tag)
    except LookupError:
        body = OUT / 'release-notes.md'
        body.write_text('\n'.join('- ' + c for c in metadata['changes']) + '\n\nRequires macOS 14 or later. Universal Apple silicon and Intel app.\n')
        gh('release', 'create', tag, '--verify-tag', '--draft', '--title', f"Redmi Buds Bar {metadata['version']}", '--notes-file', body, '-R', REPO)
        current = release(tag)
    if not current['draft']:
        print('Release already published; distribution can be finalized.')
        return
    names = {a['name'] for a in current['assets']}
    if 'release-state.json' in names:
        state = json.loads(download(tag, 'release-state.json').read_text())
        if state['commit'] != commit or state['version'] != metadata['version']:
            raise RuntimeError('Saved release does not match checkout')
    else:
        state = {'version': metadata['version'], 'commit': commit, 'phase': 'building'}
        save(tag, state)
    phase = state['phase']
    if phase.endswith(('_submitting', '_rejected')):
        raise RuntimeError(f'{phase}: inspect Apple submission history; do not resubmit. See RELEASING.md.')
    if phase == 'building':
        run('./script/package_app.sh', '--universal')
        path = OUT / 'notary-app.zip'
        path.unlink(missing_ok=True)
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', OUT / 'RedmiBudsBar.app', path)
        upload(tag, path)
        submit(tag, state, 'app', path)
    if state['phase'] == 'app_pending':
        if not accepted(tag, state, 'app'):
            return
        path = download(tag, state['app_filename'], state['app_sha256'])
        shutil.rmtree(OUT / 'RedmiBudsBar.app', ignore_errors=True)
        run('ditto', '-x', '-k', path, OUT)
        run('xcrun', 'stapler', 'staple', OUT / 'RedmiBudsBar.app')
        run('xcrun', 'stapler', 'validate', OUT / 'RedmiBudsBar.app')
        run('spctl', '--assess', '--type', 'execute', '--verbose=2', OUT / 'RedmiBudsBar.app')
        appzip = OUT / f"RedmiBudsBar-{metadata['version']}.zip"
        appzip.unlink(missing_ok=True)
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', OUT / 'RedmiBudsBar.app', appzip)
        upload(tag, appzip)
        state['zip_filename'] = appzip.name
        state['zip_sha256'] = digest(appzip)
        run('./script/package_dmg.sh')
        dmg = OUT / f"RedmiBudsBar-{metadata['version']}.dmg"
        staged = OUT / 'notary-dmg.dmg'
        shutil.copy2(dmg, staged)
        upload(tag, staged)
        submit(tag, state, 'dmg', staged)
    if state['phase'] == 'dmg_pending':
        if not accepted(tag, state, 'dmg'):
            return
        dmg = download(tag, state['dmg_filename'], state['dmg_sha256'])
        run('xcrun', 'stapler', 'staple', dmg)
        run('xcrun', 'stapler', 'validate', dmg)
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
        final = OUT / f"RedmiBudsBar-{metadata['version']}.dmg"
        shutil.copy2(dmg, final)
        stable = OUT / 'RedmiBudsBar.dmg'
        shutil.copy2(dmg, stable)
        appzip = download(tag, state['zip_filename'], state['zip_sha256'])
        archive = OUT / 'feed'
        shutil.rmtree(archive, ignore_errors=True)
        archive.mkdir()
        shutil.copy2(appzip, archive / appzip.name)
        shutil.copy2(ROOT / 'website/public/appcast.xml', archive / 'appcast.xml')
        (archive / appzip.with_suffix('.html').name).write_text('<ul>' + ''.join('<li>' + html.escape(c) + '</li>' for c in metadata['changes']) + '</ul>')
        key = os.environ['SPARKLE_PRIVATE_KEY']
        tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
        run('swift', 'package', 'resolve')
        run(tools / 'generate_appcast', '--ed-key-file', '-', '--download-url-prefix', f'https://github.com/{REPO}/releases/download/{tag}/', '--maximum-deltas', '0', '--maximum-versions', '3', '-o', archive / 'appcast.xml', archive, input=key)
        run(tools / 'sign_update', '--ed-key-file', '-', '--verify', archive / 'appcast.xml', input=key)
        evidence = OUT / 'notarization.json'
        evidence.write_text(json.dumps({k: v for k, v in state.items() if k != 'phase'} | {'status': 'Accepted'}, indent=2) + '\n')
        sums = OUT / 'SHA256SUMS'
        sums.write_text(''.join(f'{digest(p)}  {p.name}\n' for p in [final, stable, appzip]))
        for path in [final, stable, archive / 'appcast.xml', archive / appzip.with_suffix('.html').name, evidence, sums, ROOT / 'release.json']:
            upload(tag, path)
        # Upload completion marker before removing private draft staging assets.
        state['phase'] = 'ready'
        save(tag, state)
    if state['phase'] == 'ready':
        current = release(tag)
        required = {f"RedmiBudsBar-{metadata['version']}.dmg", state['zip_filename'], 'RedmiBudsBar.dmg', 'appcast.xml', 'SHA256SUMS', 'release.json', 'notarization.json'}
        if not required.issubset({a['name'] for a in current['assets']}):
            raise RuntimeError('Missing final release assets')
        # Retain state for audit/resume; it contains identifiers and hashes, no credentials.
        for asset in current['assets']:
            if asset['name'] in {'notary-app.zip', 'notary-dmg.dmg'}:
                gh('api', f"repos/{REPO}/releases/assets/{asset['id']}", '-X', 'DELETE')
        gh('release', 'edit', tag, '--draft=false', '--latest', '-R', REPO)
        print(f'Published {tag}. Run script/finalize_release.py {tag} to update website and Homebrew.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('tag')
    advance(parser.parse_args().tag)
