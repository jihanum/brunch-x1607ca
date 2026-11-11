#!/bin/sh
ret=0

rm -f /roota/usr/sbin/x1607ca-bt-sco-daemon.py 2>/dev/null || true

cat > /roota/lib/udev/rules.d/99-x1607ca-uhid.rules << 'EOF'
KERNEL=="uhid", SUBSYSTEM=="misc", OWNER="bluetooth", GROUP="bluetooth", MODE="0660", RUN+="/bin/chcon u:object_r:uhid_device:s0 /dev/uhid"
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0026", TEST=="power/control", ATTR{power/control}="on"
EOF
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi
chmod 0644 /roota/lib/udev/rules.d/99-x1607ca-uhid.rules 2>/dev/null || true
chcon u:object_r:cros_udev_rules_file:s0 /roota/lib/udev/rules.d/99-x1607ca-uhid.rules 2>/dev/null || true

mkdir -p /roota/etc/modprobe.d
cat > /roota/etc/modprobe.d/99-x1607ca-btusb.conf << 'EOF'
options btusb enable_autosuspend=0
EOF
chmod 0644 /roota/etc/modprobe.d/99-x1607ca-btusb.conf 2>/dev/null || true
chcon u:object_r:cros_conf_file:s0 /roota/etc/modprobe.d/99-x1607ca-btusb.conf 2>/dev/null || true

cat > /roota/etc/init/x1607ca-bt.conf << 'EOF'
start on started boot-services
stop on stopping boot-services
respawn

env BT_USB_AUTOSUSPEND_OFF=1

