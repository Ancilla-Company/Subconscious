# Assembles the MSIX layout and packs it with makeappx.
# Run the build tasks first: engine (PyInstaller or Nuitka), Flutter Windows, TUI.
#
# Store submission: use the Product identity values from Partner Center
# (-IdentityName, -Publisher, -PublisherDisplayName). Microsoft signs the package
# on ingestion, so no certificate is needed for the Store upload.
# Local install: pass -CertPath/-CertPassword to sign with a trusted test cert.
param(
  [ValidateSet('pyinstaller', 'nuitka')] [string] $Engine = 'pyinstaller',
  [string] $IdentityName = 'Subconscious.Placeholder',
  [string] $Publisher = 'CN=Placeholder',
  [string] $PublisherDisplayName = 'Subconscious',
  [string] $Version = '0.1.0.0',
  [string] $CertPath,
  [string] $CertPassword
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$build = Join-Path $root 'build\packaging'
$layout = Join-Path $build 'msix-layout'

$engineDir = Join-Path $build "$Engine\engine"
$guiDir = Join-Path $root 'apps\unified_app\build\windows\x64\runner\Release'
$tuiExe = Join-Path $build 'tui\subconscious-tui.exe'

# PyInstaller makes two exes; Nuitka makes one that serves both roles.
if ($Engine -eq 'pyinstaller') { $trayExe = 'subconscious-tray.exe' } else { $trayExe = 'subconscious.exe' }
$cliExe = 'subconscious.exe'

foreach ($required in @($engineDir, $guiDir, $tuiExe, (Join-Path $engineDir $cliExe), (Join-Path $engineDir $trayExe))) {
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
Copy-Item $tuiExe (Join-Path $layout 'tui')

# MSIX reserves OPC part names such as [Content_Types].xml and _rels\*.rels and
# rejects payload files that look like them. python-docx ships an unused,
# unzipped template source folder containing those; the runtime uses
# templates\default.docx instead.
Get-ChildItem $layout -Recurse -Directory -Force -Filter 'default-docx-template' |
  ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }

python (Join-Path $PSScriptRoot 'make_logos.py') `
  (Join-Path $root 'engine\src\subconscious_engine\app_icon.ico') (Join-Path $layout 'Assets')
if ($LASTEXITCODE -ne 0) { throw 'Logo generation failed' }

$manifest = Get-Content (Join-Path $PSScriptRoot 'AppxManifest.xml.template') -Raw
$manifest = $manifest.
  Replace('{{IDENTITY_NAME}}', $IdentityName).
  Replace('{{PUBLISHER}}', $Publisher).
  Replace('{{PUBLISHER_DISPLAY}}', $PublisherDisplayName).
  Replace('{{VERSION}}', $Version).
  Replace('{{ENGINE_TRAY_EXE}}', $trayExe).
  Replace('{{ENGINE_CLI_EXE}}', $cliExe)
Set-Content -Path (Join-Path $layout 'AppxManifest.xml') -Value $manifest -Encoding UTF8

$package = Join-Path $build "Subconscious-$Engine-$Version.msix"
& (Find-SdkTool 'makeappx.exe') pack /d $layout /p $package /o
if ($LASTEXITCODE -ne 0) { throw "makeappx failed with exit code $LASTEXITCODE" }

if ($CertPath) {
  & (Find-SdkTool 'signtool.exe') sign /fd SHA256 /f $CertPath /p $CertPassword $package
  if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE" }
}
Write-Host "MSIX: $package"
