# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-05-06

Initial public release.

### Added
- Registry-based scan of installed programs (HKLM, HKCU, WOW6432Node).
- Update detection from **winget**, **Scoop**, and **Chocolatey**.
- WinForms GUI with sortable grid, filter box, and "Only show updates" toggle.
- One-click **Update Selected** and **Update All Available** actions.
- CSV and stand-alone HTML report export (light/dark theme aware).
- Console mode (`-NoGui`) and direct export modes (`-ExportCsv`, `-ExportHtml`).
- `-Source` flag to restrict the package managers queried.
- `-IncludeSystemComponents` flag to include hidden Windows components.
- About dialog with version and repo link, F5 refresh shortcut.

### Distribution
- Inno Setup installer (`installer/setup.iss`) producing `WinUpdateChecker-Setup-x.y.z.exe`.
- Portable zip artifact built alongside the installer.
- GitHub Actions release workflow (`.github/workflows/release.yml`) — tag push builds installer, zip, and `SHA256SUMS.txt`, then drafts a release.
- Authenticode signing helper (`tools/Sign-Script.ps1`).
- Signing documentation including SignPath OSS application steps (`docs/SIGNING.md`).
