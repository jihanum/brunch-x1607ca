#!/bin/sh

chroot /roota /bin/bash -s <<'EOF'
set -o pipefail
ret=0

restore_selinux_file() {
        local ref="$1"
        local dst="$2"
        local ctx="$3"
        chcon --reference="$ref" "$dst" 2>/dev/null || true
        if command -v setfattr >/dev/null 2>&1; then
                setfattr -n security.selinux -v "$ctx" "$dst" 2>/dev/null || true
        fi
}

REF_BIN="/usr/bin/awk"
[ ! -f "$REF_BIN" ] && REF_BIN="/bin/sh"

REF_CONF="/etc/init/cras.conf"
[ ! -f "$REF_CONF" ] && REF_CONF="/etc/init/cros-camera.conf"

REF_UDEV="/lib/udev/rules.d/50-udev-default.rules"
[ ! -f "$REF_UDEV" ] && REF_UDEV="$REF_CONF"

CTRL_BIN="/usr/bin/cros-camera-ctrl"
CTRL_CONF="/etc/camera-controls.conf"
UPSTART_CONF="/etc/init/cros-camera-ctrl.conf"
UDEV_RULE="/lib/udev/rules.d/99-cros-camera-ctrl.rules"

cat <<'CONFEOF' > "${CTRL_CONF}.tmp"
USB_VENDOR=3277
USB_PRODUCT=0018

power_line_frequency=2
backlight_compensation=2
brightness=25
contrast=35
gamma=75
saturation=72
sharpness=5
gain=0
exposure_dynamic_framerate=1
white_balance_automatic=1

# To test changes live:
# sudo /usr/local/bin/python3 /usr/bin/cros-camera-ctrl --list
# sudo /usr/local/bin/python3 /usr/bin/cros-camera-ctrl --set [element1=value] [element2=value]...

CONFEOF

if [ "$?" -eq 0 ] && [ -s "${CTRL_CONF}.tmp" ]; then
        cat "${CTRL_CONF}.tmp" > "$CTRL_CONF"
        rm -f "${CTRL_CONF}.tmp"
        chmod 0644 "$CTRL_CONF"
        restore_selinux_file "$REF_CONF" "$CTRL_CONF" "u:object_r:cros_conf_file:s0"
else
        rm -f "${CTRL_CONF}.tmp"
        ret=$((ret + 1))
fi

cat <<'PYEOF' > "${CTRL_BIN}.tmp"
#!/usr/local/bin/python3
import os
import sys
import glob
import time
import fcntl
import struct
import ctypes
import select
import signal
import errno

VIDIOC_QUERYCTRL = 0xC0445624  # _IOWR('V', 36, struct v4l2_queryctrl) [68 bytes]
VIDIOC_G_CTRL    = 0xC008561B  # _IOWR('V', 27, struct v4l2_control)   [8 bytes]
VIDIOC_S_CTRL    = 0xC008561C  # _IOWR('V', 28, struct v4l2_control)   [8 bytes]

V4L2_CTRL_FLAG_NEXT_CTRL = 0x80000000
V4L2_CTRL_FLAG_DISABLED  = 0x0001
V4L2_CTRL_FLAG_GRABBED   = 0x0002
V4L2_CTRL_FLAG_READ_ONLY = 0x0004
V4L2_CTRL_FLAG_INACTIVE  = 0x0010

STANDARD_CIDS = {
    "brightness":                  0x00980900,
    "contrast":                    0x00980901,
    "saturation":                  0x00980902,
    "hue":                         0x00980903,
    "white_balance_automatic":     0x0098090C,
    "auto_white_balance":          0x0098090C,
    "gamma":                       0x00980910,
    "gain":                        0x00980913,
    "power_line_frequency":        0x00980918,
    "hue_auto":                    0x00980919,
    "white_balance_temperature":   0x0098091A,
    "sharpness":                   0x0098091B,
    "backlight_compensation":      0x0098091C,
    "auto_exposure":               0x009A0901,
    "exposure_auto":               0x009A0901,
    "exposure_time_absolute":      0x009A0902,
    "exposure_absolute":           0x009A0902,
    "exposure_dynamic_framerate":  0x009A0903,
    "exposure_auto_priority":      0x009A0903,
    "focus_absolute":              0x009A090A,
    "focus_automatic_continuous":  0x009A090C,
    "focus_auto":                  0x009A090C,
}

