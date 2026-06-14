@echo off
setlocal
cd /d "%~dp0\.."
node scripts\package-portable.mjs
