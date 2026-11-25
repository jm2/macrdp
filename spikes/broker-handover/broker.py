#!/usr/bin/env python3
"""Spike C toy broker: accept RDP connections, hand each one to the instance
for the current console session, and move the live session on a switch.

Fork-only spike for docs/fork/PLAN.md (Phase 0, Spike C). It never reads a
byte of RDP: it accepts TCP, passes the socket over a Unix socket (SCM_RIGHTS)
and closes its own copy. In Phase 2 this becomes a root LaunchDaemon; here it
runs as the user so the handover and the client's reconnect can be measured.

macrdp instances connect with --listen-from-broker <dir>/instances.sock
--broker-instance <name>. The protocol is in src/broker_source.rs.

Control (one command per line on <dir>/control.sock, e.g. with ctl.sh):
  status
  switch <name> redirect <address>  Server Redirection PDU to <address>
  switch <name> drop                end the connection like a network failure
  switch <name> errinfo             Set Error Info "disconnected by another connection"
  switch <name> none                route new connections only; leave the session

With --follow-console the broker polls the owner of /dev/console and switches
by itself: owner root means the login window (instance "loginwindow"), any
other owner means instance "user:<name>". --move picks the method.
"""

import argparse
import os
import pwd
import socket
import threading
import time

MSG_LEN = 64
T0 = time.monotonic()


def log(*parts):
    print(f"[{(time.monotonic() - T0) * 1000:9.0f} ms]", *parts, flush=True)


def msg(text):
    data = text.encode()
    if len(data) > MSG_LEN:
        raise ValueError(f"message too long: {text}")
    return data.ljust(MSG_LEN)


class Broker:
    def __init__(self, move_target):
        self.lock = threading.Lock()
        self.instances = {}  # name -> socket
        self.current = None
        self.last_move = None  # (time, from, to, method)
        self.move_target = move_target

    # --- instances -------------------------------------------------------
    def register(self, name, sock):
        with self.lock:
            old = self.instances.get(name)
            self.instances[name] = sock
            if self.current is None:
                self.current = name
        if old is not None:
            old.close()
        log(f"instance '{name}' registered" + (" (current)" if self.current == name else ""))

    def unregister(self, name, sock):
        with self.lock:
            if self.instances.get(name) is sock:
                del self.instances[name]
                log(f"instance '{name}' went away")

    # --- connections -----------------------------------------------------
    def route(self, conn, peer):
        with self.lock:
            name = self.current
            sock = self.instances.get(name) if name else None
            since = None
            if self.last_move:
                since = (time.monotonic() - self.last_move[0]) * 1000
        where = f"{peer[0]}:{peer[1]}"
        after = f", {since:.0f} ms after the last move" if since is not None else ""
        if sock is None:
            log(f"connection from {where}: no instance for '{name}', closing{after}")
            conn.close()
            return
        try:
            socket.send_fds(sock, [msg("CONN")], [conn.fileno()])
            log(f"connection from {where} -> '{name}'{after}")
        except OSError as e:
            log(f"connection from {where}: handing to '{name}' failed: {e}")
        finally:
            conn.close()

    # --- switching -------------------------------------------------------
    def switch(self, new, method, arg=None):
        with self.lock:
            old = self.current
            old_sock = self.instances.get(old) if old else None
            self.current = new
            self.last_move = (time.monotonic(), old, new, method)
        command = {
            "redirect": f"MOVE redirect {arg or self.move_target}",
            "drop": "MOVE drop",
            "errinfo": "MOVE errinfo",
            "none": None,
        }[method]
        sent = ""
        if command and old_sock is not None and old != new:
            try:
                old_sock.sendall(msg(command))
                sent = f", told '{old}': {command}"
            except OSError as e:
                sent = f", telling '{old}' failed: {e}"
        log(f"switch '{old}' -> '{new}' ({method}){sent}")
        return f"ok: '{old}' -> '{new}' ({method}){sent}"

    def status(self):
        with self.lock:
            return f"current={self.current} instances={sorted(self.instances)}"


