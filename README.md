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

for mpv ipc handling, add the following to your `mpv.conf` to open a socket

```
input-ipc-server=/tmp/mpvsocket
```