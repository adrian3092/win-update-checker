<#
.SYNOPSIS
  WinUpdateChecker — scans installed Windows programs and reports available
  updates from winget, Scoop, and Chocolatey.

.DESCRIPTION
  Reads installed programs from the Windows registry (HKLM and HKCU Uninstall
  keys), queries each available package manager for upgrades, matches them
  against installed entries, and presents a sortable GUI. Selected items can
  be upgraded with one click. Reports can be exported to CSV or a stand-alone
  HTML file.

.PARAMETER NoGui
  Run in console mode and print the update list without opening a window.

.PARAMETER IncludeSystemComponents
  Include Windows components, hotfixes, and child uninstall entries that are
  hidden by default.

.PARAMETER ExportCsv
  Path to a .csv file. The merged report is written there and the program
  exits without showing the GUI.

.PARAMETER ExportHtml
  Path to a .html file. A stand-alone styled report is written there and the
  program exits without showing the GUI.

.PARAMETER Source
  Restrict the package managers that are queried. Default: all detected.
  Allowed values: winget, scoop, chocolatey.

.EXAMPLE
  .\UpdateChecker.ps1
  Launches the GUI.

.EXAMPLE
  .\UpdateChecker.ps1 -NoGui
  Prints a console table of available updates.

.EXAMPLE
  .\UpdateChecker.ps1 -ExportHtml report.html
  Writes a stand-alone HTML report and exits.

.LINK
  https://github.com/adrian3092/win-update-checker
#>

[CmdletBinding()]
param(
    [switch]$NoGui,
    [switch]$IncludeSystemComponents,
    [string]$ExportCsv,
    [string]$ExportHtml,
    [ValidateSet('winget','scoop','chocolatey')]
    [string[]]$Source
)

# --- Constants --------------------------------------------------------------

$script:ProductName = 'WinUpdateChecker'
$script:Version     = '1.0.3'
$script:RepoUrl     = 'https://github.com/adrian3092/win-update-checker'

# --- Tool detection ---------------------------------------------------------

$script:Tools = @{ winget = $null; scoop = $null; chocolatey = $null }

function Test-Tool {
    param([Parameter(Mandatory)][string]$Name)
    if ($null -ne $script:Tools[$Name]) { return $script:Tools[$Name] }
    $exe = switch ($Name) {
        'winget'     { 'winget' }
        'scoop'      { 'scoop' }
        'chocolatey' { 'choco' }
    }
    try {
        $null = Get-Command $exe -ErrorAction Stop
        $script:Tools[$Name] = $true
    } catch {
        $script:Tools[$Name] = $false
    }
    return $script:Tools[$Name]
}

function Get-EnabledSources {
    $candidates = if ($Source) { $Source } else { @('winget','scoop','chocolatey') }
    return $candidates | Where-Object { Test-Tool $_ }
}

# --- Registry scan ----------------------------------------------------------

function Get-InstalledPrograms {
    [CmdletBinding()]
    param([switch]$IncludeSystemComponents)

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $programs = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($path in $uninstallPaths) {
        try {
            $entries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        } catch { continue }

        foreach ($entry in $entries) {
            $name = $entry.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            if (-not $IncludeSystemComponents) {
                if ($entry.SystemComponent -eq 1) { continue }
                if ($entry.ParentKeyName) { continue }
                if ($entry.ReleaseType -in @('Update','Hotfix','Security Update')) { continue }
                if ($name -match '^(KB\d+|Update for|Security Update|Hotfix)') { continue }
            }

            $version = $entry.DisplayVersion
            if ([string]::IsNullOrWhiteSpace($version)) { $version = '' }

            $key = "$name|$version".ToLowerInvariant()
            if (-not $seen.Add($key)) { continue }

            $programs.Add([pscustomobject]@{
                Name            = $name.Trim()
                Version         = $version.Trim()
                Publisher       = ($entry.Publisher -as [string])
                InstallDate     = ($entry.InstallDate -as [string])
                UninstallString = ($entry.UninstallString -as [string])
            })
        }
    }

    return $programs | Sort-Object Name
}

# --- Source: winget ---------------------------------------------------------

