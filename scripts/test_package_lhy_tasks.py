"""Exercise release boundaries using only synthetic temporary fixtures."""
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import tempfile
import unittest
from zipfile import ZipFile

SCRIPT = Path(__file__).with_name('package_lhy_tasks.py')


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), 'task packager must exist')
        spec = importlib.util.spec_from_file_location('task_packager', SCRIPT)
        self.package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.package)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.out = Path(self.temp.name) / 'out'
        self.root.mkdir()
        self.required = [
            'Package.swift', 'ios/Fitcore.xcodeproj/project.pbxproj',
            'ios/Fitcore.xcodeproj/project.xcworkspace/contents.xcworkspacedata',
            'ios/Fitcore.xcodeproj/xcshareddata/xcschemes/Fitcore-Mock.xcscheme',
            'ios/Configuration/Base.xcconfig', 'ios/Configuration/Debug.xcconfig',
            'ios/Configuration/Release.xcconfig', 'ios/Configuration/Local.xcconfig.example',
            'ios/Fitcore/App/FitcoreApp.swift', 'ios/Fitcore/Resources/Info.plist',
            'ios/Fitcore/Core/Audio/WAVFileValidator.swift',
            'ios/Fitcore/Services/Audio/Capture.swift',
            'ios/Fitcore/Features/Capture/CaptureView.swift',
            'tests/WAVCaptureKitTests/WAVFileValidatorTests.swift',
            'scripts/generate_xcode_project.py', 'scripts/verify.py',
            'scripts/check_core.swift', 'scripts/check_dynamic_records.swift',
            'docs/LHY-01-LOCAL-HANDOFF.md', 'docs/LHY-01-VERIFICATION.json',
        ]
        for name in self.required:
            self.put(name)

    def put(self, name, content='synthetic fixture\n'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_lhy_excludes_sensitive_files_and_preserves_safe_paths_and_hashes(self):
        for name in ['.env', 'ios/Configuration/Local.xcconfig',
                     'ios/Fitcore/.env', 'ios/Fitcore/private/record.swift',
                     'ios/Fitcore/SDK/sdk.swift', 'ios/Fitcore/cache/cache.json',
                     'ios/Fitcore/clip.wav', 'ios/Fitcore/history.db',
                     'ios/Fitcore/signing.p12', 'ios/Fitcore/xcuserdata/state.json',
                     'data/D01/real.csv']:
            self.put(name, 'DO NOT EXPORT')
        self.put('ios/Fitcore/Resources/Assets.xcassets/Icon.imageset/icon.png')
        self.put('ios/Fitcore/Resources/Assets.xcassets/Icon.imageset/Contents.json', '{}')
        (self.root / 'ios/Fitcore/link.swift').symlink_to(self.root / '.env')
        (self.root / 'ios/Fitcore/linked').symlink_to(self.root, target_is_directory=True)
        paths = self.package.package_tasks(self.root, self.out, 'LHY-01')
        self.assertEqual(len(paths), 1)
        with ZipFile(paths[0]) as archive:
            names = set(archive.namelist())
            self.assertTrue(set(self.required) <= names)
            self.assertIn('README.md', names)
            self.assertEqual(archive.read('README.md'), archive.read('docs/LHY-01-LOCAL-HANDOFF.md'))
            for name in names:
                path = PurePosixPath(name)
                self.assertFalse(path.is_absolute())
                self.assertNotIn('..', path.parts)
                self.assertNotIn(b'DO NOT EXPORT', archive.read(name))
            checksums = archive.read('SHA256SUMS').decode().splitlines()
            checked = set()
            for line in checksums:
                digest, name = line.split('  ', 1)
                self.assertEqual(digest, hashlib.sha256(archive.read(name)).hexdigest())
                checked.add(name)
            self.assertEqual(checked, names - {'SHA256SUMS'})
            status = json.loads(archive.read('DELIVERY.json'))
            self.assertEqual(status['human_acceptance'], 'pending_acceptance')
            self.assertEqual(status['software_validation']['status'], 'not_verified')
            self.assertIsNone(archive.testzip())

    def add_d01_fixture(self):
        for name in ['README.md', 'SAMPLING_MATRIX.md', 'scripts/d01.py',
                     'tests/test_d01.py', 'verification/RED_GREEN.md']:
            self.put('data/D01/' + name)
        self.put('data/D01/templates/CONSENT_REGISTER.csv', 'participant_id,consent\n')
        self.put('data/D01/templates/WAV_MANIFEST.csv', 'file,sha256\n')

    def test_d01_exports_only_public_tools_and_empty_templates(self):
        self.add_d01_fixture()
        for name in ['data/D01/records.csv', 'data/D01/manifest.csv',
                     'data/D01/private/metadata.json', 'data/D01/private/subject.wav',
                     'data/D01/real.wav', 'data/D01/.env', 'data/D01/SDK/library.py']:
            self.put(name, 'DO NOT EXPORT')
        paths = self.package.package_tasks(self.root, self.out, 'D01')
        expected = {
            'README.md', 'DELIVERY.json', 'SHA256SUMS', 'data/D01/README.md',
            'data/D01/SAMPLING_MATRIX.md', 'data/D01/scripts/d01.py',
            'data/D01/tests/test_d01.py', 'data/D01/verification/RED_GREEN.md',
            'data/D01/templates/CONSENT_REGISTER.csv', 'data/D01/templates/WAV_MANIFEST.csv',
        }
        with ZipFile(paths[0]) as archive:
            self.assertEqual(set(archive.namelist()), expected)
            for name in archive.namelist():
                self.assertNotIn(b'DO NOT EXPORT', archive.read(name))

    def test_d01_rejects_real_records_inside_allowed_template(self):
        self.add_d01_fixture()
        self.put('data/D01/templates/WAV_MANIFEST.csv', 'file,sha256\nreal.wav,private\n')
        with self.assertRaises(ValueError):
            self.package.package_tasks(self.root, self.out, 'D01')
        self.assertFalse(self.out.exists())

    def test_all_builds_independent_archives(self):
        self.add_d01_fixture()
        paths = self.package.package_tasks(self.root, self.out, 'all')
        self.assertEqual({path.name for path in paths}, {'LHY-01-delivery.zip', 'D01-delivery.zip'})
        with ZipFile(paths[0]) as lhy, ZipFile(paths[1]) as d01:
            self.assertFalse(any(name.startswith('data/') for name in lhy.namelist()))
            self.assertFalse(any(name.startswith('ios/') for name in d01.namelist()))

    def test_missing_required_file_does_not_publish_archive(self):
        (self.root / 'Package.swift').unlink()
        with self.assertRaises(ValueError):
            self.package.package_tasks(self.root, self.out, 'LHY-01')
        self.assertFalse(self.out.exists())

    def test_all_preflights_before_publishing_any_archive(self):
        with self.assertRaises(ValueError):
            self.package.package_tasks(self.root, self.out, 'all')
        self.assertFalse(self.out.exists())

    def test_existing_archive_is_never_overwritten(self):
        paths = self.package.package_tasks(self.root, self.out, 'LHY-01')
        before = paths[0].read_bytes()
        with self.assertRaises(FileExistsError):
            self.package.package_tasks(self.root, self.out, 'LHY-01')
        self.assertEqual(paths[0].read_bytes(), before)

    def test_symlinked_required_parent_is_rejected(self):
        external = Path(self.temp.name) / 'external'
        external.mkdir()
        (external / 'LHY-01-LOCAL-HANDOFF.md').write_text('private')
        # Replace the whole public docs fixture with a link, retaining files outside it.
        (self.root / 'docs').rename(self.root / 'saved-docs')
        (self.root / 'docs').symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.package.package_tasks(self.root, self.out, 'LHY-01')

    def test_symlinked_test_parent_cannot_supply_external_sources(self):
        (self.root / 'tests').rename(self.root / 'saved-tests')
        (self.root / 'tests').symlink_to(self.root / 'saved-tests', target_is_directory=True)
        with self.assertRaises(ValueError):
            self.package.package_tasks(self.root, self.out, 'LHY-01')

    def test_sensitive_json_and_unsafe_names_are_excluded(self):
        for name in ['ios/Fitcore/credentials.json', 'ios/Fitcore/secrets.json',
                     'ios/Fitcore/bad\nname.swift', 'ios/Fitcore/Backups/private.json',
                     'ios/Fitcore/PersonalExports/metadata.json',
                     'ios/Fitcore/Core/Models/metadata.json']:
            self.put(name, 'DO NOT EXPORT')
        paths = self.package.package_tasks(self.root, self.out, 'LHY-01')
        with ZipFile(paths[0]) as archive:
            for name in archive.namelist():
                self.assertNotIn(b'DO NOT EXPORT', archive.read(name))

    def test_evidence_must_refer_to_packaged_public_file(self):
        with self.assertRaises(ValueError):
            self.package.package_tasks(self.root, self.out, 'LHY-01', ['../private.json'])
        paths = self.package.package_tasks(self.root, self.out, 'LHY-01', ['docs/LHY-01-VERIFICATION.json'])
        with ZipFile(paths[0]) as archive:
            status = json.loads(archive.read('DELIVERY.json'))
            self.assertEqual(status['software_validation']['status'], 'evidence_supplied')
            self.assertEqual(status['human_acceptance'], 'pending_acceptance')


if __name__ == '__main__':
    unittest.main()
