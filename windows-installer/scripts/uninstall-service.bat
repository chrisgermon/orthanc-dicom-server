@echo off
echo Removing Orthanc Store-and-Forward service ...
net stop OrthancSF 2>NUL
sc delete OrthancSF
echo.
echo Service removed.
pause
