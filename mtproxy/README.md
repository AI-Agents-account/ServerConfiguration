# MTProxy (MTProto Proxy) — Docker installer

This folder contains a simple installer script for running Telegram **MTProto Proxy (MTProxy)** in Docker on Ubuntu/Debian VPS.

## Requirements

- Docker installed and running
- Root/sudo access
- An open TCP port on the VPS (default: **8443**)

> Note: MTProto is not HTTP; `curl` will not show a “nice” response. Connectivity is checked by opening the TCP port.

## Install

```bash
chmod +x install-mtproxy.sh
sudo ./install-mtproxy.sh
```

### Choose another port

```bash
sudo PORT=4443 ./install-mtproxy.sh
```

## Result

The script prints:
- the generated **SECRET** (also saved at `/opt/mtproxy/secret.hex`)
- a ready Telegram link:

```text
tg://proxy?server=<YOUR_SERVER_IP>&port=<PORT>&secret=<SECRET>
```

Open that link on a device with Telegram to add the proxy.

## Useful commands

```bash
sudo docker ps
sudo docker logs mtproto-proxy --tail 80
```
