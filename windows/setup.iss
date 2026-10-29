; 之计 Inno Setup 安装脚本
; 免管理员安装到 %LOCALAPPDATA%\Judging，按需装 VC++ 运行库，安装前关闭旧版。

#define MyAppName "之计"
#define MyAppNameEn "Judging"
#define MyAppVersion "5.16.25"
#define MyAppExeName "zhiji.exe"
#define MyAppId "{{8E4F5C2A-9B71-4D3E-A0C6-5A1B2C3D4E5F}"

[InstallDelete]
; 旧版本的可执行文件换个名字后要清掉，免得留两个
Type: files; Name: "{app}\judging.exe"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
DefaultDirName={localappdata}\{#MyAppNameEn}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 相对路径基于本 .iss 所在目录(goalday/windows/)。
OutputDir=..\..\
OutputBaseFileName=之计-v{#MyAppVersion}-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
MinVersion=10.0
ShowLanguageDialog=auto
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=LICENSE-GPL.txt

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "LICENSE-GPL.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; VC++ 运行库可选：仓库里不带这个 13MB 的安装包，需要的话自己下载放到本目录
#if FileExists("vc_redist.x64.exe")
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
#endif

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; \
  Flags: skipifdoesntexist runhidden waituntilterminated; \
  Check: NeedVCRuntime
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; \
  Flags: nowait postinstall skipifsilent unchecked

[Code]
function NeedVCRuntime(): Boolean;
begin
  // 缺 msvcp140.dll(VC++ 2015-2022 运行库)时才安装
  Result := not FileExists(ExpandConstant('{sys}\msvcp140.dll'));
end;

function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/im {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(1500);
  Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/f /im {#MyAppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(300);
end;
