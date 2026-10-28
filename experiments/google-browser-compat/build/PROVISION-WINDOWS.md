# Native Windows prerequisites

`provision-windows.ps1` prepares the Microsoft toolchain for a full Chromium source build. It does not build a browser. The fixed installer identities, official download URLs, SHA-256 values and selected components are in [windows-installers.lock.json](windows-installers.lock.json). No installer binary belongs in this repository.

From the repository root, use Windows PowerShell or PowerShell 7 to download and verify the two small bootstrappers:

```powershell
powershell -NoProfile -File experiments/google-browser-compat/build/provision-windows.ps1 -Download
```

This downloads about 7 MB into `C:\zacro-google-prototype\toolchains\installers` and verifies byte count, pinned SHA-256, valid Microsoft Authenticode signature and product version. Omitting `-Download` verifies the existing files and prints the same installation plan. Neither command runs an installer. Use `-ExternalRoot C:\AnotherDedicatedDirectory` for a different external cache and installation root. Existing nonempty directories without the toolchain's owner marker are refused, as are repository paths and junctions.

To install, open an **Administrator PowerShell**, review the printed plan, then run:

```powershell
powershell -NoProfile -File experiments/google-browser-compat/build/provision-windows.ps1 -Install
```

Microsoft requires administrator rights for initial installation and unattended setup. The script does not elevate itself or change execution/security policy. It installs Build Tools **18.11.2** under `<ExternalRoot>\VS2026`, selects the C++ build workload, x86/x64 tools and ATL/MFC, and installs Windows SDK **10.0.28000.2270** with desktop C++ libraries, signing tools and x64 debugging tools. The SDK bootstrapper reports product version `10.1.28000.2270`; its SDK headers use the directory name `10.0.28000.0`. [Microsoft installation permissions](https://learn.microsoft.com/en-us/visualstudio/ide/user-permissions-and-visual-studio?view=visualstudio), [SDK releases](https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads).

Existing VS2022 product instances are not installation targets, and the script checks that their registered versions remain unchanged. Microsoft's setup can service its shared Installer and runtime prerequisites. A restart request is reported without restarting the computer. Installation receipts stay under `<ExternalRoot>\receipts`; no existing product is uninstalled and no package-cache policy is changed. [Side-by-side installation](https://learn.microsoft.com/en-us/visualstudio/install/install-visual-studio-versions-side-by-side?view=visualstudio).

After successful provisioning, set these variables only in the build session:

```powershell
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:vs2026_install = 'C:\zacro-google-prototype\toolchains\VS2026'
```

The script reserves 30 GiB on the toolchain volume and 15 GiB on the system volume before installation. These are provisioning guards, not proof that Chromium fits. Microsoft's published Build Tools range is 2.3–60 GB depending on components; Chromium documents at least 100 GB free for its source-build environment. Check actual free space after installation, checkout and generation, and retain working files if a build must stop. A shallow checkout and disabled debug symbols reduce storage; they do not establish a guaranteed final size. [Build Tools requirements](https://learn.microsoft.com/en-us/visualstudio/releases/2026/vs-system-requirements), [Chromium Windows build instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/windows_build_instructions.md).

The supported Chromium `vs2026_install` override selects a complete Visual Studio installation. It is not a portable installer or a way to avoid administrator requirements. This tool uses the signed official installers and their normal payload validation; it does not extract MSI packages into a fabricated toolchain or bypass signature checks.
