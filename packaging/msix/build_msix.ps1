# Assembles the MSIX layout and packs it with makeappx.
# Generates plate-free logos (unplated/lightunplated) and a resources.pri (makepri)
# so Windows honours them.
# Run the build tasks first: engine (PyInstaller), Flutter Windows, TUI.
#
# Store submission: use the Product identity values from Partner Center
# (-IdentityName, -Publisher, -PublisherDisplayName). Microsoft signs the package
# on ingestion, so no certificate is needed for the Store upload.
# Local install: pass -CertPath/-CertPassword to sign with a trusted test cert.
param(
  # Defaults are the Partner Center Product identity values (Store build).
  [string] $IdentityName = 'Ancilla.Subconscious',
  [string] $Publisher = 'CN=2282687B-F481-4041-BC27-2F0BAA048427',
  [string] $PublisherDisplayName = 'Ancilla',
  [string] $Version = '0.1.0.0',
  [string] $Python = 'python',
  [string] $CertPath,
  [string] $CertPassword
)
$ErrorActionPreference = 'Stop'
$Engine = 'pyinstaller'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$build = Join-Path $root 'build\packaging'
$layout = Join-Path $build 'msix-layout'

$engineDir = Join-Path $build "$Engine\engine"
$guiDir = Join-Path $root 'apps\unified_app\build\windows\x64\runner\Release'
$tuiExe = Join-Path $build 'tui\subconscious-tui.exe'

# PyInstaller makes two exes: the tray app and the CLI.
$desktopExe = 'subconscious-desktop.exe'
$cliExe = 'subconscious.exe'

foreach ($required in @($engineDir, $guiDir, $tuiExe, (Join-Path $engineDir $cliExe), (Join-Path $engineDir $desktopExe))) {
  if (-not (Test-Path $required)) { throw "Missing build output: $required" }
}

function Find-SdkTool([string] $name) {
  $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $tool = Get-ChildItem $kits -Recurse -Filter $name -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\bin\\10\.0\.\d+\.\d+\\x64\\' } |
    Sort-Object { [version]($_.FullName -replace '.*\\bin\\(10\.0\.\d+\.\d+)\\.*', '$1') } -Descending |
    Select-Object -First 1
  if (-not $tool) { throw "$name not found. Install the Windows 10/11 SDK." }
  $tool.FullName
}

if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
New-Item -ItemType Directory -Force $layout | Out-Null
Copy-Item -Recurse $guiDir (Join-Path $layout 'gui')
Copy-Item -Recurse $engineDir (Join-Path $layout 'engine')
New-Item -ItemType Directory -Force (Join-Path $layout 'tui') | Out-Null
Copy-Item $tuiExe (Join-Path $layout 'tui\tui.exe')

# Package-internal exe names are decoupled from the build outputs
# (Flutter's BINARY_NAME stays unified_app so `flutter run` keeps working).
Rename-Item (Join-Path $layout 'gui\unified_app.exe') 'gui.exe'

# MSIX reserves OPC part names such as [Content_Types].xml and _rels\*.rels and
# rejects payload files that look like them. python-docx ships an unused,
# unzipped template source folder containing those; the runtime uses
# templates\default.docx instead.
Get-ChildItem $layout -Recurse -Directory -Force -Filter 'default-docx-template' |
  ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }

& $Python (Join-Path $PSScriptRoot 'make_logos.py') `
  (Join-Path $root 'engine\src\subconscious_engine\app_icon.ico') (Join-Path $layout 'Assets')
if ($LASTEXITCODE -ne 0) { throw 'Logo generation failed' }
foreach ($asset in @(
    'Square44x44Logo.targetsize-16_altform-unplated.png',
    'Square44x44Logo.targetsize-256_altform-unplated.png',
    'Square44x44Logo.targetsize-256_altform-lightunplated.png')) {
  if (-not (Test-Path (Join-Path $layout "Assets\$asset"))) { throw "Missing generated asset: $asset" }
}

$manifest = Get-Content (Join-Path $PSScriptRoot 'AppxManifest.xml.template') -Raw
$manifest = $manifest.
  Replace('{{IDENTITY_NAME}}', $IdentityName).
  Replace('{{PUBLISHER}}', $Publisher).
  Replace('{{PUBLISHER_DISPLAY}}', $PublisherDisplayName).
  Replace('{{VERSION}}', $Version).
  Replace('{{ENGINE_TRAY_EXE}}', $desktopExe).
  Replace('{{ENGINE_CLI_EXE}}', $cliExe)
Set-Content -Path (Join-Path $layout 'AppxManifest.xml') -Value $manifest -Encoding UTF8

# resources.pri lets Windows resolve the qualified (targetsize/unplated) logos.
# Index only Assets and the manifest, never gui\ or engine\.
$priWork = Join-Path $build 'pri-work'
if (Test-Path $priWork) { Remove-Item -Recurse -Force $priWork }
New-Item -ItemType Directory -Force $priWork | Out-Null
Copy-Item -Recurse (Join-Path $layout 'Assets') (Join-Path $priWork 'Assets')
Copy-Item (Join-Path $layout 'AppxManifest.xml') $priWork
$makepri = Find-SdkTool 'makepri.exe'
& $makepri createconfig /cf (Join-Path $priWork 'priconfig.xml') /dq lang-en-US /pv 10.0.0 /o
if ($LASTEXITCODE -ne 0) { throw "makepri createconfig failed with exit code $LASTEXITCODE" }
& $makepri new /pr $priWork /cf (Join-Path $priWork 'priconfig.xml') /mn (Join-Path $priWork 'AppxManifest.xml') /of (Join-Path $layout 'resources.pri') /o
if ($LASTEXITCODE -ne 0) { throw "makepri new failed with exit code $LASTEXITCODE" }
Remove-Item -Recurse -Force $priWork

$package = Join-Path $build "Subconscious-$Version.msix"
& (Find-SdkTool 'makeappx.exe') pack /d $layout /p $package /o
if ($LASTEXITCODE -ne 0) { throw "makeappx failed with exit code $LASTEXITCODE" }

if ($CertPath) {
  & (Find-SdkTool 'signtool.exe') sign /fd SHA256 /f $CertPath /p $CertPassword $package
  if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE" }
}
Write-Host "MSIX: $package"
