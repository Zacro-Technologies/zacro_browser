[CmdletBinding()]
param(
  [string]$ExternalRoot = 'C:\zacro-google-prototype\toolchains',
  [switch]$Download,
  [switch]$Install,
  [switch]$SdkOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Default invocation verifies cached files and prints the plan. -Download fetches
# the two pinned small bootstrappers. Only -Install runs official installers.
# Execute -Install from an Administrator PowerShell after reviewing this file.
# No elevation, uninstall, reboot, policy change or portable extraction is attempted.
# -SdkOnly keeps a qualified existing VS 18+ instance and selects only the SDK.
if ($env:OS -ne 'Windows_NT') { throw 'Provision this toolchain on native Windows only.' }
$zacroIdentity = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$zacroElevated = $zacroIdentity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Install -and -not $zacroElevated) { throw 'Administrator PowerShell is required. No installer was started.' }

function Test-ZacroContained([string]$Parent, [string]$Child) {
  return $Child.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
    $Child.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Write-ZacroJson([string]$Path, $Value, [switch]$Exclusive) {
  $zacroMode = if ($Exclusive) { [IO.FileMode]::CreateNew } else { [IO.FileMode]::Create }
  $zacroStream = [IO.File]::Open($Path, $zacroMode, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $zacroWriter = [IO.StreamWriter]::new($zacroStream, [Text.UTF8Encoding]::new($false))
  try { $zacroWriter.WriteLine(($Value | ConvertTo-Json -Depth 10)) } finally { $zacroWriter.Dispose() }
}
function Get-ZacroInstallerSpecifications($Manifest, [bool]$OnlySdk) {
  if ($Manifest.schemaVersion -ne 1 -or $Manifest.installers.Count -ne 2 -or
      @($Manifest.installers | Where-Object id -eq 'visual-studio').Count -ne 1 -or
      @($Manifest.installers | Where-Object id -eq 'windows-sdk').Count -ne 1) { throw 'Unsupported installer manifest.' }
  if ($OnlySdk) { return @($Manifest.installers | Where-Object id -eq 'windows-sdk') }
  return @($Manifest.installers)
}
function Get-ZacroVisualStudio([switch]$Qualified) {
  if (-not (Test-Path -LiteralPath $zacroVswhere)) { return @() }
  $zacroDiscoveryArguments = @('-all', '-products', '*', '-format', 'json', '-utf8')
  if ($Qualified) {
    $zacroDiscoveryArguments += @('-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.VC.ATLMFC')
  }
  $zacroDiscovery = & $zacroVswhere @zacroDiscoveryArguments
  if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery failed; no installer was started.' }
  # Windows PowerShell 5 keeps a JSON array as one pipeline item. Wrapping the
  # conversion in @() produces a nested array, even for [], and Select-Object
  # then invents one instance with null fields. Enumerate the parsed value
  # explicitly so both PowerShell editions emit zero, one or multiple instances.
  $zacroDiscoveryText = ($zacroDiscovery -join [Environment]::NewLine).Trim()
  if (-not $zacroDiscoveryText.StartsWith('[')) { throw 'Visual Studio discovery returned an invalid result; no installer was started.' }
  $zacroInstances = ConvertFrom-Json -InputObject $zacroDiscoveryText
  foreach ($zacroInstance in $zacroInstances) { $zacroInstance }
}
function Select-ZacroQualifiedCompiler($Instances) {
  # The caller supplies the result of vswhere's C++ and ATL/MFC component filter.
  $zacroCandidates = @($Instances | Where-Object {
    $zacroVersion = [Version]'0.0'
    $_.installationPath -and $_.instanceId -and
      [Version]::TryParse([string]$_.installationVersion, [ref]$zacroVersion) -and $zacroVersion.Major -ge 18 -and
      (-not ($_.PSObject.Properties.Name -contains 'isComplete') -or $_.isComplete) -and
      (-not ($_.PSObject.Properties.Name -contains 'isLaunchable') -or $_.isLaunchable)
  } | Sort-Object -Property { [Version]$_.installationVersion } -Descending)
  if ($zacroCandidates.Count -eq 0) { throw 'SdkOnly requires an existing VS 18+ instance with x64 C++ and ATL/MFC components. No installer was started.' }
  return $zacroCandidates[0]
}
function Assert-ZacroPreservedInstances($Before, $After) {
  foreach ($zacroPriorInstance in $Before) {
    $zacroCurrentInstance = @($After | Where-Object { $_.instanceId -eq $zacroPriorInstance.instanceId })
    if ($zacroCurrentInstance.Count -ne 1 -or
        $zacroCurrentInstance[0].installationVersion -ne $zacroPriorInstance.installationVersion -or
        $zacroCurrentInstance[0].installationPath -ne $zacroPriorInstance.installationPath) {
      throw 'An existing product instance changed unexpectedly. Review official installer logs before further work.'
    }
  }
}
if ($ExternalRoot -notmatch '^[A-Za-z]:\\') { throw 'ExternalRoot must be an absolute dedicated directory on a local Windows drive.' }
if ($ExternalRoot.Contains('"')) { throw 'ExternalRoot cannot contain quotation marks.' }
$zacroToolchainRoot = [IO.Path]::GetFullPath($ExternalRoot).TrimEnd('\')
$zacroRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$zacroSearchParent = $zacroRepositoryRoot
while ($zacroSearchParent) {
  $zacroPackagePath = Join-Path $zacroSearchParent 'package.json'
  if ((Test-Path -LiteralPath $zacroPackagePath) -and (Test-Path -LiteralPath (Join-Path $zacroSearchParent 'src\main\main.cjs'))) {
    $zacroPackage = Get-Content -LiteralPath $zacroPackagePath -Raw | ConvertFrom-Json
    if ($zacroPackage.name -eq 'zacro-browser') { $zacroRepositoryRoot = $zacroSearchParent; break }
  }
  $zacroSearchParent = Split-Path -Path $zacroSearchParent -Parent
}
if ($zacroToolchainRoot -eq [IO.Path]::GetPathRoot($zacroToolchainRoot).TrimEnd('\') -or
    $zacroToolchainRoot -eq [Environment]::GetFolderPath('UserProfile') -or
    (Test-ZacroContained $zacroRepositoryRoot $zacroToolchainRoot) -or
    (Test-ZacroContained $zacroToolchainRoot $zacroRepositoryRoot)) {
  throw 'Toolchain caches and installations must use a dedicated directory outside the repository.'
}
$zacroAncestor = $zacroToolchainRoot
while ($zacroAncestor) {
  if (Test-Path -LiteralPath $zacroAncestor) {
    # Hosted runners commonly use hidden ancestors such as AppData. -Force
    # includes those entries; the reparse-point check still rejects redirects.
    $zacroAncestorItem = Get-Item -LiteralPath $zacroAncestor -Force
    if ($zacroAncestorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'ExternalRoot cannot traverse a junction or symbolic link.' }
  }
  $zacroAncestor = Split-Path -Path $zacroAncestor -Parent
}
if ($zacroToolchainRoot -eq 'C:\zacro-google-prototype\toolchains') {
  $zacroDefaultParent = 'C:\zacro-google-prototype'
  $zacroParentOwnerPath = Join-Path $zacroDefaultParent '.zacro-google-prototype.json'
  if (-not (Test-Path -LiteralPath $zacroDefaultParent)) { New-Item -ItemType Directory -Path $zacroDefaultParent | Out-Null }
  if (-not (Test-Path -LiteralPath $zacroParentOwnerPath)) {
    if (@(Get-ChildItem -LiteralPath $zacroDefaultParent -Force).Count -ne 0) { throw 'Default experiment parent is nonempty and unowned.' }
    Write-ZacroJson -Path $zacroParentOwnerPath -Value ([ordered]@{schemaVersion=1;kind='zacro-google-browser-compat';root=$zacroDefaultParent}) -Exclusive
  }
  if ((Get-Item -LiteralPath $zacroParentOwnerPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Parent owner marker must be an ordinary file.' }
  $zacroParentOwner = Get-Content -LiteralPath $zacroParentOwnerPath -Raw | ConvertFrom-Json
  if ($zacroParentOwner.schemaVersion -ne 1 -or $zacroParentOwner.kind -ne 'zacro-google-browser-compat' -or $zacroParentOwner.root -ne $zacroDefaultParent) { throw 'Default parent owner marker does not match.' }
}
if (-not (Test-Path -LiteralPath $zacroToolchainRoot)) { New-Item -ItemType Directory -Path $zacroToolchainRoot | Out-Null }
$zacroOwnerPath = Join-Path $zacroToolchainRoot '.zacro-native-toolchain.json'
if (-not (Test-Path -LiteralPath $zacroOwnerPath)) {
  if (@(Get-ChildItem -LiteralPath $zacroToolchainRoot -Force).Count -ne 0) { throw 'Refusing to adopt a nonempty toolchain directory without its owner marker.' }
  Write-ZacroJson -Path $zacroOwnerPath -Value ([ordered]@{schemaVersion=1;kind='zacro-native-toolchain';root=$zacroToolchainRoot}) -Exclusive
}
if ((Get-Item -LiteralPath $zacroOwnerPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Owner marker must be an ordinary file.' }
$zacroOwner = Get-Content -LiteralPath $zacroOwnerPath -Raw | ConvertFrom-Json
if ($zacroOwner.schemaVersion -ne 1 -or $zacroOwner.kind -ne 'zacro-native-toolchain' -or $zacroOwner.root -ne $zacroToolchainRoot) { throw 'Toolchain owner marker does not match.' }
$zacroInstallerRoot = Join-Path $zacroToolchainRoot 'installers'
if (-not (Test-Path -LiteralPath $zacroInstallerRoot)) { New-Item -ItemType Directory -Path $zacroInstallerRoot | Out-Null }
if ((Get-Item -LiteralPath $zacroInstallerRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installer cache cannot be a junction or symbolic link.' }
$zacroVisualStudioPath = Join-Path $zacroToolchainRoot 'VS2026'
$zacroVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$zacroManifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-installers.lock.json') -Raw | ConvertFrom-Json
$zacroSpecifications = @(Get-ZacroInstallerSpecifications $zacroManifest ([bool]$SdkOnly))
$zacroVsSpec = $zacroManifest.installers | Where-Object id -eq 'visual-studio'
$zacroBefore = @(Get-ZacroVisualStudio)
$zacroExistingCompiler = $null
if ($SdkOnly) {
  $zacroExistingCompiler = Select-ZacroQualifiedCompiler @(Get-ZacroVisualStudio -Qualified)
  $zacroVisualStudioPath = $zacroExistingCompiler.installationPath
}
foreach ($zacroSpecification in $zacroSpecifications) {
  if ($zacroSpecification.id -eq 'visual-studio') {
    $zacroArguments = @('--quiet', '--wait', '--norestart', '--installPath', $zacroVisualStudioPath)
    foreach ($zacroComponent in $zacroSpecification.components) { $zacroArguments += @('--add', $zacroComponent) }
  } else { $zacroArguments = @('/quiet', '/norestart', '/ceip', 'off', '/features') + @($zacroSpecification.features) }
  $zacroSpecification | Add-Member -NotePropertyName Arguments -NotePropertyValue $zacroArguments
}

function Assert-ZacroInstaller($zacroSpecification, [string]$zacroInstallerPath) {
  $zacroInstallerItem = Get-Item -LiteralPath $zacroInstallerPath -Force
  if ($zacroInstallerItem.LinkType) { throw 'Installer must not be a symbolic link.' }
  if ($zacroInstallerItem.Length -ne $zacroSpecification.Bytes -or
      (Get-FileHash -LiteralPath $zacroInstallerPath -Algorithm SHA256).Hash -ne $zacroSpecification.SHA256) {
    throw "Installer integrity mismatch: $($zacroSpecification.Name)"
  }
  $zacroSignature = Get-AuthenticodeSignature -LiteralPath $zacroInstallerPath
  if ($zacroSignature.Status -ne 'Valid' -or
      $zacroSignature.SignerCertificate.Subject -notmatch '(^|, )CN=Microsoft Corporation(,|$)' -or
      $zacroInstallerItem.VersionInfo.ProductVersion -ne $zacroSpecification.ProductVersion) {
    throw "Installer publisher, trust or version check failed: $($zacroSpecification.Name)"
  }
}

foreach ($zacroSpecification in $zacroSpecifications) {
  if ($zacroSpecification.file -ne [IO.Path]::GetFileName($zacroSpecification.file) -or
      $zacroSpecification.sha256 -notmatch '^[a-f0-9]{64}$' -or $zacroSpecification.bytes -le 0 -or $zacroSpecification.bytes -gt 16MB) { throw 'Unsafe installer manifest entry.' }
  $zacroUri = [Uri]$zacroSpecification.url
  if ($zacroUri.Scheme -ne 'https' -or $zacroUri.UserInfo -or $zacroUri.Host -notin @('download.microsoft.com','download.visualstudio.microsoft.com')) { throw 'Installer must come from a pinned Microsoft HTTPS endpoint.' }
  $zacroInstallerPath = Join-Path $zacroInstallerRoot $zacroSpecification.File
  if (-not (Test-Path -LiteralPath $zacroInstallerPath)) {
    if (-not $Download) { throw 'A pinned bootstrapper is missing. Run this script with -Download first; no installer was started.' }
    $zacroPart = Join-Path $zacroInstallerRoot ([Guid]::NewGuid().ToString() + '.part.exe')
    Add-Type -AssemblyName System.Net.Http
    $zacroClient = [Net.Http.HttpClient]::new()
    $zacroClient.Timeout = [TimeSpan]::FromMinutes(2)
    $zacroDeadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(2))
    $zacroResponse = $null; $zacroInput = $null; $zacroOutput = $null
    try {
      $zacroResponse = $zacroClient.GetAsync($zacroUri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $zacroDeadline.Token).GetAwaiter().GetResult()
      $zacroResponse.EnsureSuccessStatusCode() | Out-Null
      $zacroFinalUri = $zacroResponse.RequestMessage.RequestUri
      if ($zacroFinalUri.Scheme -ne 'https' -or $zacroFinalUri.Host -notin @('download.microsoft.com','download.visualstudio.microsoft.com')) { throw 'Unexpected installer redirect.' }
      if ($zacroResponse.Content.Headers.ContentLength -and $zacroResponse.Content.Headers.ContentLength -ne $zacroSpecification.bytes) { throw 'Installer size differs from its pin.' }
      $zacroInput = $zacroResponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $zacroOutput = [IO.File]::Open($zacroPart, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      $zacroBuffer = [byte[]]::new(65536); $zacroReceived = 0L
      while (($zacroCount = $zacroInput.ReadAsync($zacroBuffer, 0, $zacroBuffer.Length, $zacroDeadline.Token).GetAwaiter().GetResult()) -gt 0) {
        $zacroReceived += $zacroCount
        if ($zacroReceived -gt $zacroSpecification.bytes) { throw 'Installer exceeded its pinned size.' }
        $zacroOutput.Write($zacroBuffer, 0, $zacroCount)
      }
      $zacroOutput.Dispose(); $zacroOutput = $null
      Assert-ZacroInstaller $zacroSpecification $zacroPart
      Move-Item -LiteralPath $zacroPart -Destination $zacroInstallerPath
    } finally {
      if ($zacroOutput) { $zacroOutput.Dispose() }; if ($zacroInput) { $zacroInput.Dispose() }
      if ($zacroResponse) { $zacroResponse.Dispose() }; $zacroClient.Dispose(); $zacroDeadline.Dispose()
      if (Test-Path -LiteralPath $zacroPart) { Remove-Item -LiteralPath $zacroPart }
    }
  }
  Assert-ZacroInstaller $zacroSpecification $zacroInstallerPath
}
$zacroPlan = [ordered]@{
  schemaVersion = 1; verifiedAt = [DateTime]::UtcNow.ToString('o'); installRequested = [bool]$Install;
  mode = $(if ($SdkOnly) { 'sdk-only' } else { 'full' });
  elevated = $zacroElevated; installPath = $zacroVisualStudioPath;
  existingCompiler = $zacroExistingCompiler;
  externalRoot = $zacroToolchainRoot;
  currentFreeGiB = [Math]::Round((Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($zacroToolchainRoot).Substring(0,1))).SizeRemaining / 1GB, 2);
  systemFreeGiB = [Math]::Round((Get-Volume -DriveLetter $env:SystemDrive.Substring(0,1)).SizeRemaining / 1GB, 2);
  existingInstances = @($zacroBefore | Select-Object instanceId, installationPath, installationVersion);
  installers = @($zacroSpecifications | ForEach-Object {
    [ordered]@{name=$_.Name; path=(Join-Path $zacroInstallerRoot $_.File); sha256=$_.SHA256; arguments=$_.Arguments}
  });
  notes = @(
    $(if ($SdkOnly) { 'Only the pinned Windows SDK is selected. The qualified existing Visual Studio instance is retained.' } else { 'A new VS2026 BuildTools instance is selected; neither existing VS2022 instance is an installation target.' }),
    'Official setup may service the shared Visual Studio Installer and shared runtime prerequisites.',
    'Package cache policy and existing software are not removed or changed by this script.',
    'SDK files use their normal Windows Kits location, with the x64 debugging tools selected.',
    'This is a preparation plan; no compiler or browser build is claimed.'
  )
}
if (-not $Install) { $zacroPlan | ConvertTo-Json -Depth 8; return }
if ($zacroPlan.currentFreeGiB -lt 30 -or $zacroPlan.systemFreeGiB -lt 15) { throw 'The provisioning reserve is below 30 GiB on the toolchain volume or 15 GiB on the system volume. No installer was started.' }

$zacroExistingTarget = @($zacroBefore | Where-Object { $_.installationPath -eq $zacroVisualStudioPath })
if (-not $SdkOnly -and (Test-Path -LiteralPath $zacroVisualStudioPath) -and
    ((Get-Item -LiteralPath $zacroVisualStudioPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw 'The dedicated VS2026 destination cannot be a junction or symbolic link.'
}
if (-not $SdkOnly -and (Test-Path -LiteralPath $zacroVisualStudioPath) -and $zacroExistingTarget.Count -eq 0) {
  throw 'The dedicated VS2026 destination already exists without a matching installed product. It was left intact.'
}
if (-not $SdkOnly -and $zacroExistingTarget.Count -gt 0 -and $zacroExistingTarget[0].installationVersion -ne $zacroVsSpec.installedVersion) {
  throw 'The dedicated destination contains a different Visual Studio version. It was left intact.'
}
$zacroReceiptDirectory = Join-Path $zacroToolchainRoot 'receipts'
if ((Test-Path -LiteralPath $zacroReceiptDirectory) -and
    ((Get-Item -LiteralPath $zacroReceiptDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw 'The receipt directory cannot be a junction or symbolic link.'
}
New-Item -ItemType Directory -Path $zacroReceiptDirectory -Force | Out-Null
$zacroReceiptPath = Join-Path $zacroReceiptDirectory ('provision-' + [Guid]::NewGuid().ToString() + '.json')
$zacroResults = @()
foreach ($zacroSpecification in $zacroSpecifications) {
  if ($zacroSpecification.File -like 'vs_*' -and $zacroExistingTarget.Count -gt 0) {
    $zacroMatchingComponents = @(Get-ZacroVisualStudio -Qualified |
      Where-Object { $_.installationPath -eq $zacroVisualStudioPath })
    if ($zacroMatchingComponents.Count -eq 0) { throw 'The dedicated VS instance lacks required components. Review it manually; no modification was attempted.' }
    continue
  }
  $zacroInstallerPath = Join-Path $zacroInstallerRoot $zacroSpecification.File
  # Start-Process joins arrays into one native command line. These fixed arguments
  # never contain quotes or end in a backslash, so quoting each preserves spaces
  # in a custom ExternalRoot without introducing shell parsing.
  $zacroLaunchArguments = @($zacroSpecification.Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $zacroProcess = Start-Process -FilePath $zacroInstallerPath -ArgumentList $zacroLaunchArguments -WindowStyle Hidden -Wait -PassThru
  $zacroResults += [ordered]@{name=$zacroSpecification.Name; exitCode=$zacroProcess.ExitCode; completedAt=[DateTime]::UtcNow.ToString('o')}
  Write-ZacroJson -Path $zacroReceiptPath -Value ([ordered]@{plan=$zacroPlan; results=$zacroResults})
  if ($zacroProcess.ExitCode -notin @(0,3010)) { throw "Official installer failed with exit code $($zacroProcess.ExitCode); see $zacroReceiptPath. No retry or bypass was attempted." }
  if ($zacroProcess.ExitCode -eq 3010) { throw "Official installer requires a restart. No restart was initiated. After a human-controlled restart, review and rerun this script; receipt: $zacroReceiptPath" }
}
$zacroAfter = @(Get-ZacroVisualStudio)
Assert-ZacroPreservedInstances $zacroBefore $zacroAfter
if ($SdkOnly) {
  $zacroStillQualified = @(Get-ZacroVisualStudio -Qualified | Where-Object { $_.instanceId -eq $zacroExistingCompiler.instanceId })
  if ($zacroStillQualified.Count -ne 1) { throw 'The existing compiler component qualification changed unexpectedly.' }
  Select-ZacroQualifiedCompiler $zacroStillQualified | Out-Null
} else {
  $zacroInstalled = @($zacroAfter | Where-Object { $_.installationPath -eq $zacroVisualStudioPath -and $_.installationVersion -eq $zacroVsSpec.installedVersion })
  if ($zacroInstalled.Count -ne 1) { throw 'Expected pinned Build Tools installation was not verified.' }
}
$zacroKit = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
foreach ($zacroRequired in @('Include\10.0.28000.0\um\Windows.h','Lib\10.0.28000.0\um\x64\kernel32.lib','Debuggers\x64\dbghelp.dll')) {
  if (-not (Test-Path -LiteralPath (Join-Path $zacroKit $zacroRequired))) { throw "Required SDK file missing: $zacroRequired" }
}
$zacroDebuggerVersion = (Get-Item -LiteralPath (Join-Path $zacroKit 'Debuggers\x64\dbghelp.dll') -Force).VersionInfo.FileVersionRaw
if ($zacroDebuggerVersion -lt [Version]'10.0.26100.3323') { throw 'Installed x64 debugging tools are below the source requirement.' }
Write-Output "Prerequisites verified. Task-local build environment: DEPOT_TOOLS_WIN_TOOLCHAIN=0; vs2026_install=$zacroVisualStudioPath"
