@echo off
setlocal
cd /d "%~dp0"
where cl >nul 2>nul
if errorlevel 1 (
  if not exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" (
    echo Install Visual Studio C++ build tools and the Windows SDK first. 1>&2
    exit /b 1
  )
  for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do call "%%i\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64
)
if "%~1"=="--project" (
  msbuild menkh-viewer.vcxproj /p:Configuration=Release /p:Platform=x64 /verbosity:minimal
  if errorlevel 1 exit /b 1
  exit /b 0
)
if not exist "..\..\out\windows-viewer" mkdir "..\..\out\windows-viewer"
cl /nologo /utf-8 /std:c++17 /EHsc /MT /O2 /W4 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN main.cpp /Fo"..\..\out\windows-viewer\main.obj" /Fe"..\..\out\windows-viewer\menkh-viewer.exe" /link d3d12.lib dxgi.lib d3dcompiler.lib user32.lib gdi32.lib comctl32.lib comdlg32.lib
if errorlevel 1 exit /b 1
copy /y Voxel.hlsl "..\..\out\windows-viewer\Voxel.hlsl" >nul
if exist "..\..\zig-out\bin\menkh.exe" copy /y "..\..\zig-out\bin\menkh.exe" "..\..\out\windows-viewer\menkh.exe" >nul
if exist "..\..\zig-out\bin\menkh.dll" copy /y "..\..\zig-out\bin\menkh.dll" "..\..\out\windows-viewer\menkh.dll" >nul
if errorlevel 1 exit /b 1
exit /b 0
