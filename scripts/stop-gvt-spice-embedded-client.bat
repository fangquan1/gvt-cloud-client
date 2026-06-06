@echo off
setlocal
cd /d "%~dp0"
set "PYEXE=%LOCALAPPDATA%\Python\pythoncore-3.14-64\python.exe"

"%PYEXE%" ".\direct-stream\start_gvt_stream_qemu.py" stop
"%PYEXE%" ".\direct-stream\start_input_proxy.py" stop
"%PYEXE%" ".\direct-stream\client\stop_local_direct.py" >nul 2>nul
