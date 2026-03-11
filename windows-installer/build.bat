@echo off
REM ═══════════════════════════════════════════════════════════
REM Build the Orthanc Store-and-Forward Windows Installer
REM ═══════════════════════════════════════════════════════════
REM
REM Prerequisites:
REM   - Python 3.8+ installed and on PATH
REM   - pip install pyinstaller
REM
REM Output: dist\OrthancStoreForwardSetup.exe
REM ═══════════════════════════════════════════════════════════

echo.
echo ╔═══════════════════════════════════════════════════════╗
echo ║  Building Orthanc Store-and-Forward Installer .exe   ║
echo ╚═══════════════════════════════════════════════════════╝
echo.

REM Install dependencies
echo [1/3] Installing dependencies ...
pip install pyinstaller
echo.

REM Build the .exe
echo [2/3] Building executable ...
pyinstaller ^
    --onefile ^
    --windowed ^
    --name "OrthancStoreForwardSetup" ^
    --add-data "icon.ico;." ^
    --clean ^
    installer.py

echo.
echo [3/3] Done!
echo.
echo ═══════════════════════════════════════════════════════
echo   Output: dist\OrthancStoreForwardSetup.exe
echo ═══════════════════════════════════════════════════════
echo.
pause
