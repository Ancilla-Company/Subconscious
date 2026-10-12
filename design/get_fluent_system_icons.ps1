[CmdletBinding()]
param(
  [string[]]$Icons = @(
    'apps_24_regular', 'apps_24_filled', 'chat_24_regular', 'chat_24_filled',
    'document_copy_24_regular', 'document_copy_24_filled',
    'settings_24_regular', 'settings_24_filled',
    'person_24_regular', 'person_24_filled', 'add_20_regular'
  ),
  [string]$Ref,
  [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = 'microsoft/fluentui-system-icons'
$assetsDir = Join-Path $PSScriptRoot 'assets\fluent'
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
if (-not $Ref) {
  $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/main" -Headers @{ 'User-Agent' = 'Subconscious-design-assets' }
  $Ref = $commit.sha
}
if ($Ref -notmatch '^[0-9a-f]{40}$') { throw 'Ref must be a 40-character Fluent UI System Icons commit SHA.' }
$items = foreach ($icon in $Icons) {
  if ($icon -notmatch '^(?<name>[a-z0-9_]+)_(?<size>\d+)_(?<style>regular|filled)$') { throw "Invalid Fluent icon name: $icon" }
  $name = $Matches.name; $size = $Matches.size; $style = $Matches.style
  $folder = (($name -split '_') | ForEach-Object { (Get-Culture).TextInfo.ToTitleCase($_) }) -join ' '
  $file = "ic_fluent_${name}_${size}_${style}.svg"
  $destination = Join-Path $assetsDir $file
  $url = "https://raw.githubusercontent.com/$repo/$Ref/assets/$([uri]::EscapeDataString($folder))/SVG/$file"
  if ($Force -or -not (Test-Path -LiteralPath $destination)) {
    $temp = "$destination.download"
    Invoke-WebRequest -Uri $url -OutFile $temp -Headers @{ 'User-Agent' = 'Subconscious-design-assets' }
    if ((Get-Content -LiteralPath $temp -Raw) -notmatch '<svg[\s>]') { Remove-Item $temp -Force; throw "Downloaded content is not SVG: $url" }
    Move-Item -LiteralPath $temp -Destination $destination -Force
  }
  [pscustomobject]@{ icon = $icon; file = $file; source = $url; sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash }
}
[pscustomobject]@{ repository = "https://github.com/$repo"; commit = $Ref; generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); assets = @($items) } |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $assetsDir 'manifest.json') -Encoding utf8
Write-Host "Downloaded $(@($items).Count) Fluent SVG assets to $assetsDir (commit $Ref)."
