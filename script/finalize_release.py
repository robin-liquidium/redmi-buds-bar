#!/usr/bin/env python3
"""Publish a verified release's feed, website, and Homebrew cask. Safe to rerun."""
import argparse, base64, hashlib, json, os, re, shutil, subprocess, tempfile
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPO = 'robin-liquidium/redmi-buds-bar'
TAP = 'robin-liquidium/homebrew-tap'

def run(*args, cwd=ROOT, capture=False, input=None):
    r = subprocess.run([str(x) for x in args], cwd=cwd, check=True, text=True, input=input,
                       stdout=subprocess.PIPE if capture else None)
    return r.stdout.strip() if capture else None

def api(path, **kwargs):
    return json.loads(run('gh', 'api', path, capture=True, **kwargs) or '{}')

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def finalize(tag):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('Expected vMAJOR.MINOR.PATCH')
    if run('git', 'status', '--porcelain', capture=True):
        raise RuntimeError('Commit local changes before finalizing')
    if run('git', 'branch', '--show-current', capture=True) != 'main':
        raise RuntimeError('Run from main')
    run('git', 'pull', '--ff-only')
    latest = api(f'repos/{REPO}/releases/latest')
    if latest['tag_name'] != tag or latest['draft'] or latest['prerelease']:
        raise RuntimeError('Only the latest public stable release can be distributed')
    with tempfile.TemporaryDirectory(prefix='redmi-release-') as tmp:
        stage = Path(tmp)
        run('gh', 'release', 'download', tag, '-R', REPO, '--dir', stage)
        metadata = json.loads((stage / 'release.json').read_text())
        if tag != 'v' + metadata['version']:
            raise RuntimeError('Release metadata mismatch')
        sums = dict(line.split('  ', 1)[::-1] for line in (stage / 'SHA256SUMS').read_text().splitlines())
        for name, checksum in sums.items():
            if Path(name).name != name or sha(stage / name) != checksum:
                raise RuntimeError(f'Checksum mismatch: {name}')
        feed = stage / 'appcast.xml'
        run('swift', 'package', 'resolve')
        verifier = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
        run(verifier, '--account', 'redmi-buds-bar', '--verify', feed)
        tree = ET.parse(feed)
        ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
        item = tree.find('./channel/item')
        if item is None or item.findtext('sparkle:version', namespaces=ns) != str(metadata['build']):
            raise RuntimeError('Sparkle build number does not match release')
        enclosure = item.find('enclosure')
        zipname = f"RedmiBudsBar-{metadata['version']}.zip"
        expected_url = f'https://github.com/{REPO}/releases/download/{tag}/{zipname}'
        if enclosure is None or enclosure.attrib['url'] != expected_url:
            raise RuntimeError('Unexpected Sparkle archive URL')
        run(verifier, '--account', 'redmi-buds-bar', '--verify', stage / zipname,
            enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'])
        public = ROOT / 'website/public'
        releases = json.loads((public / 'releases.json').read_text())
        releases = [metadata] + [r for r in releases if r['version'] != metadata['version']]
        (public / 'releases.json').write_text(json.dumps(releases, indent=2) + '\n')
        shutil.copy2(feed, public / 'appcast.xml')
        run('bun', 'install', '--frozen-lockfile', cwd=ROOT / 'website')
        run('bun', 'run', 'check', cwd=ROOT / 'website')
        run('bun', 'run', 'build', cwd=ROOT / 'website')
        run('git', 'add', 'website/public/releases.json', 'website/public/appcast.xml')
        if run('git', 'diff', '--cached', '--name-only', capture=True):
            run('git', 'commit', '-m', f'Publish {tag} changelog and signed update feed')
            run('git', 'push', 'origin', 'main')
        run('bun', 'x', 'wrangler', 'deploy', cwd=ROOT / 'website')
        # Check exact bytes so stale deployment/cache cannot silently pass.
        for name in ['appcast.xml', 'releases.json']:
            command = ['curl', '--fail', '--silent', '--show-error', '--max-time', '60',
                       '-H', 'Cache-Control: no-cache', 'https://buds.robin.build/' + name]
            response = subprocess.run(command, capture_output=True)
            # A newly created hostname can be missing from the local DNS resolver.
            # Retry only DNS failures, with HTTPS DNS; certificate checks stay enabled.
            if response.returncode == 6:
                response = subprocess.run(command + ['--doh-url', 'https://dns.google/dns-query'], capture_output=True)
            if response.returncode:
                raise RuntimeError(response.stderr.decode(errors='replace'))
            data = response.stdout
            if data != (public / name).read_bytes():
                raise RuntimeError(f'Production {name} differs from the release')
        version = metadata['version']
        dmgname = f'RedmiBudsBar-{version}.dmg'
        run('xcrun', 'stapler', 'validate', stage / dmgname)
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', stage / dmgname)
        cask = f'''cask "redmi-buds-bar" do
  version "{version}"
  sha256 "{sha(stage / dmgname)}"

  url "https://github.com/{REPO}/releases/download/v#{{version}}/RedmiBudsBar-#{{version}}.dmg"
  name "Redmi Buds Bar"
  desc "Menu bar noise controls and battery levels for REDMI Buds 8 Pro"
  homepage "https://buds.robin.build/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "RedmiBudsBar.app"
end
'''
        tapfile = f'repos/{TAP}/contents/Casks/redmi-buds-bar.rb'
        files = api(f'repos/{TAP}/contents/Casks')
        previous = next((f for f in files if f['name'] == 'redmi-buds-bar.rb'), None)
        content = base64.b64encode(cask.encode()).decode()
        existing = api(tapfile) if previous else None
        if not existing or base64.b64decode(existing['content']).decode() != cask:
            payload = {'message': f'Update Redmi Buds Bar to {version}', 'content': content, 'branch': 'main'}
            if existing:
                payload['sha'] = existing['sha']
            run('gh', 'api', tapfile, '-X', 'PUT', '--input', '-', input=json.dumps(payload), capture=True)
        # Fetching verifies Homebrew's public URL and SHA without replacing the installed app.
        run('brew', 'tap', 'robin-liquidium/tap')
        tap_path = run('brew', '--repository', 'robin-liquidium/tap', capture=True)
        if run('git', 'status', '--porcelain', cwd=tap_path, capture=True):
            raise RuntimeError('Homebrew tap checkout has local changes; refresh it manually')
        run('git', 'pull', '--ff-only', cwd=tap_path)
        run('brew', 'style', '--cask', 'robin-liquidium/tap/redmi-buds-bar')
        run('brew', 'fetch', '--cask', 'robin-liquidium/tap/redmi-buds-bar')
        print(f'{tag} is published: GitHub, signed Sparkle feed, Cloudflare website, and Homebrew.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('tag')
    finalize(parser.parse_args().tag)
