#!/bin/bash

PLIST_PATH="/Library/LaunchDaemons/local.me.sleep_manager.plist"
BIN_LINK="/usr/local/bin/sleep_manager"

echo "Unloading launchd daemon..."
sudo launchctl unload "$PLIST_PATH" 2>/dev/null

echo "Removing plist..."
sudo rm -f "$PLIST_PATH"

echo "Removing executable..."
sudo rm -f "$BIN_LINK"

echo "Uninstall complete"
