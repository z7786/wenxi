; Build with tool/build-windows-installer.ps1 (Inno Setup 6.7.3).
; Keep AppId and SetupMutex stable across releases so upgrades share one entry.
#define AppName "文析助手"
#define AppExe "asterlink.exe"
#ifndef AppArchitecture
  #define AppArchitecture "x64"
#endif
#ifndef RuntimeDir
  #error RuntimeDir must point to the complete Windows release directory.
#endif
#ifndef AppVersion
  #error AppVersion must match the Windows executable.
#endif
#ifndef AppFullVersion
  #error AppFullVersion must include the Flutter build number.
#endif
#ifndef AppFileVersion
  #error AppFileVersion must be a four-part numeric version.
#endif
#ifndef InstallerOutputDir
  #error InstallerOutputDir is required.
#endif
#ifndef WebView2Setup
  #error WebView2Setup must point to the verified Microsoft bootstrapper.
#endif

[Setup]
AppId={{80F54E69-3402-4527-B376-D8A6F2442A58}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppName}
VersionInfoVersion={#AppFileVersion}
VersionInfoProductVersion={#AppFileVersion}
VersionInfoProductTextVersion={#AppFullVersion}
VersionInfoDescription={#AppName} 安装程序
DefaultDirName={code:DefaultInstallDirectory}
DefaultGroupName={#AppName}
DisableWelcomePage=no
DisableDirPage=no
DisableProgramGroupPage=yes
AlwaysShowDirOnReadyPage=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes
PrivilegesRequired=lowest
#if AppArchitecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
MinVersion=10.0
WizardStyle=modern dynamic
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
UninstallLogMode=append
SetupMutex=Local\AsterLink-Setup-80F54E69-3402-4527-B376-D8A6F2442A58
; Do not silently interrupt downloads or schedule partially updated files.
CloseApplications=no
RestartApplications=no
RestartIfNeededByRun=no
Compression=lzma2/max
SolidCompression=yes
LZMAUseSeparateProcess=yes
OutputDir={#InstallerOutputDir}
OutputBaseFilename={#AppName}-{#AppVersion}-Windows-{#AppArchitecture}-Setup

[Languages]
Name: "chinesesimp"; MessagesFile: "languages\ChineseSimplified.isl"

[Messages]
WelcomeLabel1=欢迎安装 [name]
WelcomeLabel2=本向导将安装 [name/ver]。%n%n您可以选择安装位置，并创建桌面快捷方式。%n%n如已打开文析助手，请先从系统托盘退出，等待下载进程结束后再继续。
ConfirmUninstall=确定卸载 %1 吗？%n%n账号、设置、播放记录和已下载的文件会保留。

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："
Name: "webview2"; Description: "安装网页登录组件（Microsoft WebView2，需要联网）"; GroupDescription: "此电脑缺少的组件："; Check: NeedsWebView2

[Files]
Source: "{#RuntimeDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#WebView2Setup}"; Flags: dontcopy

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppExe}"
Name: "{group}\卸载{#AppName}"; Filename: "{uninstallexe}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Description: "运行{#AppName}"; Flags: nowait postinstall skipifsilent runasoriginaluser
Filename: "https://developer.microsoft.com/microsoft-edge/webview2/#download-section"; Description: "打开网页登录组件下载页面"; Flags: shellexec postinstall skipifsilent unchecked; Check: NeedsWebView2

[Registry]
Root: HKCU; Subkey: "Software\Classes\wenxi"; ValueType: string; ValueName: ""; ValueData: "URL:文析助手"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\wenxi"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\wenxi\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExe},0"
Root: HKCU; Subkey: "Software\Classes\wenxi\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" --open ""%1"""

[Code]
const
  WebView2Key = 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  PreviousInstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{80F54E69-3402-4527-B376-D8A6F2442A58}_is1';
  BusyMessage = '文析助手的程序文件正在使用中或暂时无法写入。' + #13#10 + #13#10 +
    '请从系统托盘退出文析助手，并等待下载进程结束后重试。' + #13#10 +
    '如果仍无法继续，请检查安装目录的写入权限。';

var
  DetectedInstallDirectory: String;
  InstallDirectoryResolved: Boolean;

function IsApplicationDirectory(const DirectoryName: String): Boolean;
begin
  Result := (Trim(DirectoryName) <> '') and
    FileExists(AddBackslash(DirectoryName) + '{#AppExe}') and
    FileExists(AddBackslash(DirectoryName) + 'flutter_windows.dll') and
    FileExists(AddBackslash(DirectoryName) + 'data\icudtl.dat');
end;

function PreviousDirectory(RootKey: Integer): String;
var
  Candidate: String;
begin
  Result := '';
  if RegQueryStringValue(RootKey, PreviousInstallKey, 'Inno Setup: App Path', Candidate) and
      IsApplicationDirectory(Candidate) then
    Result := RemoveBackslashUnlessRoot(Candidate)
  else if RegQueryStringValue(RootKey, PreviousInstallKey, 'InstallLocation', Candidate) and
      IsApplicationDirectory(Candidate) then
    Result := RemoveBackslashUnlessRoot(Candidate);
end;

function DefaultInstallDirectory(Param: String): String;
var
  Candidate: String;
begin
  if not InstallDirectoryResolved then
  begin
    InstallDirectoryResolved := True;
    DetectedInstallDirectory := PreviousDirectory(HKCU64);
    if DetectedInstallDirectory = '' then
      DetectedInstallDirectory := PreviousDirectory(HKCU32);
    if DetectedInstallDirectory = '' then
      DetectedInstallDirectory := PreviousDirectory(HKLM64);
    if DetectedInstallDirectory = '' then
      DetectedInstallDirectory := PreviousDirectory(HKLM32);
    if DetectedInstallDirectory = '' then
    begin
      { A portable copy beside this installer can also be upgraded. }
      Candidate := ExpandConstant('{src}');
      if IsApplicationDirectory(Candidate) then
        DetectedInstallDirectory := Candidate;
    end;
    if DetectedInstallDirectory = '' then
    begin
      Candidate := ExpandConstant('{localappdata}\Programs\AsterLink');
      if IsApplicationDirectory(Candidate) then
        DetectedInstallDirectory := Candidate;
    end;
  end;
  if DetectedInstallDirectory <> '' then
    Result := DetectedInstallDirectory
  else
    Result := ExpandConstant('{localappdata}\Programs\AsterLink');
end;

procedure InitializeWizard;
var
  IgnoredDefault: String;
begin
  IgnoredDefault := DefaultInstallDirectory('');
  if DetectedInstallDirectory <> '' then
  begin
    WizardForm.SelectDirLabel.Caption :=
      '已识别旧版安装目录，将在所选目录覆盖安装。您仍可更改路径：';
    WizardForm.WelcomeLabel2.Caption := WizardForm.WelcomeLabel2.Caption + #13#10 + #13#10 +
      '检测到旧版：' + DetectedInstallDirectory;
    Log('Detected previous AsterLink directory: ' + DetectedInstallDirectory);
  end;
  { Inno Setup applies an explicit /DIR after DefaultDirName. Do not overwrite
    WizardForm.DirEdit here: user and scripted directory choices must win. }
end;

function OpenFileForWrite(FileName: String; DesiredAccess, ShareMode: LongWord;
  SecurityAttributes: THandle; CreationDisposition, FlagsAndAttributes: LongWord;
  TemplateFile: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall';

function CloseFileHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function FileIsBusy(const FileName: String): Boolean;
var
  Handle: THandle;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  { Opening with write access fails for a running EXE. No bytes are written. }
  Handle := OpenFileForWrite(FileName, $40000000, 7, 0, 3, $80, 0);
  Result := Handle = THandle(-1);
  if not Result then
    CloseFileHandle(Handle);
end;

function ApplicationFilesBusy: Boolean;
begin
  Result := FileIsBusy(ExpandConstant('{app}\{#AppExe}')) or
    FileIsBusy(ExpandConstant('{app}\asterlink_gopeed.exe'));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if ApplicationFilesBusy then
    Result := BusyMessage;
end;

function InitializeUninstall: Boolean;
begin
  Result := not ApplicationFilesBusy;
  if not Result then
    SuppressibleMsgBox(BusyMessage, mbError, MB_OK, IDOK);
end;

function HasWebView2Version(RootKey: Integer): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(RootKey, WebView2Key, 'pv', Version) and
    (Trim(Version) <> '') and (Trim(Version) <> '0.0.0.0');
end;

function NeedsWebView2: Boolean;
begin
  Result := not (HasWebView2Version(HKLM32) or HasWebView2Version(HKCU));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('webview2') and
      NeedsWebView2 then
  begin
    WizardForm.StatusLabel.Caption := '正在安装网页登录组件，请保持联网…';
    ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
    if Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'),
        '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
      Log(Format('WebView2 bootstrapper exit code: %d', [ExitCode]))
    else
      Log(Format('WebView2 bootstrapper could not start: %d', [ExitCode]));
    { A failed optional prerequisite must not roll back an otherwise usable app. }
    if NeedsWebView2 then
      Log('WebView2 remains unavailable; the finish page offers the official download.');
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and NeedsWebView2 then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10 + #13#10 +
      '网页登录组件尚未安装，网页登录暂不可用。' +
      '可以勾选下方的下载页面，稍后补装 Microsoft WebView2。';
end;

{ No wildcard deletion sections: account data, downloads, and user-created
  files are never recursively removed by this installer. }