function Get-WingetUpgrades {
    if (-not (Test-Tool 'winget')) { return @() }
    try {
        $raw = & winget upgrade --include-unknown --accept-source-agreements 2>$null | Out-String
    } catch { return @() }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $lines = $raw -split "`r?`n"
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Name\s+Id\s+Version\s+Available') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0) { return @() }

    $headerLine = $lines[$headerIndex]
    $idCol        = $headerLine.IndexOf('Id')
    $versionCol   = $headerLine.IndexOf('Version')
    $availableCol = $headerLine.IndexOf('Available')
    $sourceCol    = $headerLine.IndexOf('Source')

    $upgrades = New-Object System.Collections.Generic.List[object]
    for ($i = $headerIndex + 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*\d+\s+upgrades available') { break }
        if ($line -match '^\s*[-]+\s*$') { continue }
        if ($line.Length -lt $availableCol) { continue }

        try {
            $name      = $line.Substring(0, $idCol).Trim()
            $id        = $line.Substring($idCol, $versionCol - $idCol).Trim()
            $current   = $line.Substring($versionCol, $availableCol - $versionCol).Trim()
            if ($sourceCol -gt 0 -and $line.Length -ge $sourceCol) {
                $available = $line.Substring($availableCol, $sourceCol - $availableCol).Trim()
            } else {
                $available = $line.Substring($availableCol).Trim()
            }
        } catch { continue }

        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($id)) { continue }

        $upgrades.Add([pscustomobject]@{
            Name          = $name
            Id            = $id
            Current       = $current
            Available     = $available
            PackageSource = 'winget'
        })
    }
    return $upgrades
}

# --- Source: Scoop ----------------------------------------------------------

function Get-ScoopUpgrades {
    if (-not (Test-Tool 'scoop')) { return @() }
    try {
        $raw = & scoop status 2>$null | Out-String
    } catch { return @() }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $lines = $raw -split "`r?`n"
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Name\s+Installed Version\s+Latest Version') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0) { return @() }

    $headerLine = $lines[$headerIndex]
    $instCol = $headerLine.IndexOf('Installed Version')
    $latestCol = $headerLine.IndexOf('Latest Version')

    $upgrades = New-Object System.Collections.Generic.List[object]
    for ($i = $headerIndex + 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*[-]+\s*$') { continue }
        if ($line.Length -lt $latestCol) { continue }

        try {
            $name      = $line.Substring(0, $instCol).Trim()
            $current   = $line.Substring($instCol, $latestCol - $instCol).Trim()
            $available = $line.Substring($latestCol).Trim() -replace '\s+.*$',''
        } catch { continue }

        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ([string]::IsNullOrWhiteSpace($available)) { continue }
        if ($current -eq $available) { continue }

        $upgrades.Add([pscustomobject]@{
            Name          = $name
            Id            = $name
            Current       = $current
            Available     = $available
            PackageSource = 'scoop'
        })
    }
    return $upgrades
}

# --- Source: Chocolatey -----------------------------------------------------

function Get-ChocoUpgrades {
    if (-not (Test-Tool 'chocolatey')) { return @() }
    try {
        $raw = & choco outdated -r --no-color 2>$null
    } catch { return @() }
    if (-not $raw) { return @() }

    $upgrades = New-Object System.Collections.Generic.List[object]
    foreach ($line in $raw) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\|'
        if ($parts.Count -lt 3) { continue }
        $upgrades.Add([pscustomobject]@{
            Name          = $parts[0].Trim()
            Id            = $parts[0].Trim()
            Current       = $parts[1].Trim()
            Available     = $parts[2].Trim()
            PackageSource = 'chocolatey'
        })
    }
    return $upgrades
}

# --- Matching helpers -------------------------------------------------------

function Get-MatchBase {
    # Normalize a program name for fuzzy matching. Strips a trailing dotted
    # version (e.g. " - 14.44.35211") but PRESERVES edition tokens like "2013"
    # or "2015-2022" so different product editions never collapse together.
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $b = $Name.ToLowerInvariant()
    $b = $b -replace '\s*[-–]?\s*v?\d+\.\d[\d.]*\s*$', ''  # trailing dotted version
    $b = $b -replace '…+$', ''                            # winget ellipsis truncation
    $b = $b.TrimEnd(' ', '-', '(', '[', '/', '+')
    return $b.Trim()
}

function Test-BasePrefixMatch {
    # True when two normalized bases are equal, or one is a word-boundary prefix
    # of the other. The prefix path handles winget's truncated names without
    # matching unrelated products (e.g. "Edge" vs "EdgeWebView2").
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    if ($A -eq $B) { return $true }
    if ($A.Length -ge $B.Length) { $long = $A; $short = $B } else { $long = $B; $short = $A }
    if ($short.Length -lt 6) { return $false }
    if (-not $long.StartsWith($short, [System.StringComparison]::Ordinal)) { return $false }
    $next = $long[$short.Length]
    return ($next -eq ' ' -or $next -eq '(')
}

