#!/usr/bin/env python3
"""Validate the public, unprovisioned iOS artifact before upload and distribution."""
import argparse
import plistlib
import struct
import zipfile
from pathlib import PurePosixPath


def verify(ipa, version, build):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if any(PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts for name in names):
            raise ValueError('Unsafe IPA path')
        if any(name.endswith('.mobileprovision') or '_CodeSignature' in PurePosixPath(name).parts for name in names):
            raise ValueError('Public IPA must not include signing profiles or signatures')
        apps = [name for name in names if name.count('/') == 2 and name.endswith('.app/Info.plist')]
        if apps != ['Payload/RedmiBuds.app/Info.plist']:
            raise ValueError('Expected exactly one Redmi Buds application')
        paths = [apps[0], 'Payload/RedmiBuds.app/PlugIns/RedmiBudsControls.appex/Info.plist']
        for path in paths:
            info = plistlib.loads(archive.read(path))
            if info.get('CFBundleShortVersionString') != version or info.get('CFBundleVersion') != str(build):
                raise ValueError('App and controls must match the release version/build')
            if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
                raise ValueError('Expected a physical-device build, not a simulator')
            if info.get('BudsAppGroupIdentifier') != 'group.build.robin.RedmiBuds':
                raise ValueError('Missing shared App Group configuration')
            expected_id = 'build.robin.RedmiBuds' + ('.Controls' if path == paths[1] else '')
            if info.get('CFBundleIdentifier') != expected_id:
                raise ValueError('Unexpected app or controls bundle identifier')
            binary = archive.read(path.rsplit('/', 1)[0] + '/' + info['CFBundleExecutable'])
            # Device builds target arm64. Reject simulator/x86 and unexpected fat executables.
            if len(binary) < 32 or struct.unpack('<II', binary[:8]) != (0xfeedfacf, 0x100000c):
                raise ValueError('Expected an arm64 Mach-O executable')
            _, _, _, _, count, _, _, _ = struct.unpack('<8I', binary[:32])
            offset = 32
            platform = None
            for _ in range(count):
                if offset + 8 > len(binary):
                    raise ValueError('Truncated Mach-O load commands')
                command, size = struct.unpack('<II', binary[offset:offset + 8])
                if size < 8 or offset + size > len(binary):
                    raise ValueError('Invalid Mach-O load commands')
                if command == 0x32:
                    if size < 24:
                        raise ValueError('Invalid build-version command')
                    platform = struct.unpack('<I', binary[offset + 8:offset + 12])[0]
                offset += size
            if platform != 2:
                raise ValueError('Mach-O platform must be iOS, not iOS Simulator')
        extension = plistlib.loads(archive.read(paths[1]))
        if extension.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension':
            raise ValueError('Missing Control Center extension')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa')
    parser.add_argument('version')
    parser.add_argument('build', type=int)
    args = parser.parse_args()
    verify(args.ipa, args.version, args.build)
    print('Verified unsigned device IPA and Control Center extension.')
