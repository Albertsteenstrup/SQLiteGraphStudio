"""Exercise packaging in a disposable repo with toolchain/signing command doubles.

These tests never build, sign, submit, install, or launch the real application.
"""
import json
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
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["SGS_TEST_LOG"], "a") as log:
    log.write(name + " " + " ".join(args) + "\\n")
if name == "swift" and "--show-bin-path" in args:
    print(os.environ["SGS_TEST_BIN"])
elif name == "lipo":
    if "-archs" in args:
        data = pathlib.Path(args[-1]).read_bytes()
        print(" ".join(json.loads(data[4:])["archs"]) if data.startswith(bytes.fromhex("cffaedfe")) else os.environ.get("SGS_TEST_APP_ARCHS", "arm64 x86_64"))
    else: pathlib.Path(args[args.index("-output") + 1]).write_text("universal fixture")
elif name == "otool":
    if "SGS_TEST_OTOOL_OUTPUT" in os.environ:
        print(os.environ["SGS_TEST_OTOOL_OUTPUT"])
        sys.exit(0)
    data = json.loads(pathlib.Path(args[-1]).read_bytes()[4:])
    arch = args[args.index("-arch") + 1]
    print(args[-1] + ":")
    commands = [("LC_UUID", "uuid", "fixture")]
    commands += [("LC_RPATH", "path", value) for value in data.get("rpaths", [])]
    commands += [("LC_LOAD_DYLIB", "name", value) for value in data.get("deps", [])]
    commands += data.get("loads", []) + data.get("slices", {}).get(arch, [])
    for i, (command, field, value) in enumerate(commands):
        print(f"Load command {i}\\n          cmd {command}\\n      cmdsize 72\\n         {field} {value} (offset 24)")
elif name == "hdiutil":
    pathlib.Path(args[-1]).write_text("fixture dmg")
if os.environ.get("SGS_TEST_FAIL_TOOL") == name:
    sys.exit(1)