function Get-VersionValue {
    # Parse a version-ish string into [version], or 0.0 when it can't be parsed.
    param([string]$Text)
    $v = $null
    $clean = ($Text -replace '[^\d.]', '').Trim('.')
    if ($clean -and [version]::TryParse($clean, [ref]$v)) { return $v }
    return [version]'0.0'
}

function Test-IsNewerVersion {
    # True when Available is strictly newer than Current. When either side can't
    # be parsed as a version, assume an update IS available so real updates are
    # never hidden by an odd version string.
    param([string]$Current, [string]$Available)
    $c = $null; $a = $null
    $cClean = ($Current  -replace '[^\d.]', '').Trim('.')
    $aClean = ($Available -replace '[^\d.]', '').Trim('.')
    if ([version]::TryParse($cClean, [ref]$c) -and [version]::TryParse($aClean, [ref]$a)) {
        return $a -gt $c
    }
    return $true
}

function Resolve-DuplicatePackageRows {
    # Collapse multiple installed entries that map to the same package id into a
    # single "Update available" row (keeping the highest installed version), so
    # stale leftover registry entries don't show as separate phantom updates.
    param([Parameter(Mandatory)] $Rows)
    $kept = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        $isUpdate = ($r.Status -like 'Update available*')
        if (-not $isUpdate -or [string]::IsNullOrWhiteSpace($r.PackageId)) {
            $result.Add($r); continue
        }
        $key = "$($r.PackageSource)|$($r.PackageId)"
        if (-not $kept.ContainsKey($key)) {
            $kept[$key] = $r
            $result.Add($r)
        } elseif ((Get-VersionValue $r.Current) -gt (Get-VersionValue $kept[$key].Current)) {
            [void]$result.Remove($kept[$key])
            $result.Add($r)
            $kept[$key] = $r
        }
    }
    return $result
}

# --- Merge ------------------------------------------------------------------

