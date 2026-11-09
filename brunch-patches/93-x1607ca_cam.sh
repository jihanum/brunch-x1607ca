#!/bin/sh

chroot /roota /bin/bash -s <<'EOF'
set -o pipefail
ret=0

GBM_CUR="/usr/lib64/libgbm.so.1.0.0"
GBM_M="/usr/lib64/libgbm_m.so"
MINI="/usr/lib64/libminigbm.so.1.0.0"
EGL="/usr/lib64/libEGL_mesa.so.0.0.0"
DRI_GBM="/usr/lib64/gbm/dri_gbm.so"

REF_LIB="$MINI"
[ ! -f "$REF_LIB" ] && REF_LIB="/lib64/libc.so.6"

restore_selinux_file() {
    local ref="$1"
    local dst="$2"
    local ctx="$3"
    chcon --reference="$ref" "$dst" 2>/dev/null || true
    if command -v setfattr >/dev/null 2>&1; then
        setfattr -n security.selinux -v "$ctx" "$dst" 2>/dev/null || true
    fi
}

if [ -f "$GBM_CUR" ] && [ ! -L "$GBM_CUR" ]; then
    FILE_SIZE=$(wc -c < "$GBM_CUR" 2>/dev/null || echo 999999)
    if [ "$FILE_SIZE" -lt 60000 ]; then
        rm -f "$GBM_M"
        cp --preserve=all "$REF_LIB" "$GBM_M" 2>/dev/null || cp -a "$REF_LIB" "$GBM_M"
        chmod 0755 "$GBM_M"
        LC_ALL=C sed 's/libgbm\.so\.1\x00/libgbm_m.so\x00/g' "$GBM_CUR" > "$GBM_M"
        if [ "$?" -ne 0 ]; then ret=$((ret + 1)); fi
        restore_selinux_file "$REF_LIB" "$GBM_M" "u:object_r:cros_system_file:s0"
    fi
fi

if [ -s "$GBM_M" ] && [ -f "$MINI" ]; then
    for TARGET in "$EGL" "$DRI_GBM"; do
        if [ -f "$TARGET" ]; then
            chmod 0755 "$TARGET"
            LC_ALL=C sed 's/libgbm\.so\.1\x00/libgbm_m.so\x00/g' "$TARGET" > "${TARGET}.tmp"
            if [ "$?" -eq 0 ] && [ -s "${TARGET}.tmp" ]; then
                cat "${TARGET}.tmp" > "$TARGET"
                rm -f "${TARGET}.tmp"
                restore_selinux_file "$REF_LIB" "$TARGET" "u:object_r:cros_system_file:s0"
            else
                rm -f "${TARGET}.tmp"
                ret=$((ret + 2))
            fi
        fi
    done

    ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so.1.0.0
    ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so.1
    ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so
    for LINK in /usr/lib64/libgbm.so /usr/lib64/libgbm.so.1 /usr/lib64/libgbm.so.1.0.0; do
        chcon -h --reference="$REF_LIB" "$LINK" 2>/dev/null || true
        if command -v setfattr >/dev/null 2>&1; then
            setfattr -h -n security.selinux -v "u:object_r:cros_system_file:s0" "$LINK" 2>/dev/null || true
        fi
    done
else
    ret=$((ret + 1))
fi

if [ -f "$MINI" ]; then
    chmod 0755 "$MINI"
    LC_ALL=C sed 's/\xd5\x7d/\xd1\x7d/g' "$MINI" > "${MINI}.tmp"
    if [ "$?" -eq 0 ] && [ -s "${MINI}.tmp" ]; then
        cat "${MINI}.tmp" > "$MINI"
        rm -f "${MINI}.tmp"
        restore_selinux_file "$REF_LIB" "$MINI" "u:object_r:cros_system_file:s0"
    else
        rm -f "${MINI}.tmp"
        ret=$((ret + 4))
    fi
fi

