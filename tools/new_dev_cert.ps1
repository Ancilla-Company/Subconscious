# Creates (if missing) a self-signed code-signing cert for LOCAL MSIX installs and
# trusts it on this machine. Never use for Store builds: Microsoft signs those.
#
# Outputs (under build/, which is gitignored):
#   build/packaging/dev-cert/dev.pfx   signing key, used by build_msix.ps1 -CertPath
#   build/packaging/dev-cert/dev.cer   public cert, trusted in LocalMachine\TrustedPeople
#
# The cert Subject MUST equal the manifest Publisher (build_msix.ps1 -Publisher,
# default 'CN=Placeholder'), otherwise Add-AppxPackage rejects the signature.
# Trusting needs admin; the script relaunches just that step elevated (UAC prompt).
param(
  [string] $Subject = 'CN=Placeholder',
  [string] $Password = 'subconscious-dev',
  [switch] $Force,
  [switch] $TrustOnly
)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$dir = Join-Path $root 'build\packaging\dev-cert'
$pfx = Join-Path $dir 'dev.pfx'
$cer = Join-Path $dir 'dev.cer'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-Trust {
  $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cer
  $store = 'Cert:\LocalMachine\TrustedPeople'
  if (Get-ChildItem $store | Where-Object Thumbprint -eq $c.Thumbprint) {
    Write-Host "Already trusted: $($c.Thumbprint)"
    return
  }
  Import-Certificate -FilePath $cer -CertStoreLocation $store | Out-Null
  Write-Host "Trusted $($c.Subject) ($($c.Thumbprint)) in LocalMachine\TrustedPeople"
}

if ($TrustOnly) { Install-Trust; return }

New-Item -ItemType Directory -Force $dir | Out-Null

# Reuse the existing cert unless it is missing, forced, or its subject changed.
$reuse = $false
if (-not $Force -and (Test-Path $pfx) -and (Test-Path $cer)) {
  $existing = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cer
  $reuse = ($existing.Subject -eq $Subject)
  if (-not $reuse) { Write-Host "Subject changed ($($existing.Subject) -> $Subject); regenerating." }
}

if (-not $reuse) {
  $cert = New-SelfSignedCertificate -Type Custom -Subject $Subject `
    -KeyUsage DigitalSignature -FriendlyName 'Subconscious Dev' `
    -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(3) `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
  $secure = ConvertTo-SecureString -String $Password -Force -AsPlainText
  Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
  Export-Certificate -Cert $cert -FilePath $cer | Out-Null
  # Keep the user's store clean; the pfx is the source of truth.
  Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)"
  Write-Host "Created $pfx"
} else {
  Write-Host "Reusing $pfx"
}

if (Test-Admin) {
  Install-Trust
} else {
  Write-Host 'Elevating to trust the certificate (UAC prompt)...'
  $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$PSCommandPath`"", '-TrustOnly', '-Subject', "`"$Subject`"")
  if ($p.ExitCode -ne 0) { throw "Trusting the certificate failed (exit $($p.ExitCode))." }
  $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cer
  if (-not (Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq $c.Thumbprint)) {
    throw 'Certificate is not trusted (UAC declined?).'
  }
  Write-Host 'Certificate trusted.'
}
