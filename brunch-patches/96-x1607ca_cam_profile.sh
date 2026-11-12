#!/bin/sh

ret=0

if [ -d /roota/etc ]; then
    ROOT="/roota"
    LIVE=0
else
    ROOT=""
    LIVE=1
fi

restore_selinux_file() {
    local ref="$1"
    local dst="$2"
    local ctx="$3"
    if ! chcon --reference="$ref" "$dst" 2>/dev/null; then
        if command -v setfattr >/dev/null 2>&1; then
            setfattr -n security.selinux -v "$ctx" "$dst" 2>/dev/null || true
        fi
    fi
}

REF_BIN="${ROOT}/usr/bin/mawk"
[ ! -f "$REF_BIN" ] && REF_BIN="${ROOT}/bin/bash"

REF_INIT="${ROOT}/etc/init/cras.conf"
[ ! -f "$REF_INIT" ] && REF_INIT="${ROOT}/etc/init/ui.conf"

REF_CONF="${ROOT}/etc/hosts"
[ ! -f "$REF_CONF" ] && REF_CONF="$REF_INIT"

CTRL_BIN="${ROOT}/usr/bin/cros-camera-ctrl"
CTRL_CONF="${ROOT}/etc/camera-controls.conf"
UPSTART_CONF="${ROOT}/etc/init/cros-camera-ctrl.conf"
UDEV_RULE="${ROOT}/lib/udev/rules.d/99-cros-camera-ctrl.rules"

rm -f "$UDEV_RULE" "${ROOT}/etc/ld.so.conf.d/99-usr-local-python.conf" 2>/dev/null || true

rm -f "/run/cros-camera-ctrl.override.conf" \
      "/mnt/stateful_partition/etc/camera-controls.conf" \
      "${ROOT}/mnt/stateful_partition/etc/camera-controls.conf" 2>/dev/null || true

rm -f "$CTRL_CONF" 2>/dev/null || true
cp -a "$REF_CONF" "$CTRL_CONF" 2>/dev/null || true
cat <<'CONFEOF' > "$CTRL_CONF"
USB_VENDOR=3277
USB_PRODUCT=0018

power_line_frequency=2
backlight_compensation=2
brightness=48
contrast=42
gamma=90
saturation=72
sharpness=5
gain=0
exposure_dynamic_framerate=1
white_balance_automatic=1

# To test changes live:
# sudo cros-camera-ctrl --list
# sudo cros-camera-ctrl --set [argument1]=[value] [argument2]=[value] ...
#
# To save live overrides:
# sudo cros-camera-ctrl --set --save brightness=40
#
# To revert to values saved in this file:
# sudo cros-camera-ctrl --reset
CONFEOF
if [ "$?" -ne 0 ]; then ret=$((ret + 1)); fi
chmod 0644 "$CTRL_CONF"
restore_selinux_file "$REF_CONF" "$CTRL_CONF" "u:object_r:cros_system_file:s0"

rm -f "$CTRL_BIN" 2>/dev/null || true
if [ -f "$REF_BIN" ] && [ ! -L "$REF_BIN" ]; then
    cp -a "$REF_BIN" "$CTRL_BIN" 2>/dev/null || true
fi
cat <<'PYEOF' > "$CTRL_BIN"
#!/bin/sh
""":"
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /usr/local/bin/python3 "$0" "$@"
":"""
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
import hashlib

VIDIOC_QUERYCTRL = 0xC0445624  # _IOWR('V', 36, struct v4l2_queryctrl) [68 bytes]
VIDIOC_G_CTRL    = 0xC008561B  # _IOWR('V', 27, struct v4l2_control)   [8 bytes]
VIDIOC_S_CTRL    = 0xC008561C  # _IOWR('V', 28, struct v4l2_control)   [8 bytes]

V4L2_CTRL_FLAG_NEXT_CTRL = 0x80000000
V4L2_CTRL_FLAG_DISABLED  = 0x0001
V4L2_CTRL_FLAG_GRABBED   = 0x0002
V4L2_CTRL_FLAG_READ_ONLY = 0x0004
V4L2_CTRL_FLAG_INACTIVE  = 0x0010
V4L2_CTRL_TYPE_CTRL_CLASS = 6

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

