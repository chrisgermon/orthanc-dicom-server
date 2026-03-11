@echo off
echo Starting Orthanc Store-and-Forward ...
echo.
echo Press Ctrl+C to stop.
echo.
"%~dp0Orthanc.exe" --config="%~dp0Configuration"
pause
