#!/bin/bash
# Uninstaller for Proxy Menubar

PLIST="$HOME/Library/LaunchAgents/com.proxy-menubar.plist"

echo "Uninstalling Proxy Menubar..."

# Remove LaunchAgent
if [ -f "$PLIST" ]; then
    echo "  Removing LaunchAgent..."
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "  LaunchAgent removed."
else
    echo "  LaunchAgent not found."
fi

# Kill running instances
PIDS=$(pgrep -f "ProxyMenubar.app/Contents/MacOS/ProxyMenubar" 2>/dev/null)
if [ -n "$PIDS" ]; then
    echo "  Killing running instances (PIDs: $PIDS)..."
    kill $PIDS 2>/dev/null || true
    echo "  Done."
else
    echo "  No running instances found."
fi

echo ""
echo "To fully remove, delete:"
echo "  /Applications/ProxyMenubar.app   (if installed there)"
echo "  $(dirname "$0")   (this project folder)"
