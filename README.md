# SOCKS-over-SSH tunnel

Secure SOCKS5 tunnel through a remote (relay) server to bypass regional
network blocks, e.g. when web-search services reject your local IP.

- **Local machine** (blocked region) — SSH client exposing a SOCKS5 proxy.
- **Remote server** (foreign IP) — stocks an `sshd` and a dedicated,
  restricted tunnel user. Nothing else needs to be installed.

All traffic travels inside an encrypted SSH channel. The SOCKS endpoint
listens only on `127.0.0.1`.

## How it works

`ssh -D` on the local machine binds a SOCKS5 proxy to
`127.0.0.1:1080`. Requests to that port are forwarded through the SSH
connection to the remote server and exit from its public IP. The remote
side runs no additional software: OpenSSH provides the SOCKS endpoint
via dynamic forwarding (`-D`).

For applications that only speak plain HTTP proxying (e.g. the runtime
bundled with OpenCode), set `PROXY_BRIDGE=1` in `config.env` — a tiny
`bridge.py` (pure Python 3) then exposes an `http://` proxy on
`127.0.0.1:18080` that tunnels every connection into the SOCKS endpoint.

## Requirements

- OpenSSH client on the local machine.
- Root access (`sudo`) on the remote server.
- An existing key-based login to the remote server (the setup disables
  password authentication - otherwise you may lock yourself out).
- `curl` locally for the `check` command.
- Python 3 on the local machine only if you use the HTTP bridge.

## Quick start

### 1. Local machine

```bash
cd socks-tunnel
cp config.env config.local.env   # optional: edit settings
./setup-local.sh
```

This generates the keypair `~/.ssh/tunnel` (and `.pub`), appends a
`Host tunnel` block to `~/.ssh/config`, and prints the public key you
need for the next step. It never connects to the remote server.

### 2. Remote server (run manually on that host)

Transfer the script and the public key there:

```bash
scp socks-tunnel/setup-remote.sh ~/.ssh/tunnel.pub user@server:~/
```

Then, on the server:

```bash
sudo ./setup-remote.sh "$(cat ~/tunnel.pub)"
# or, equivalently:
sudo ./setup-remote.sh ~/tunnel.pub
```

The script:

- creates a dedicated user (default `tunnel`) with `nologin` shell;
- installs your key as `restrict,port-forwarding[,from="<allow-list>"]`
  (no PTY, X11 or agent forwarding; when `REMOTE_ALLOW_FROM` is set the
  key works only from the given CIDRs/IPs);
- writes an sshd drop-in, `/etc/ssh/sshd_config.d/60-socks-tunnel.conf`
  (when the distro includes `sshd_config.d`; otherwise appends to
  `/etc/ssh/sshd_config` with a backup), that:
  hardens global settings (`PasswordAuthentication no`,
  `PermitRootLogin no`), optionally restricts `AllowUsers <admin> tunnel`
  (`SSH_ALLOW_USERS=1`), and confines the tunnel user with a
  `Match User tunnel [Address <allow-list>]` block;
- validates the config with `sshd -t` and reloads ssh;
- optionally installs fail2ban and enables ufw (see `INSTALL_FAIL2BAN`
  and `ENABLE_UFW`).

If the server runs an unattended, already-hardened SSH (e.g. custom
drop-ins), you can skip the hardening entirely
(`SSH_HARDEN=0 SSH_ALLOW_USERS=0`) — the input you must always bring is
the tunnel user and its key.

### 3. Back on the local machine

```bash
./tunnel.sh start
./tunnel.sh check        # prints the remote server's public IP
source ./proxy-env.sh    # exports HTTPS_PROXY/ALL_PROXY/NO_PROXY
opencode                 # or any CLI that respects proxy env vars
```

## OpenCode-specific note

The runtime used by OpenCode honours proxy environment variables but only
with an `http://` URL — it ignores `socks5`/`socks5h` schemes. Two options:

- `PROXY_SOCKS5H=1` (default, `socks5h://`): use when your OpenCode build
  does accept the SOCKS scheme (verify with `curl -x socks5h://127.0.0.1:1080 https://api.ipify.org`
  end-to-end through the whole stack).
- `PROXY_BRIDGE=1`: guaranteed — `bridge.py` speaks plain HTTP CONNECT on
  `127.0.0.1:18080` and forwards into the SOCKS tunnel. `proxy-env.sh`
  then exports `http://` URLs. Both `bridge.py` and the tunnel are
  started/stopped by `./tunnel.sh start|stop`.

Keep the LLM provider API domains in `PROXY_BYPASS`
(`NO_PROXY`) so the model API stays on your direct connection.

## Configuration

`config.env` holds the local-side settings: remote host/port, the sudo
user, the tunnel user name, SOCKS address/port, the optional
`REMOTE_ALLOW_FROM` allow-list, DNS mode, the HTTP bridge switch, and
flags for optional remote hardening.

If you already ran the setup once, re-running is safe (idempotent):
keys, config blocks and files are only created when missing.

## Scripts

| File | Purpose |
| --- | --- |
| `setup-local.sh` | Local side: keypair + `~/.ssh/config` block, prints the public key |
| `setup-remote.sh` | Remote side, run manually on the server: user, key, sshd drop-in + hardening |
| `tunnel.sh` | `start` / `stop` / `restart` / `status` / `check` (+ `bridge-start`/`bridge-stop`) |
| `bridge.py` | Local HTTP CONNECT → SOCKS5 forwarder (used when `PROXY_BRIDGE=1`) |
| `proxy-env.sh` | `source` to export proxy env vars for the current shell |
| `config.env` | Configuration values (local and remote) |

## Tunnel management

| Command | Action |
| --- | --- |
| `./tunnel.sh start` | start the tunnel (+ HTTP bridge if enabled) |
| `./tunnel.sh stop` | stop it |
| `./tunnel.sh restart` | restart it |
| `./tunnel.sh status` | process and port status |
| `./tunnel.sh check` | print the public IP reachable through the tunnel |

## Security

- The SOCKS port listens only on `127.0.0.1` (never use `-g` or a
  wildcard bind with `-D`).
- The tunnel key is restricted on the server:
  `restrict,port-forwarding`, and can be bound to a source allow-list
  (`REMOTE_ALLOW_FROM`, e.g. your ISP's announced prefixes).
- The tunnel user is confined to forwarding by a `Match User` sshd
  block; sshd stays hardened (no passwords, no root login).
- With `socks5h` DNS is resolved on the server, so no DNS queries leak
  from the local network.
- Outbound traffic is visible at the remote server - trust it
  accordingly. The tunnel does not add anonymity beyond your trust
  in that server.
- See [SECURITY.md](docs/SECURITY.md) for the full threat model.

## Troubleshooting

See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues:
proxy env vars not picked up, DNS leaks, connection loss, and more.