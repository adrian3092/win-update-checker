# WinUpdateChecker

A small, portable Windows tool that scans your installed programs and tells you which ones have updates available.

It reads the same uninstall registry keys that **Programs and Features** uses, then cross-references them against three of the most popular Windows package managers — **winget**, **Scoop**, and **Chocolatey** — to find updates. One-click upgrade for any program a package manager can update.

No installer. No telemetry. Pure PowerShell + WinForms — runs on any Windows 10/11 machine out of the box.

---

## Features

- Scans installed programs from the Windows registry (HKLM + HKCU + WOW6432Node).
- Queries every package manager you have installed (winget / Scoop / Chocolatey).
- Sortable, filterable grid with a "Only show updates" toggle.
- One-click **Update Selected** or **Update All Available**.
- Export to **CSV** or a stand-alone **HTML report** (light/dark theme aware).
- Console mode for scheduled tasks (`-NoGui`, `-ExportCsv`, `-ExportHtml`).
- Zero dependencies. Single-file script. Fully portable.

## Screenshots

> Place screenshots in `docs/screenshots/` and reference them here.
>
> ![GUI screenshot placeholder](docs/screenshots/gui.png)
> ![HTML report placeholder](docs/screenshots/report.png)

## Requirements

- Windows 10 1809+ or Windows 11 — **x64 and ARM64 supported** (Surface Pro X, Snapdragon Copilot+ PCs, Windows Dev Kit, etc.). 32-bit Windows works too.
- PowerShell 5.1 (built into Windows) or PowerShell 7+.
- At least one of these for update detection:
  - [winget](https://learn.microsoft.com/windows/package-manager/winget/) — pre-installed on modern Windows; otherwise install **App Installer** from the Microsoft Store.
  - [Scoop](https://scoop.sh/) — optional.
  - [Chocolatey](https://chocolatey.org/) — optional.

> The single installer / portable zip works on all three architectures. There are no native binaries — the tool is pure PowerShell + WinForms, both of which run natively on ARM64 Windows. winget, Scoop, and Chocolatey all support ARM64.

## Install

Pick whichever you prefer — both ship from the same GitHub release page.

### Installer (recommended for most users)

Download `WinUpdateChecker-Setup-x.y.z.exe` from the [latest release](https://github.com/adrian3092/win-update-checker/releases/latest), run it, click through the wizard, launch from the Start menu. Standard Add-or-Remove-Programs uninstall.

### Portable zip

1. Download `WinUpdateChecker-portable-x.y.z.zip`.
2. Right-click the downloaded zip → **Properties** → tick **Unblock** → OK.
3. Extract anywhere.
4. Double-click **`Run.bat`**.

That's it. The first scan takes 5–15 seconds.

### From source

```powershell
git clone https://github.com/adrian3092/win-update-checker.git
cd win-update-checker
.\Run.bat
```

## Usage

### GUI

```powershell
.\Run.bat
# or
powershell -ExecutionPolicy Bypass -File .\UpdateChecker.ps1
```

### Console mode

```powershell
.\Run-Console.bat
# or
powershell -ExecutionPolicy Bypass -File .\UpdateChecker.ps1 -NoGui
```

### Generate a stand-alone HTML report

```powershell
.\UpdateChecker.ps1 -ExportHtml report.html
```

### Generate a CSV (handy for scheduled tasks)

```powershell
.\UpdateChecker.ps1 -ExportCsv "$env:USERPROFILE\Desktop\updates.csv"
```

### Restrict to a single package manager

```powershell
.\UpdateChecker.ps1 -Source winget
.\UpdateChecker.ps1 -Source scoop,chocolatey
```

### Include Windows components and hotfixes

```powershell
.\UpdateChecker.ps1 -IncludeSystemComponents
```

## Schedule a daily check

Run this once in an admin PowerShell window. It creates a Task Scheduler job that emails you a fresh HTML report at 9 a.m. (replace the path):

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\WinUpdateChecker\UpdateChecker.ps1" -ExportHtml "C:\Tools\WinUpdateChecker\latest.html"'
$trigger = New-ScheduledTaskTrigger -Daily -At 9am
Register-ScheduledTask -TaskName 'WinUpdateChecker Daily' -Action $action -Trigger $trigger
```

## How it works

```
+---------------------------+
|  Registry Uninstall keys  |  <-- HKLM, HKCU, WOW6432Node
+-------------+-------------+
              |
              v
+---------------------------+      +---------------------+
|  Installed program list   |      |  winget upgrade     |
+-------------+-------------+      |  scoop status       |
              |                    |  choco outdated -r  |
              |                    +----------+----------+
              |                               |
              +---------+---------+-----------+
                        |         |
                        v         v
              +-------------------------+
              |  Name match + version   |  <-- exact, then base-name,
              |  comparison             |      then word-boundary
              +-----------+-------------+
                          |
                          v
              +-------------------------+
              |  Sortable grid / report |
              +-------------------------+
```

The **PackageSource** column tells you which manager owns each update; **Update Selected** dispatches to the correct CLI (`winget upgrade`, `scoop update`, `choco upgrade`). winget and Chocolatey upgrades trigger a UAC prompt; Scoop runs as the current user.

## FAQ

**Does it modify anything on its own?**
No. It only reads the registry and queries package managers. Updates only run when you explicitly click an Update button or invoke a CLI flag.

**Why does Windows say "Windows protected your PC"?**
SmartScreen warns on unsigned scripts. Right-click the zip → Properties → Unblock before extracting, or run via the included `Run.bat` (which uses `-ExecutionPolicy Bypass` for the single invocation only and never modifies system policy).

**It says my program is "Up to date / unknown" but I know there's an update.**
That program isn't in any of the package-manager catalogs. WinUpdateChecker can only report on what winget/Scoop/Chocolatey know about. For full coverage, install winget at minimum.

**Does it support PortableApps / Microsoft Store / Steam / etc.?**
Microsoft Store apps appear if winget can see them (it usually can). Steam and other store-managed apps are reported as installed but updates are managed by their own clients.

**Can I run it without admin?**
Yes — for scanning. Some upgrades (winget, choco) request elevation when invoked.

## Verify a release

Each GitHub release includes a `SHA256SUMS.txt`. Verify a downloaded artifact:

```powershell
Get-FileHash .\WinUpdateChecker-Setup-1.0.0.exe -Algorithm SHA256
```

Compare against the published hash before running. Once the project is enrolled in [SignPath OSS signing](docs/SIGNING.md), installer downloads will also carry a verifiable Authenticode signature — check the file's **Properties → Digital Signatures** tab.

## Building releases

```powershell
# Local build (requires Inno Setup 6 installed)
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DMyAppVersion=1.0.0 installer\setup.iss
```

CI builds run automatically on tag push: `git tag v1.0.1 && git push --tags`. See [`.github/workflows/release.yml`](.github/workflows/release.yml) and [`docs/SIGNING.md`](docs/SIGNING.md) for details.

## Contributing

PRs welcome. Please:

1. Open an issue first for non-trivial changes.
2. Keep the script self-contained — no external module dependencies.
3. Test on PowerShell 5.1 (Windows default) and 7+.

## License

[MIT](LICENSE).
