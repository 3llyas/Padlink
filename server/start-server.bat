@echo off
cd /d "%~dp0"
python -c "import vgamepad" 2>nul
if errorlevel 1 (
    echo Installing vgamepad - accept the ViGEmBus driver installer if it pops up...
    python -m pip install vgamepad
)
python padlink_server.py %*
pause
