#!/usr/bin/env python3
"""
Decide whether "Ctrl+Alt+Arrow does nothing" is a GNOME fault or a keyboard fault.

Creates a virtual keyboard via /dev/uinput and types Ctrl+Alt+<arrow> into it,
then watches _NET_CURRENT_DESKTOP. This bypasses the physical keyboard entirely,
so the result is unambiguous:

  workspace changes  -> GNOME, mutter and Workspace Matrix are all fine;
                        the physical key combo is what never arrives
                        (Fn-layer arrows, or AltGr instead of the left Alt).
  workspace does not -> the fault is in the compositor/extension after all.

Run as root:  sudo python3 test_workspace_keys.py
"""
import ctypes, fcntl, os, struct, subprocess, sys, time

# linux/input-event-codes.h
EV_SYN, EV_KEY = 0x00, 0x01
SYN_REPORT = 0
KEY = {"LEFTCTRL": 29, "LEFTALT": 56, "UP": 103, "LEFT": 105, "RIGHT": 106, "DOWN": 108}

# linux/uinput.h ioctls
UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_CREATE  = 0x5501
UI_DEV_DESTROY = 0x5502


def current_desktop():
    try:
        out = subprocess.run(["xprop", "-root", "_NET_CURRENT_DESKTOP"],
                             capture_output=True, text=True, timeout=5).stdout
        return int(out.strip().split()[-1])
    except Exception:
        return None


class VirtualKeyboard:
    def __init__(self):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for code in KEY.values():
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        # struct uinput_user_dev: char name[80]; struct input_id {u16 x4};
        # int ff_effects_max; int absmax[64]/absmin/absfuzz/absflat
        dev = (b"claude-wsgrid-test".ljust(80, b"\0")
               + struct.pack("HHHH", 0x03, 0x1234, 0x5678, 1)   # BUS_USB
               + struct.pack("i", 0)
               + b"\0" * (4 * 64 * 4))
        os.write(self.fd, dev)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        # Give mutter/libinput time to notice the new seat device.
        time.sleep(2)

    def _emit(self, etype, code, value):
        # struct input_event: struct timeval (2x long), u16 type, u16 code, s32 value
        os.write(self.fd, struct.pack("llHHi", 0, 0, etype, code, value))

    def _syn(self):
        self._emit(EV_SYN, SYN_REPORT, 0)

    def combo(self, arrow):
        seq = [KEY["LEFTCTRL"], KEY["LEFTALT"], KEY[arrow]]
        for code in seq:
            self._emit(EV_KEY, code, 1); self._syn(); time.sleep(0.03)
        time.sleep(0.08)
        for code in reversed(seq):
            self._emit(EV_KEY, code, 0); self._syn(); time.sleep(0.03)

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


def main():
    if os.geteuid() != 0:
        sys.exit("Run as root:  sudo python3 test_workspace_keys.py")

    if current_desktop() is None:
        sys.exit("Cannot read _NET_CURRENT_DESKTOP (need xprop + XWayland).")

    subprocess.run(["modprobe", "uinput"], check=False)
    kbd = VirtualKeyboard()
    results = {}
    try:
        print(f"starting on workspace {current_desktop()}\n")
        for arrow in ("RIGHT", "DOWN", "UP", "LEFT"):
            before = current_desktop()
            kbd.combo(arrow)
            time.sleep(1.0)
            after = current_desktop()
            moved = before != after
            results[arrow] = moved
            print(f"  Ctrl+Alt+{arrow:<5} {before} -> {after}   "
                  f"{'MOVED' if moved else 'no change'}")
    finally:
        kbd.close()

    horiz = results["LEFT"] or results["RIGHT"]
    vert = results["UP"] or results["DOWN"]

    print("\n" + "=" * 62)
    if vert and horiz:
        print("All four directions work when injected at the kernel.")
        print("=> GNOME, mutter and Workspace Matrix are CORRECT.")
        print("   Your physical keyboard is not delivering the combo.")
        print("   Check Fn-Lock (often Fn+Esc on ASUS) and use the LEFT Alt")
        print("   key -- AltGr does not satisfy <Alt> in GNOME keybindings.")
        print("   Confirm with:  sudo evtest /dev/input/event3")
    elif horiz and not vert:
        print("Horizontal works, vertical does not, even when injected.")
        print("=> The grid override is not driving the up/down handler.")
        print("   Workspace Matrix's _overrideKeybindingHandlers is not")
        print("   taking effect. Log out and back in, then re-run.")
    else:
        print("Nothing moved even when injected at the kernel.")
        print("=> The compositor is not acting on these bindings at all;")
        print("   this is not a keyboard problem.")
    print("=" * 62)


if __name__ == "__main__":
    main()