''')
        driver.chmod(0o755)
        for name in ["swift", "lipo", "otool", "pkill", "codesign", "hdiutil", "xcrun", "spctl"]:
            (self.tools / name).symlink_to(driver)
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}",
                        SGS_TEST_LOG=str(self.root / "commands.log"), SGS_TEST_BIN=str(self.bin))
        self.env.pop("SIGNING_IDENTITY", None)
        self.env.pop("NOTARYTOOL_PROFILE", None)
        self.env.pop("SGS_POSTGRES_RUNTIME", None)
        for key in ["SGS_TEST_FAIL_TOOL", "SGS_TEST_APP_ARCHS", "SGS_TEST_OTOOL_OUTPUT"]:
            self.env.pop(key, None)

    def native(self, path, **metadata):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes.fromhex("cffaedfe") + json.dumps(
            {"archs": ["arm64", "x86_64"], **metadata}).encode())
        path.chmod(0o755)

    def runtime(self):
        runtime = self.root / "runtime with spaces"
        for name in ["postgres", "initdb", "pg_ctl", "pg_restore", "psql", "pg_config"]:
            self.native(runtime / "bin" / name, deps=["@rpath/libpq.5.dylib"],
                        rpaths=["@executable_path/../lib"])
        self.native(runtime / "lib/libpq.5.dylib", deps=["@loader_path/libssl.dylib"],
                    loads=[["LC_ID_DYLIB", "name", "@rpath/libpq.5.dylib"]])
        self.native(runtime / "lib/libssl.dylib", deps=["/usr/lib/libSystem.B.dylib"])
        (runtime / "lib/libpq.dylib").symlink_to("libpq.5.dylib")
        for extension in ["pgcrypto", "vector"]:
            self.native(runtime / f"lib/postgresql/{extension}.so", deps=["@rpath/libssl.dylib"])
            share = runtime / "share/postgresql/extension"
            share.mkdir(parents=True, exist_ok=True)
            (share / f"{extension}.control").write_text("default_version = '1.0'")
            (share / f"{extension}--1.0.sql").write_text("-- extension fixture")
        (runtime / "share/postgresql/postgres.bki").write_text("catalog fixture")
        (runtime / "COPYRIGHT").write_text("PostgreSQL license fixture")
        licenses = runtime / "licenses"
        licenses.mkdir()
        (licenses / "THIRD-PARTY.txt").write_text("dependency license fixture")
        self.env["SGS_POSTGRES_RUNTIME"] = str(runtime)
        return runtime

    def packaged_runtime(self):
        return self.root / "dist/SQLiteGraphStudio.app/Contents/Resources/PostgreSQL"

    def assert_runtime_failure(self, message, script="build_app.sh"):
        args = ["--build-only"] if script == "build_and_run.sh" else []
        result = self.run_script(script, *args)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertNotIn("codesign --force", self.log())
        self.assertNotIn("hdiutil", self.log())
        self.assertFalse(self.packaged_runtime().exists(), "invalid runtime must not be packaged")

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

    def test_ordinary_builds_do_not_inspect_or_bundle_a_runtime(self):
        for script, args in [("build_and_run.sh", ["--build-only"]), ("build_app.sh", [])]:
            with self.subTest(script=script):
                result = self.run_script(script, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.packaged_runtime().exists())
                self.assertNotIn("otool", self.log())

    def test_both_builds_copy_runtime_licenses_and_relative_symlinks(self):
        source = self.runtime()
        for script, args in [("build_and_run.sh", ["--build-only"]), ("build_app.sh", [])]:
            with self.subTest(script=script):
                result = self.run_script(script, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                packaged = self.packaged_runtime()
                self.assertTrue((packaged / "bin/postgres").is_file())
                for file in source.rglob("*"):
                    destination = packaged / file.relative_to(source)
                    if file.is_symlink():
                        self.assertEqual(os.readlink(destination), os.readlink(file))
                    elif file.is_file():
                        self.assertEqual(destination.read_bytes(), file.read_bytes())
                        self.assertEqual(destination.stat().st_mode, file.stat().st_mode)

    def test_unsetting_runtime_removes_previous_bundle_copy(self):
        self.runtime()
        self.assertEqual(self.run_script("build_and_run.sh", "--build-only").returncode, 0)
        self.assertTrue(self.packaged_runtime().exists())
        self.env.pop("SGS_POSTGRES_RUNTIME")
        self.assertEqual(self.run_script("build_and_run.sh", "--build-only").returncode, 0)
        self.assertFalse(self.packaged_runtime().exists())

    def test_explicit_missing_runtime_fails(self):
        self.env["SGS_POSTGRES_RUNTIME"] = str(self.root / "missing runtime")
        self.assert_runtime_failure("runtime directory")

    def test_runtime_inside_existing_app_is_preserved_and_rejected_before_build(self):
        source = self.runtime()
        bundled = self.packaged_runtime()
        shutil.copytree(source, bundled)
        self.env["SGS_POSTGRES_RUNTIME"] = str(bundled)
        for script, args in [("build_and_run.sh", ["--build-only"]), ("build_app.sh", [])]:
            with self.subTest(script=script):
                result = self.run_script(script, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((bundled / "bin/postgres").is_file(), "existing runtime source was deleted")
                self.assertIn("overlap", result.stderr)
                self.assertNotIn("swift", self.log())

    def test_relative_runtime_path_is_resolved_from_callers_directory(self):
        source = self.runtime()
        self.env["SGS_POSTGRES_RUNTIME"] = os.path.relpath(source, self.tools)
        for script, args in [("build_and_run.sh", ["--build-only"]), ("build_app.sh", [])]:
            with self.subTest(script=script):
                result = subprocess.run(["bash", str(self.root / "script" / script), *args],
                                        cwd=self.tools, env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.packaged_runtime() / "bin/postgres").is_file())

    def test_incomplete_runtime_fails_for_each_required_component(self):
        source = self.runtime()
        for relative in [f"bin/{name}" for name in ["postgres", "initdb", "pg_ctl", "pg_restore", "psql", "pg_config"]] + [
            "share/postgresql/postgres.bki", "share/postgresql/extension/vector.control",
            "share/postgresql/extension/pgcrypto--1.0.sql", "lib/postgresql/pgcrypto.so", "lib/postgresql/vector.so"
        ]:
            with self.subTest(relative=relative):
                path = source / relative
                path.rename(path.with_suffix(path.suffix + ".saved"))
                try:
                    self.assert_runtime_failure("PostgreSQL runtime")
                finally:
                    path.with_suffix(path.suffix + ".saved").rename(path)

    def test_required_tool_must_be_executable_native_code(self):
        source = self.runtime()
        (source / "bin/initdb").chmod(0o644)
        self.assert_runtime_failure("executable", "build_and_run.sh")
        (source / "bin/initdb").chmod(0o755)
        (source / "bin/initdb").write_text("#!/bin/sh\nexit 0\n")
        self.assert_runtime_failure("Mach-O", "build_and_run.sh")

    def test_external_dynamic_dependency_fails_even_in_secondary_architecture(self):
        source = self.runtime()
        self.native(source / "lib/postgresql/vector.so", slices={"x86_64": [
            ["LC_LOAD_WEAK_DYLIB", "name", "/opt/homebrew/opt/openssl/lib/libssl.dylib"]]})
        self.assert_runtime_failure("external")

    def test_absolute_source_dependency_is_not_relocatable(self):
        source = self.runtime()
        self.native(source / "lib/postgresql/vector.so", deps=[str(source / "lib/libssl.dylib")])
        self.assert_runtime_failure("external")

    def test_missing_relative_dependency_and_escaping_rpath_fail(self):
        source = self.runtime()
        self.native(source / "lib/postgresql/vector.so", deps=["@loader_path/missing.dylib"])
        self.assert_runtime_failure("unresolved")
        self.native(source / "lib/postgresql/vector.so", rpaths=["/opt/homebrew/lib"])
        self.assert_runtime_failure("external")

    def test_runtime_symlinks_must_be_relative_internal_and_not_dangling(self):
        source = self.runtime()
        link = source / "lib/extra.dylib"
        for target in [str(source / "lib/libssl.dylib"), "../../outside", "missing.dylib"]:
            with self.subTest(target=target):
                link.symlink_to(target)
                try:
                    self.assert_runtime_failure("symlink")
                finally:
                    link.unlink()

    def test_release_requires_both_architectures_in_extensions_too(self):
        source = self.runtime()
        path = source / "lib/postgresql/vector.so"
        data = json.loads(path.read_bytes()[4:])
        data["archs"] = ["arm64"]
        path.write_bytes(bytes.fromhex("cffaedfe") + json.dumps(data).encode())
        self.assert_runtime_failure("x86_64")

    def test_inspection_tool_failure_is_fatal(self):
        self.runtime()
        self.env["SGS_TEST_FAIL_TOOL"] = "otool"
        self.assert_runtime_failure("otool")

    def test_debug_accepts_matching_thin_runtime_but_release_rejects_it(self):
        source = self.runtime()
        for path in source.rglob("*"):
            if path.is_file() and not path.is_symlink() and path.read_bytes().startswith(bytes.fromhex("cffaedfe")):
                data = json.loads(path.read_bytes()[4:])
                data["archs"] = ["arm64"]
                self.native(path, **data)
        self.env["SGS_TEST_APP_ARCHS"] = "arm64"
        result = self.run_script("build_and_run.sh", "--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.packaged_runtime().exists())
        self.env.pop("SGS_TEST_APP_ARCHS")
        self.assert_runtime_failure("x86_64")

    def test_malformed_otool_dependency_output_fails_closed(self):
        self.runtime()
        self.env["SGS_TEST_OTOOL_OUTPUT"] = "fixture:\nLoad command 0\n cmd LC_LOAD_DYLIB\n name invalid output"
        self.assert_runtime_failure("otool")

    def test_nested_code_bundles_require_a_separate_signing_workflow(self):
        source = self.runtime()
        self.native(source / "lib/Extra.framework/Versions/A/Extra")
        self.assert_runtime_failure("unsupported nested code bundle")

    def test_dependency_cannot_borrow_an_unrelated_executables_rpath(self):
        source = self.runtime()
        self.native(source / "bin/psql", deps=["@rpath/libpq.5.dylib"])
        self.assert_runtime_failure("unresolved")

    def test_lipo_inspection_failure_is_fatal(self):
        self.runtime()
        self.env["SGS_TEST_FAIL_TOOL"] = "lipo"
        result = self.run_script("build_and_run.sh", "--build-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.packaged_runtime().exists())

    def test_every_nested_macho_is_signed_before_app(self):
        source = self.runtime()
        self.env["SIGNING_IDENTITY"] = "Developer ID Application: Example (TEAM)"
        result = self.run_script("build_app.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log().splitlines()
        app_signature = next(i for i, line in enumerate(commands) if line.startswith("codesign --force") and line.endswith("SQLiteGraphStudio.app"))
        nested = [line for line in commands[:app_signature] if line.startswith("codesign --force")]
        native_files = [p.relative_to(source) for p in source.rglob("*") if p.is_file() and not p.is_symlink() and p.read_bytes().startswith(bytes.fromhex("cffaedfe"))]
        self.assertEqual(len(nested), len(native_files))
        for relative in native_files:
            self.assertTrue(any(line.endswith(str(self.packaged_runtime() / relative)) for line in nested), relative)
        self.assertTrue(all("--options runtime --timestamp --sign" in line for line in nested))
        self.assertLess(app_signature, next(i for i, line in enumerate(commands) if line.startswith("hdiutil")))

    def test_nested_signing_failure_prevents_app_signature_and_dmg(self):
        self.runtime()
        self.env.update(SIGNING_IDENTITY="Developer ID Application: Example (TEAM)", SGS_TEST_FAIL_TOOL="codesign")
        result = self.run_script("build_app.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("/Resources/PostgreSQL/", self.log())
        self.assertNotIn("hdiutil", self.log())
        self.assertFalse(any(line.startswith("codesign --force") and line.endswith("SQLiteGraphStudio.app") for line in self.log().splitlines()))


if __name__ == "__main__":
    unittest.main()
