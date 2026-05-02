@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if not errorlevel 1 (
    py -3 "%~dp0local_http_bridge_server.py"
    goto :eof
)

where python >nul 2>nul
if not errorlevel 1 (
    python "%~dp0local_http_bridge_server.py"
    goto :eof
)

echo Python 3 was not found on PATH.
echo Install Python 3 and rerun this launcher.
pause
exit /b 1