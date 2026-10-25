# Zacro Electron runtime

The source pins are in [build.json](build.json), and the ordered native patch
set and its hashes are in [patches/series.json](patches/series.json). This is an
Electron derivative. The application negotiates the native ABI from the actual
profile session; stock Electron keeps the engine-dependent capabilities closed.

A patch passing application checks is **not** a compiled or accepted runtime.
The required gates are compilation, the native Electron specs, Zacro's native
acceptance, and packaging on macOS arm64, macOS x64 and Windows x64. Signing and
notarization remain the separate distribution gate.

## Prepare a dedicated build machine

Install the platform prerequisites from the pinned
[Electron build instructions](https://github.com/electron/electron/blob/v45.0.0/docs/development/build-instructions-gn.md).
Use Node.js 24 and a dedicated directory without spaces. For macOS, use an APFS
volume, Xcode and its command-line tools. A 300 GiB build volume is the current
project allocation, not a measured guarantee for every configuration. The
source, tools and build outputs are much larger than a prebuilt Electron app.
The scripts use four compile jobs and disable remote execution.

Xcode may provide Metal as a separate component. Verify `xcrun metal --version`
before the first build. If it reports a missing Metal Toolchain, install Apple's
component with `xcodebuild -downloadComponent MetalToolchain`, then repeat the
version check and resume the build. The current local build required this step
for ANGLE's native Metal shaders; completed build outputs were retained.

The current local build uses `/Volumes/ZacroElectronBuild`, an APFS sparse disk
image stored at `/Volumes/EVA SSD/ZacroElectronBuild.sparsebundle`. The existing
SSD is exFAT; it was not reformatted. Keep the SSD connected until builds stop
and this volume is safely detached. The image grows with data written, up to
300 GiB. It contains only task-created build data. Container acceptance uses a separate
local Colima test profile, stopped after its tests.

From the Zacro checkout, run each phase in order (use `x64` on a matching Intel
Mac or Windows host):

```sh
node scripts/build-electron-runtime.cjs doctor /Volumes/ZacroElectronBuild arm64
node scripts/build-electron-runtime.cjs sync /Volumes/ZacroElectronBuild arm64
node scripts/build-electron-runtime.cjs hooks /Volumes/ZacroElectronBuild arm64
node scripts/build-electron-runtime.cjs patch /Volumes/ZacroElectronBuild arm64
node scripts/build-electron-runtime.cjs build /Volumes/ZacroElectronBuild arm64
node scripts/build-electron-runtime.cjs test /Volumes/ZacroElectronBuild arm64
node scripts/build-electron-runtime.cjs test-app /Volumes/ZacroElectronBuild arm64
```

`sync` pins depot_tools and Electron and fetches Chromium dependencies without
history. `hooks` applies Electron's normal upstream patches and gets toolchains.
`patch` verifies every patch hash and records the applied series. `build` rejects
a changed patch series and writes the native GN configuration. Existing source
changes are never reset or deleted to force a phase through. Re-run a failed
phase after addressing its specific error; do not rerun hooks over custom
patches without first checking the upstream patch tool's state.
Resumed phases recheck the depot_tools commit before running pinned tools;
an unexpected checkout is rejected without resetting it.

Native tests use `src/out/Zacro-ARCH`. The build also creates `dist.zip` there.
The `testing.gn` base retains DCHECKs and is a development runtime; it is not a
signed release artifact. Native positive tests must run on the binary built
from the patched source, not the npm stock runtime.

## Install and validate a local artifact

Extract `dist.zip` into a new directory with a ZIP tool that preserves framework
symlinks (macOS `ditto -x -k`). Then run:

```sh
node scripts/electron-runtime-artifact.cjs seal /absolute/extracted-runtime
node scripts/electron-runtime-artifact.cjs verify /absolute/extracted-runtime
node scripts/electron-runtime-artifact.cjs install /absolute/extracted-runtime
ZACRO_REQUIRE_CUSTOM_ELECTRON=1 npm run verify
ZACRO_REQUIRE_CUSTOM_ELECTRON=1 npm run pack:mac
npm run test:package
```

The receipt records the upstream commit, ordered patch identity, target, every
regular-file hash and relative symlink target. Installation verifies the source
and staged copy, then preserves the previous npm runtime at the printed backup
path. Packaging checks the receipt again. `npm ci` reinstalls stock Electron;
reinstall the verified artifact before custom acceptance or packaging.
Sealing and verification also inspect the Electron executable and native runtime
dependencies for matching Mach-O macOS arm64/x64 or PE Windows x64 headers.
Mixed architectures and unsupported native formats are rejected; relative internal
framework links are preserved and checked for containment.

The receipt proves local content integrity against its recorded identity. It
does not authenticate a third-party publisher, prove that compilation used
those sources, or replace native tests/signatures. Only seal an artifact from
the reviewed build you just performed. Keep the compiler/test logs with its
archive and digest. Do not publish it as an accepted release before all required
platform and distribution checks pass.

The manual [native runtime workflow](../../.github/workflows/electron-runtime.yml)
uses dedicated `zacro-electron-build` self-hosted runners for the three targets.
It builds, runs the native engine and application capability fixtures, and saves
the archive plus SHA-256. Creating the workflow does not provision runners or
prove a successful run. The normal browser workflow and signed package gates
remain required after installing each accepted runtime.

## Runtime upgrades

Update the exact Electron, Chromium and depot_tools pins together. Rebase the
patches against pristine sources, regenerate their hashes, then repeat every
native and package gate. A missing ABI method or unexpected ABI version disables
the corresponding capability; it must not fall back to simulated permission,
script-world or CSS behavior.
