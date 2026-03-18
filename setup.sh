#!/bin/bash

# Get the absolute path of the directory containing this setup script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPT_TARGET="$DIR/sleep_manager.sh"
BIN_LINK="/usr/local/bin/sleep_manager"
PLIST_PATH="/Library/LaunchDaemons/local.me.sleep_manager.plist"

echo "Making script executable..."
chmod +x "$SCRIPT_TARGET"

echo "Copying script to $BIN_LINK..."
# Requires sudo to write to /usr/local/bin
sudo cp "$SCRIPT_TARGET" "$BIN_LINK"
sudo chmod +x "$BIN_LINK"

echo "Generating launchd plist at $PLIST_PATH..."
sudo bash -c "cat << 'PLIST_EOF' > \"$PLIST_PATH\"
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>local.me.sleep_manager</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/bin/sleep_manager</string>
    </array>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>KeepAlive</key>
    <true/>
    
    <key>StandardOutPath</key>
    <string>/tmp/sleep_manager.log</string>
    
    <key>StandardErrorPath</key>
    <string>/tmp/sleep_manager.err</string>
</dict>
</plist>
PLIST_EOF"

echo "Setting correct permissions for Daemon..."
sudo chown root:wheel "$PLIST_PATH"

echo "Loading launchd daemon..."
# Unload it first just in case it already exists
sudo launchctl unload "$PLIST_PATH" 2>/dev/null
sudo launchctl load -w "$PLIST_PATH"

echo "Setup complete"
