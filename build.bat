@echo off
echo Building ProxyMenubar for Windows...
dotnet publish -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true /p:PublishReadyToRun=true
if %errorlevel% equ 0 (
    echo.
    echo Build successful!
    echo Output: bin\Release\net6.0-windows\win-x64\publish\ProxyMenubar.exe
) else (
    echo.
    echo Build failed!
)
pause
