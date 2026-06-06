@echo off
setlocal

set "ROOT=%~dp0..\.."
set "GSTROOT=%ROOT%\tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64"
set "PATH=%GSTROOT%\bin;%PATH%"
set "GST_PLUGIN_PATH=%GSTROOT%\lib\gstreamer-1.0"
set "GST_PLUGIN_SYSTEM_PATH_1_0=%GSTROOT%\lib\gstreamer-1.0"
set "GST_REGISTRY=%ROOT%\tools\gst-registry-gvt-direct.bin"

set "PORT=%~1"
if "%PORT%"=="" set "PORT=5004"
set "LATENCY=%~2"
if "%LATENCY%"=="" set "LATENCY=50"

gst-launch-1.0.exe -e -v ^
  udpsrc port=%PORT% buffer-size=4194304 caps="application/x-rtp, media=(string)video, clock-rate=(int)90000, encoding-name=(string)H264, payload=(int)96, ssrc=(uint)2222" ^
  ! rtpstorage size-time=1000000000 name=storage ^
  ! rtpjitterbuffer latency=%LATENCY% drop-on-latency=false do-lost=true faststart-min-packets=2 ^
  ! rtpulpfecdec pt=122 ^
  ! rtph264depay ^
  ! h264parse ^
  ! d3d11h264dec ^
  ! d3d11videosink sync=false

if errorlevel 1 (
  echo.
  echo Hardware decode path failed, trying software decoder...
  gst-launch-1.0.exe -e -v ^
    udpsrc port=%PORT% buffer-size=4194304 caps="application/x-rtp, media=(string)video, clock-rate=(int)90000, encoding-name=(string)H264, payload=(int)96, ssrc=(uint)2222" ^
    ! rtpstorage size-time=1000000000 name=storage ^
    ! rtpjitterbuffer latency=%LATENCY% drop-on-latency=false do-lost=true faststart-min-packets=2 ^
    ! rtpulpfecdec pt=122 ^
    ! rtph264depay ^
    ! h264parse ^
    ! avdec_h264 ^
    ! videoconvert ^
    ! autovideosink sync=false
)
