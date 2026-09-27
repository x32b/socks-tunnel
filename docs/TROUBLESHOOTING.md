# Troubleshooting

## The `check` command fails

```bash
./tunnel.sh check
```

- Confirm the tunnel is running: `./tunnel.sh status`.
- Check the SSH log: `cat run/tunnel.log` after `./tunnel.sh start`.
- Test the SOCKS endpoint directly:
  ```bash
  curl -x socks5h://127.0.0.1:1080 https://api.ipify.org
  ```
- Test the SSH connection without the proxy:
  ```bash
  ssh -N tunnel -v   # watch "Local forwarding listening on ..."
  ```

## ssh: Permission denied (publickey)

The tunnel key is not installed on the server or is restricted:

- Verify the key on the server:
  ```bash
  sudo grep -c "socks-tunnel\|ssh-ed25519" /home/tunnel/.ssh/authorized_keys
  ```
- Re-run `setup-remote.sh` with the correct key on the server.
- If `AllowUsers` was applied and your admin account is missing from it,
  you can edit `/etc/ssh/sshd_config` and restart sshd from the web
  console.

## Password login is disabled and I lost access

You must use the server's out-of-band console (web/panel console).

- Restore the backup. With drop-ins (`sshd_config.d`) remove/sanitize
  `/etc/ssh/sshd_config.d/60-socks-tunnel.conf` (backed up as
  `60-socks-tunnel.conf.bak.pre-tunnel`) and restart ssh. Without
  drop-ins: `cp /etc/ssh/sshd_config.bak.pre-tunnel
  /etc/ssh/sshd_config && systemctl restart ssh`.
- Or re-enable password auth, then add a proper key before hardening
  again (use the pre-tunnel backup as a reference).

## Local opencode does not use the tunnel

- Proxy env vars must be exported in the same shell that launches
  opencode:
  ```bash
  source socks-tunnel/proxy-env.sh
  opencode
  ```
- The TUI talks to a local HTTP server - it must bypass the proxy.
  `proxy-env.sh` already sets `NO_PROXY=localhost,127.0.0.1`; do not
  remove it, otherwise you get routing loops.
- Some tools read `all_proxy`/`ALL_PROXY`. The script sets `ALL_PROXY`
  as well. If a specific tool still ignores proxies, check its docs and
  set its `HTTPS_PROXY`/`ALL_PROXY` explicitly.

## opencode ignores socks5/socks5h (Bun runtime)

The runtime bundled with OpenCode honours proxy env vars only as an
`http://` URL and silently ignores `socks5`/`socks5h` schemes, so the
tunnel seems dead while `curl -x socks5h://...` works.

Fix: enable the HTTP bridge.

- `config.env`: `PROXY_BRIDGE=1` (leave `PROXY_SOCKS5H=1`; the bridge
  uses the SOCKS endpoint regardless of the scheme string).
- `./tunnel.sh restart` — it now also starts/restarts `bridge.py`,
  which listens on `127.0.0.1:18080` and forwards every CONNECT/HTTP
  request into the SOCKS tunnel.
- `source ./proxy-env.sh` again — you will see `Proxy env vars set to
  http://127.0.0.1:18080`.
- Verify end-to-end before blaming opencode:
  ```bash
  curl -x http://127.0.0.1:18080 https://api.ipify.org
  ```
  The answer must be the **remote** server's IP.

## HTTP bridge is not listening / WARN in proxy-env.sh

- The bridge only starts when `PROXY_BRIDGE=1` in `config.env` before
  `tunnel.sh start`. `tunnel.sh` also has dedicated
  `./tunnel.sh bridge-start` / `bridge-stop`.
- The bridge always binds `127.0.0.1`; if something else owns `BRIDGE_PORT`
  on loopback, change `BRIDGE_PORT` in `config.env` on conflict.
- Check its log and status:
  ```bash
  ./tunnel.sh status        # shows "Port 18080 (http bridge): listening"
  cat run/bridge.log
  ```
- `ss -tln | grep 18080` — find who owns the port; change
  `BRIDGE_PORT` in `config.env` on conflict.
- `bridge.py` needs Python 3; the script refuses to start without it.

## DNS still resolves via the blocking network

With the default `PROXY_SOCKS5H=1` DNS is handled on the remote server
(`socks5h://`) and nothing leaks from the local network. Two ways to end
up with local DNS despite this:

- The tool does not understand the `socks5h` scheme (OpenCode/Bun
  ignores it) and falls back to local resolution and IP addresses. Use
  the HTTP bridge (`PROXY_BRIDGE=1`) — tunnel.sh + bridge.py route those
  connections through the tunnel with remote DNS.
- You set `PROXY_SOCKS5H=0`, which intentionally switches to local
  resolution (`socks5://`). Only do this when local DNS is trustworthy.

## Tunnel drops after idle time

The generated SSH config block already sets:

```
ServerAliveInterval 30
ServerAliveCountMax 3
```

If drops persist (e.g. NAT timeouts on the host network), increase the
interval or count in `~/.ssh/config` under `Host tunnel`, then
`./tunnel.sh restart`.

## Port 1080 already in use

```bash
ss -tlnp | grep 1080     # find the process
```

Change `LOCAL_SOCKS_PORT` in `config.env`, delete the old `Host tunnel`
block in `~/.ssh/config` (or update its `DynamicForward` line), then run
`./setup-local.sh` again.

## sshd did not restart after setup

- Numbers for service names differ across distros (`ssh` vs `sshd`).
  Restart manually:
  ```bash
  sudo systemctl restart ssh || sudo systemctl restart sshd || sudo service sshd restart
  ```
- Any syntax error would have been caught by `sshd -t`; if it refused,
  restore the backup config and inspect it. Note that drop-in files are
  read in `sshd_config.d` order: a later file can override an earlier
  one — our block always ends with `Match all`.