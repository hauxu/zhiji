# Build + package the Windows release (portable zip, optional installer).
#   powershell -File tools/package_windows.ps1 -AppKey <GD_APP_KEY>
# Pass -SkipBuild to package the existing build output.
param(
  [Parameter(Mandatory = $true)][string]$AppKey,
  [string]$SyncHost = "your.server.com",
  [string]$CertSha256 = "<cert sha256>",
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$release = Join-Path $root "build\windows\x64\runner\Release"
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$version = (Select-String -Path (Join-Path $root "pubspec.yaml") -Pattern '^version: ([0-9.]+)' |
  ForEach-Object { $_.Matches[0].Groups[1].Value })
Write-Output "version: $version"

if (-not $SkipBuild) {
  Write-Output "building windows release..."
  & flutter build windows --release `
    "--dart-define=ZHIZI_SYNC_HOST=$SyncHost" `
    "--dart-define=ZHIZI_SYNC_PORT=8443" `
    "--dart-define=ZHIZI_SYNC_APPKEY=$AppKey" `
    "--dart-define=ZHIZI_SYNC_CERT=$CertSha256"
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }
}

$zipName = "zhiji-v$version-windows-portable.zip"
$zipPath = Join-Path $dist $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$stage = Join-Path $env:TEMP "gd_win_stage_$version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item "$release\*" $stage -Recurse -Force
$vc = Join-Path $root "windows\vc_redist.x64.exe"
if (Test-Path $vc) { Copy-Item $vc $stage -Force }
$readme = Join-Path $root "windows\使用说明.txt"
if (Test-Path $readme) { Copy-Item $readme $stage -Force }
Compress-Archive -Path "$stage\*" -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force
$zipSize = (Get-Item $zipPath).Length
Write-Output ("portable zip: {0} ({1} B)" -f $zipName, $zipSize)

# 找 Inno Setup 编译器：先用 PATH，再看常见安装位置
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
  foreach ($c in @("$env:ProgramFiles\Inno Setup 6\ISCC.exe",
                   "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe")) {
    if (Test-Path $c) { $iscc = $c; break }
  }
}
if ($iscc -and (Test-Path $iscc)) {
  Write-Output "building installer..."
  & $iscc (Join-Path $root "windows\setup.iss") | Select-Object -Last 2
}
else {
  Write-Output "skip installer: ISCC.exe not found"
}

$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
Write-Output ("zip sha256: " + $hash)
Write-Output "DONE"