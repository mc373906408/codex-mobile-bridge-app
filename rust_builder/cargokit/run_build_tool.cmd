@echo off
setlocal
set "BUILD_TOOL_PKG_DIR=%~dp0build_tool"
set "DART=%FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart.exe"
if not defined FLUTTER_ROOT set "DART=dart.exe"
if not exist "%CARGOKIT_TOOL_TEMP_DIR%" mkdir "%CARGOKIT_TOOL_TEMP_DIR%"
if not exist "%CARGOKIT_TOOL_TEMP_DIR%" exit /b 1
for %%I in ("%CARGOKIT_TOOL_TEMP_DIR%") do set "RUNNER_DIR=%%~fI"
cd /D "%BUILD_TOOL_PKG_DIR%"
if errorlevel 1 exit /b %errorlevel%
REM Resolve only the reviewed lockfile; compilation never upgrades dependencies.
"%DART%" pub get --enforce-lockfile --no-precompile
if errorlevel 1 exit /b %errorlevel%
"%DART%" compile kernel bin/build_tool.dart -o "%RUNNER_DIR%\build_tool.dill"
if errorlevel 1 exit /b %errorlevel%
"%DART%" "%RUNNER_DIR%\build_tool.dill" %*
exit /b %errorlevel%