function Merge-ProgramsAndUpgrades {
    param(
        [Parameter(Mandatory)] $Programs,
        [Parameter(Mandatory)] $Upgrades,
        [Parameter(Mandatory)] [string[]] $EnabledSources
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $matchedKeys = New-Object System.Collections.Generic.HashSet[string]

    foreach ($prog in $Programs) {
        $match = $null
        foreach ($up in $Upgrades) {
            if ($up.Name -ieq $prog.Name) { $match = $up; break }
        }
        if (-not $match -and $prog.Name) {
            $progBase = Get-MatchBase $prog.Name
            foreach ($up in $Upgrades) {
                if (-not $up.Name) { continue }
                $upBase = Get-MatchBase $up.Name
                if (Test-BasePrefixMatch $progBase $upBase) { $match = $up; break }
            }
        }
        if (-not $match -and $prog.Name) {
            $progLower = $prog.Name.ToLower()
            foreach ($up in $Upgrades) {
                if (-not $up.Name) { continue }
                $upLower = $up.Name.ToLower()
                $escapedUp   = [regex]::Escape($upLower)
                $escapedProg = [regex]::Escape($progLower)
                if ($progLower -match "\b$escapedUp\b" -or $upLower -match "\b$escapedProg\b") {
                    $match = $up; break
                }
            }
        }

        if ($match) {
            [void]$matchedKeys.Add("$($match.PackageSource)|$($match.Id)")
            # Only flag an update when the available version is actually newer
            # than what's installed. This stops phantom "updates" where winget
            # keys off an older wrapper entry than the runtime you already have.
            $isNewer = Test-IsNewerVersion -Current $prog.Version -Available $match.Available
            $rows.Add([pscustomobject]@{
                Name          = $prog.Name
                Publisher     = $prog.Publisher
                Current       = $prog.Version
                Available     = if ($isNewer) { $match.Available } else { '' }
                Status        = if ($isNewer) { 'Update available' } else { 'Up to date / unknown' }
                PackageId     = if ($isNewer) { $match.Id } else { '' }
                PackageSource = if ($isNewer) { $match.PackageSource } else { '' }
            })
        } else {
            $status = if ($EnabledSources.Count -gt 0) { 'Up to date / unknown' } else { 'No package manager detected' }
            $rows.Add([pscustomobject]@{
                Name          = $prog.Name
                Publisher     = $prog.Publisher
                Current       = $prog.Version
                Available     = ''
                Status        = $status
                PackageId     = ''
                PackageSource = ''
            })
        }
    }

    foreach ($up in $Upgrades) {
        $key = "$($up.PackageSource)|$($up.Id)"
        if ($matchedKeys.Contains($key)) { continue }
        $rows.Add([pscustomobject]@{
            Name          = $up.Name
            Publisher     = ''
            Current       = $up.Current
            Available     = $up.Available
            Status        = "Update available ($($up.PackageSource) only)"
            PackageId     = $up.Id
            PackageSource = $up.PackageSource
        })
    }

    $rows = Resolve-DuplicatePackageRows -Rows $rows
    return $rows | Sort-Object @{ Expression = { if ($_.Status -like 'Update available*') { 0 } else { 1 } } }, Name
}

# --- Upgrade dispatch -------------------------------------------------------

function Test-SafePackageId {
    # Package ids are machine-generated identifiers (e.g. Microsoft.VCRedist.2015+.x64,
    # dotnet-sdk, git.install). Restrict to that charset so a crafted name can never
    # inject extra arguments or shell commands into an elevated installer call.
    # Whitelist, not blacklist: anything with a space, quote, ';', '&', '$', '(', '`'
    # or other metacharacter is rejected.
    param([string]$Id)
    return ($Id -match '^[\w.+-]+$')
}

function Get-UpgradeExitMessage {
    # Translate a package-manager exit code into a human-readable result so the
    # GUI can tell the user WHY an upgrade did nothing instead of failing silently.
    param([string]$Source, $ExitCode)
    if ($null -eq $ExitCode) { return 'No exit code was returned by the installer.' }
    $code = [int]$ExitCode
    if ($code -eq 0) { return 'Succeeded.' }
    if ($Source -eq 'winget') {
        switch ($code) {
            -1978335189 { return 'No applicable upgrade (already current, pinned, or version mismatch).' } # 0x8A15002B
            -1978335212 { return 'No installed package matched for upgrade.' }                              # 0x8A150014
            -1978334969 { return 'No installer applicable to this system.' }                               # 0x8A150107
            1602        { return 'Installer cancelled.' }
            1603        { return 'Fatal installer error (1603) — a newer version may already be present.' }
            -2147023673 { return 'Operation cancelled (UAC prompt declined?).' }
            default {
                $hex = ('0x{0:X8}' -f ($code -band [uint32]::MaxValue))
                return "winget exited with code $code ($hex)."
            }
        }
    }
    return "$Source exited with code $code."
}

function Invoke-PackageUpgrade {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Id,
        [string]$Name = $Id
    )
    $result = [pscustomobject]@{
        Name = $Name; Id = $Id; Source = $Source
        Success = $false; ExitCode = $null; Message = ''
    }
    if (-not (Test-SafePackageId $Id)) {
        $result.Message = 'Refused: package id contains unexpected characters.'
        return $result
    }
    try {
        $proc = switch ($Source) {
            'winget' {
                Start-Process -FilePath 'winget' -ArgumentList @(
                    'upgrade','--id',$Id,'--exact','--source','winget',
                    '--accept-package-agreements','--accept-source-agreements',
                    '--disable-interactivity','-h'
                ) -Verb RunAs -Wait -PassThru
            }
            'scoop' {
                # $Id is interpolated into a child-shell command, so it MUST stay
                # constrained to the safe id charset enforced by Test-SafePackageId above.
                Start-Process -FilePath 'powershell' -ArgumentList @(
                    '-NoProfile','-Command',"scoop update $Id"
                ) -Wait -PassThru
            }
            'chocolatey' {
                Start-Process -FilePath 'choco' -ArgumentList @(
                    'upgrade',$Id,'-y'
                ) -Verb RunAs -Wait -PassThru
            }
        }
        $result.ExitCode = $proc.ExitCode
        $result.Success  = ($proc.ExitCode -eq 0)
        $result.Message  = Get-UpgradeExitMessage -Source $Source -ExitCode $proc.ExitCode
    } catch {
        # Most commonly the user declined the UAC elevation prompt.
        $result.Message = $_.Exception.Message
    }
    return $result
}

# --- Reporting --------------------------------------------------------------

