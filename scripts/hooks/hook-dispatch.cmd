@echo off
REM hook-dispatch.cmd — Windows fallback: finds Git Bash and forwards to hook-dispatch.sh
REM Usage: hook-dispatch.cmd <hook-name> [args...]

setlocal

REM Try bash on PATH first (Git Bash installed with PATH option)
where bash >nul 2>nul
if %ERRORLEVEL% equ 0 (
    bash "%~dp0hook-dispatch.sh" %*
    exit /b %ERRORLEVEL%
)

REM Try to find Git Bash via git location
where git >nul 2>nul
if %ERRORLEVEL% equ 0 (
    for /f "delims=" %%i in ('where git') do set "GIT_EXE=%%i"
    for %%i in ("%GIT_EXE%") do set "GIT_DIR=%%~dpi.."
    "%GIT_DIR%\bin\bash.exe" "%~dp0hook-dispatch.sh" %*
    exit /b %ERRORLEVEL%
)

echo ERROR: Git Bash not found. Install Git for Windows. >&2
exit /b 1
