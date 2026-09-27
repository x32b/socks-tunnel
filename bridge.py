#!/usr/bin/env python3
"""Local HTTP proxy that forwards connections through a local SOCKS5 tunnel.

Some runtimes (e.g. the one bundled with OpenCode / Bun) honour HTTPS_PROXY
but only accept an `http://` URL and may ignore socks5/socks5h schemes.
This tool exposes plain HTTP CONNECT proxying on 127.0.0.1 and relays every
tunnel through the local SOCKS5 listener started by `ssh -D` / tunnel.sh.

Pure Python 3 standard library - no pip dependencies.
The HTTP listener ALWAYS binds 127.0.0.1 (loopback only) - this is not
configurable, so the bridge can never become an open proxy for the LAN.
Usage:  python3 bridge.py --port 18080 --socks 127.0.0.1:1080
"""
import argparse
import os
import select
import socket
import socketserver
import sys
import threading

DEBUG = os.environ.get("BRIDGE_DEBUG") == "1"


def _dbg(msg):
    if DEBUG:
        sys.stderr.write("bridge: %s\n" % msg)
        sys.stderr.flush()


class SocksError(Exception):
    pass


def socks5_connect(socks_addr, host, port, timeout=15.0):
    s = socket.create_connection(socks_addr, timeout=timeout)
    try:
        s.sendall(b"\x05\x01\x00")
        if s.recv(2) != b"\x05\x00":
            raise SocksError("SOCKS5: no acceptable auth method")

        if isinstance(host, bytes):
            host = host.decode("idna")
        if isinstance(host, str):
            host = host.encode("idna")
            req = b"\x05\x01\x00\x03" + bytes([len(host)]) + host
        else:
            req = b"\x05\x01\x00\x01" + host
        req += port.to_bytes(2, "big")
        s.sendall(req)

        rep = s.recv(4)
        if len(rep) < 4:
            raise SocksError("SOCKS5: short reply")
        if rep[1] != 0x00:
            raise SocksError("SOCKS5: connect failed (code %d)" % rep[1])
        atyp = rep[3]
        if atyp == 0x01:
            s.recv(4)
        elif atyp == 0x04:
            s.recv(16)
        elif atyp == 0x03:
            n = s.recv(1)[0]
            s.recv(n)
        s.recv(2)
        return s
    except Exception:
        s.close()
        raise


def relay(a, b):
    sockets = [a, b]
    try:
        while True:
            r, _, _ = select.select(sockets, [], [])
            for s in r:
                data = s.recv(65536)
                if not data:
                    _dbg("EOF on %s" % id(s))
                    return
                peer = b if s is a else a
                peer.sendall(data)
                _dbg("relay %d %s->%s  first=%s" % (
                    len(data), id(s), id(peer), data[:16].hex()))
    finally:
        for s in sockets:
            try:
                s.close()
            except OSError:
                pass


def read_request(client, timeout=15.0):
    client.settimeout(timeout)
    buf = b""
    while b"\r\n\r\n" not in buf and len(buf) < 65536:
        chunk = client.recv(65536)
        if not chunk:
            break
        buf += chunk
    head, sep, rest = buf.partition(b"\r\n\r\n")
    return head, rest


def split_hostport(h):
    """Parse a Host/CONNECT host[:port] value; default port 80/443 caller side."""
    if h.startswith(b"["):
        close = h.find(b"]")
        if close == -1:
            raise SocksError("bad IPv6 host")
        host = h[1:close]
        rest = h[close + 1:]
        return host, int(rest[1:]) if rest.startswith(b":") else 80
    if h.count(b":") == 1:
        host, sep, p = h.rpartition(b":")
        if p.isdigit():
            return host, int(p)
    return h, 80


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            client = self.request
            head, rest = read_request(client)
            if not head:
                return
            lines = head.split(b"\r\n")
            request_line = lines[0]
            verb = request_line.split(b" ", 1)[0].upper()

            headers = {}
            for ln in lines[1:]:
                if b":" in ln:
                    k, v = ln.split(b":", 1)
                    headers[k.strip().lower()] = v.strip()

            if verb == b"CONNECT":
                # target line: CONNECT host:port HTTP/1.1
                hostport = request_line.split(b" ", 2)[1]
                host, port = split_hostport(hostport)
                ups = socks5_connect(SOCKS, host, port)
                client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                if rest:
                    ups.sendall(rest)
                relay(client, ups)
                return

            # Plain HTTP:  GET /path HTTP/1.1 with Host header
            if headers.get(b"host"):
                host, port = split_hostport(headers[b"host"])
                # strip an explicit scheme+host from absolute-form targets
                parts = request_line.split(b" ")
                if len(parts) >= 2 and parts[1].lower().startswith(b"http://"):
                    from urllib.parse import urlsplit
                    u = urlsplit(parts[1].decode("ascii"))
                    if (u.netloc or "").lower() != headers[b"host"].lower().decode("ascii"):
                        raise SocksError("target mismatch")
                    parts[1] = ((u.path or "/") + (("?" + u.query) if u.query else "")).encode("ascii")
                    head = b" ".join(parts) + b"\r\n" + b"\r\n".join(lines[1:])
                ups = socks5_connect(SOCKS, host, port)
                ups.sendall(head + b"\r\n\r\n" + rest)
                relay(client, ups)
                return

            client.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        except Exception as e:
            try:
                self.request.sendall(
                    b"HTTP/1.1 502 Bad Gateway\r\n\r\n%r" % (e,))
            except OSError:
                pass


class Threaded(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


BIND_ADDR = "127.0.0.1"  # loopback only, deliberately not configurable


def is_loopback(host):
    """True when host is a loopback address (IP or hostname resolving only to loopback)."""
    if host in ("localhost", "127.0.0.1", "::1"):
        return True
    if host.startswith("127."):
        octets = host.split(".")
        return len(octets) == 4 and all(o.isdigit() and 0 <= int(o) <= 255 for o in octets)
    try:
        addrs = socket.getaddrinfo(host, 1, socket.AF_UNSPEC, socket.SOCK_STREAM)
    except socket.gaierror:
        return False
    return addrs and all(
        (a[4][0] == "::1") or a[4][0].startswith("127.")
        for a in addrs)


def main():
    global SOCKS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--socks", default="127.0.0.1:1080")
    args = ap.parse_args()
    host, _, port = args.socks.rpartition(":")
    if not is_loopback(host):
        sys.exit("refusing to use a non-loopback SOCKS address: %s (bridge is local-only)" % args.socks)
    SOCKS = (host, int(port))
    try:
        Threaded((BIND_ADDR, args.port), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()