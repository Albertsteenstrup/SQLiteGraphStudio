# Building and packaging

`Sources/SQLiteGraphStudio/App/Info.plist` is the source of truth for the app's bundle identifier, marketing version, build number, minimum macOS version, and document associations. Both packaging scripts copy that file. Update versions there when preparing a release. The canonical identity remains `com.albertsteenstrup.sqlitegraphstudio`, with the existing release metadata `0.3.1` / build `2`; this change does not declare a new release.

## Local builds

```bash
bash script/build_and_run.sh --build-only
```

This builds a debug app in `dist/SQLiteGraphStudio.app`, including SwiftPM resources, without stopping or launching an app. Omit `--build-only` to build and launch during normal development. `swift run` remains available but does not have a packaged bundle identity.

```bash
bash script/build_app.sh
```

This builds a universal arm64/x86_64 release app and local DMG in `dist`. Without signing configuration the outputs are for local testing, with no claim of Gatekeeper acceptance. Neither build command installs or publishes anything.

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

## Preserving preferences

The previous development launcher used `com.albertsteenstrup.sqlite-graph-studio`. Before the packaged app creates its session, a one-time migration copies missing app-owned preferences from that domain: recent documents, saved queries, query history, version-2 graph layouts, and story layouts. Existing canonical values always win, including empty values. Opaque values are copied as whole values; saved query lists from the two domains are not combined. The old domain is left intact. The migration marker prevents subsequently deleted values from being imported again. Unbundled command-line and test processes do not run the automatic migration.

## Signed and notarized distribution

Public distribution requires an appropriate **Developer ID Application** certificate and its private key in the signing keychain, plus Apple notarization credentials. An **Apple Development** certificate does not establish Developer ID distribution trust. Follow Apple's [Developer ID guidance](https://developer.apple.com/developer-id/) and [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Configure a named notarytool Keychain profile outside this repository using `xcrun notarytool store-credentials`. Keep credentials and private keys out of source control. On an explicitly authorized release machine:

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARYTOOL_PROFILE='your-notary-keychain-profile' \
bash script/build_app.sh
```

This command builds both architectures, signs the app with hardened runtime and a secure timestamp, verifies its signature, creates and signs the DMG, and **uploads that DMG to Apple's notarization service**. It then waits for processing, staples and validates the ticket, and assesses the DMG locally. A failure stops the pipeline. The script never publishes a release, installs the app, or launches it.

`SIGNING_IDENTITY` alone signs the app and DMG without notarizing. `NOTARYTOOL_PROFILE` requires a `Developer ID Application:` identity. When PostgreSQL is supplied, the release script signs every nested Mach-O file in that runtime with the same identity, hardened runtime, and timestamp **before signing the app**. It then verifies the app deeply and strictly; any signing failure stops the pipeline. Debug bundles remain unsigned by the packaging script. This runtime layout supports ordinary executables and libraries; adding nested app/framework/XPC bundles or native code elsewhere requires explicit inside-out signing updates.

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

The Python suite also exercises optional runtime copying, preserved licenses and symlinks, missing components, native binary requirements, per-architecture dependency inspection, external/unresolved dependencies, architecture mismatches, nested signing order, and unchanged builds without a runtime. Its `swift`, `lipo`, `otool`, and signing invocations are command doubles in disposable directories, not real builds or runtime execution.
