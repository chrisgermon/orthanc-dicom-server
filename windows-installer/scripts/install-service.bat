@echo off
echo Installing Orthanc Store-and-Forward as a Windows Service ...
echo.

if not exist "C:\Program Files\Orthanc Server\OrthancService.exe" (
    echo ERROR: OrthancService.exe not found.
    echo Please install the official Orthanc Windows package first from:
    echo   https://orthanc.uclouvain.be/downloads/
    pause
    exit /b 1
)

sc create OrthancSF start= auto binPath= "\"C:\Program Files\Orthanc Server\OrthancService.exe\""
sc description OrthancSF "Orthanc Store-and-Forward DICOM Server"

echo.
echo Copying configuration ...
copy /Y "%~dp0Configuration\orthanc.json" "C:\Program Files\Orthanc Server\Configuration\orthanc.json"
if not exist "C:\Program Files\Orthanc Server\Lua" mkdir "C:\Program Files\Orthanc Server\Lua"
copy /Y "%~dp0Lua\store-and-forward.lua" "C:\Program Files\Orthanc Server\Lua\store-and-forward.lua"

echo.
echo Starting service ...
sc start OrthancSF

echo.
echo Done! Orthanc Store-and-Forward is now running as a service.
pause
