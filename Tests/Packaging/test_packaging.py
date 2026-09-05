"""Exercise packaging in a disposable repo with toolchain/signing command doubles.

These tests never build, sign, submit, install, or launch the real application.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sgs-packaging-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / "script", self.root / "script")
        info = self.root / "Sources/SQLiteGraphStudio/App/Info.plist"
        info.parent.mkdir(parents=True)
        shutil.copy(ROOT / "Sources/SQLiteGraphStudio/App/Info.plist", info)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.bin = self.root / "build"
        self.bin.mkdir()
        (self.bin / "SQLiteGraphStudio").write_text("fixture executable")
        resources = self.bin / "SQLiteGraphStudio_SQLiteGraphStudio.bundle"
        resources.mkdir()
        (resources / "asset.txt").write_text("fixture resource")
        driver = self.tools / "driver"
        driver.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["SGS_TEST_LOG"], "a") as log:
    log.write(name + " " + " ".join(args) + "\\n")
if name == "swift" and "--show-bin-path" in args:
    print(os.environ["SGS_TEST_BIN"])
elif name == "lipo":
    if "-archs" in args: print("arm64 x86_64")
    else: pathlib.Path(args[args.index("-output") + 1]).write_text("universal fixture")
elif name == "hdiutil":
    pathlib.Path(args[-1]).write_text("fixture dmg")
if os.environ.get("SGS_TEST_FAIL_TOOL") == name:
    sys.exit(1)
''')
        driver.chmod(0o755)
        for name in ["swift", "lipo", "pkill", "codesign", "hdiutil", "xcrun", "spctl"]:
            (self.tools / name).symlink_to(driver)
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}",
                        SGS_TEST_LOG=str(self.root / "commands.log"), SGS_TEST_BIN=str(self.bin))
        self.env.pop("SIGNING_IDENTITY", None)
        self.env.pop("NOTARYTOOL_PROFILE", None)

    def run_script(self, name, *args):
        return subprocess.run(["bash", str(self.root / "script" / name), *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def info(self):
        return plistlib.loads((self.root / "dist/SQLiteGraphStudio.app/Contents/Info.plist").read_bytes())

    def log(self):
        path = self.root / "commands.log"
        return path.read_text() if path.exists() else ""

    def test_launcher_and_release_share_canonical_identity_and_versions(self):
        # Read output even if the old launcher rejects build-only after assembly.
        self.run_script("build_and_run.sh", "--build-only")
        launcher = self.info()
        release_result = self.run_script("build_app.sh")
        self.assertEqual(release_result.returncode, 0, release_result.stderr)
        release = self.info()
        canonical = plistlib.loads((self.root / "Sources/SQLiteGraphStudio/App/Info.plist").read_bytes())
        for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]:
            self.assertEqual(launcher[key], release[key], key)
            self.assertEqual(release[key], canonical[key], key)

    def test_build_only_packages_resources_without_stopping_or_launching_app(self):
        result = self.run_script("build_and_run.sh", "--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        resource = self.root / "dist/SQLiteGraphStudio.app/Contents/Resources/SQLiteGraphStudio_SQLiteGraphStudio.bundle/asset.txt"
        self.assertEqual(resource.read_text(), "fixture resource")
        self.assertNotIn("pkill", self.log())
        self.assertNotIn("hdiutil", self.log())

    def test_signed_release_signs_before_dmg_then_notarizes_and_validates(self):
        self.env.update(SIGNING_IDENTITY="Developer ID Application: Example (TEAM)", NOTARYTOOL_PROFILE="example-profile")
        result = self.run_script("build_app.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log()
        self.assertIn("--options runtime", log)
        self.assertIn("--timestamp", log)
        self.assertLess(log.index("codesign --force"), log.index("hdiutil create"))
        self.assertIn("notarytool submit", log)
        self.assertIn("--keychain-profile example-profile --wait", log)
        self.assertIn("stapler staple", log)
        self.assertIn("stapler validate", log)

    def test_distribution_dmg_is_signed_before_submission(self):
        self.env.update(SIGNING_IDENTITY="Developer ID Application: Example (TEAM)", NOTARYTOOL_PROFILE="example-profile")
        result = self.run_script("build_app.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log().splitlines()
        dmg_signature = next((i for i, line in enumerate(commands) if line.startswith("codesign --force") and line.endswith("SQLiteGraphStudio.dmg")), None)
        self.assertIsNotNone(dmg_signature, "distribution disk image must be signed")
        submission = next(i for i, line in enumerate(commands) if "notarytool submit" in line)
        self.assertLess(dmg_signature, submission)

    def test_standalone_dmg_packager_accepts_explicit_output_from_other_directory(self):
        app = self.root / "fixture/SQLiteGraphStudio.app"
        app.mkdir(parents=True)
        output = self.root / "output with spaces/test.dmg"
        result = subprocess.run(["bash", str(self.root / "script/create_dmg.sh"), str(app), str(output)],
                                cwd=self.tools, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_file(), "DMG must use explicit output path")

    def test_failed_notarization_stops_before_stapling(self):
        self.env.update(SIGNING_IDENTITY="Developer ID Application: Example (TEAM)", NOTARYTOOL_PROFILE="example-profile", SGS_TEST_FAIL_TOOL="xcrun")
        result = self.run_script("build_app.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notarytool submit", self.log())
        self.assertNotIn("stapler", self.log())

    def test_notarization_requires_distribution_identity_before_building(self):
        self.env["NOTARYTOOL_PROFILE"] = "example-profile"
        result = self.run_script("build_app.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("swift build", self.log())

    def test_signing_failure_prevents_dmg_creation(self):
        self.env.update(SIGNING_IDENTITY="Developer ID Application: Example (TEAM)", SGS_TEST_FAIL_TOOL="codesign")
        result = self.run_script("build_app.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("hdiutil", self.log())

    def test_unsigned_build_is_labeled_local_only(self):
        result = self.run_script("build_app.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("local testing", result.stdout)
        self.assertNotIn("notarytool", self.log())


if __name__ == "__main__":
    unittest.main()
