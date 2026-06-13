@echo off
setlocal
cd /d "%~dp0"
set "PYEXE=%LOCALAPPDATA%\Python\pythoncore-3.14-64\python.exe"
set "VIDEO_LATENCY=%GVT_VIDEO_LATENCY_MS%"
if "%VIDEO_LATENCY%"=="" set "VIDEO_LATENCY=15"
set "SOURCE_WIDTH=%GVT_SOURCE_WIDTH%"
if "%SOURCE_WIDTH%"=="" set "SOURCE_WIDTH=1024"
set "SOURCE_HEIGHT=%GVT_SOURCE_HEIGHT%"
if "%SOURCE_HEIGHT%"=="" set "SOURCE_HEIGHT=768"

"%PYEXE%" ".\direct-stream\client\stop_local_direct.py" >nul 2>nul
"%PYEXE%" ".\direct-stream\start_input_proxy.py" stop >nul 2>nul
"%PYEXE%" ".\direct-stream\start_gvt_stream_qemu.py" start --restart --port 5004 --fps 60 --bitrate 12000 --capture-ms 16 --idle-capture-ms 16 --idle-after-ms 0 --idle-probe-ms 0 --fec 0 --fec-important 0
start "GVT SPICE Embedded Client" ".\direct-stream\client\gvt_spice_viewer.exe" --video-port 5004 --latency %VIDEO_LATENCY% --spice-host 192.168.0.188 --spice-port 5900 --native-input --invert-case --input-host 192.168.0.188 --input-port 5905 --source-width %SOURCE_WIDTH% --source-height %SOURCE_HEIGHT% --auto-size
