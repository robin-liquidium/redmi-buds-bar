import importlib.util
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('verify_ios_package', Path(__file__).parents[1] / 'script/verify_ios_package.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class IOSPackageTests(unittest.TestCase):
    def package(self, directory, platform=2, extension=True, extra=None, extension_version='1.0.0'):
        binary = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, 0, 0, 0)
        assets = {}
        for suffix in ['', '/PlugIns/RedmiBudsControls.appex']:
            if suffix and not extension:
                continue
            root = 'Payload/RedmiBuds.app' + suffix
            info = dict(CFBundleShortVersionString=extension_version if suffix else '1.0.0', CFBundleVersion='2', CFBundleSupportedPlatforms=['iPhoneOS'], BudsAppGroupIdentifier='group.build.robin.RedmiBuds', CFBundleIdentifier='build.robin.RedmiBuds' + ('.Controls' if suffix else ''), CFBundleExecutable='Executable')
            if suffix:
                info['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}
            assets[root + '/Info.plist'] = plistlib.dumps(info)
            assets[root + '/Executable'] = binary
        assets.update(extra or {})
        target = Path(directory) / 'app.ipa'
        with zipfile.ZipFile(target, 'w') as archive:
            for name, data in assets.items():
                archive.writestr(name, data)
        return target

    def test_valid_device_app_and_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            verifier.verify(self.package(directory), '1.0.0', 2)

    def test_simulator_arm64_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                verifier.verify(self.package(directory, platform=7), '1.0.0', 2)

    def test_missing_extension_and_mismatched_version_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(KeyError):
                verifier.verify(self.package(directory, extension=False), '1.0.0', 2)
            with self.assertRaises(ValueError):
                verifier.verify(self.package(directory, extension_version='0.9.0'), '1.0.0', 2)

    def test_provisioning_profiles_signatures_and_unsafe_paths_are_rejected(self):
        for name in ['Payload/RedmiBuds.app/embedded.mobileprovision', 'Payload/RedmiBuds.app/_CodeSignature/CodeResources', '../secret']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    verifier.verify(self.package(directory, extra={name: b'private'}), '1.0.0', 2)

    def test_truncated_load_command_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                verifier.verify(self.package(directory, extra={'Payload/RedmiBuds.app/Executable': struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0)}), '1.0.0', 2)
