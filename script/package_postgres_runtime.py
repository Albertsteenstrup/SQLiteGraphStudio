#!/usr/bin/env python3
"""Copy an explicitly supplied, already-relocatable macOS PostgreSQL runtime.

No downloads, install-name rewriting, or execution of supplied PostgreSQL code.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


TOOLS = ("postgres", "initdb", "pg_ctl", "pg_restore", "psql", "pg_config")
MACH_O_MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}


def inside(path, root):
    return path == root or root in path.parents


def system_path(path):
    return any(inside(path, Path(root)) for root in ("/usr/lib", "/System/Library"))


def native_files(root):
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACH_O_MAGIC:
                    result.append(path)
    return result


def command(*args):
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(f"{args[0]} failed for {args[-1]}: {result.stderr.strip()}")
    return result.stdout


def load_commands(path, arch):
    output = command("otool", "-arch", arch, "-l", str(path))
    if "Load command " not in output:
        raise ValueError(f"otool returned no Mach-O load commands: {path} ({arch})")
    dependencies, rpaths = [], []
    for block in re.split(r"(?m)^Load command \d+\s*$", output)[1:]:
        match = re.search(r"(?m)^\s*cmd (LC_\w+)\s*$", block)
        if not match:
            raise ValueError(f"malformed otool load command in {path} ({arch})")
        current = match[1]
        # Includes weak, re-exported and upward dependencies; the dylib's
        # own install name is not a dependency.
        dependency = (current.endswith("_DYLIB") and current != "LC_ID_DYLIB") or current == "LC_LOAD_DYLINKER"
        if current == "LC_RPATH" or dependency:
            field = "path" if current == "LC_RPATH" else "name"
            value = re.search(rf"(?m)^\s*{field} (.+) \(offset \d+\)\s*$", block)
            if not value:
                raise ValueError(f"malformed otool {current} path in {path} ({arch})")
            (dependencies if dependency else rpaths).append(value[1])
    return dependencies, rpaths


def validate(root, required_archs):
    for path in root.rglob("*"):
        if path.is_symlink():
            try:
                valid = not Path(os.readlink(path)).is_absolute() and inside(path.resolve(strict=True), root)
            except (OSError, RuntimeError):
                valid = False
            if not valid:
                raise ValueError(f"non-relocatable or dangling symlink: {path}")

    for name in TOOLS:
        path = root / "bin" / name
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f"missing executable bin/{name}")
    if not (root / "share/postgresql/postgres.bki").is_file():
        raise ValueError("missing share/postgresql/postgres.bki")
    modules = []
    for extension in ("pgcrypto", "vector"):
        share = root / "share/postgresql/extension"
        if not (share / f"{extension}.control").is_file() or not any(
            path.is_file() for path in share.glob(f"{extension}--*.sql")
        ):
            raise ValueError(f"missing {extension} extension control/SQL files")
        candidates = [root / directory / f"{extension}{suffix}"
                      for directory in ("lib", "lib/postgresql")
                      for suffix in (".so", ".dylib")]
        found = [path.resolve() for path in candidates if path.is_file()]
        if not found:
            raise ValueError(f"missing {extension} native extension in lib or lib/postgresql")
        modules.extend(found)

    code = native_files(root)
    for path in [*(root / "bin" / name for name in TOOLS), *modules]:
        if path.resolve() not in code:
            raise ValueError(f"required file is not Mach-O native code: {path}")
    metadata = {}
    for path in code:
        if any(parent.suffix in (".app", ".framework", ".xpc", ".bundle")
               for parent in path.relative_to(root).parents):
            raise ValueError(f"unsupported nested code bundle: {path}")
        archs = command("lipo", "-archs", str(path)).split()
        missing = set(required_archs) - set(archs)
        if not archs or missing:
            raise ValueError(f"{path}: missing required architecture(s): {' '.join(sorted(missing))}")
        metadata[path] = {arch: load_commands(path, arch) for arch in archs}

    def expand(value, loader, executable):
        for token, base in (("@loader_path", loader.parent), ("@executable_path", executable.parent)):
            if value == token or value.startswith(token + "/"):
                path = (base / value[len(token):].lstrip("/")).resolve()
                if inside(path, root):
                    return path
                break
        else:
            path = Path(os.path.normpath(value))
            if path.is_absolute() and system_path(path):
                return path
        raise ValueError(f"external or unsupported dynamic path {value!r} in {loader}")

    def walk(path, arch, executable, inherited, active):
        if path in active:
            return
        if arch not in metadata[path]:
            raise ValueError(f"{path}: dependency missing architecture {arch}")
        dependencies, raw_rpaths = metadata[path][arch]
        rpaths = tuple(dict.fromkeys([*(expand(value, path, executable) for value in raw_rpaths), *inherited]))
        for value in dependencies:
            if value.startswith("@rpath/"):
                candidates = [(base / value[len("@rpath/"):]).resolve() for base in rpaths]
            else:
                candidates = [expand(value, path, executable)]
            target = None
            for candidate in candidates:
                if system_path(candidate):
                    target = candidate
                    break
                if not inside(candidate, root):
                    raise ValueError(f"external dynamic dependency {value!r} in {path}")
                if candidate.is_file():
                    target = candidate
                    break
            if target is None:
                raise ValueError(f"unresolved dynamic dependency {value!r} in {path} ({arch})")
            if not system_path(target):
                if target not in metadata:
                    raise ValueError(f"dependency is not Mach-O: {target}")
                walk(target, arch, executable, rpaths, active | {path})

    # Executables inherit their loader chain's rpaths. Extension modules are
    # loaded by postgres, so validate them in that executable's context too.
    postgres = (root / "bin/postgres").resolve()
    for path in code:
        for arch in metadata[path]:
            executable = path if inside(path, root / "bin") else postgres
            inherited = ()
            if executable == postgres and path != postgres:
                if arch not in metadata[postgres]:
                    raise ValueError(f"postgres missing architecture {arch} needed by {path}")
                inherited = tuple(expand(value, postgres, postgres) for value in metadata[postgres][arch][1])
            walk(path, arch, executable, inherited, set())


def check_source(source, output):
    source = source.resolve()
    output = output.resolve()
    if not source.is_dir():
        raise ValueError(f"runtime directory does not exist: {source}")
    if inside(output, source) or inside(source, output):
        raise ValueError("runtime source and app output must not overlap; copy the runtime elsewhere first")
    return source


def package(source, destination, archs):
    source = check_source(source, destination)
    destination = destination.resolve()
    if destination.exists():
        raise ValueError(f"runtime destination already exists: {destination}")
    # Validate the copied bytes; expose the final directory only after success.
    # copytree preserves modes, relative symlinks and all license/notice files.
    with tempfile.TemporaryDirectory(prefix=".PostgreSQL-", dir=destination.parent) as staging:
        copied = Path(staging) / "runtime"
        shutil.copytree(source, copied, symlinks=True)
        validate(copied, archs)
        copied.rename(destination)
    print(f"    PostgreSQL runtime: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="action", required=True)
    check_parser = subcommands.add_parser("check-source")
    check_parser.add_argument("source", type=Path)
    check_parser.add_argument("output", type=Path)
    copy_parser = subcommands.add_parser("package")
    copy_parser.add_argument("source", type=Path)
    copy_parser.add_argument("destination", type=Path)
    copy_parser.add_argument("archs", nargs="+")
    sign_parser = subcommands.add_parser("sign")
    sign_parser.add_argument("runtime", type=Path)
    sign_parser.add_argument("identity")
    args = parser.parse_args()
    try:
        if args.action == "check-source":
            print(check_source(args.source, args.output))
        elif args.action == "package":
            package(args.source, args.destination, args.archs)
        else:
            # Files under Resources are explicit code-signing targets. Never
            # rely on --deep to discover/sign nested code during app signing.
            for path in sorted(native_files(args.runtime), key=lambda p: (-len(p.parts), str(p))):
                command("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.identity, str(path))
    except (OSError, ValueError, RuntimeError) as error:
        print(f"PostgreSQL runtime: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
