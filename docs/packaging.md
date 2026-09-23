# Building and packaging

`Sources/SQLiteGraphStudio/App/Info.plist` is the source of truth for the app's bundle identifier, marketing version, build number, minimum macOS version, and document associations. Both packaging scripts copy that file. Update versions there when preparing a release. The canonical identity remains `com.albertsteenstrup.sqlitegraphstudio`. The next release candidate uses `0.4.0` / build `3`; this metadata does not mean the unsigned local artifact is approved for public distribution.

## Local builds

```bash
bash script/build_and_run.sh --build-only
```

This builds a debug app in `dist/SQLiteGraphStudio.app`, including SwiftPM resources and the `StudioMCP` local helper at `Contents/MacOS/StudioMCP`, without stopping or launching an app. Omit `--build-only` to build and launch during normal development. `swift run` remains available but does not have a packaged bundle identity.

```bash
bash script/build_app.sh
```

This builds a universal arm64/x86_64 release app, universal local MCP helper, and local DMG in `dist`. Without signing configuration the outputs are for local testing, with no claim of Gatekeeper acceptance. Neither build command installs or publishes anything.

## Optional PostgreSQL runtime for dump opening

This repository does not currently ship or manufacture a redistributable PostgreSQL runtime. The optional bundling support below requires a separately prepared runtime; supplying and validating that distribution remains a release prerequisite for a self-contained dump opener. Installed-runtime discovery remains available without it.

Both scripts bundle a native PostgreSQL runtime only when `SGS_POSTGRES_RUNTIME` is a non-empty, explicitly supplied path:

```bash
SGS_POSTGRES_RUNTIME='/absolute/path/to/relocatable-postgresql' \
bash script/build_and_run.sh --build-only

SGS_POSTGRES_RUNTIME='/absolute/path/to/universal-relocatable-postgresql' \
bash script/build_app.sh
```

The whole supplied directory is copied to `SQLiteGraphStudio.app/Contents/Resources/PostgreSQL`, including license and copyright notices, extension SQL, and relative internal symlinks. Supply the notices for PostgreSQL, pgvector, and every bundled dependency in the runtime tree; the packager preserves them but does not determine license completeness. The source runtime is not modified or executed. Source paths overlapping the output app are rejected before building; copy a runtime from a previous app to a separate directory first. There are no downloads or binary relocation fixes.

The required layout is:

```text
bin/{postgres,initdb,pg_ctl,pg_restore,psql,pg_config}
share/postgresql/postgres.bki
share/postgresql/extension/{pgcrypto,vector}.control
share/postgresql/extension/{pgcrypto,vector}--*.sql
lib/                         # all non-system dynamic dependencies
lib/postgresql/{pgcrypto,vector}.so
COPYRIGHT                    # example; all supplied notice paths are preserved
```

Extension libraries may also live directly in `lib`, and `.dylib` is accepted as well as `.so`. Include the complete PostgreSQL shared-data directory and matching native libraries; the layout checks are not an exhaustive catalog of files needed by every PostgreSQL configuration. All six tools and both extensions must be Mach-O code, and the tools must be executable. Release packaging requires **arm64 and x86_64 in every bundled Mach-O file**, including dependencies and extensions. Debug packaging requires the architectures present in the debug app executable. It does not merge separate runtime installations or translate incompatible architectures.

The helper validates a staged copy using `lipo` and `otool` before putting it at the final resource path. It examines load commands in every architecture, follows bundled dynamic dependencies, and rejects unresolved references, escaping/dangling/absolute symlinks, and non-system absolute dependency or rpath references. Supported references are `@loader_path`, `@executable_path`, and `@rpath` resolved within the runtime using the loader chain, plus system paths under `/usr/lib` and `/System/Library`. Extension modules are checked in the `postgres` loader context. Library install names (`LC_ID_DYLIB`) are not themselves dependency loads. An inspection or validation failure stops packaging before signing or creating a DMG.

