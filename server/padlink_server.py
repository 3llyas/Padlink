"""PadLink PC server.

Receives controller input from the PadLink iPhone app over UDP and feeds it to
a virtual Xbox 360 controller (ViGEmBus, via the `vgamepad` package). Games see
it as a normal wired Xbox controller. Up to 4 phones at once = 4 controllers.

Usage:  python padlink_server.py [--port 28910]
"""

import argparse
import json
import socket
import sys
import time

DEFAULT_PORT = 28910
MAX_PADS = 4               # XInput limit
NEUTRAL_AFTER_S = 0.5      # no packets for this long -> release everything
DROP_AFTER_S = 60.0        # no packets for this long -> unplug the virtual pad

# XUSB button bits, same values the app sends.
BUTTON_BITS = (
    0x0001, 0x0002, 0x0004, 0x0008,  # dpad up/down/left/right
    0x0010, 0x0020,                  # start, back
    0x0040, 0x0080,                  # L3, R3
    0x0100, 0x0200,                  # LB, RB
    0x0400,                          # guide
    0x1000, 0x2000, 0x4000, 0x8000,  # A, B, X, Y
)

try:
    import vgamepad as vg
except ImportError:
    print("The 'vgamepad' package is missing. Install it with:\n"
          "    python -m pip install vgamepad\n"
          "(it will also offer to install the ViGEmBus driver - accept that).")
    sys.exit(1)


def clamp(v, lo, hi):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return 0.0
    if v != v:  # NaN
        return 0.0
    return lo if v < lo else hi if v > hi else v


def local_ip():
    """Best guess at this PC's LAN address (no packets are actually sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class Pad:
    def __init__(self, ip, slot):
        self.ip = ip
        self.slot = slot
        self.gp = vg.VX360Gamepad()
        self.session = None
        self.last_seq = -1
        self.last_seen = time.monotonic()
        self.neutral = True

    def apply(self, m):
        seq = int(m.get("q", 0))
        bits = int(m.get("b", 0)) & 0xFFFF
        session = m.get("sid")
        if session != self.session:
            # New app session (reconnect / relaunch): sequence numbers restart.
            self.session = session
            self.last_seq = -1
        # Drop late/out-of-order UDP packets.
        if self.last_seq >= 0 and seq <= self.last_seq:
            return
        self.last_seq = seq

        for bit in BUTTON_BITS:
            button = vg.XUSB_BUTTON(bit)
            if bits & bit:
                self.gp.press_button(button)
            else:
                self.gp.release_button(button)

        lx, ly = clamp(m.get("lx"), -1, 1), clamp(m.get("ly"), -1, 1)
        rx, ry = clamp(m.get("rx"), -1, 1), clamp(m.get("ry"), -1, 1)
        lt, rt = clamp(m.get("lt"), 0, 1), clamp(m.get("rt"), 0, 1)
        self.gp.left_joystick_float(lx, ly)
        self.gp.right_joystick_float(rx, ry)
        self.gp.left_trigger_float(lt)
        self.gp.right_trigger_float(rt)
        self.gp.update()
        self.neutral = bits == 0 and not any((lx, ly, rx, ry, lt, rt))

    def release_all(self):
        self.gp.reset()
        self.gp.update()
        self.neutral = True

    def close(self):
        try:
            self.release_all()
        finally:
            del self.gp


def main():
    ap = argparse.ArgumentParser(description="PadLink PC server")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"UDP port (default {DEFAULT_PORT})")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(0.1)

    name = socket.gethostname()
    print("=" * 52)
    print("  PadLink server running")
    print(f"  In the iPhone app, enter:  {local_ip()}   port {args.port}")
    print("  (phone and PC must be on the same Wi-Fi network)")
    print("  Press Ctrl+C to stop.")
    print("=" * 52, flush=True)

    pads = {}  # phone IP -> Pad

    def free_slot():
        used = {p.slot for p in pads.values()}
        return next(i for i in range(1, MAX_PADS + 1) if i not in used)

    try:
        while True:
            data = addr = None
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                pass
            except ConnectionResetError:
                # Windows reports ICMP "port unreachable" from an earlier reply here.
                pass

            now = time.monotonic()
            msg = None
            if data:
                try:
                    msg = json.loads(data)
                except ValueError:
                    msg = None
                if not isinstance(msg, dict):
                    msg = None

            if msg is not None:
                ip = addr[0]
                pad = pads.get(ip)
                if pad is None:
                    if len(pads) >= MAX_PADS:
                        print(f"Ignoring {ip}: already {MAX_PADS} controllers connected.")
                    else:
                        try:
                            pad = Pad(ip, free_slot())
                        except Exception as e:  # driver missing, etc.
                            print(f"Could not create virtual controller: {e}\n"
                                  "Is the ViGEmBus driver installed? "
                                  "(reinstall with: python -m pip install --force-reinstall vgamepad)")
                        else:
                            pads[ip] = pad
                            print(f"[+] Phone {ip} connected as controller #{pad.slot}", flush=True)

                if pad is not None:
                    pad.last_seen = now
                    kind = msg.get("t")
                    if kind == "hello":
                        reply = json.dumps({"t": "ok", "name": name, "slot": pad.slot}).encode()
                        try:
                            sock.sendto(reply, addr)
                        except OSError:
                            pass
                    elif kind == "s":
                        try:
                            pad.apply(msg)
                        except (TypeError, ValueError):
                            pass

            for ip, pad in list(pads.items()):
                idle = now - pad.last_seen
                if idle > DROP_AFTER_S:
                    pad.close()
                    del pads[ip]
                    print(f"[-] Phone {ip} timed out, controller #{pad.slot} unplugged", flush=True)
                elif idle > NEUTRAL_AFTER_S and not pad.neutral:
                    pad.release_all()
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        for pad in pads.values():
            pad.close()
        sock.close()


if __name__ == "__main__":
    main()
