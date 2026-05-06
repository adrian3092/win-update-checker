; WinUpdateChecker installer script (Inno Setup 6).
; Compile with: ISCC.exe installer\setup.iss
; CI overrides MyAppVersion via:  ISCC.exe /DMyAppVersion=1.2.3 installer\setup.iss

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0-dev"
#endif

#define MyAppName        "WinUpdateChecker"
#define MyAppPublisher   "WinUpdateChecker contributors"
#define MyAppURL         "https://github.com/adrian3092/win-update-checker"
#define MyAppExeName     "Run.bat"

[Setup]
; AppId uniquely identifies this application. Regenerate ONCE for your own fork
; (Tools -> Generate GUID in the Inno Setup IDE) and never change it again, or
; uninstall/upgrade detection will break.
AppId={{60cbe8cd-e316-4bc8-9a92-96305ec2c7d2}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\dist
OutputBaseFilename=WinUpdateChecker-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; x64compatible covers both x64 and ARM64 — installs to {pf64} on either.
; ArchitecturesAllowed is intentionally unset so the installer also runs on
; legacy 32-bit Windows; the script itself is architecture-agnostic.
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#MyAppName} {#MyAppVersion}
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\UpdateChecker.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Run.bat";           DestDir: "{app}"; Flags: ignoreversion
Source: "..\Run-Console.bat";   DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";         DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE";           DestDir: "{app}"; Flags: ignoreversion
Source: "..\CHANGELOG.md";      DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}";       Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autoprograms}\{#MyAppName} (Console)"; Filename: "{app}\Run-Console.bat"; WorkingDir: "{app}"
Name: "{autoprograms}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";        Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