script
    set +e
    exec >> /var/log/x1607ca-bt.log 2>&1
    echo "[$(date -Iseconds)] Starting x1607ca-bt service..."

    if ! grep -qi "X1607CA" /sys/class/dmi/id/bios_version /sys/class/dmi/id/board_name /sys/class/dmi/id/product_name 2>/dev/null; then
        echo "Not an X1607CA board, exiting."
        stop
        exit 0
    fi

    if [ -e /dev/uhid ]; then
        chown bluetooth:bluetooth /dev/uhid
        chmod 0660 /dev/uhid
        chcon u:object_r:uhid_device:s0 /dev/uhid 2>/dev/null || true
    fi

    chmod 0666 /sys/power/wake_lock /sys/power/wake_unlock 2>/dev/null || true

    if [ -d /var/lib/bluetooth ]; then
        chown -R bluetooth:bluetooth /var/lib/bluetooth
        find /var/lib/bluetooth -type d -exec chmod 0770 {} +
        find /var/lib/bluetooth -type f -exec chmod 0660 {} +
        chcon -R u:object_r:cros_var_lib_bluetooth:s0 /var/lib/bluetooth 2>/dev/null || true
    fi

    if [ "${BT_USB_AUTOSUSPEND_OFF}" = "1" ]; then
        for dev in /sys/bus/usb/devices/*; do
            if [ -f "${dev}/idVendor" ] && [ "$(cat "${dev}/idVendor" 2>/dev/null)" = "8087" ]; then
                if [ -w "${dev}/power/control" ]; then
                    echo "on" > "${dev}/power/control"
                fi
            fi
        done
    fi

    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib"

    while ! /usr/local/bin/python3 -c "import ctypes, socket" >/dev/null 2>&1; do
        sleep 1
    done

    echo "[$(date -Iseconds)] Launching inline Python SCO/WBS bridge..."
    exec /usr/local/bin/python3 -u - << 'PY_EOF'
import ctypes
import glob
import os
import select
import socket
import struct
import subprocess
import sys
import time

AF_BLUETOOTH = 31
BTPROTO_HCI = 1
HCI_CHANNEL_RAW = 0
HCI_CHANNEL_USER = 1

SYS_pidfd_open = 434
SYS_pidfd_getfd = 438

HCI_DRV_PKT = 0xF1
BTUSB_OP_SWITCH_ALTSETTING = 0x0401

SIG_GET_WBS = bytes.fromhex("488b15d5851c00488b0dd6851c00")
SIG_IS_CODING = bytes.fromhex("554889e54881ec9000000064488b042528000000488945f883ff03740583ff05")
SIG_GET_PKT_SIZE = bytes.fromhex("488b0d967e1c00488b15977e1c00")

libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.syscall.restype = ctypes.c_long

class SockaddrHci(ctypes.Structure):
    _fields_ = [
        ("hci_family", ctypes.c_ushort),
        ("hci_dev", ctypes.c_ushort),
        ("hci_channel", ctypes.c_ushort),
    ]

def patch_btadapterd_wbs_in_ram(pid):
    try:
        with open("/usr/bin/btadapterd", "rb") as f:
            btd = f.read()
    except Exception as e:
        print(f"Cannot read /usr/bin/btadapterd: {e}")
        return False

    off_wbs = btd.find(SIG_GET_WBS)
    off_coding = btd.find(SIG_IS_CODING)
    off_pktsz = btd.find(SIG_GET_PKT_SIZE)

    base = None
    try:
        with open(f"/proc/{pid}/maps") as mf:
            for line in mf:
                if "/usr/bin/btadapterd" in line and " 00000000 " in line:
                    base = int(line.split("-")[0], 16)
                    break
    except Exception:
        return False

    if base is None:
        return False

    try:
        with open(f"/proc/{pid}/mem", "r+b", buffering=0) as memf:
            if off_wbs >= 0:
                memf.seek(base + off_wbs)
                memf.write(b"\xb8\x01\x00\x00\x00\xc3")
            if off_coding >= 0:
                memf.seek(base + off_coding)
                memf.write(b"\xb8\x01\x00\x00\x00\xc3")
            if off_pktsz >= 0:
                memf.seek(base + off_pktsz)
                memf.write(b"\xb8\x3c\x00\x00\x00\xc3")
        print(f"Patched WBS & packet size in RAM for btadapterd PID {pid} (base 0x{base:x})")
        return True
    except Exception as e:
        print(f"RAM patch failed for PID {pid}: {e}")
        return False

def read_altsetting():
    for p in glob.glob("/sys/bus/usb/drivers/btusb/*:1.1/bAlternateSetting"):
        try:
            with open(p) as f:
                return f.read().strip()
        except Exception:
            pass
    return None

def attach_btadapterd(patched_pids):
    try:
        pids = subprocess.check_output(["pgrep", "-f", "/usr/bin/btadapterd"], text=True).split()
    except Exception:
        return None, None

    for pid_str in pids:
        pid = int(pid_str)
        pidfd = libc.syscall(SYS_pidfd_open, ctypes.c_int(pid), ctypes.c_uint(0))
        if pidfd < 0:
            continue
        try:
            for fd_path in glob.glob(f"/proc/{pid}/fd/*"):
                try:
                    target_fd = int(os.path.basename(fd_path))
                except ValueError:
                    continue
                dup_fd = libc.syscall(SYS_pidfd_getfd, ctypes.c_int(pidfd), ctypes.c_int(target_fd), ctypes.c_uint(0))
                if dup_fd < 0:
                    continue
                addr = SockaddrHci()
                addr_len = ctypes.c_uint(ctypes.sizeof(addr))
                ret = libc.getsockname(ctypes.c_int(dup_fd), ctypes.byref(addr), ctypes.byref(addr_len))
                if ret == 0 and addr.hci_family == AF_BLUETOOTH and addr.hci_channel == HCI_CHANNEL_USER:
                    os.close(pidfd)
                    if pid not in patched_pids:
                        if patch_btadapterd_wbs_in_ram(pid):
                            patched_pids.add(pid)
                    print(f"Attached to btadapterd PID {pid} FD {target_fd} (dup_fd={dup_fd})")
                    return dup_fd, pid
                os.close(dup_fd)
        finally:
            try:
                os.close(pidfd)
            except OSError:
                pass
    return None, None

def switch_usb_altsetting(user_fd, target_alt):
    try:
        pkt = struct.pack("<BHHB", HCI_DRV_PKT, BTUSB_OP_SWITCH_ALTSETTING, 1, target_alt)
        os.write(user_fd, pkt)
        time.sleep(0.02)
        cur = read_altsetting()
        print(f"Switched USB AltSetting -> target={target_alt}, actual={cur}")
        return cur == str(target_alt)
    except Exception as e:
        print(f"switch_usb_altsetting error: {e}")
        return False

def send_intel_sco_over_usb(raw_sock):
    try:
        raw_sock.send(struct.pack("<BHB2B", 0x01, 0xFC1E, 2, 0x00, 0x00))
    except Exception:
        pass

def open_raw_monitor(dev_id=0):
    s = socket.socket(AF_BLUETOOTH, socket.SOCK_RAW, BTPROTO_HCI)
    addr = SockaddrHci(AF_BLUETOOTH, dev_id, HCI_CHANNEL_RAW)
    ret = libc.bind(s.fileno(), ctypes.byref(addr), ctypes.sizeof(addr))
    if ret < 0:
        s.close()
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    flt = struct.pack("<IIIH2x", (1 << 4), 0xFFFFFFFF, 0xFFFFFFFF, 0)
    s.setsockopt(0, 2, flt)
    return s

def main():
    patched_pids = set()
    checked_early_nb_mic = False

    while True:
        raw_sock = None
        user_fd = None
        current_pid = None
        try:
            raw_sock = open_raw_monitor(0)
            send_intel_sco_over_usb(raw_sock)
            sco_handles = set()

            while True:
                if user_fd is None or not os.path.exists(f"/proc/{current_pid}"):
                    if user_fd is not None:
                        try:
                            os.close(user_fd)
                        except OSError:
                            pass
                    user_fd, current_pid = attach_btadapterd(patched_pids)

                    if user_fd is not None and not checked_early_nb_mic:
                        checked_early_nb_mic = True
                        try:
                            cras_out = subprocess.check_output(["cras_test_client"], text=True)
                            if "BLUETOOTH_NB_MIC" in cras_out:
                                print("Detected early BLUETOOTH_NB_MIC node; restarting btadapterd to apply WBS...")
                                os.close(user_fd)
                                user_fd = None
                                subprocess.run(["stop", "btadapterd", "INDEX=0"], check=False)
                                time.sleep(1)
                                subprocess.run(["start", "btadapterd", "INDEX=0"], check=False)
                                continue
                        except Exception:
                            pass

                timeout = 0.2 if user_fd is None else 1.0
                rlist, _, _ = select.select([raw_sock], [], [], timeout)
                if not rlist:
                    continue

                pkt = raw_sock.recv(1024)
                if not pkt or len(pkt) < 3 or pkt[0] != 0x04:
                    continue

                evt = pkt[1]
                if evt == 0x0E and len(pkt) >= 6:
                    opcode = struct.unpack_from("<H", pkt, 4)[0]
                    if opcode == 0x0C03:
                        send_intel_sco_over_usb(raw_sock)
                        if user_fd is not None:
                            try:
                                os.close(user_fd)
                            except OSError:
                                pass
                        user_fd, current_pid = attach_btadapterd(patched_pids)

                elif evt == 0x2C and len(pkt) >= 20:
                    status = pkt[3]
                    handle = struct.unpack_from("<H", pkt, 4)[0] & 0x0FFF
                    air_mode = pkt[19]
                    print(f"eSCO Connect Complete: status=0x{status:02x} handle={handle} air_mode=0x{air_mode:02x}")
                    if status == 0x00:
                        sco_handles.add(handle)
                        if user_fd is None or not os.path.exists(f"/proc/{current_pid}"):
                            if user_fd is not None:
                                try:
                                    os.close(user_fd)
                                except OSError:
                                    pass
                            user_fd, current_pid = attach_btadapterd(patched_pids)
                        if user_fd is not None:
                            if air_mode == 0x03:
                                if not switch_usb_altsetting(user_fd, 6):
                                    switch_usb_altsetting(user_fd, 2)
                            else:
                                switch_usb_altsetting(user_fd, 2)

                elif evt == 0x05 and len(pkt) >= 7:
                    handle = struct.unpack_from("<H", pkt, 4)[0] & 0x0FFF
                    if handle in sco_handles:
                        sco_handles.discard(handle)
                        if not sco_handles and user_fd is not None:
                            switch_usb_altsetting(user_fd, 0)
        except Exception as e:
            print(f"Loop exception: {e}")
            if user_fd is not None:
                try:
                    os.close(user_fd)
                except OSError:
                    pass
            if raw_sock is not None:
                try:
                    raw_sock.close()
                except OSError:
                    pass
            time.sleep(1)

if __name__ == "__main__":
    main()
PY_EOF
end script
EOF
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi
chmod 0644 /roota/etc/init/x1607ca-bt.conf 2>/dev/null || true
chcon u:object_r:cros_init_conf_file:s0 /roota/etc/init/x1607ca-bt.conf 2>/dev/null || true

exit $ret
