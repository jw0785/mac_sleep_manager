## setup

don't manually create plist. instead run

```bash
sudo bash ./setup.sh
```

run

```bash
sudo bash ./uninstall.sh
```

before upgrade

## extra

for mpv ipc handling, make below symlink

```
ln -s [full/path/to]/mpv_auto_socket.lua ~/.config/mpv/scripts/mpv_auto_socket.lua
```