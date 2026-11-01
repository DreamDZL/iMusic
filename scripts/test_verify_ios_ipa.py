"""Synthetic structural tests; these do not establish device installability."""

import contextlib
import io
import json
import plistlib
import stat
import struct
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path

from verify_ios_ipa import ValidationError, main, verify_ipa


ROOT = "Payload/Test.app/"


def macho(platform=2, minimum=0x00110000, cryptid=0, signature=False):
    commands = [struct.pack("<6I", 0x32, 24, platform, minimum, 0x001B0000, 0),
                struct.pack("<6I", 0x2C, 24, 0, 0, cryptid, 0)]
    blob = b""
    if signature:
        # An intentionally non-cryptographic synthetic superblob.
        blob = struct.pack(">7I", 0xFADE0CC0, 28, 1, 0, 20, 0xFADE0C02, 8)
        commands.append(struct.pack("<4I", 0x1D, 16, 96, len(blob)))
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2,
                         len(commands), sum(map(len, commands)), 0, 0)
    return header + b"".join(commands) + blob


class VerifyIPATests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "test.ipa"

    def make_ipa(self, binary=None, info=None, mode=stat.S_IFREG | 0o755,
                 missing_executable=False, extras=(), signature=False, resources=True):
        metadata = {"CFBundleIdentifier": "org.example.test", "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "7", "CFBundlePackageType": "APPL",
                    "CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [1, 2],
                    "MinimumOSVersion": "17.0", "CFBundleExecutable": "Test"}
        metadata.update(info or {})
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.path, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr(ROOT + "Info.plist", plistlib.dumps(metadata))
                if not missing_executable:
                    entry = zipfile.ZipInfo(ROOT + "Test")
                    entry.create_system = 3
                    entry.external_attr = mode << 16
                    archive.writestr(entry, macho(signature=signature) if binary is None else binary)
                if signature and resources:
                    archive.writestr(ROOT + "_CodeSignature/CodeResources", plistlib.dumps({}))
                for name, content in extras:
                    archive.writestr(name, content)
        return self.path

    def test_unsigned_metadata_and_expected_values(self):
        result = verify_ipa(self.make_ipa(), "1.2.3", "org.example.test")
        self.assertEqual(result["arch"], "arm64")
        self.assertFalse(result["encrypted"])
        self.assertFalse(result["signature_present"])
        self.assertEqual(result["zip_size"], self.path.stat().st_size)
        self.assertEqual(len(result["sha256"]), 64)

    def test_expected_values_must_match(self):
        self.make_ipa()
        for kwargs in ({"expected_version": "9"}, {"expected_bundle_id": "other"}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValidationError):
                verify_ipa(self.path, **kwargs)

    def test_signature_presence_not_crypto_validity(self):
        self.make_ipa()
        with self.assertRaisesRegex(ValidationError, "signature is required"):
            verify_ipa(self.path, require_signature=True)
        self.make_ipa(signature=True)
        self.assertTrue(verify_ipa(self.path, require_signature=True)["signature_present"])
        self.make_ipa(signature=True, resources=False)
        with self.assertRaisesRegex(ValidationError, "CodeResources"):
            verify_ipa(self.path)

    def test_unsafe_paths_and_duplicate_members(self):
        for name in ("../escape", "/absolute", "C:/drive", "Payload/../escape",
                     "Payload\\escape", "Payload//empty", ROOT + "Info.plist",
                     ROOT + "info.plist"):
            with self.subTest(name=name):
                # Windows zipfile normalizes separators on write. Mutate both
                # ZIP filename records to exercise a genuinely unsafe archive.
                stored_name = name.replace("\\", "/")
                self.make_ipa(extras=[(stored_name, b"x")])
                if stored_name != name:
                    self.path.write_bytes(self.path.read_bytes().replace(
                        stored_name.encode(), name.encode()))
                with self.assertRaises(ValidationError):
                    verify_ipa(self.path)

    def test_symlink_and_executable_mode(self):
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFREG | 0o644):
            with self.subTest(mode=mode):
                with self.assertRaises(ValidationError):
                    verify_ipa(self.make_ipa(mode=mode))

    def test_missing_executable(self):
        with self.assertRaisesRegex(ValidationError, "Missing main executable"):
            verify_ipa(self.make_ipa(missing_executable=True))

    def test_missing_or_invalid_plist(self):
        for content in (None, b"not a plist", plistlib.dumps(["not a dictionary"])):
            with self.subTest(content=content):
                with zipfile.ZipFile(self.path, "w") as archive:
                    archive.writestr(ROOT + "Test", macho())
                    if content is not None:
                        archive.writestr(ROOT + "Info.plist", content)
                with self.assertRaises(ValidationError):
                    verify_ipa(self.path)

    def test_file_directory_collision(self):
        with self.assertRaisesRegex(ValidationError, "path collision"):
            verify_ipa(self.make_ipa(extras=[(ROOT + "Assets", b"file"),
                                            (ROOT + "Assets/child", b"child")]))

    def test_plist_contract(self):
        for info in ({"CFBundlePackageType": "FMWK"}, {"UIDeviceFamily": [2]},
                     {"UIDeviceFamily": [True]}, {"CFBundleSupportedPlatforms": ["iPhoneSimulator"]},
                     {"CFBundleExecutable": "../Test"}, {"MinimumOSVersion": "17"},
                     {"CFBundleIdentifier": ""}, {"CFBundleVersion": 7}):
            with self.subTest(info=info), self.assertRaises(ValidationError):
                verify_ipa(self.make_ipa(info=info))

    def test_platform_minimum_and_encryption(self):
        for kwargs in ({"platform": 7}, {"minimum": 0x00120000}, {"cryptid": 1}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValidationError):
                verify_ipa(self.make_ipa(binary=macho(**kwargs)))

    def test_invalid_macho_header_and_commands(self):
        valid = macho()
        variants = [b"", b"\xca\xfe\xba\xbe" + valid[4:], valid[:31],
                    valid[:36] + struct.pack("<I", 0) + valid[40:],
                    valid[:20] + struct.pack("<I", 5000) + valid[24:],
                    valid[:12] + struct.pack("<I", 6) + valid[16:],
                    valid[:4] + struct.pack("<I", 0x01000007) + valid[8:]]
        for binary in variants:
            with self.subTest(binary=binary[:8]), self.assertRaises(ValidationError):
                verify_ipa(self.make_ipa(binary=binary))

    def test_build_and_encryption_command_bounds(self):
        valid = macho()
        # SDK below minimum, bad tool count, bad crypt range, legacy encryption,
        # and a command table with no build-version command.
        variants = [valid[:48] + struct.pack("<I", 0x00100000) + valid[52:],
                    valid[:52] + struct.pack("<I", 1) + valid[56:],
                    valid[:64] + struct.pack("<I", 9999) + valid[68:],
                    valid[:56] + struct.pack("<I", 0x21) + valid[60:],
                    valid[:32] + struct.pack("<I", 0x99) + valid[36:]]
        for index, binary in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(ValidationError):
                verify_ipa(self.make_ipa(binary=binary))

    def test_invalid_signature_blob_and_range(self):
        valid = macho(signature=True)
        for binary in (valid[:-1], valid[:96] + b"BAD!" + valid[100:],
                       valid[:88] + struct.pack("<I", 0) + valid[92:],
                       valid[:112] + struct.pack(">I", 9999) + valid[116:]):
            with self.subTest(binary=binary[-8:]), self.assertRaises(ValidationError):
                verify_ipa(self.make_ipa(binary=binary))

    def test_no_extensions_or_second_app(self):
        for extra in ("Payload/Other.app/Info.plist", ROOT + "PlugIns/Widget.appex/Info.plist"):
            with self.subTest(extra=extra), self.assertRaises(ValidationError):
                verify_ipa(self.make_ipa(extras=[(extra, b"x")]))

    def test_crc_failure(self):
        self.make_ipa()
        data = bytearray(self.path.read_bytes())
        with zipfile.ZipFile(self.path) as archive:
            entry = archive.getinfo(ROOT + "Test")
            start = entry.header_offset
        name_size, extra_size = struct.unpack_from("<2H", data, start + 26)
        data[start + 30 + name_size + extra_size] ^= 1
        self.path.write_bytes(data)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(main([str(self.path)]), 1)
        self.assertIn("error", json.loads(stderr.getvalue()))

    def test_cli_json_and_corrupt_archive(self):
        self.make_ipa()
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(main([str(self.path), "--expected-version", "1.2.3"]), 0)
        self.assertEqual(json.loads(stdout.getvalue())["version"], "1.2.3")
        self.path.write_bytes(b"not a zip")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(main([str(self.path)]), 1)
        self.assertEqual(set(json.loads(stderr.getvalue())), {"error"})


if __name__ == "__main__":
    unittest.main()