PRIORITY_KEYS = {
    "power_line_frequency",
    "auto_exposure",
    "exposure_auto",
    "exposure_dynamic_framerate",
    "exposure_auto_priority",
    "white_balance_automatic",
    "auto_white_balance",
    "hue_auto",
    "focus_automatic_continuous",
    "focus_auto",
}

DEFAULT_CONF = "/etc/camera-controls.conf"
STATEFUL_CONF = "/mnt/stateful_partition/etc/camera-controls.conf"
LOCK_FILE = "/run/cros-camera-ctrl.lock"

IN_CLOSE_WRITE   = 0x00000008
IN_CLOSE_NOWRITE = 0x00000010
IN_OPEN          = 0x00000020
IN_CREATE        = 0x00000100
IN_DELETE        = 0x00000200
IN_DELETE_SELF   = 0x00000400
IN_NONBLOCK      = 0x00000800
IN_CLOEXEC       = 0x00080000
IN_EVENT_STRUCT  = struct.Struct("<iIII")

def normalize_name(raw_name):
    s = raw_name.strip().lower()
    out = []
    prev_us = False
    for ch in s:
        if ch.isalnum():
            out.append(ch)
            prev_us = False
        elif not prev_us:
            out.append("_")
            prev_us = True
    return "".join(out).strip("_")

def load_config():
    vendor = "3277"
    product = "0018"
    controls = {}
    for path in (DEFAULT_CONF, STATEFUL_CONF):
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.split("#", 1)[0].strip()
                    if not line or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip()
                    if k == "USB_VENDOR":
                        vendor = v.lower()
                    elif k == "USB_PRODUCT":
                        product = v.lower()
                    else:
                        controls[normalize_name(k)] = v
        except Exception:
            pass
    return vendor, product, controls