CAMERA_CONF="/etc/init/cros-camera.conf"
if [ -f "$CAMERA_CONF" ]; then
    chmod 0644 "$CAMERA_CONF"
    grep -vE 'LIBGL_ALWAYS_SOFTWARE|MESA_LOADER_DRIVER_OVERRIDE|GALLIUM_DRIVER' "$CAMERA_CONF" | \
        sed -E 's|-S[[:space:]]+"\$\{SECCOMP_POLICY_FILE\}"||g' > "${CAMERA_CONF}.tmp"
    if [ "$?" -eq 0 ] && [ -s "${CAMERA_CONF}.tmp" ]; then
        cat "${CAMERA_CONF}.tmp" > "$CAMERA_CONF"
        rm -f "${CAMERA_CONF}.tmp"
        restore_selinux_file "/etc/init/cras.conf" "$CAMERA_CONF" "u:object_r:cros_conf_file:s0"
    else
        rm -f "${CAMERA_CONF}.tmp"
        ret=$((ret + 8))
    fi
fi

EXP_CONF="/etc/init/x1607ca-cam-exposure.conf"
cat > "$EXP_CONF" << 'INITEOF'
start on started cros-camera
stop on stopping cros-camera
respawn

script
    if ! grep -qi "X1607CA" \
        /sys/class/dmi/id/bios_version \
        /sys/class/dmi/id/board_name \
        /sys/class/dmi/id/product_name 2>/dev/null; then
        exit 0
    fi

    # Prevent USB autosuspend from wiping camera registers
    for pwr in /sys/class/video4linux/video0/device/../power/control \
               /sys/class/video4linux/video0/device/../../power/control; do
        [ -f "$pwr" ] && echo "on" > "$pwr" 2>/dev/null || true
    done

    exec /usr/bin/python3 - << 'PYEOF'
import ctypes
import fcntl
import os
import time

DEVICE = "/dev/video0"
LOG = "/var/log/x1607ca-cam-exposure.log"

VIDIOC_S_CTRL = 0xc008561c
VIDIOC_G_CTRL = 0xc008561b

class Control(ctypes.Structure):
    _fields_ = [
        ("id", ctypes.c_uint32),
        ("value", ctypes.c_int32),
    ]

def log(message):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG, "a") as f:
            f.write(f"[{timestamp}] {message}\n")
    except OSError:
        pass

def ioctl(fd, request, ctrl):
    buf = bytearray(ctypes.string_at(
        ctypes.addressof(ctrl), ctypes.sizeof(ctrl)
    ))
    fcntl.ioctl(fd, request, buf, True)
    ctypes.memmove(
        ctypes.addressof(ctrl), bytes(buf), ctypes.sizeof(ctrl)
    )

SETTINGS = [
    ("Exposure Auto",          0x009a0901, 1),
    ("Exposure Absolute",      0x009a0902, 250),
    ("Exposure Auto Priority", 0x009a0903, 0),
    ("Brightness",             0x00980900, 25),
    ("Gamma",                  0x00980910, 100),
    ("Gain",                   0x00980913, 0),
    ("Backlight Compensation", 0x0098091c, 2),
]

def apply_settings(fd):
    for name, cid, value in SETTINGS:
        try:
            ctrl = Control(id=cid, value=value)
            ioctl(fd, VIDIOC_S_CTRL, ctrl)

            if name == "Exposure Auto":
                time.sleep(0.2)

            result = Control(id=cid, value=0)
            ioctl(fd, VIDIOC_G_CTRL, result)
            log(f"OK: {name}: requested={value}, actual={result.value}")
        except OSError as e:
            log(f"FAILED: {name}: {e}")

def needs_reapply(fd):
    try:
         exp_mode = Control(id=0x009a0901, value=0)
         exp_val = Control(id=0x009a0902, value=0)
         ioctl(fd, VIDIOC_G_CTRL, exp_mode)
         ioctl(fd, VIDIOC_G_CTRL, exp_val)
         return exp_mode.value != 1 or exp_val.value != 250
    except OSError:
        return False

log("Starting x1607ca camera exposure daemon")

while True:
    if os.path.exists(DEVICE):
        try:
            fd = os.open(DEVICE, os.O_RDWR | os.O_NONBLOCK)
            try:
                if needs_reapply(fd):
                    time.sleep(0.3)
                    apply_settings(fd)
            finally:
                os.close(fd)
        except OSError as e:
            log(f"Device access error: {e}")
    time.sleep(2)
PYEOF
end script
INITEOF

chmod 0644 "$EXP_CONF"
restore_selinux_file "/etc/init/cras.conf" "$EXP_CONF" "u:object_r:cros_conf_file:s0"

exit $ret
EOF

exit $?
