@echo off
setlocal
cd /d "%~dp0\.."

set "GVT_CONSOLE_HOST=127.0.0.1"
set "GVT_CONSOLE_PORT=5177"

npm run build
if errorlevel 1 exit /b %errorlevel%

start "GVT Cloud Client Service" /min node ".\scripts\launcher-server.mjs"
powershell -NoProfile -Command "Start-Sleep -Milliseconds 800; Start-Process 'http://127.0.0.1:5177/'"
