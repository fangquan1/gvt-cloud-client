@echo off
setlocal

set "ROOT=%~dp0..\.."
set "GSTROOT=%ROOT%\tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64"
set "PATH=%GSTROOT%\bin;%PATH%"
set "GST_PLUGIN_PATH=%GSTROOT%\lib\gstreamer-1.0"
set "GST_PLUGIN_SYSTEM_PATH_1_0=%GSTROOT%\lib\gstreamer-1.0"
set "GST_REGISTRY=%ROOT%\tools\gst-registry-gvt-direct.bin"

set "PORT=%~1"
if "%PORT%"=="" set "PORT=5006"
set "LATENCY=%~2"
if "%LATENCY%"=="" set "LATENCY=40"

gst-launch-1.0.exe -e -v ^
  udpsrc port=%PORT% buffer-size=262144 caps="application/x-rtp, media=(string)audio, clock-rate=(int)48000, encoding-name=(string)OPUS, payload=(int)97, ssrc=(uint)3333" ^
  ! rtpjitterbuffer latency=%LATENCY% drop-on-latency=true do-lost=true faststart-min-packets=2 ^
  ! rtpopusdepay ^
  ! opusdec plc=true ^
  ! audioconvert ^
  ! audioresample ^
  ! wasapisink sync=false low-latency=true buffer-time=40000 latency-time=10000

if errorlevel 1 (
  echo.
  echo WASAPI low latency path failed, trying DirectSound...
  gst-launch-1.0.exe -e -v ^
    udpsrc port=%PORT% buffer-size=262144 caps="application/x-rtp, media=(string)audio, clock-rate=(int)48000, encoding-name=(string)OPUS, payload=(int)97, ssrc=(uint)3333" ^
    ! rtpjitterbuffer latency=%LATENCY% drop-on-latency=true do-lost=true faststart-min-packets=2 ^
    ! rtpopusdepay ^
    ! opusdec plc=true ^
    ! audioconvert ^
    ! audioresample ^
    ! directsoundsink sync=false
)
