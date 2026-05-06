<#
.SYNOPSIS
  Authenticode-signs UpdateChecker.ps1 with a code-signing certificate.

.DESCRIPTION
  Once you have a code-signing certificate (from SignPath.io, DigiCert, SSL.com,
  etc.), use this script to sign the PowerShell file so Windows trusts it under
  any execution policy. Signing also removes the SmartScreen prompt for the
  installer once the installer .exe itself is signed.

  The script picks a certificate by:
    1. -CertificateThumbprint, if provided.
    2. -CertSubject substring match against the Subject of code-signing certs.
    3. The first available code-signing cert in CurrentUser\My.

.PARAMETER ScriptPath
  File to sign. Defaults to ..\UpdateChecker.ps1 relative to this helper.

.PARAMETER CertificateThumbprint
  Exact thumbprint of the cert to use.

.PARAMETER CertSubject
  Substring of the Subject (e.g. 'My Name' or 'O=My Org').

.PARAMETER TimestampUrl
  RFC3161 timestamp server. The default works for most public CAs.

.EXAMPLE
  .\tools\Sign-Script.ps1
  Signs with the first available code-signing cert.

.EXAMPLE
  .\tools\Sign-Script.ps1 -CertificateThumbprint ABCDEF1234...
#>

[CmdletBinding()]
param(
    [string]$ScriptPath          = (Join-Path $PSScriptRoot '..\UpdateChecker.ps1'),
    [string]$CertificateThumbprint,
    [string]$CertSubject,
    [string]$TimestampUrl        = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) {
    throw "Script not found: $ScriptPath"
}
$ScriptPath = (Resolve-Path $ScriptPath).Path

$cert = $null
if ($CertificateThumbprint) {
    $cert = Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object Thumbprint -eq $CertificateThumbprint | Select-Object -First 1
} elseif ($CertSubject) {
    $cert = Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like "*$CertSubject*" } | Select-Object -First 1
} else {
    $cert = Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

if (-not $cert) {
    Write-Host ''
    Write-Host 'No code-signing certificate found.' -ForegroundColor Yellow
    Write-Host 'Options:'
    Write-Host '  1. Apply for free OSS signing at https://signpath.io/ (recommended for public projects)'
    Write-Host '  2. Buy a cert from DigiCert/SSL.com/Sectigo (~$200/year)'
    Write-Host '  3. Generate a self-signed cert for local testing only:'
    Write-Host '     New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=WinUpdateChecker-Dev" -CertStoreLocation Cert:\CurrentUser\My' -ForegroundColor Gray
    throw 'No suitable certificate available.'
}

Write-Host "Signing with certificate:" -ForegroundColor Cyan
Write-Host "  Subject:    $($cert.Subject)"
Write-Host "  Thumbprint: $($cert.Thumbprint)"
Write-Host "  Expires:    $($cert.NotAfter)"
Write-Host "Target file:  $ScriptPath"
Write-Host ''

$result = Set-AuthenticodeSignature -FilePath $ScriptPath -Certificate $cert `
    -TimestampServer $TimestampUrl -HashAlgorithm SHA256

switch ($result.Status) {
    'Valid'       { Write-Host 'Signature: Valid' -ForegroundColor Green }
    'NotSigned'   { Write-Warning 'File reports NotSigned. Check the cert is a code-signing cert.' }
    default       { Write-Warning "Signature status: $($result.Status). Message: $($result.StatusMessage)" }
}
