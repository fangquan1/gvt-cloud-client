@echo off
setlocal
cd /d "%~dp0"
set "PYEXE=%LOCALAPPDATA%\Python\pythoncore-3.14-64\python.exe"
set "VIDEO_LATENCY=%GVT_VIDEO_LATENCY_MS%"
if "%VIDEO_LATENCY%"=="" set "VIDEO_LATENCY=15"
set "SOURCE_WIDTH=%GVT_SOURCE_WIDTH%"
if "%SOURCE_WIDTH%"=="" set "SOURCE_WIDTH=1920"
set "SOURCE_HEIGHT=%GVT_SOURCE_HEIGHT%"
if "%SOURCE_HEIGHT%"=="" set "SOURCE_HEIGHT=1200"
set "VIDEO_CODEC=%GVT_VIDEO_CODEC%"
if "%VIDEO_CODEC%"=="" set "VIDEO_CODEC=h264"
set "GVT_SPICE_VIEWER_DROP_COMPLETE_FRAMES=1"
set "GVT_SPICE_VIEWER_UDP_BUFFER_SIZE=%GVT_VIDEO_UDP_BUFFER_SIZE%"
if "%GVT_SPICE_VIEWER_UDP_BUFFER_SIZE%"=="" set "GVT_SPICE_VIEWER_UDP_BUFFER_SIZE=524288"
set "GVT_SPICE_VIEWER_VIDEO_TAIL=queue name=post_decode_q leaky=downstream max-size-buffers=1 max-size-time=0 max-size-bytes=0 ! d3d11videosink name=vsink sync=false async=false qos=true max-lateness=0 processing-deadline=0 render-delay=0 enable-last-sample=false"

"%PYEXE%" ".\direct-stream\client\stop_local_direct.py" >nul 2>nul
"%PYEXE%" ".\direct-stream\start_input_proxy.py" stop >nul 2>nul
"%PYEXE%" ".\direct-stream\start_gvt_stream_qemu.py" start --restart --port 5004 --fps 59 --bitrate 18000 --video-codec %VIDEO_CODEC% --keyint 59 --capture-ms 17 --idle-capture-ms 66 --idle-after-ms 1500 --idle-probe-ms 500 --idle-changed-ppm 3000 --idle-pixel-delta 8 --fec 0 --fec-important 0
if errorlevel 1 (
    set "CLIENT_EXIT=1"
    goto cleanup
)

start "GVT SPICE Embedded Client - Power Save" /wait /b ".\direct-stream\client\gvt_spice_viewer.exe" --video-codec %VIDEO_CODEC% --video-port 5004 --latency %VIDEO_LATENCY% --spice-host 192.168.0.188 --spice-port 5900 --native-input --invert-case --input-host 192.168.0.188 --input-port 5905 --source-width %SOURCE_WIDTH% --source-height %SOURCE_HEIGHT% --auto-size
set "CLIENT_EXIT=%ERRORLEVEL%"

:cleanup
"%PYEXE%" ".\direct-stream\start_gvt_stream_qemu.py" stop
"%PYEXE%" ".\direct-stream\start_input_proxy.py" stop
"%PYEXE%" ".\direct-stream\client\stop_local_direct.py" >nul 2>nul
exit /b %CLIENT_EXIT%