function Export-CsvReport {
    param([Parameter(Mandatory)] $Rows, [Parameter(Mandatory)] [string]$Path)
    $Rows | Select-Object Name, Publisher, Current, Available, Status, PackageId, PackageSource |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Export-HtmlReport {
    param([Parameter(Mandatory)] $Rows, [Parameter(Mandatory)] [string]$Path)

    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $available = @($Rows | Where-Object { $_.Status -like 'Update available*' })
    $availableCount = $available.Count
    $totalCount = @($Rows).Count

    $rowsHtml = New-Object System.Text.StringBuilder
    foreach ($r in $Rows) {
        $cls = if ($r.Status -like 'Update available*') { 'update' } else { 'ok' }
        [void]$rowsHtml.AppendLine(("<tr class='{0}'><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td></tr>" -f
            $cls,
            [System.Web.HttpUtility]::HtmlEncode($r.Name),
            [System.Web.HttpUtility]::HtmlEncode($r.Publisher),
            [System.Web.HttpUtility]::HtmlEncode($r.Current),
            [System.Web.HttpUtility]::HtmlEncode($r.Available),
            [System.Web.HttpUtility]::HtmlEncode($r.Status),
            [System.Web.HttpUtility]::HtmlEncode($r.PackageId),
            [System.Web.HttpUtility]::HtmlEncode($r.PackageSource)
        ))
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>$($script:ProductName) Report</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: 'Segoe UI', system-ui, sans-serif; margin: 2rem; max-width: 1300px; }
  h1 { margin: 0 0 0.25rem; }
  .meta { color: #666; margin-bottom: 1.5rem; font-size: 0.9rem; }
  .summary { display: flex; gap: 1rem; margin-bottom: 1.5rem; }
  .card { padding: 0.75rem 1.25rem; border-radius: 6px; background: #f4f4f7; border: 1px solid #ddd; }
  .card.warn { background: #fff7d6; border-color: #e0c870; }
  table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
  th, td { text-align: left; padding: 0.4rem 0.6rem; border-bottom: 1px solid #e5e5e5; }
  th { background: #f0f0f5; position: sticky; top: 0; }
  tr.update { background: #fffbe6; }
  tr.update td:nth-child(5) { color: #b06a00; font-weight: 600; }
  tbody tr:hover { background: #f7f7fb; }
  footer { margin-top: 2rem; color: #888; font-size: 0.8rem; }
  @media (prefers-color-scheme: dark) {
    body { background: #1a1a1d; color: #e8e8e8; }
    .card { background: #25252b; border-color: #38383f; }
    .card.warn { background: #3a3422; border-color: #6b5d2a; }
    th { background: #25252b; }
    th, td { border-color: #2e2e34; }
    tr.update { background: #2e2820; }
    tr.update td:nth-child(5) { color: #f0c060; }
    tbody tr:hover { background: #28282e; }
  }
</style>
</head>
<body>
<h1>$($script:ProductName) Report</h1>
<div class="meta">Generated $generated &middot; v$($script:Version)</div>
<div class="summary">
  <div class="card warn"><strong>$availableCount</strong> updates available</div>
  <div class="card"><strong>$totalCount</strong> programs scanned</div>
</div>
<table>
  <thead>
    <tr><th>Name</th><th>Publisher</th><th>Current</th><th>Available</th><th>Status</th><th>Package Id</th><th>Source</th></tr>
  </thead>
  <tbody>
$($rowsHtml.ToString())
  </tbody>
</table>
<footer>
  Generated by <a href="$($script:RepoUrl)">$($script:ProductName)</a>.
</footer>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
}

# --- Data acquisition pipeline ----------------------------------------------

function Get-Report {
    param(
        [scriptblock]$ProgressCallback = { param($msg) },
        [switch]$IncludeSystemComponents
    )

    & $ProgressCallback 'Scanning installed programs...'
    $programs = Get-InstalledPrograms -IncludeSystemComponents:$IncludeSystemComponents
    & $ProgressCallback "Found $($programs.Count) programs."

    $enabled = Get-EnabledSources
    $allUpgrades = New-Object System.Collections.Generic.List[object]

    foreach ($src in $enabled) {
        & $ProgressCallback "Querying $src..."
        $upgrades = switch ($src) {
            'winget'     { Get-WingetUpgrades }
            'scoop'      { Get-ScoopUpgrades }
            'chocolatey' { Get-ChocoUpgrades }
        }
        foreach ($u in $upgrades) { $allUpgrades.Add($u) }
    }

    & $ProgressCallback 'Matching...'
    $rows = Merge-ProgramsAndUpgrades -Programs $programs -Upgrades $allUpgrades -EnabledSources $enabled
    return [pscustomobject]@{
        Rows           = $rows
        EnabledSources = $enabled
        ProgramCount   = $programs.Count
    }
}

# --- GUI --------------------------------------------------------------------

function Show-AboutDialog {
    param([System.Windows.Forms.Form]$Owner)
    Add-Type -AssemblyName System.Windows.Forms

    $about = New-Object System.Windows.Forms.Form
    $about.Text = "About $($script:ProductName)"
    $about.Size = New-Object System.Drawing.Size(540, 240)
    $about.FormBorderStyle = 'FixedDialog'
    $about.MaximizeBox = $false
    $about.MinimizeBox = $false
    $about.StartPosition = 'CenterParent'

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $script:ProductName
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(20, 20)
    $title.AutoSize = $true
    $about.Controls.Add($title)

    $ver = New-Object System.Windows.Forms.Label
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    $ver.Text = "Version $($script:Version)  -  $arch  -  PowerShell $($PSVersionTable.PSVersion.ToString())"
    $ver.Location = New-Object System.Drawing.Point(20, 55)
    $ver.AutoSize = $true
    $about.Controls.Add($ver)

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = "Scans installed programs and reports available updates from`r`nwinget, Scoop, and Chocolatey."
    $desc.Location = New-Object System.Drawing.Point(20, 80)
    $desc.Size = New-Object System.Drawing.Size(390, 40)
    $about.Controls.Add($desc)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = $script:RepoUrl
    $link.Location = New-Object System.Drawing.Point(20, 130)
    $link.AutoSize = $true
    $link.Add_LinkClicked({ Start-Process $script:RepoUrl })
    $about.Controls.Add($link)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point(430, 165)
    $about.Controls.Add($ok)
    $about.AcceptButton = $ok

    [void]$about.ShowDialog($Owner)
}

function Show-Gui {
    param(
        [Parameter(Mandatory)] $Report,
        [switch]$IncludeSystemComponents
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:ProductName) v$($script:Version)"
    $form.Size = New-Object System.Drawing.Size(1180, 680)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(900, 450)

    # Menu
    $menu = New-Object System.Windows.Forms.MenuStrip
    $fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem('&File')
    $miRefresh   = New-Object System.Windows.Forms.ToolStripMenuItem('&Refresh',$null,{ Refresh-Data })
    $miRefresh.ShortcutKeys = [System.Windows.Forms.Keys]::F5
    $miCsv       = New-Object System.Windows.Forms.ToolStripMenuItem('Export to &CSV...',$null,{ Export-CsvDialog })
    $miHtml      = New-Object System.Windows.Forms.ToolStripMenuItem('Export to &HTML...',$null,{ Export-HtmlDialog })
    $miSep       = New-Object System.Windows.Forms.ToolStripSeparator
    $miExit      = New-Object System.Windows.Forms.ToolStripMenuItem('E&xit',$null,{ $form.Close() })
    [void]$fileMenu.DropDownItems.AddRange(@($miRefresh,$miCsv,$miHtml,$miSep,$miExit))

    $helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem('&Help')
    $miGitHub = New-Object System.Windows.Forms.ToolStripMenuItem('Open &GitHub repo',$null,{ Start-Process $script:RepoUrl })
    $miAbout  = New-Object System.Windows.Forms.ToolStripMenuItem('&About...',$null,{ Show-AboutDialog -Owner $form })
    [void]$helpMenu.DropDownItems.AddRange(@($miGitHub,$miAbout))

    [void]$menu.Items.AddRange(@($fileMenu,$helpMenu))
    $form.MainMenuStrip = $menu
    $form.Controls.Add($menu)

    # Toolbar
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Height = 50
    $form.Controls.Add($top)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = 'Refresh (F5)'
    $btnRefresh.Location = New-Object System.Drawing.Point(10, 12)
    $btnRefresh.Size = New-Object System.Drawing.Size(110, 28)
    $top.Controls.Add($btnRefresh)

    $btnUpgradeSel = New-Object System.Windows.Forms.Button
    $btnUpgradeSel.Text = 'Update Selected'
    $btnUpgradeSel.Location = New-Object System.Drawing.Point(130, 12)
    $btnUpgradeSel.Size = New-Object System.Drawing.Size(140, 28)
    $top.Controls.Add($btnUpgradeSel)

    $btnUpgradeAll = New-Object System.Windows.Forms.Button
    $btnUpgradeAll.Text = 'Update All Available'
    $btnUpgradeAll.Location = New-Object System.Drawing.Point(280, 12)
    $btnUpgradeAll.Size = New-Object System.Drawing.Size(150, 28)
    $top.Controls.Add($btnUpgradeAll)

    $chkOnlyUpdates = New-Object System.Windows.Forms.CheckBox
    $chkOnlyUpdates.Text = 'Only show updates'
    $chkOnlyUpdates.Location = New-Object System.Drawing.Point(450, 16)
    $chkOnlyUpdates.AutoSize = $true
    $top.Controls.Add($chkOnlyUpdates)

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = 'Filter:'
    $lblFilter.Location = New-Object System.Drawing.Point(610, 18)
    $lblFilter.AutoSize = $true
    $top.Controls.Add($lblFilter)

    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Location = New-Object System.Drawing.Point(660, 14)
    $txtFilter.Size = New-Object System.Drawing.Size(220, 24)
    $top.Controls.Add($txtFilter)

    # Status bar
    $status = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Spring = $true
    $statusLabel.TextAlign = 'MiddleLeft'
    $sourceLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    [void]$status.Items.Add($statusLabel)
    [void]$status.Items.Add($sourceLabel)
    $form.Controls.Add($status)

    # Grid
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $true
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.RowHeadersVisible = $false
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245,245,250)
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $form.Controls.Add($grid)
    $grid.BringToFront()

    $colSelect = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colSelect.HeaderText = ''
    $colSelect.Name = 'Select'
    $colSelect.Width = 36
    $colSelect.AutoSizeMode = 'None'
    [void]$grid.Columns.Add($colSelect)

    foreach ($colSpec in @(
        @{ Name = 'Name';          Weight = 24 },
        @{ Name = 'Publisher';     Weight = 16 },
        @{ Name = 'Current';       Weight = 10 },
        @{ Name = 'Available';     Weight = 10 },
        @{ Name = 'Status';        Weight = 14 },
        @{ Name = 'PackageId';     Weight = 16 },
        @{ Name = 'PackageSource'; Weight = 8  }
    )) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $colSpec.Name
        $col.Name = $colSpec.Name
        $col.ReadOnly = $true
        $col.FillWeight = $colSpec.Weight
        [void]$grid.Columns.Add($col)
    }

    $script:Report = $Report

    function Update-Grid {
        $grid.SuspendLayout()
        $grid.Rows.Clear()
        $filterText = $txtFilter.Text.Trim()
        $onlyUpdates = $chkOnlyUpdates.Checked
        $count = 0
        foreach ($r in $script:Report.Rows) {
            if ($onlyUpdates -and ($r.Status -notlike 'Update available*')) { continue }
            if ($filterText -and -not (
                ($r.Name -and $r.Name -like "*$filterText*") -or
                ($r.Publisher -and $r.Publisher -like "*$filterText*") -or
                ($r.PackageId -and $r.PackageId -like "*$filterText*"))) { continue }

            $rowIndex = $grid.Rows.Add(
                $false,
                $r.Name, $r.Publisher, $r.Current, $r.Available,
                $r.Status, $r.PackageId, $r.PackageSource
            )
            if ($r.Status -like 'Update available*') {
                $grid.Rows[$rowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,250,205)
            }
            $count++
        }
        $grid.ResumeLayout()
        $totalAvailable = @($script:Report.Rows | Where-Object { $_.Status -like 'Update available*' }).Count
        $statusLabel.Text = "Showing $count of $($script:Report.Rows.Count) rows. Updates available: $totalAvailable."
        $sourceLabel.Text = if ($script:Report.EnabledSources.Count -gt 0) {
            "Sources: $($script:Report.EnabledSources -join ', ')"
        } else {
            "No package manager detected"
        }
    }

    function Refresh-Data {
        $statusLabel.Text = 'Scanning...'
        $form.Refresh()
        $script:Report = Get-Report -IncludeSystemComponents:$IncludeSystemComponents -ProgressCallback {
            param($msg)
            $statusLabel.Text = $msg
            [System.Windows.Forms.Application]::DoEvents()
        }
        Update-Grid
    }

    function Show-UpgradeResults {
        param($Results)
        $Results = @($Results)
        if (-not $Results) { return }
        $ok   = @($Results | Where-Object { $_.Success })
        $fail = @($Results | Where-Object { -not $_.Success })
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("Succeeded: $($ok.Count)    Failed: $($fail.Count)")
        if ($fail.Count) {
            [void]$sb.AppendLine('')
            foreach ($f in $fail) { [void]$sb.AppendLine("- $($f.Name): $($f.Message)") }
        }
        $icon = if ($fail.Count) { 'Warning' } else { 'Information' }
        [System.Windows.Forms.MessageBox]::Show($sb.ToString(), 'Upgrade results', 'OK', $icon) | Out-Null
    }

    function Get-CheckedRows {
        $items = @()
        foreach ($row in $grid.Rows) {
            if (-not [bool]$row.Cells['Select'].Value) { continue }
            $items += [pscustomobject]@{
                Source = $row.Cells['PackageSource'].Value
                Id     = $row.Cells['PackageId'].Value
                Name   = $row.Cells['Name'].Value
            }
        }
        return ,$items
    }

    function Export-CsvDialog {
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'CSV files (*.csv)|*.csv'
        $dlg.FileName = "winupdatechecker-$((Get-Date).ToString('yyyy-MM-dd')).csv"
        if ($dlg.ShowDialog() -ne 'OK') { return }
        Export-CsvReport -Rows $script:Report.Rows -Path $dlg.FileName
        $statusLabel.Text = "CSV exported: $($dlg.FileName)"
    }

    function Export-HtmlDialog {
        Add-Type -AssemblyName System.Web
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'HTML files (*.html)|*.html'
        $dlg.FileName = "winupdatechecker-$((Get-Date).ToString('yyyy-MM-dd')).html"
        if ($dlg.ShowDialog() -ne 'OK') { return }
        Export-HtmlReport -Rows $script:Report.Rows -Path $dlg.FileName
        $statusLabel.Text = "HTML exported: $($dlg.FileName)"
        if ([System.Windows.Forms.MessageBox]::Show('Open the report now?','Report saved','YesNo','Question') -eq 'Yes') {
            Start-Process $dlg.FileName
        }
    }

    $btnRefresh.Add_Click({ Refresh-Data })
    $chkOnlyUpdates.Add_CheckedChanged({ Update-Grid })
    $txtFilter.Add_TextChanged({ Update-Grid })

    $btnUpgradeSel.Add_Click({
        $items = @(Get-CheckedRows | Where-Object { $_.Id -and $_.Source })
        if (-not $items) {
            [System.Windows.Forms.MessageBox]::Show('Tick the checkbox for items you want to update.', 'No selection', 'OK', 'Information') | Out-Null
            return
        }
        $msg = "Upgrade $($items.Count) package(s)?`r`n`r`n" + ($items | ForEach-Object { "$($_.Name)  ($($_.Source))" } | Out-String)
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'Confirm', 'YesNo', 'Question') -ne 'Yes') { return }
        $results = foreach ($it in $items) { Invoke-PackageUpgrade -Source $it.Source -Id $it.Id -Name $it.Name }
        Show-UpgradeResults $results
        Refresh-Data
    })

    $btnUpgradeAll.Add_Click({
        $items = @($script:Report.Rows | Where-Object {
            $_.Status -like 'Update available*' -and $_.PackageId -and $_.PackageSource
        })
        if (-not $items) {
            [System.Windows.Forms.MessageBox]::Show('Nothing to update.', 'All clear', 'OK', 'Information') | Out-Null
            return
        }
        if ([System.Windows.Forms.MessageBox]::Show("Upgrade ALL $($items.Count) available package(s)?", 'Confirm', 'YesNo', 'Question') -ne 'Yes') { return }
        $results = foreach ($it in $items) { Invoke-PackageUpgrade -Source $it.PackageSource -Id $it.PackageId -Name $it.Name }
        Show-UpgradeResults $results
        Refresh-Data
    })

    Update-Grid
    [void]$form.ShowDialog()
}

# --- Main -------------------------------------------------------------------

# When dot-sourced (e.g. from the test suite) the invocation name is '.', so the
# functions above are loaded without launching the scanner or GUI.
if ($MyInvocation.InvocationName -eq '.') { return }

# CSV export shortcut
if ($ExportCsv) {
    $report = Get-Report -IncludeSystemComponents:$IncludeSystemComponents -ProgressCallback {
        param($msg) Write-Host $msg -ForegroundColor Cyan
    }
    Export-CsvReport -Rows $report.Rows -Path $ExportCsv
    Write-Host "CSV written to $ExportCsv" -ForegroundColor Green
    return
}

# HTML export shortcut
if ($ExportHtml) {
    Add-Type -AssemblyName System.Web
    $report = Get-Report -IncludeSystemComponents:$IncludeSystemComponents -ProgressCallback {
        param($msg) Write-Host $msg -ForegroundColor Cyan
    }
    Export-HtmlReport -Rows $report.Rows -Path $ExportHtml
    Write-Host "HTML written to $ExportHtml" -ForegroundColor Green
    return
}

# Console mode
if ($NoGui) {
    $report = Get-Report -IncludeSystemComponents:$IncludeSystemComponents -ProgressCallback {
        param($msg) Write-Host $msg -ForegroundColor Cyan
    }
    if ($report.EnabledSources.Count -eq 0) {
        Write-Warning 'No supported package manager found (winget, scoop, chocolatey).'
    }
    $available = @($report.Rows | Where-Object { $_.Status -like 'Update available*' })
    Write-Host ""
    Write-Host "Updates available: $($available.Count) of $($report.Rows.Count) entries" -ForegroundColor Green
    Write-Host "Sources queried: $($report.EnabledSources -join ', ')" -ForegroundColor Green
    Write-Host ""
    $available | Format-Table Name, Current, Available, PackageId, PackageSource -AutoSize
    return
}

# GUI mode
$initial = Get-Report -IncludeSystemComponents:$IncludeSystemComponents -ProgressCallback {
    param($msg) Write-Host $msg -ForegroundColor Cyan
}
Show-Gui -Report $initial -IncludeSystemComponents:$IncludeSystemComponents
