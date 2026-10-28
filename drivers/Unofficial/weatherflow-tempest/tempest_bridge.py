#!/usr/bin/env python3
"""
WeatherFlow Tempest -> SmartThings relay (runs on an Android phone, e.g. Termux).

The Tempest hub broadcasts UDP JSON on port 50222. The SmartThings Edge driver
sends a "ST_PORT:<port>" handshake to this relay every 30 s from its listening
socket. The relay forwards Tempest packets to the address the most recent
handshake came from, so no hub IP needs to be configured here.

Keep the phone awake or Android will stop delivering broadcasts:
  * Termux: run `termux-wake-lock` (this script tries to do it for you)
  * Settings > Apps > Termux > Battery: Unrestricted / not optimized
  * Wi-Fi advanced settings: keep Wi-Fi on during sleep (if offered)
"""

import json
import shutil
import socket
import subprocess
import sys
import time

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
WEATHERFLOW_PORT = 50222
# Optional: only accept handshakes from this IP (e.g. "192.168.1.45"). None = any.
ALLOWED_HUB_IP = None
# Message types the driver uses. Others (hub_status every 10 s) are dropped.
FORWARD_TYPES = {"obs_st", "rapid_wind", "device_status", "evt_precip", "evt_strike"}
STATS_INTERVAL = 600          # seconds between status lines
HANDSHAKE_STALE_AFTER = 120   # warn if the driver goes quiet this long
RECV_BUFFER = 4096            # Tempest packets are < 1 KB; this avoids truncation


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def acquire_wake_lock():
    if shutil.which("termux-wake-lock"):
        try:
            subprocess.run(["termux-wake-lock"], timeout=10, check=False)
            log("[*] Termux wake lock acquired")
        except Exception as e:  # noqa: BLE001
            log(f"[!] Could not acquire wake lock: {e}")
    else:
        log("[!] termux-wake-lock not found; keep the phone awake another way")


def parse_handshake(data, addr):
    """Return the (ip, port) to forward to, or None if invalid.

    New drivers send the handshake from their listening socket, so addr is the
    target. Older drivers sent it from a throwaway socket, so the port in the
    payload is authoritative; using it keeps both versions working.
    """
    try:
        port = int(data.decode("ascii", "replace").split(":", 1)[1].strip())
    except (IndexError, ValueError):
        return None
    if not 0 < port < 65536:
        return None
    return (addr[0], port)


def main():
    acquire_wake_lock()

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("", WEATHERFLOW_PORT))
        sock.settimeout(5)
    except OSError as e:
        log(f"System error initializing network socket: {e}")
        sys.exit(1)

    log("=========================================================")
    log(" WeatherFlow Tempest relay for SmartThings")
    log(f" Listening on UDP {WEATHERFLOW_PORT}; waiting for hub handshake")
    log("=========================================================")

    target = None
    last_handshake = 0.0
    stale_warned = False
    stats = {"forwarded": 0, "dropped": 0, "errors": 0}
    last_stats = time.monotonic()

    while True:
        now = time.monotonic()
        if now - last_stats >= STATS_INTERVAL:
            log(f"[i] target={target} forwarded={stats['forwarded']} "
                f"dropped={stats['dropped']} errors={stats['errors']}")
            stats = dict.fromkeys(stats, 0)
            last_stats = now
        if target and not stale_warned and now - last_handshake > HANDSHAKE_STALE_AFTER:
            log(f"[!] No handshake from the hub for {HANDSHAKE_STALE_AFTER}s (still forwarding to {target})")
            stale_warned = True

        try:
            data, addr = sock.recvfrom(RECV_BUFFER)
        except socket.timeout:
            continue
        except OSError as e:
            log(f"Receive error: {e}")
            time.sleep(1)
            continue

        if not data:
            continue

        # Handshake from the SmartThings driver
        if data.startswith(b"ST_PORT:"):
            if ALLOWED_HUB_IP and addr[0] != ALLOWED_HUB_IP:
                log(f"[!] Ignoring handshake from unexpected host {addr[0]}")
                continue
            new_target = parse_handshake(data, addr)
            if new_target is None:
                log(f"[!] Malformed handshake from {addr}: {data[:40]!r}")
                continue
            if new_target != target:
                log(f"[*] Hub linked: forwarding to {new_target[0]}:{new_target[1]}")
            target = new_target
            last_handshake = now
            stale_warned = False
            continue

        if target is None:
            continue

        # Tempest packet: forward only what the driver uses
        try:
            msg_type = json.loads(data).get("type")
        except (ValueError, AttributeError):
            stats["dropped"] += 1
            continue
        if msg_type not in FORWARD_TYPES:
            stats["dropped"] += 1
            continue

        try:
            sock.sendto(data, target)
            stats["forwarded"] += 1
        except OSError as e:
            stats["errors"] += 1
            log(f"Forwarding error to {target}: {e}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Stopped")
