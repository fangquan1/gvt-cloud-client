@echo off
setlocal
cd /d "%~dp0"
set "PYEXE=%LOCALAPPDATA%\Python\pythoncore-3.14-64\python.exe"
set "VIDEO_LATENCY=%GVT_VIDEO_LATENCY_MS%"
if "%VIDEO_LATENCY%"=="" set "VIDEO_LATENCY=0"
set "SOURCE_WIDTH=%GVT_SOURCE_WIDTH%"
if "%SOURCE_WIDTH%"=="" set "SOURCE_WIDTH=1920"
set "SOURCE_HEIGHT=%GVT_SOURCE_HEIGHT%"
if "%SOURCE_HEIGHT%"=="" set "SOURCE_HEIGHT=1200"
set "VIDEO_CODEC=%GVT_VIDEO_CODEC%"
if "%VIDEO_CODEC%"=="" set "VIDEO_CODEC=h264"
set "GVT_SPICE_VIEWER_UDP_BUFFER_SIZE=%GVT_VIDEO_UDP_BUFFER_SIZE%"
if "%GVT_SPICE_VIEWER_UDP_BUFFER_SIZE%"=="" set "GVT_SPICE_VIEWER_UDP_BUFFER_SIZE=524288"

"%PYEXE%" ".\direct-stream\client\stop_local_direct.py" >nul 2>nul
"%PYEXE%" ".\direct-stream\start_input_proxy.py" stop >nul 2>nul
"%PYEXE%" ".\direct-stream\start_gvt_stream_qemu.py" start --restart --port 5004 --rtp-mtu 1400 --fps 60 --bitrate 18000 --video-codec %VIDEO_CODEC% --keyint 60 --capture-ms 16 --idle-capture-ms 66 --idle-after-ms 1500 --idle-probe-ms 500 --idle-changed-ppm 3000 --idle-pixel-delta 8 --fec 0 --fec-important 0
start "GVT SPICE Embedded Client - Power Save" ".\direct-stream\client\gvt_spice_viewer.exe" --video-codec %VIDEO_CODEC% --video-port 5004 --latency %VIDEO_LATENCY% --spice-host 192.168.0.188 --spice-port 5900 --native-input --invert-case --input-host 192.168.0.188 --input-port 5905 --source-width %SOURCE_WIDTH% --source-height %SOURCE_HEIGHT% --auto-size
