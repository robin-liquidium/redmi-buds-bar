#!/usr/bin/env python3
"""Build a device IPA for users to re-sign; never publish personal provisioning profiles."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from verify_ios_package import verify

ROOT = Path(__file__).resolve().parent.parent


def package():
    metadata = json.loads((ROOT / 'release.json').read_text())
    derived = ROOT / 'work/ios-package'
    subprocess.run([
        'xcodebuild', '-project', 'iOS/RedmiBuds.xcodeproj', '-scheme', 'RedmiBuds',
        '-configuration', 'Release', '-destination', 'generic/platform=iOS',
        '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO',
        'CODE_SIGNING_REQUIRED=NO', f"MARKETING_VERSION={metadata['version']}",
        f"CURRENT_PROJECT_VERSION={metadata['build']}", 'build',
    ], cwd=ROOT, check=True)
    app = derived / 'Build/Products/Release-iphoneos/RedmiBuds.app'
    output = ROOT / 'outputs'
    output.mkdir(exist_ok=True)
    ipa = output / f"RedmiBuds-{metadata['version']}-unsigned.ipa"
    with tempfile.TemporaryDirectory(prefix='ios-payload-', dir=output) as temporary:
        payload = Path(temporary) / 'Payload'
        payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        ipa.unlink(missing_ok=True)
        subprocess.run(['ditto', '-c', '-k', '--keepParent', str(payload), str(ipa)], check=True)
    verify(ipa, metadata['version'], metadata['build'])
    shutil.copyfile(ROOT / 'iOS/SIDELOADING.md', output / 'iOS-Sideloading.md')
    print(f'Unsigned device IPA verified: {ipa}')


if __name__ == '__main__':
    package()