An ordinary Homebrew prefix or Cellar binary tree is **not assumed to be relocatable**. Copying it, or merely copying its dylibs, does not repair absolute load commands, symlinks, compiled-in paths, or extension ABI compatibility. Provide a runtime prepared and tested for relocation. These static checks cannot prove compiled-in data paths, arbitrary `dlopen` targets, PostgreSQL/extension version compatibility, macOS deployment compatibility, or a successful sandboxed restore. Before distribution, move the packaged app away from the source runtime and verify dump restore, extension loading, and cleanup on each supported architecture in the parent runtime/UI verification workflow.

When the variable is unset or empty, neither build script includes PostgreSQL or searches for an installation to bundle. The app retains installed PostgreSQL 17/18 runtime discovery. Consequently, a build without the runtime is **not a self-contained dump opener**: dump opening requires a compatible installed runtime and the required extensions; it reports a missing-runtime/dependency error when they are unavailable. Rebuilding without the variable also removes any runtime from the previous assembled app. Existing connection-document and SQLite functionality do not require bundling this runtime.

## Optional Pocket TTS runtime

The repository pins Pocket TTS 3.1.0 and its Python dependencies in `script/pocket-tts-runtime/uv.lock` and the hash-bearing `requirements.lock`. The build script uses the official Astral CPython 3.12.13 arm64 archive and verifies its SHA-256 before installing only the pinned PyPI wheels. It retains the Python and package license metadata, records the archive and lock hashes in `runtime-manifest.json`, and includes the lock in the packaged runtime. Model weights remain a separate user-triggered download, pinned to the public Kyutai Hugging Face repository; no gated voice-cloning files are included.

Build the arm64 artifact on an Apple Silicon Mac with uv 0.11.31 installed:

```bash
script/pocket-tts-runtime/build_runtime.sh --architecture arm64 \
  '/absolute/path/to/prepared-PocketTTSRuntime/arm64'

SGS_POCKET_TTS_RUNTIME_REQUIRED=1 \
SGS_POCKET_TTS_RUNTIME='/absolute/path/to/prepared-PocketTTSRuntime' \
bash script/build_and_run.sh --build-only

SGS_POCKET_TTS_RUNTIME_REQUIRED=1 \
SGS_POCKET_TTS_RUNTIME='/absolute/path/to/prepared-PocketTTSRuntime' \
bash script/build_app.sh
```

The current official PyTorch wheel release required by the lock has no macOS x86_64 wheel. The runtime builder fails immediately with that reason on Intel. A universal app may contain the arm64 runtime in `PocketTTSRuntime/arm64`; an Intel launch finds no x86_64 runtime and uses the built-in macOS speech provider. `SGS_POCKET_TTS_RUNTIME_REQUIRED=1` makes either build script fail before building when the runtime path is absent; a supplied but invalid or incomplete artifact also fails validation. Leave the flag unset for a build that intentionally omits Pocket TTS.

The packaged worker stays offline and loads only the pinned, nongated English 2026-09 Alba preset. Its four user-installed files (config, model, paired SentencePiece tokenizer, and voice) total **225,285,245 bytes** (about 215 MiB); the app offers the download only after an explicit install action and verifies each file's exact size and SHA-256. The downloaded Hugging Face tokenizer JSON is not used: Pocket TTS 3.1.0 reads SentencePiece, and the model repository's pinned `.model` file has the same 4,000-piece order and scores. The app rewrites only the local config asset paths before loading, so model startup does not contact Hugging Face.

On this arm64 Mac, the staged Python runtime occupied about **841 MiB** on disk. A fresh worker process completed its ready handshake in **23.23 seconds**; then it emitted the first audio frame **46 ms** after a synthesis request, streamed 3.12 seconds of speech in 0.79 seconds, and exited successfully. The worker's maximum resident set size was **906 MiB** for that run. These are one-machine smoke measurements, not a performance guarantee; validate launch time and memory on release hardware, including an 8 GB device, before shipping. The locked PyTorch dependency currently prevents a usable Intel build. Software and model terms are recorded in `script/pocket-tts-runtime/THIRD_PARTY_NOTICES.md`; Kyutai code is MIT, and the model and Alba voice are CC BY 4.0.