def read_sysfs(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        return ""

def find_usb_parent(sys_video_dir):
    cur = os.path.realpath(os.path.join(sys_video_dir, "device"))
    for _ in range(6):
        if not cur or cur == "/":
            break
        v = read_sysfs(os.path.join(cur, "idVendor")).lower()
        p = read_sysfs(os.path.join(cur, "idProduct")).lower()
        if v and p:
            return cur, v, p
        cur = os.path.dirname(cur)
    return None, "", ""


def query_all_controls(fd):
    ctrls = {}
    cid = V4L2_CTRL_FLAG_NEXT_CTRL
    while True:
        buf = bytearray(struct.pack("<II32siiiiI8x", cid, 0, b"", 0, 0, 0, 0, 0))
        try:
            fcntl.ioctl(fd, VIDIOC_QUERYCTRL, buf, True)
        except OSError:
            break
        q_id, q_type, q_name, q_min, q_max, q_step, q_def, q_flags = struct.unpack(
            "<II32siiiiI8x", buf
        )
        name_str = q_name.split(b"\x00", 1)[0].decode("ascii", errors="ignore")
        norm = normalize_name(name_str)
        if not (q_flags & V4L2_CTRL_FLAG_DISABLED):
            cur_val = get_ctrl(fd, q_id)
            ctrls[norm] = {
                "id": q_id,
                "raw_name": name_str,
                "min": q_min,
                "max": q_max,
                "step": q_step if q_step > 0 else 1,
                "default": q_def,
                "flags": q_flags,
                "current": cur_val,
            }
        cid = q_id | V4L2_CTRL_FLAG_NEXT_CTRL
    return ctrls


def get_ctrl(fd, cid):
    buf = bytearray(struct.pack("<Ii", cid, 0))
    try:
        fcntl.ioctl(fd, VIDIOC_G_CTRL, buf, True)
        _, val = struct.unpack("<Ii", buf)
        return val
    except OSError:
        return None


def set_ctrl(fd, cid, val):
    buf = bytearray(struct.pack("<Ii", cid, int(val)))
    fcntl.ioctl(fd, VIDIOC_S_CTRL, buf, True)


def resolve_target_value(spec_str, meta):
    spec_str = str(spec_str).strip()
    if spec_str.endswith("%") and meta is not None:
        pct = float(spec_str[:-1].strip())
        pct = max(0.0, min(100.0, pct))
        raw = meta["min"] + (meta["max"] - meta["min"]) * (pct / 100.0)
    else:
        raw = float(spec_str)

    if meta is not None:
        step = meta["step"] if meta["step"] > 0 else 1
        clamped = max(meta["min"], min(meta["max"], int(round(raw))))
        clamped = meta["min"] + ((clamped - meta["min"]) // step) * step
        return int(clamped)
    return int(round(raw))


def find_camera_nodes(target_vendor, target_product):
    nodes = []
    for sys_dir in sorted(glob.glob("/sys/class/video4linux/video*")):
        dev_name = os.path.basename(sys_dir)
        dev_path = f"/dev/{dev_name}"
        if not os.path.exists(dev_path):
            continue
        _, v, p = find_usb_parent(sys_dir)
        if target_vendor and target_product:
            if v != target_vendor.lower() or p != target_product.lower():
                continue
        try:
            fd = os.open(dev_path, os.O_RDWR | os.O_NONBLOCK)
            try:
                ctrls = query_all_controls(fd)
                if ctrls:
                    nodes.append(dev_path)
            finally:
                os.close(fd)
        except OSError:
            continue
    return nodes


def is_held_by_other_process(dev_path):
    my_pid = str(os.getpid())
    try:
        for fd_link in glob.glob("/proc/[0-9]*/fd/*"):
            parts = fd_link.split("/")
            if len(parts) > 2 and parts[2] == my_pid:
                continue
            try:
                if os.readlink(fd_link) == dev_path:
                    return True
            except OSError:
                continue
    except Exception:
        pass
    return False


def apply_controls_to_node(dev_path, controls_cfg, only_if_changed=False):
    if not controls_cfg:
        return False
    changed = False
    try:
        fd = os.open(dev_path, os.O_RDWR | os.O_NONBLOCK)
    except OSError:
        return False

    try:
        hw_ctrls = query_all_controls(fd)
        cid_to_meta = {m["id"]: m for m in hw_ctrls.values()}

        ordered_items = sorted(
            controls_cfg.items(),
            key=lambda kv: (0 if kv[0] in PRIORITY_KEYS else 1, kv[0]),
        )

        for key, spec_val in ordered_items:
            meta = hw_ctrls.get(key)
            if meta is None and key in STANDARD_CIDS:
                meta = cid_to_meta.get(STANDARD_CIDS[key])

            cid = meta["id"] if meta else STANDARD_CIDS.get(key)
            if cid is None:
                continue

            try:
                target_val = resolve_target_value(spec_val, meta)
            except ValueError:
                continue

            cur_val = get_ctrl(fd, cid)
            if only_if_changed and cur_val is not None and cur_val == target_val:
                continue

            try:
                set_ctrl(fd, cid, target_val)
                changed = True
            except OSError:
                pass
    finally:
        os.close(fd)
    return changed


def list_camera_controls():
    vendor, product, cfg = load_config()
    nodes = find_camera_nodes(vendor, product)
    if not nodes:
        nodes = find_camera_nodes("", "")
    if not nodes:
        print("No V4L2 control-capable camera nodes found.")
        return 1

    for dev_path in nodes:
        print(f"=== {dev_path} (USB {vendor}:{product}) ===")
        fd = os.open(dev_path, os.O_RDWR | os.O_NONBLOCK)
        try:
            ctrls = query_all_controls(fd)
            for norm, m in sorted(ctrls.items(), key=lambda x: x[1]["id"]):
                cfg_val = cfg.get(norm, "-")
                print(
                    f"  {norm:<30} (0x{m['id']:08x}): "
                    f"cur={m['current']}  min={m['min']} max={m['max']} "
                    f"step={m['step']} def={m['default']}  [conf: {cfg_val}]"
                )
        finally:
            os.close(fd)
    return 0


def drain_self_events(inotify_fd, dev_watch_wds):
    preserved_create_or_delete = False
    while True:
        try:
            raw = os.read(inotify_fd, 4096)
            if not raw:
                break
        except BlockingIOError:
            break
        except OSError:
            break

        offset = 0
        while offset + IN_EVENT_STRUCT.size <= len(raw):
            wd, mask, cookie, name_len = IN_EVENT_STRUCT.unpack_from(raw, offset)
            offset += IN_EVENT_STRUCT.size + name_len
            if wd not in dev_watch_wds and (mask & (IN_CREATE | IN_DELETE)):
                preserved_create_or_delete = True
    return preserved_create_or_delete


def run_daemon():
    os.makedirs("/run", exist_ok=True)
    lock_fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0

    os.ftruncate(lock_fd, 0)
    os.write(lock_fd, f"{os.getpid()}\n".encode("ascii"))

    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_init1.restype = ctypes.c_int
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    libc.inotify_add_watch.restype = ctypes.c_int
    libc.inotify_rm_watch.argtypes = [ctypes.c_int, ctypes.c_int]
    libc.inotify_rm_watch.restype = ctypes.c_int

    inotify_fd = libc.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
    if inotify_fd < 0:
        return 1

    dev_dir_wd = libc.inotify_add_watch(
        inotify_fd, b"/dev", IN_CREATE | IN_DELETE
    )
    etc_dir_wd = libc.inotify_add_watch(
        inotify_fd, b"/etc", IN_CLOSE_WRITE | IN_CREATE
    )
    stateful_etc = "/mnt/stateful_partition/etc"
    os.makedirs(stateful_etc, exist_ok=True)
    stateful_wd = libc.inotify_add_watch(
        inotify_fd, stateful_etc.encode("utf-8"), IN_CLOSE_WRITE | IN_CREATE
    )

    watched_nodes = {}  # wd -> dev_path
    reload_requested = [True]

    def sig_handler(_signum, _frame):
        reload_requested[0] = True

    signal.signal(signal.SIGHUP, sig_handler)
    signal.signal(signal.SIGUSR1, sig_handler)

    vendor, product, controls_cfg = load_config()

    def refresh_watches_and_apply():
        nonlocal vendor, product, controls_cfg
        vendor, product, controls_cfg = load_config()
        for wd in list(watched_nodes.keys()):
            libc.inotify_rm_watch(inotify_fd, wd)
        watched_nodes.clear()

        nodes = find_camera_nodes(vendor, product)
        for dev_path in nodes:
            apply_controls_to_node(dev_path, controls_cfg, only_if_changed=False)
            wd = libc.inotify_add_watch(
                inotify_fd,
                dev_path.encode("utf-8"),
                IN_OPEN | IN_CLOSE_WRITE | IN_CLOSE_NOWRITE | IN_DELETE_SELF,
            )
            if wd >= 0:
                watched_nodes[wd] = dev_path
        drain_self_events(inotify_fd, set(watched_nodes.keys()))

    refresh_watches_and_apply()

    poller = select.poll()
    poller.register(inotify_fd, select.POLLIN)

    BURST_DELAYS = (0.05, 0.20, 0.50, 1.20)
    pending_bursts = []
    last_sleep_gap = time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(
        time.CLOCK_MONOTONIC
    )

    while True:
        now = time.monotonic()

        cur_gap = time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(
            time.CLOCK_MONOTONIC
        )
        if cur_gap - last_sleep_gap > 1.5:
            last_sleep_gap = cur_gap
            time.sleep(0.4)
            refresh_watches_and_apply()
            now = time.monotonic()

        if reload_requested[0]:
            reload_requested[0] = False
            refresh_watches_and_apply()
            now = time.monotonic()

        if pending_bursts and now >= pending_bursts[0]:
            pending_bursts.pop(0)
            for dev_path in set(watched_nodes.values()):
                apply_controls_to_node(dev_path, controls_cfg, only_if_changed=False)
            if drain_self_events(inotify_fd, set(watched_nodes.keys())):
                reload_requested[0] = True
            continue

        external_active = any(
            is_held_by_other_process(p) for p in set(watched_nodes.values())
        )

        if pending_bursts:
            timeout_ms = max(10, int((pending_bursts[0] - now) * 1000))
        elif external_active:
            timeout_ms = 2000
        else:
            timeout_ms = None

        try:
            events = poller.poll(timeout_ms)
        except InterruptedError:
            continue

        if not events:
            if external_active and not pending_bursts:
                for dev_path in set(watched_nodes.values()):
                    apply_controls_to_node(dev_path, controls_cfg, only_if_changed=True)
                if drain_self_events(inotify_fd, set(watched_nodes.keys())):
                    reload_requested[0] = True
            continue

        need_rescan = False
        external_open_detected = False

        while True:
            try:
                raw = os.read(inotify_fd, 4096)
                if not raw:
                    break
            except BlockingIOError:
                break
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EINTR):
                    break
                raise

            offset = 0
            while offset + IN_EVENT_STRUCT.size <= len(raw):
                wd, mask, cookie, name_len = IN_EVENT_STRUCT.unpack_from(raw, offset)
                name_bytes = raw[
                    offset + IN_EVENT_STRUCT.size : offset + IN_EVENT_STRUCT.size + name_len
                ]
                offset += IN_EVENT_STRUCT.size + name_len
                name = name_bytes.split(b"\x00", 1)[0].decode("utf-8", errors="ignore")

                if wd == dev_dir_wd and name.startswith("video"):
                    need_rescan = True
                elif wd in (etc_dir_wd, stateful_wd) and name == "camera-controls.conf":
                    need_rescan = True
                elif wd in watched_nodes:
                    if mask & IN_DELETE_SELF:
                        need_rescan = True
                    elif mask & IN_OPEN:
                        external_open_detected = True

        if need_rescan:
            time.sleep(0.2)
            refresh_watches_and_apply()

        if external_open_detected:
            base = time.monotonic()
            pending_bursts = [base + d for d in BURST_DELAYS]


def main():
    args = sys.argv[1:]
    if not args or "--apply" in args:
        vendor, product, cfg = load_config()
        for dev_path in find_camera_nodes(vendor, product):
            apply_controls_to_node(dev_path, cfg, only_if_changed=False)
        return 0

    if "--list" in args:
        return list_camera_controls()

    if "--set" in args:
        idx = args.index("--set")
        overrides = {}
        for item in args[idx + 1 :]:
            if "=" in item:
                k, v = item.split("=", 1)
                overrides[normalize_name(k)] = v.strip()
        vendor, product, _ = load_config()
        for dev_path in find_camera_nodes(vendor, product):
            apply_controls_to_node(dev_path, overrides, only_if_changed=False)
        return 0

    if "--udev" in args:
        vendor, product, cfg = load_config()
        for dev_path in find_camera_nodes(vendor, product):
            apply_controls_to_node(dev_path, cfg, only_if_changed=False)
        try:
            pid = int(read_sysfs(LOCK_FILE))
            os.kill(pid, signal.SIGHUP)
        except Exception:
            pass
        return 0

    if "--daemon" in args:
        return run_daemon()

    print("Usage: cros-camera-ctrl [--apply | --list | --daemon | --udev | --set key=val ...]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

if [ "$?" -eq 0 ] && [ -s "${CTRL_BIN}.tmp" ]; then
        cat "${CTRL_BIN}.tmp" > "$CTRL_BIN"
        rm -f "${CTRL_BIN}.tmp"
        chmod 0755 "$CTRL_BIN"
        restore_selinux_file "$REF_BIN" "$CTRL_BIN" "u:object_r:cros_system_file:s0"
else
        rm -f "${CTRL_BIN}.tmp"
        ret=$((ret + 2))
fi

cat <<'INITEOF' > "${UPSTART_CONF}.tmp"
description "Persistent V4L2 camera property daemon for Brunch ChromeOS"
author "brunch-patch"

start on started system-services or started cros-camera
stop on stopping system-services

respawn
respawn limit 10 30

pre-start script
        for i in 1 2 3 4 5 6 7 8 9 10; do
                [ -x /usr/local/bin/python3 ] && break
                sleep 1
        done
end script

exec /usr/local/bin/python3 /usr/bin/cros-camera-ctrl --daemon
INITEOF

if [ "$?" -eq 0 ] && [ -s "${UPSTART_CONF}.tmp" ]; then
        cat "${UPSTART_CONF}.tmp" > "$UPSTART_CONF"
        rm -f "${UPSTART_CONF}.tmp"
        chmod 0644 "$UPSTART_CONF"
        restore_selinux_file "$REF_CONF" "$UPSTART_CONF" "u:object_r:cros_conf_file:s0"
else
        rm -f "${UPSTART_CONF}.tmp"
        ret=$((ret + 4))
fi

cat <<'UDEVEOF' > "${UDEV_RULE}.tmp"
ACTION=="add|change|bind", SUBSYSTEM=="video4linux", ATTRS{idVendor}=="3277", ATTRS{idProduct}=="0018", RUN+="/usr/local/bin/python3 /usr/bin/cros-camera-ctrl --udev"
UDEVEOF

if [ "$?" -eq 0 ] && [ -s "${UDEV_RULE}.tmp" ]; then
        cat "${UDEV_RULE}.tmp" > "$UDEV_RULE"
        rm -f "${UDEV_RULE}.tmp"
        chmod 0644 "$UDEV_RULE"
        restore_selinux_file "$REF_UDEV" "$UDEV_RULE" "u:object_r:cros_system_file:s0"
else
        rm -f "${UDEV_RULE}.tmp"
        ret=$((ret + 8))
fi

exit $ret
EOF
ext $?
