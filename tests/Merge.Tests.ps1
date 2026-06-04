<#
  Plain-assertion tests for the program/upgrade matching logic.
  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Merge.Tests.ps1

  No Pester dependency. Exits non-zero if any assertion fails.
#>

. "$PSScriptRoot\..\UpdateChecker.ps1"   # dot-source; main block is guarded out

$script:Failures = 0
function Assert-That {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "  PASS  $Message" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $Message" -ForegroundColor Red
        $script:Failures++
    }
}

# --- Sample data drawn from a real machine ----------------------------------
# Multiple VC++ editions + a stale 14.30 leftover + a separate 2013 (v12) product,
# plus winget upgrade rows whose names are truncated with an ellipsis (as winget
# actually prints them).

$programs = @(
    [pscustomobject]@{ Name = 'Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.40664';      Version = '12.0.40664.0'; Publisher = 'Microsoft Corporation' }
    [pscustomobject]@{ Name = 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.30.30708'; Version = '14.30.30708.0'; Publisher = 'Microsoft Corporation' }
    [pscustomobject]@{ Name = 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.44.35211'; Version = '14.44.35211.0'; Publisher = 'Microsoft Corporation' }
    [pscustomobject]@{ Name = 'Microsoft Visual C++ v14 Redistributable (x86) - 14.50.35719';       Version = '14.50.35719.0'; Publisher = 'Microsoft Corporation' }
    [pscustomobject]@{ Name = 'Microsoft Windows Desktop Runtime - 8.0.8 (x64)';                    Version = '8.0.8.33916';  Publisher = 'Microsoft Corporation' }
    [pscustomobject]@{ Name = 'Google Chrome';                                                      Version = '120.0.0.0';    Publisher = 'Google LLC' }
)

$upgrades = @(
    [pscustomobject]@{ Name = 'Microsoft Visual C++ 2015-2022 Redistributable (…'; Id = 'Microsoft.VCRedist.2015+.x64';       Current = '14.44.35211.0'; Available = '14.51.36231.0'; PackageSource = 'winget' }
    [pscustomobject]@{ Name = 'Microsoft Visual C++ v14 Redistributable (x86) -…';  Id = 'Microsoft.VCRedist.2015+.x86';       Current = '14.50.35719.0'; Available = '14.51.36231.0'; PackageSource = 'winget' }
    [pscustomobject]@{ Name = 'Microsoft Windows Desktop Runtime - 8.0.8 (x64)';    Id = 'Microsoft.DotNet.DesktopRuntime.8';  Current = '8.0.8';         Available = '8.0.27';        PackageSource = 'winget' }
)

$rows = @(Merge-ProgramsAndUpgrades -Programs $programs -Upgrades $upgrades -EnabledSources @('winget'))

$updates = @($rows | Where-Object { $_.Status -like 'Update available*' })

Write-Host "`nMatching logic" -ForegroundColor Cyan

# Bug 1 — the 2013 (v12) product must NOT be flagged as an update to the 2015+ package.
$row2013 = $rows | Where-Object { $_.Name -like '*2013*' } | Select-Object -First 1
Assert-That ($row2013.Status -notlike 'Update available*') 'VC++ 2013 (v12) is not a phantom update'

# Bug 1 — the stale 14.30 leftover collapses into a single x64 update row.
$x64 = @($updates | Where-Object { $_.PackageId -eq 'Microsoft.VCRedist.2015+.x64' })
Assert-That ($x64.Count -eq 1) 'Exactly one updatable row for VCRedist x64 (14.30 leftover collapsed)'
Assert-That ($x64.Count -eq 1 -and $x64[0].Current -eq '14.44.35211.0') 'Kept the highest installed VCRedist x64 version (14.44)'

# Genuine updates still match correctly.
Assert-That (@($updates | Where-Object { $_.PackageId -eq 'Microsoft.VCRedist.2015+.x86' }).Count -eq 1) 'VCRedist x86 still matches as an update'
Assert-That (@($updates | Where-Object { $_.PackageId -eq 'Microsoft.DotNet.DesktopRuntime.8' }).Count -eq 1) '.NET Desktop Runtime 8 still matches as an update'

# Total updatable rows == what winget itself would report (3), not 5.
Assert-That ($updates.Count -eq 3) "Reports 3 real updates, not phantoms (got $($updates.Count))"

# Unrelated software is untouched.
$chrome = $rows | Where-Object { $_.Name -eq 'Google Chrome' } | Select-Object -First 1
Assert-That ($chrome.Status -notlike 'Update available*') 'Unrelated program (Chrome) not falsely matched'

Write-Host "`nVersion comparison" -ForegroundColor Cyan
Assert-That ((Test-IsNewerVersion -Current '14.44.35211.0' -Available '14.51.36231.0')) '14.44 < 14.51 is an update'
Assert-That (-not (Test-IsNewerVersion -Current '14.51.36231.0' -Available '14.51.36231.0')) 'equal versions are not an update'
Assert-That (-not (Test-IsNewerVersion -Current '14.52.0.0' -Available '14.51.36231.0')) 'installed-newer is not an update'

Write-Host "`nName normalization" -ForegroundColor Cyan
Assert-That ((Get-MatchBase 'Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.40664') -eq 'microsoft visual c++ 2013 redistributable (x64)') '2013 edition token preserved'
Assert-That ((Get-MatchBase 'Microsoft Visual C++ 2015-2022 Redistributable (…') -eq 'microsoft visual c++ 2015-2022 redistributable') 'winget ellipsis truncation stripped'
Assert-That (-not (Test-BasePrefixMatch 'microsoft edge' 'microsoft edgewebview2 runtime')) 'Edge vs EdgeWebView2 do not prefix-match'

Write-Host "`nExit-code messages" -ForegroundColor Cyan
Assert-That ((Get-UpgradeExitMessage -Source 'winget' -ExitCode 0) -eq 'Succeeded.') 'exit 0 reads as success'
Assert-That ((Get-UpgradeExitMessage -Source 'winget' -ExitCode -1978335189) -like 'No applicable upgrade*') 'UPDATE_NOT_APPLICABLE is explained'

Write-Host ""
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All tests passed." -ForegroundColor Green
exit 0