CANONICAL_ALIASES = {
    "auto_white_balance": "white_balance_automatic",
    "exposure_auto": "auto_exposure",
    "exposure_absolute": "exposure_time_absolute",
    "exposure_auto_priority": "exposure_dynamic_framerate",
    "focus_auto": "focus_automatic_continuous",
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

IMAGE_CTRL_KEYS = {
    "brightness",
    "contrast",
    "saturation",
    "gamma",
    "sharpness",
    "backlight_compensation",
    "white_balance_automatic",
    "auto_exposure",
    "power_line_frequency",
}

DEFAULT_CONF = "/etc/camera-controls.conf"
STATEFUL_CONF = "/mnt/stateful_partition/etc/camera-controls.conf"
RUNTIME_CONF = "/run/cros-camera-ctrl.override.conf"
LOCK_FILE = "/run/cros-camera-ctrl.lock"

IN_MODIFY        = 0x00000002
IN_CLOSE_WRITE   = 0x00000008
IN_CLOSE_NOWRITE = 0x00000010
IN_OPEN          = 0x00000020
IN_MOVED_TO      = 0x00000080
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


def get_file_sha256(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except Exception:
        return ""


def parse_conf_file(path):
    vendor = None
    product = None
    base_hash = None
    controls = {}
    if not os.path.isfile(path):
        return vendor, product, base_hash, controls
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
                elif k == "BASE_CONF_HASH":
                    base_hash = v.lower()
                else:
                    controls[normalize_name(k)] = v
    except Exception:
        pass
    return vendor, product, base_hash, controls


def merge_control_dict(dst, src):
    for k, val in src.items():
        canon = CANONICAL_ALIASES.get(k, k)
        for alias_k, alias_canon in CANONICAL_ALIASES.items():
            if alias_canon == canon and alias_k in dst and alias_k != k:
                del dst[alias_k]
        if canon in dst and canon != k:
            del dst[canon]
        dst[k] = val


def load_config():
    vendor = "3277"
    product = "0018"
    controls = {}
    default_hash = get_file_sha256(DEFAULT_CONF)

    v, p, _, def_ctrls = parse_conf_file(DEFAULT_CONF)
    if v:
        vendor = v
    if p:
        product = p
    merge_control_dict(controls, def_ctrls)

    for over_path in (STATEFUL_CONF, RUNTIME_CONF):
        if not os.path.isfile(over_path):
            continue
        ov, op, base_hash, over_ctrls = parse_conf_file(over_path)
        if default_hash and base_hash != default_hash:
            try:
                os.remove(over_path)
            except OSError:
                pass
            continue
        if ov:
            vendor = ov
        if op:
            product = op
        merge_control_dict(controls, over_ctrls)

    return vendor, product, controls


def save_overrides(new_overrides, target_path):
    target_dir = os.path.dirname(target_path)
    os.makedirs(target_dir, exist_ok=True)
    default_hash = get_file_sha256(DEFAULT_CONF)

    v, p, base_hash, existing = parse_conf_file(target_path)
    if default_hash and base_hash != default_hash:
        existing = {}
        v, p = None, None

    merge_control_dict(existing, new_overrides)

    tmp_path = f"{target_path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write("# Camera control overrides (managed by cros-camera-ctrl)\n")
        if default_hash:
            f.write(f"BASE_CONF_HASH={default_hash}\n")
        if v:
            f.write(f"USB_VENDOR={v}\n")
        if p:
            f.write(f"USB_PRODUCT={p}\n")
        for k, val in existing.items():
            f.write(f"{k}={val}\n")
    os.chmod(tmp_path, 0o644)
    os.replace(tmp_path, target_path)


def notify_daemon():
    try:
        pid_str = read_sysfs(LOCK_FILE)
        if pid_str.isdigit():
            os.kill(int(pid_str), signal.SIGHUP)
            return True
    except Exception:
        pass
    return False


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


def enable_usb_autosuspend(usb_dir):
    if not usb_dir:
        return
    for attr, val in (("power/autosuspend_delay_ms", "2000\n"), ("power/control", "auto\n")):
        p = os.path.join(usb_dir, attr)
        try:
            with open(p, "w", encoding="ascii") as f:
                f.write(val)
        except OSError:
            pass


def query_all_controls(fd):
    """Enumerate all V4L2 controls supported by the open device fd."""
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
        cid = q_id | V4L2_CTRL_FLAG_NEXT_CTRL
        if q_type == V4L2_CTRL_TYPE_CTRL_CLASS or (q_flags & V4L2_CTRL_FLAG_DISABLED):
            continue
        name_str = q_name.split(b"\x00", 1)[0].decode("ascii", errors="ignore")
        norm = normalize_name(name_str)
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
        usb_dir, v, p = find_usb_parent(sys_dir)
        if target_vendor and target_product:
            if v != target_vendor.lower() or p != target_product.lower():
                continue
        enable_usb_autosuspend(usb_dir)
        idx_str = read_sysfs(os.path.join(sys_dir, "index"))
        if idx_str in ("", "0"):
            nodes.append(dev_path)
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


def apply_controls_to_node(dev_path, controls_cfg, only_if_changed=False, verbose=False):
    if not controls_cfg:
        return False
    changed = False
    try:
        fd = os.open(dev_path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        if verbose:
            print(f"[{dev_path}] Failed to open device: {e}", file=sys.stderr)
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
            if meta is None and key in CANONICAL_ALIASES:
                meta = hw_ctrls.get(CANONICAL_ALIASES[key])
            if meta is None and key in STANDARD_CIDS:
                meta = cid_to_meta.get(STANDARD_CIDS[key])

            if meta is None:
                if verbose:
                    print(
                        f"[{dev_path}] Control '{key}' is not supported by this node (run --list to see valid names)",
                        file=sys.stderr,
                    )
                continue

            cid = meta["id"]
            try:
                target_val = resolve_target_value(spec_val, meta)
            except ValueError:
                if verbose:
                    print(f"[{dev_path}] Invalid value '{spec_val}' for '{key}'", file=sys.stderr)
                continue

            cur_val = get_ctrl(fd, cid)
            if only_if_changed and cur_val is not None and cur_val == target_val:
                continue

            try:
                set_ctrl(fd, cid, target_val)
                new_val = get_ctrl(fd, cid)
                changed = True
                if verbose:
                    print(f"[{dev_path}] {key}: {cur_val} -> {new_val} (target={target_val})")
            except OSError as e:
                if verbose:
                    hint = ""
                    if meta["flags"] & V4L2_CTRL_FLAG_INACTIVE:
                        hint = " (control is inactive/locked by an auto mode switch)"
                    print(f"[{dev_path}] Failed to set {key}={target_val}: {e}{hint}", file=sys.stderr)
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
        fd = os.open(dev_path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            ctrls = query_all_controls(fd)
            for norm, m in sorted(ctrls.items(), key=lambda x: x[1]["id"]):
                cfg_val = cfg.get(norm, "-")
                if cfg_val == "-":
                    for alias_k, canon_k in CANONICAL_ALIASES.items():
                        if canon_k == norm and alias_k in cfg:
                            cfg_val = cfg[alias_k]
                            break
                inactive = " [INACTIVE]" if (m["flags"] & V4L2_CTRL_FLAG_INACTIVE) else ""
                print(
                    f"  {norm:<30} (0x{m['id']:08x}): "
                    f"cur={m['current']}  min={m['min']} max={m['max']} "
                    f"step={m['step']} def={m['default']}  [conf: {cfg_val}]{inactive}"
                )
        finally:
            os.close(fd)
    return 0


def drain_self_events(inotify_fd, dev_watch_wds):
    """Consume IN_OPEN / IN_CLOSE events generated by our own brief ioctl open/close."""
    need_rescan = False
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
            name_bytes = raw[
                offset + IN_EVENT_STRUCT.size : offset + IN_EVENT_STRUCT.size + name_len
            ]
            offset += IN_EVENT_STRUCT.size + name_len
            name = name_bytes.split(b"\x00", 1)[0].decode("utf-8", errors="ignore")
            if wd not in dev_watch_wds:
                if name.startswith("video") or name in (
                    "camera-controls.conf",
                    "cros-camera-ctrl.override.conf",
                ):
                    need_rescan = True
            elif mask & IN_DELETE_SELF:
                need_rescan = True
    return need_rescan


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

    conf_watch_mask = IN_CLOSE_WRITE | IN_CREATE | IN_MOVED_TO | IN_MODIFY | IN_DELETE
    dev_dir_wd = libc.inotify_add_watch(
        inotify_fd, b"/dev", IN_CREATE | IN_DELETE
    )
    etc_dir_wd = libc.inotify_add_watch(
        inotify_fd, b"/etc", conf_watch_mask
    )
    run_dir_wd = libc.inotify_add_watch(
        inotify_fd, b"/run", conf_watch_mask
    )
    stateful_etc = "/mnt/stateful_partition/etc"
    os.makedirs(stateful_etc, exist_ok=True)
    stateful_wd = libc.inotify_add_watch(
        inotify_fd, stateful_etc.encode("utf-8"), conf_watch_mask
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
            if is_held_by_other_process(dev_path):
                apply_controls_to_node(dev_path, controls_cfg, only_if_changed=True)
            wd = libc.inotify_add_watch(
                inotify_fd,
                dev_path.encode("utf-8"),
                IN_OPEN | IN_CLOSE_WRITE | IN_CLOSE_NOWRITE | IN_DELETE_SELF,
            )
            if wd >= 0:
                watched_nodes[wd] = dev_path
        if drain_self_events(inotify_fd, set(watched_nodes.keys())):
            reload_requested[0] = True

    refresh_watches_and_apply()

    poller = select.poll()
    poller.register(inotify_fd, select.POLLIN)

    BURST_DELAYS = (0.20, 0.60, 1.20)
    pending_bursts = []

    while True:
        now = time.monotonic()

        if reload_requested[0]:
            reload_requested[0] = False
            pending_bursts.clear()
            refresh_watches_and_apply()
            now = time.monotonic()

        if pending_bursts and now >= pending_bursts[0]:
            pending_bursts.pop(0)
            for dev_path in set(watched_nodes.values()):
                if is_held_by_other_process(dev_path):
                    apply_controls_to_node(dev_path, controls_cfg, only_if_changed=True)
            if drain_self_events(inotify_fd, set(watched_nodes.keys())):
                reload_requested[0] = True
            continue

        if pending_bursts:
            timeout_ms = max(10, int((pending_bursts[0] - now) * 1000))
        else:
            timeout_ms = None

        try:
            events = poller.poll(timeout_ms)
        except InterruptedError:
            continue

        if not events:
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
                elif wd in (etc_dir_wd, stateful_wd, run_dir_wd) and name in (
                    "camera-controls.conf",
                    "cros-camera-ctrl.override.conf",
                ):
                    need_rescan = True
                elif wd in watched_nodes:
                    if mask & IN_DELETE_SELF:
                        need_rescan = True
                    elif mask & IN_OPEN:
                        external_open_detected = True

        if need_rescan or reload_requested[0]:
            reload_requested[0] = False
            pending_bursts.clear()
            time.sleep(0.1)
            refresh_watches_and_apply()
        elif external_open_detected:
            base = time.monotonic()
            pending_bursts = [base + d for d in BURST_DELAYS]


def main():
    args = sys.argv[1:]
    if not args or "--apply" in args:
        vendor, product, cfg = load_config()
        for dev_path in find_camera_nodes(vendor, product):
            apply_controls_to_node(dev_path, cfg, only_if_changed=False, verbose=True)
        notify_daemon()
        return 0

    if "--list" in args:
        return list_camera_controls()

    if "--reset" in args:
        for path in (RUNTIME_CONF, STATEFUL_CONF):
            if os.path.exists(path):
                try:
                    os.remove(path)
                    print(f"Removed overrides in {path}.")
                except OSError as e:
                    print(f"Failed to remove {path}: {e}", file=sys.stderr)
                    return 1
        vendor, product, cfg = load_config()
        for dev_path in find_camera_nodes(vendor, product):
            apply_controls_to_node(dev_path, cfg, only_if_changed=False, verbose=True)
        notify_daemon()
        return 0

    if "--set" in args:
        idx = args.index("--set")
        persist_save = "--save" in args
        overrides = {}
        for item in args[idx + 1 :]:
            if item == "--save":
                continue
            if "=" in item:
                k, v = item.split("=", 1)
                overrides[normalize_name(k)] = v.strip()
        if not overrides:
            print("Usage: cros-camera-ctrl --set [--save] key1=val1 [key2=val2 ...]", file=sys.stderr)
            return 1
        vendor, product, _ = load_config()
        nodes = find_camera_nodes(vendor, product)
        for dev_path in nodes:
            apply_controls_to_node(dev_path, overrides, only_if_changed=False, verbose=True)
        target_conf = STATEFUL_CONF if persist_save else RUNTIME_CONF
        save_overrides(overrides, target_conf)
        notify_daemon()
        return 0

    if "--udev" in args:
        return 0

    if "--daemon" in args:
        return run_daemon()

    print("Usage: cros-camera-ctrl [--apply | --list | --set [--save] key=val ... | --reset | --daemon | --udev]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
if [ "$?" -ne 0 ]; then ret=$((ret + 2)); fi
chmod 0755 "$CTRL_BIN"
restore_selinux_file "$REF_BIN" "$CTRL_BIN" "u:object_r:cros_system_file:s0"

rm -f "$UPSTART_CONF" 2>/dev/null || true
cp -a "$REF_INIT" "$UPSTART_CONF" 2>/dev/null || true
cat <<'INITEOF' > "$UPSTART_CONF"
description "Persistent V4L2 camera property daemon for Brunch ChromeOS"
author "brunch-patch"

start on started system-services or started cros-camera
stop on stopping system-services

respawn
respawn limit 10 30

env PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
env LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib"

pre-start script
    export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
    export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib"
    for i in $(seq 1 30); do
        if /usr/local/bin/python3 -c "import ctypes, fcntl" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
end script

exec /usr/local/bin/python3 /usr/bin/cros-camera-ctrl --daemon
INITEOF
if [ "$?" -ne 0 ]; then ret=$((ret + 4)); fi
chmod 0644 "$UPSTART_CONF"
restore_selinux_file "$REF_INIT" "$UPSTART_CONF" "u:object_r:cros_conf_file:s0"

if [ "$LIVE" -eq 1 ]; then
    udevadm control --reload-rules 2>/dev/null || true
    initctl reload-configuration 2>/dev/null || true
    stop cros-camera-ctrl 2>/dev/null || true
    start cros-camera-ctrl 2>/dev/null || true
fi

exit $ret
