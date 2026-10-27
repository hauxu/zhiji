@echo off
if not exist "%SystemRoot%\System32\msvcp140.dll" (
  echo 正在安装 VC++ 运行库，请稍候...
  "%~dp0vc_redist.x64.exe" /install /quiet /norestart
  echo 安装完成。
) else (
  echo 运行库已就绪，无需安装。
)
pause
