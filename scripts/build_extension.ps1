<#
.SYNOPSIS
  Builds apps/unified_app for the web and embeds it in apps/chromium_extension/app/.

.PARAMETER ServerUrl
  Subconscious server URL baked into the build (default https://api.subconscious.chat).
.PARAMETER Dev
  Dev build: engine dev mode on port 51515, server http://127.0.0.1:5050/ (mirrors the 'GUI (Web)' launch config).
.PARAMETER SkipBuild
  Reuse apps/unified_app/build/web (only copy, generate pages and verify).
#>
param(
  [string]$ServerUrl = 'https://api.subconscious.chat',
  [switch]$Dev,
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'apps/unified_app'
$ext = Join-Path $root 'apps/chromium_extension'
$out = Join-Path $ext 'app'
$webOut = Join-Path $appDir 'build/web'

$defines = @('--dart-define=SUBCONSCIOUS_EXTENSION=true')
if ($Dev) {
  $defines += '--dart-define=SUBCONSCIOUS_ENGINE_DEV=true'
  $defines += '--dart-define=SUBCONSCIOUS_ENGINE_PORT=51515'
  $defines += '--dart-define=SUBCONSCIOUS_SERVER_URL=http://127.0.0.1:5050/'
} else {
  $defines += "--dart-define=SUBCONSCIOUS_SERVER_URL=$ServerUrl"
}

if (-not $SkipBuild) {
  # --csp: dart2js output without dynamic code generation (MV3 forbids 'unsafe-eval').
  # Default CanvasKit renderer (skwasm needs cross-origin isolation headers an extension cannot send).
  $flutterArgs = @('build', 'web', '--release', '--no-web-resources-cdn', '--csp', '--no-source-maps', '--base-href', '/') + $defines
  Write-Host "flutter $($flutterArgs -join ' ')"
  Push-Location $appDir
  try { & flutter @flutterArgs; if ($LASTEXITCODE -ne 0) { throw "flutter build web failed ($LASTEXITCODE)" } }
  finally { Pop-Location }
}
if (-not (Test-Path (Join-Path $webOut 'index.html'))) { throw "Missing $webOut/index.html" }

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item -Recurse -Force (Join-Path $webOut '*') $out

# index.html of the build is only used for the <base> sanity check; pages are generated below.
# Remove the web manifest / service worker leftovers: extension pages don't use them.
foreach ($f in @('manifest.json', 'flutter_service_worker.js', 'version.json')) {
  $p = Join-Path $out $f
  if (Test-Path $p) { Remove-Item -Force $p }
}
$bootstrapPath = Join-Path $out 'flutter_bootstrap.js'
if (-not (Test-Path $bootstrapPath)) { throw 'flutter_bootstrap.js missing from the build' }

# No service worker in an extension: drop the registration settings from the generated bootstrap.
$bs = Get-Content -Raw $bootstrapPath
$bs2 = [regex]::Replace($bs, '_flutter\.loader\.load\(\{\s*serviceWorkerSettings:\s*\{.*?\}\s*\}\);', '_flutter.loader.load();', 'Singleline')
if ($bs2 -eq $bs) { Write-Warning 'Could not strip serviceWorkerSettings from flutter_bootstrap.js' }
Set-Content -NoNewline -Encoding utf8 $bootstrapPath $bs2

# Only the CanvasKit renderer is used (skwasm needs cross-origin isolation); drop the other engine variants and symbol maps.
foreach ($pat in 'skwasm*', 'wimp*', '*.symbols') {
  Get-ChildItem -Recurse -File (Join-Path $out 'canvaskit') -Filter $pat | Remove-Item -Force
}

function New-Page([string]$mode) {
  $bodyClass = $mode
  $modeScript = if ($mode -eq 'popup') { 'mode-popup.js' } else { 'mode-panel.js' }
@"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Subconscious</title>
  <base href="app/">
  <link rel="stylesheet" href="/host.css">
  <script src="/host.js"></script>
  <script src="/$modeScript"></script>
</head>
<body class="$bodyClass">
  <script src="/boot.js"></script>
</body>
</html>
"@
}
# GENERATED pages: <base href="app/"> makes Flutter resolve assets under app/; host scripts use root-absolute paths.
Set-Content -Encoding utf8 (Join-Path $ext 'popup.html') (New-Page 'popup')
Set-Content -Encoding utf8 (Join-Path $ext 'sidepanel.html') (New-Page 'panel')

# ---- verification ----
$problems = @()
foreach ($p in 'popup.html', 'sidepanel.html') {
  $h = Get-Content -Raw (Join-Path $ext $p)
  if ($h -match '<script(?![^>]*\bsrc=)[^>]*>') { $problems += "$p has an inline <script>" }
}
$remote = @{}
$textFiles = Get-ChildItem -Recurse -File $out | Where-Object { $_.Extension -in '.js', '.html', '.css', '.json', '.mjs' }
foreach ($f in $textFiles) {
  $c = Get-Content -Raw $f.FullName
  foreach ($m in [regex]::Matches($c, 'https?://[A-Za-z0-9._~:/?#\[\]@!$&''()*+,;=%-]+')) {
    $u = $m.Value
    if ($u -match 'gstatic\.com|googleapis\.com|fonts\.|cdn\.|unpkg\.com|jsdelivr') {
      $key = "$($f.Name): $u"
      $remote[$key] = 1
    }
  }
}
if ($remote.Count) {
  Write-Host 'Remote font/CDN URLs found in the build (verify they are not fetched at runtime):'
  $remote.Keys | Sort-Object | ForEach-Object { Write-Host "  $_" }
}
$evalHits = @()
foreach ($f in Get-ChildItem -Recurse -File $out -Filter *.js) {
  $c = Get-Content -Raw $f.FullName
  $n1 = ([regex]::Matches($c, '\beval\(')).Count
  $n2 = ([regex]::Matches($c, 'new Function\(')).Count
  if ($n1 + $n2 -gt 0) { $evalHits += "$($f.Name): eval( x$n1, new Function( x$n2" }
}
if ($evalHits.Count) { Write-Host 'Dynamic-code hits (check against CSP):'; $evalHits | ForEach-Object { Write-Host "  $_" } }

$size = (Get-ChildItem -Recurse -File $out | Measure-Object Length -Sum).Sum
Write-Host ("app/ size: {0:N1} MB" -f ($size / 1MB))
if ($problems.Count) { $problems | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Host 'Extension build OK. Load apps/chromium_extension as an unpacked extension.'
