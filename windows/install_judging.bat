@echo off
setlocal
cd /d "%~dp0"
if not exist "vc_redist.x64.exe" (
  echo 未找到 vc_redist.x64.exe。
  echo 系统已有运行库的话可以跳过；没有的话从微软官网下载 VC++ 2015-2022 x64 运行库放到本目录再运行。
  pause
  exit /b 0
)
if not exist "%SystemRoot%\System32\msvcp140.dll" (
  echo 正在安装 VC++ 运行库，请稍候...
  "%~dp0vc_redist.x64.exe" /install /quiet /norestart
  echo 安装完成。
) else (
  echo 运行库已就绪，无需安装。
)
pause
