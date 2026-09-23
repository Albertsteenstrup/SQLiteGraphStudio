#!/usr/bin/env python3
"""Validate and copy a separately prepared, relocatable Pocket TTS runtime.

This script never resolves or downloads Python packages. The input must have been built from a
committed uv.lock by a release builder, and must carry that exported lock plus a manifest. Model
weights and the preset remain user-triggered, separately verified app-support assets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


MACH_O_MAGICS = {
    bytes.fromhex(value)
    for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}
WORKER_SOURCE = Path(__file__).resolve().parent / "pocket-tts-runtime/pocket_tts_worker.py"


def inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def lock_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate(source: Path, required_architectures: list[str]) -> None:
    source = source.resolve(strict=True)
    manifest_path = source / "runtime-manifest.json"
    lock_path = source / "requirements.lock"
    python_path = source / "python/bin/python3"
    if not source.is_dir():
        raise ValueError(f"runtime directory does not exist: {source}")
    if not manifest_path.is_file() or not lock_path.is_file() or not python_path.is_file():
        raise ValueError("runtime must include runtime-manifest.json, requirements.lock and python/bin/python3")
    if not os.access(python_path, os.X_OK):
        raise ValueError("python/bin/python3 is not executable")

    for path in source.rglob("*"):
        if path.is_symlink():
            try:
                target = Path(os.readlink(path))
                if target.is_absolute() or not inside(path.resolve(strict=True), source):
                    raise ValueError(f"runtime contains a non-relocatable symlink: {path.relative_to(source)}")
            except (OSError, RuntimeError) as error:
                raise ValueError(f"runtime contains a dangling symlink: {path.relative_to(source)}") from error

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"runtime manifest is invalid: {error}") from error
    if not isinstance(manifest, dict):
        raise ValueError("runtime manifest must be a JSON object")
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported Pocket TTS runtime manifest version")
    if manifest.get("python_minor") != "3.12":
        raise ValueError("Pocket TTS runtime must use the locked Python 3.12 runtime")
    if manifest.get("pocket_tts_version") != "3.1.0" or manifest.get("protocol_version") != 1:
        raise ValueError("runtime must pin Pocket TTS 3.1.0 and worker protocol 1")
    if manifest.get("requirements_lock_sha256") != lock_sha256(lock_path):
        raise ValueError("requirements.lock does not match the runtime manifest SHA-256")
    if manifest.get("python_version") not in (None, "3.12.13"):
        raise ValueError("runtime must use the pinned CPython 3.12.13 distribution")
    python_digest = manifest.get("python_executable_sha256")
    if python_digest is not None and python_digest != lock_sha256(python_path):
        raise ValueError("python/bin/python3 does not match the runtime manifest SHA-256")
    distribution_digest = manifest.get("python_distribution_sha256")
    if distribution_digest is not None and not re.fullmatch(r"[0-9a-f]{64}", distribution_digest):
        raise ValueError("runtime manifest Python distribution SHA-256 is invalid")

    lock = lock_path.read_text(encoding="utf-8")
    if not re.search(r"(?im)^pocket[-_]tts\s*==\s*3\.1\.0(?:\s|\\|$)", lock):
        raise ValueError("requirements.lock does not pin pocket-tts==3.1.0")
    if "--hash=sha256:" not in lock and "--hash sha256:" not in lock:
        raise ValueError("requirements.lock must include package hashes")

    built_architectures = manifest.get("architectures")
    if not isinstance(built_architectures, list) or not all(
        isinstance(architecture, str) for architecture in built_architectures
    ):
        raise ValueError("runtime manifest architectures must be a list of strings")
    if not set(required_architectures).issubset(built_architectures):
        missing = set(required_architectures) - set(built_architectures)
        raise ValueError(f"runtime manifest is missing architecture(s): {' '.join(sorted(missing))}")

    native_files: list[Path] = []
    for path in source.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in MACH_O_MAGICS:
                native_files.append(path)
    if python_path.resolve() not in {path.resolve() for path in native_files}:
        raise ValueError("python/bin/python3 is not a bundled Mach-O executable")

    for path in native_files:
        result = subprocess.run(
            ["lipo", "-archs", str(path)],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise ValueError(f"lipo could not inspect {path.relative_to(source)}: {result.stderr.strip()}")
        available = set(result.stdout.split())
        missing = set(required_architectures) - available
        if missing:
            raise ValueError(
                f"{path.relative_to(source)} is missing architecture(s): {' '.join(sorted(missing))}"
            )


def runtime_sources(source: Path, architectures: list[str]) -> dict[str | None, Path]:
    """Validate one universal runtime or per-architecture runtime directories.

    A universal app may intentionally ship an arm64 Pocket TTS runtime only. On Intel Macs the
    app selects the built-in macOS voice when that architecture-specific runtime is absent.
    """
    if (source / "runtime-manifest.json").is_file():
        validate(source, architectures)
        return {None: source}

    if not architectures or any(architecture not in {"arm64", "x86_64"} for architecture in architectures):
        raise ValueError("split Pocket TTS runtimes require arm64 and/or x86_64 architectures")
    result: dict[str | None, Path] = {}
    for architecture in architectures:
        architecture_root = source / architecture
        if not architecture_root.is_dir():
            if architecture == "x86_64" and "arm64" in architectures and "arm64" in result:
                continue
            raise ValueError(f"runtime directory is missing for {architecture}: {architecture_root}")
        validate(architecture_root, [architecture])
        result[architecture] = architecture_root
    if not result:
        raise ValueError("no supported architecture-specific Pocket TTS runtime was found")
    return result


def check_source(source: Path, output: Path, architectures: list[str]) -> Path:
    source = source.resolve(strict=True)
    output = output.resolve()
    if inside(output, source) or inside(source, output):
        raise ValueError("runtime source and app output must not overlap")
    runtime_sources(source, architectures)
    return source


def package(source: Path, destination: Path, architectures: list[str]) -> None:
    source = check_source(source, destination, architectures)
    destination = destination.resolve()
    if destination.exists():
        raise ValueError(f"Pocket TTS runtime destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)

    sources = runtime_sources(source, architectures)
    with tempfile.TemporaryDirectory(prefix=".PocketTTS-", dir=destination.parent) as staging:
        copied = Path(staging) / "runtime"
        copied.mkdir()
        for architecture, runtime_source in sources.items():
            runtime_destination = copied if architecture is None else copied / architecture
            shutil.copytree(runtime_source, runtime_destination, symlinks=True, dirs_exist_ok=True)
            shutil.copy2(WORKER_SOURCE, runtime_destination / "pocket_tts_worker.py")
            validate(runtime_destination, architectures if architecture is None else [architecture])
        copied.rename(destination)
    print(f"    Pocket TTS runtime: {destination}")


def native_files(root: Path) -> list[Path]:
    result = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in MACH_O_MAGICS:
                result.append(path)
    return result


def sign(runtime: Path, identity: str) -> None:
    for path in sorted(native_files(runtime), key=lambda item: (-len(item.parts), str(item))):
        subprocess.run(
            ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(path)],
            check=True,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    check = commands.add_parser("check-source")
    check.add_argument("source", type=Path)
    check.add_argument("output", type=Path)
    check.add_argument("architectures", nargs="+")
    copy = commands.add_parser("package")
    copy.add_argument("source", type=Path)
    copy.add_argument("destination", type=Path)
    copy.add_argument("architectures", nargs="+")
    signing = commands.add_parser("sign")
    signing.add_argument("runtime", type=Path)
    signing.add_argument("identity")
    args = parser.parse_args()
    try:
        if args.action == "check-source":
            print(check_source(args.source, args.output, args.architectures))
        elif args.action == "package":
            package(args.source, args.destination, args.architectures)
        else:
            sign(args.runtime, args.identity)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(2, f"Pocket TTS runtime packaging failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
