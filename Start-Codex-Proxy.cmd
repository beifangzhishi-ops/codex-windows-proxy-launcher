@echo off
chcp 65001 >nul
setlocal
set "CODEX_APP_SERVER_WS_URL="
set "shouldPause=1"
if /I "%~1"=="--no-pause" set "shouldPause=0"

set "shellPath="
set "shellKind="
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    set "shellPath=pwsh.exe"
    set "shellKind=PowerShell 7"
)
if not defined shellPath if exist "%LOCALAPPDATA%\Programs\PowerShell\7\pwsh.exe" (
    set "shellPath=%LOCALAPPDATA%\Programs\PowerShell\7\pwsh.exe"
    set "shellKind=PowerShell 7"
)
if not defined shellPath if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "shellPath=%ProgramFiles%\PowerShell\7\pwsh.exe"
    set "shellKind=PowerShell 7"
)
if not defined shellPath if exist "%ProgramFiles%\PowerShell\7-preview\pwsh.exe" (
    set "shellPath=%ProgramFiles%\PowerShell\7-preview\pwsh.exe"
    set "shellKind=PowerShell 7"
)
if not defined shellPath if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    set "shellPath=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
    set "shellKind=Windows PowerShell 5.1"
)
if not defined shellPath (
    echo [ERROR] PowerShell 7 ^(pwsh.exe^) was not found.
    echo Windows PowerShell was not found either.
    if "%shouldPause%"=="1" pause
    exit /b 1
)

echo Using %shellKind%: %shellPath%
if /I "%shellKind%"=="Windows PowerShell 5.1" echo [INFO] PowerShell 7 was not found. Falling back to Windows PowerShell 5.1.

if /I "%shellKind%"=="Windows PowerShell 5.1" (
    "%shellPath%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0Start-Codex-Proxy.ps1'"
) else (
    "%shellPath%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Codex-Proxy.ps1"
)
set "scriptExitCode=%ERRORLEVEL%"

echo.
if not "%scriptExitCode%"=="0" echo Launcher exited with code: %scriptExitCode%
if "%shouldPause%"=="1" pause
exit /b %scriptExitCode%
