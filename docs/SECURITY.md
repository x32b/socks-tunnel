# Security

This project sets up an SSH-based SOCKS5 tunnel. This document describes
the threat model, what is protected, and what is not.

## Threat model

The goal is to **bypass regional network restrictions** for outbound
requests (web search, HTTP APIs), not to provide anonymity.

Protected:

- Confidentiality of traffic between the local machine and the remote
  server (encrypted by SSH).
- Integrity of connections to the remote server (SSH authenticates the
  server and the client).
- Access to the SOCKS endpoint: it listens only on `127.0.0.1`.

Not protected:

- The remote server operator can see all traffic exiting the server
  (DNS requests, connection targets, plaintext content of non-HTTPS
  traffic).
- The tunnel does not hide the fact that you are connecting to your
  specific remote server.

## Local side

- The SOCKS listener is bound to `127.0.0.1:<port>` only. Never run
  `ssh -D` with `-g` or bind to `0.0.0.0` - that would expose an open
  SOCKS proxy to the whole network.
- There is no authentication at the SOCKS layer (by design). Any local
  process or user able to reach the port can use the proxy. On a
  single-user machine this is acceptable; on a shared machine consider
  whether this is safe for you.
- The SSH key (`~/.ssh/tunnel`) is a dedicated key restricted to
  tunnelling. Protect its permissions (`600`).

## Remote side

`setup-remote.sh` applies:

| Setting | Value | Why |
| --- | --- | --- |
| `PasswordAuthentication` | `no` | prevents password brute force |
| `KbdInteractiveAuthentication` | `no` | disables interactive auth |
| `PermitRootLogin` | `no` | no direct root login |
| `PubkeyAuthentication` | `yes` | keeps key login enabled |
| `AllowUsers` | `<admin> tunnel` | only admin and tunnel user (when `SSH_ALLOW_USERS=1`) |
| key restrictions | `restrict,port-forwarding` | no PTY, X11, agent or command execution via the tunnel key |
| key `from=` | `<REMOTE_ALLOW_FROM>` | key usable only from the allowed sources |
| `Match User tunnel` | `Address <list>`, forwarding-only | confines the tunnel user |

`authorized_keys` for the tunnel user uses `restrict,port-forwarding`,
so the key can only be used for port forwarding - not for a shell,
X11 forwarding or agent forwarding.

When `REMOTE_ALLOW_FROM` is set, the key is additionally wrapped with
`from="<cidr1,cidr2,...>"`, so `sshd` rejects it from any other source
IP. The tunnel user gets a `Match User` block (with the same `Address`
list) that forces publickey auth and limits `AllowTcpForwarding local`,
blocking any other feature of sshd for that account. The block ends with
`Match all` so it cannot leak into following drop-in files.

Configuration goes to a drop-in, `/etc/ssh/sshd_config.d/60-socks-tunnel.conf`,
when the distro includes `sshd_config.d`; otherwise it is appended to
`/etc/ssh/sshd_config`. Either way the previous file is backed up as
`*.bak.pre-tunnel` on first run, and `sshd -t` must pass before the
service is reloaded.

## DNS

SSH dynamic forwarding relies on the client for DNS resolution unless the
application asks for remote DNS (`socks5h`). With `PROXY_SOCKS5H=1`
(default) `proxy-env.sh` exports `socks5h://` URLs, so DNS is resolved on
the remote server and nothing leaks from the local (blocked) network. The
`check` command uses `socks5h://`. Tools that ignore the `socks5h` scheme
resolve locally — for those use the HTTP bridge (`PROXY_BRIDGE=1`), whose
CONNECT requests carry only IP-in-DNS or hostnames that the SOCKS server
resolves remotely; see TROUBLESHOOTING.md.

## Recommendations

- Use ed25519 keys.
- Keep OpenSSH up to date on the server.
- If possible, restrict SSH access with a firewall (ufw is optional via
  `ENABLE_UFW` in `setup-remote.sh`) and consider fail2ban
  (`INSTALL_FAIL2BAN=1`).
- Verify key-based login still works **before** closing the terminal
  after running `setup-remote.sh`.