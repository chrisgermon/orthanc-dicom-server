@echo off
echo Stopping Orthanc Store-and-Forward service ...
net stop OrthancSF 2>NUL
if %errorlevel%==0 (
    echo Service stopped successfully.
) else (
    echo Service is not running or does not exist.
)
pause