def unix_listener(path):
    # macOS caps AF_UNIX paths at 104 bytes; bind fails loudly if --dir is too deep.
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, 0o600)
    srv.listen()
    return srv


def serve_instances(broker, srv):
    while True:
        sock, _ = srv.accept()
        threading.Thread(target=instance_session, args=(broker, sock), daemon=True).start()


def instance_session(broker, sock):
    data = b""
    while len(data) < MSG_LEN:
        chunk = sock.recv(MSG_LEN - len(data))
        if not chunk:
            sock.close()
            return
        data += chunk
    words = data.decode(errors="replace").split()
    if len(words) != 2 or words[0] != "HELLO":
        log(f"bad hello {words!r}")
        sock.close()
        return
    name = words[1]
    broker.register(name, sock)
    try:
        while sock.recv(MSG_LEN):  # instances send nothing more; wait for EOF
            pass
    except OSError:
        pass
    broker.unregister(name, sock)


def serve_tcp(broker, srv):
    while True:
        conn, peer = srv.accept()
        broker.route(conn, peer)


def serve_control(broker, srv):
    while True:
        conn, _ = srv.accept()
        with conn:
            line = conn.makefile().readline().split()
            try:
                if line == ["status"]:
                    reply = broker.status()
                elif len(line) >= 3 and line[0] == "switch":
                    reply = broker.switch(line[1], line[2], line[3] if len(line) > 3 else None)
                else:
                    reply = "usage: status | switch <name> redirect [addr]|drop|errinfo|none"
            except (KeyError, ValueError) as e:
                reply = f"error: {e}"
            conn.sendall((reply + "\n").encode())


def console_instance():
    uid = os.stat("/dev/console").st_uid
    if uid == 0:
        return "loginwindow"
    try:
        return f"user:{pwd.getpwuid(uid).pw_name}"
    except KeyError:
        return f"user:{uid}"


def follow_console(broker, method, interval):
    seen = console_instance()
    log(f"console is '{seen}'")
    with broker.lock:
        if broker.current is None:
            broker.current = seen
    while True:
        time.sleep(interval)
        now = console_instance()
        if now != seen:
            log(f"console changed: '{seen}' -> '{now}'")
            broker.switch(now, method)
            seen = now


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--listen", default="127.0.0.1:3392", help="host:port for RDP (default %(default)s)")
    ap.add_argument("--dir", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "macrdp-broker"),
                    help="directory for instances.sock and control.sock (default %(default)s)")
    ap.add_argument("--redirect-to", help="address a redirect points at (default: the --listen host)")
    ap.add_argument("--follow-console", action="store_true", help="switch when /dev/console changes owner")
    ap.add_argument("--move", default="drop", choices=["redirect", "drop", "errinfo", "none"],
                    help="how --follow-console moves the session (default %(default)s)")
    args = ap.parse_args()

    host, port = args.listen.rsplit(":", 1)
    os.makedirs(args.dir, mode=0o700, exist_ok=True)
    os.chmod(args.dir, 0o700)
    inst_path = os.path.join(args.dir, "instances.sock")
    ctl_path = os.path.join(args.dir, "control.sock")
    for p in (inst_path, ctl_path):
        if os.path.exists(p):
            os.unlink(p)

    # Bind everything before starting threads, so a failure stops the broker.
    inst_srv = unix_listener(inst_path)
    ctl_srv = unix_listener(ctl_path)
    tcp_srv = socket.create_server((host, int(port)))
    broker = Broker(args.redirect_to or host)
    threading.Thread(target=serve_instances, args=(broker, inst_srv), daemon=True).start()
    threading.Thread(target=serve_control, args=(broker, ctl_srv), daemon=True).start()
    if args.follow_console:
        threading.Thread(target=follow_console, args=(broker, args.move, 0.5), daemon=True).start()
    log(f"instances: {inst_path}  control: {ctl_path}")
    log(f"listening for RDP on {host}:{port}")
    serve_tcp(broker, tcp_srv)


if __name__ == "__main__":
    main()
