@echo off
echo Uninstalling Proxy Menubar...

echo   Stopping ProxyMenubar.exe...
taskkill /f /im ProxyMenubar.exe 2>nul
if %errorlevel% equ 0 (
    echo     Stopped.
) else (
    echo     Not running.
)

echo   Cleaning up SSH tunnel (port 1080)...
for /f "tokens=5" %%a in ('netstat -ano ^| findstr :1080 ^| findstr LISTENING') do (
    taskkill /f /pid %%a 2>nul
    echo     Killed SSH process with PID %%a.
)

echo.
echo To fully remove, please manually delete the application folder or:
echo   bin\Release\net6.0-windows\win-x64\publish\ProxyMenubar.exe
echo.
echo Done!
pause