## Preserving preferences

The previous development launcher used `com.albertsteenstrup.sqlite-graph-studio`. Before the packaged app creates its session, a one-time migration copies missing app-owned preferences from that domain: recent documents, saved queries, query history, and version-2 graph layouts. Removed story layouts are not imported. Existing canonical values always win, including empty values. Opaque values are copied as whole values; saved query lists from the two domains are not combined. The old domain is left intact. The migration marker prevents subsequently deleted values from being imported again. Unbundled command-line and test processes do not run the automatic migration.

## Signed and notarized distribution

Public distribution requires an appropriate **Developer ID Application** certificate and its private key in the signing keychain, plus Apple notarization credentials. An **Apple Development** certificate does not establish Developer ID distribution trust. Follow Apple's [Developer ID guidance](https://developer.apple.com/developer-id/) and [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Configure a named notarytool Keychain profile outside this repository using `xcrun notarytool store-credentials`. Keep credentials and private keys out of source control. On an explicitly authorized release machine:

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='your-notary-keychain-profile' \
bash script/build_app.sh
```

This command builds both architectures, signs the app with hardened runtime and a secure timestamp, verifies its signature, creates and signs the DMG, and **uploads that DMG to Apple's notarization service**. It then waits for processing, staples and validates the ticket, and assesses the DMG locally. A failure stops the pipeline. The script never publishes a release, installs the app, or launches it.

`SIGNING_IDENTITY` alone signs the app and DMG without notarizing. `NOTARYTOOL_PROFILE` requires a `Developer ID Application:` identity. The release script signs `StudioMCP` with the same identity, hardened runtime, and timestamp **before signing the app**. When PostgreSQL is supplied, it also signs every nested Mach-O file in that runtime first. It then verifies the app deeply and strictly; any signing failure stops the pipeline. Debug bundles remain unsigned by the packaging script. This runtime layout supports ordinary executables and libraries; adding nested app/framework/XPC bundles or native code elsewhere requires explicit inside-out signing updates.

To repackage an already prepared app, run:

```bash
bash script/create_dmg.sh /path/to/SQLiteGraphStudio.app /path/to/output.dmg
```

This only creates a new container. It does not sign or notarize the new DMG, and a previous DMG's stapled ticket does not transfer. Complete signing, notarization, and assessment again for the exact artifact intended for distribution. Before publication, verify the final downloaded artifact through the normal Gatekeeper path on a separate Mac; a local script success alone is not that end-user check. Do not remove quarantine attributes as a substitute for distribution signing and notarization.

## Regression verification

```bash
bash script/test_packaging.sh
```

The packaging tests assemble disposable fixture bundles using command doubles for build, signing, disk image, and notarization tools. They check metadata agreement, resource inclusion, build-only behavior, signing order, and failure handling. The standalone Swift test executes the real preference migration with isolated temporary preference domains, leaving real application settings untouched. This suite does not prove an actual universal build, real certificate validity, successful Apple notarization, or Gatekeeper acceptance; those require the configured release environment and exact release artifact.

To verify packaging without invoking Swift or taking a build lock:

```bash
python3 Tests/Packaging/test_packaging.py
```

The Python suite also exercises optional runtime copying, preserved licenses and symlinks, missing components, native binary requirements, per-architecture dependency inspection, external/unresolved dependencies, architecture mismatches, nested signing order, Pocket TTS runtime manifest/lock checks, and unchanged builds without a runtime. Its `swift`, `lipo`, `otool`, and signing invocations are command doubles in disposable directories, not real builds or runtime execution.
