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

`SIGNING_IDENTITY` alone signs the app and DMG without notarizing. `NOTARYTOOL_PROFILE` requires a `Developer ID Application:` identity. The current bundle contains one executable and resource-only bundles; adding frameworks, helper executables, extensions, or other nested code requires explicit inside-out signing updates.

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
