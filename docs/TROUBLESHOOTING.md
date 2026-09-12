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

- Restore the backup: `cp /etc/ssh/sshd_config.bak.pre-tunnel
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

## DNS still resolves via the blocking network

SSH dynamic forwarding resolves DNS on the client unless the proxy URL
uses `socks5h://`. Use `socks5h://127.0.0.1:1080` for tools that
support it. For HTTPS traffic DNS does not leak the request content, but
the resolved IPs do come from the local (blocked) network.

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
  restore the backup config and inspect it.