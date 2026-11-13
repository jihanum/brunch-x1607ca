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

REF_INIT="${ROOT}/etc/init/cras.conf"
[ ! -f "$REF_INIT" ] && REF_INIT="${ROOT}/etc/init/ui.conf"

if [ -d "${ROOT}/usr/share/power_manager" ]; then
    echo 1 > "${ROOT}/usr/share/power_manager/suspend_to_idle"
    echo s2idle > "${ROOT}/usr/share/power_manager/suspend_mode"
    echo 1 > "${ROOT}/usr/share/power_manager/use_lid"
    echo 1 > "${ROOT}/usr/share/power_manager/ignore_external_policy"
    setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" "${ROOT}/usr/share/power_manager/suspend_to_idle" 2>/dev/null || true
    setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" "${ROOT}/usr/share/power_manager/suspend_mode" 2>/dev/null || true
    setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" "${ROOT}/usr/share/power_manager/use_lid" 2>/dev/null || true
    setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" "${ROOT}/usr/share/power_manager/ignore_external_policy" 2>/dev/null || true
    if [ -d "${ROOT}/usr/share/power_manager/board_specific" ]; then
        echo 1 > "${ROOT}/usr/share/power_manager/board_specific/suspend_to_idle"
        echo s2idle > "${ROOT}/usr/share/power_manager/board_specific/suspend_mode"
        echo 1 > "${ROOT}/usr/share/power_manager/board_specific/use_lid"
        echo 1 > "${ROOT}/usr/share/power_manager/board_specific/ignore_external_policy"
        setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" "${ROOT}/usr/share/power_manager/board_specific/suspend_to_idle" 2>/dev/null || true
        setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" "${ROOT}/usr/share/power_manager/board_specific/suspend_mode" 2>/dev/null || true
        setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" "${ROOT}/usr/share/power_manager/board_specific/use_lid" 2>/dev/null || true
        setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" "${ROOT}/usr/share/power_manager/board_specific/ignore_external_policy" 2>/dev/null || true
    fi
fi

if [ -f "${ROOT}/lib/udev/rules.d/99-x1607ca-uhid.rules" ]; then
    sed -i 's/ATTR{power\/control}="on"/ATTR{power\/control}="auto", ATTR{power\/autosuspend_delay_ms}="2000"/g' \
        "${ROOT}/lib/udev/rules.d/99-x1607ca-uhid.rules" 2>/dev/null || true
fi
if [ -f "${ROOT}/etc/modprobe.d/99-x1607ca-btusb.conf" ]; then
    sed -i 's/enable_autosuspend=0/enable_autosuspend=1/g' \
        "${ROOT}/etc/modprobe.d/99-x1607ca-btusb.conf" 2>/dev/null || true
fi

rm -f "${ROOT}/etc/init/lnl-runtime-pm.conf" 2>/dev/null || true
UPSTART_CONF="${ROOT}/etc/init/lnl-s2idle.conf"
rm -f "$UPSTART_CONF" 2>/dev/null || true
cp -a "$REF_INIT" "$UPSTART_CONF" 2>/dev/null || true

cat << 'EOF' > "$UPSTART_CONF"
description "Arrow Lake s2idle, Runtime PC8, Package C10, and ACPI wakeup daemon"
author "brunch-arl-lnl"

start on starting powerd
stop on stopping powerd
respawn
respawn limit 10 30

env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
env LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib"

pre-start script
    set +e
    [ -w /sys/power/mem_sleep ] && echo s2idle > /sys/power/mem_sleep 2>/dev/null || true
    [ -w /sys/power/pm_test ] && echo none > /sys/power/pm_test 2>/dev/null || true
    [ -w /sys/power/pm_trace ] && echo 0 > /sys/power/pm_trace 2>/dev/null || true

    if [ -r /proc/acpi/wakeup ] && [ -w /proc/acpi/wakeup ]; then
        for dev in RP10 TXHC XHCI; do
            if grep -q "^${dev}[[:space:]].*\*enabled" /proc/acpi/wakeup; then
                echo "$dev" > /proc/acpi/wakeup 2>/dev/null || true
            fi
        done
    fi

    mkdir -p /var/lib/power_manager
    echo 1 > /var/lib/power_manager/suspend_to_idle
    echo s2idle > /var/lib/power_manager/suspend_mode
    echo 1 > /var/lib/power_manager/use_lid
    echo 1 > /var/lib/power_manager/ignore_external_policy
    chmod 0755 /var/lib/power_manager
    chmod 0644 /var/lib/power_manager/*
    restorecon -R /var/lib/power_manager 2>/dev/null || true
end script

script
    set +e
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib"

    for i in $(seq 1 60); do
        if [ -e /sys/kernel/debug/pmc_core/ltr_ignore ] && /usr/local/bin/python3 -c "import os, struct" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    exec /usr/local/bin/python3 -u - << 'PYEOF'
import glob
import os
import struct
import time

UNBOUND_BDFS = ("0000:00:08.0", "0000:00:0a.0", "0000:00:14.2")
LTR_INDICES = (3, 4, 6, 9, 10, 11, 12, 15, 17, 21, 22, 24, 31, 32, 34, 37, 38, 39, 40)

def write_sysfs(path, val):
    try:
        with open(path, "w") as f:
            f.write(val)
    except Exception:
        pass

def read_sysfs(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except Exception:
        return ""

def force_d3hot(bdf):
    drv_path = f"/sys/bus/pci/devices/{bdf}/driver"
    if os.path.exists(f"{drv_path}/unbind"):
        write_sysfs(f"{drv_path}/unbind", bdf)
    ctrl_path = f"/sys/bus/pci/devices/{bdf}/power/control"
    if read_sysfs(ctrl_path) != "auto":
        write_sysfs(ctrl_path, "auto")
    if os.path.exists(drv_path):
        return
    if read_sysfs(f"/sys/bus/pci/devices/{bdf}/power_state") != "D0":
        return
    cfg_path = f"/sys/bus/pci/devices/{bdf}/config"
    if not os.path.exists(cfg_path):
        return
    try:
        fd = os.open(cfg_path, os.O_RDWR)
        try:
            cmd = struct.unpack("<H", os.pread(fd, 2, 0x04))[0]
            if cmd & 0x07:
                os.pwrite(fd, struct.pack("<H", cmd & ~0x07), 0x04)
            hdr = os.pread(fd, 64, 0)
            cap_ptr = hdr[0x34] & 0xFC if (hdr[0x06] & 0x10) else 0
            while cap_ptr:
                cap = os.pread(fd, 8, cap_ptr)
                if cap[0] == 0x01:
                    pmcsr = struct.unpack("<H", cap[4:6])[0]
                    if (pmcsr & 0x03) != 0x03:
                        os.pwrite(fd, struct.pack("<H", (pmcsr & ~0x03) | 0x03), cap_ptr + 4)
                    break
                cap_ptr = cap[1] & 0xFC
        finally:
            os.close(fd)
    except Exception:
        pass

def apply_all():
    write_sysfs("/sys/module/pcie_aspm/parameters/policy", "powersupersave")
    write_sysfs("/sys/bus/pci/devices/0000:01:00.0/d3cold_allowed", "0")
    write_sysfs("/sys/module/usbcore/parameters/autosuspend", "2")
    for lat in (
        glob.glob("/sys/class/nvme/nvme*/default_ps_max_latency_us")
        + glob.glob("/sys/class/nvme/nvme*/power/default_ps_max_latency_us")
        + ["/sys/module/nvme_core/parameters/default_ps_max_latency_us"]
    ):
        if os.path.exists(lat):
            write_sysfs(lat, "100000")

    for u in glob.glob("/sys/bus/usb/devices/*"):
        delay_path = f"{u}/power/autosuspend_delay_ms"
        if os.path.exists(delay_path):
            try:
                if int(read_sysfs(delay_path)) < 0:
                    target = "0" if os.path.basename(u).startswith("usb") else "2000"
                    write_sysfs(delay_path, target)
            except Exception:
                pass
        ctrl_path = f"{u}/power/control"
        if os.path.exists(ctrl_path) and read_sysfs(ctrl_path) != "auto":
            write_sysfs(ctrl_path, "auto")

    for pattern in (
        "/sys/bus/pci/devices/*/power/control",
        "/sys/bus/i2c/devices/*/power/control",
        "/sys/bus/mei/devices/*/power/control",
        "/sys/bus/platform/devices/*/power/control",
        "/sys/class/sound/card*/power/control",
    ):
        for ctrl in glob.glob(pattern):
            if read_sysfs(ctrl) != "auto":
                write_sysfs(ctrl, "auto")

    for bdf in UNBOUND_BDFS:
        force_d3hot(bdf)

write_sysfs("/sys/module/intel_pmc_core/parameters/ltr_ignore_all_suspend", "N")
for idx in LTR_INDICES:
    write_sysfs("/sys/kernel/debug/pmc_core/ltr_ignore", str(idx))

for _ in range(4):
    apply_all()
    time.sleep(2.5)

last_susp = read_sysfs("/sys/power/suspend_stats/success")
while True:
    time.sleep(10.0)
    cur_susp = read_sysfs("/sys/power/suspend_stats/success")
    if cur_susp != last_susp:
        apply_all()
        last_susp = cur_susp
        continue
    for bdf in UNBOUND_BDFS:
        if read_sysfs(f"/sys/bus/pci/devices/{bdf}/power_state") == "D0":
            force_d3hot(bdf)
    for u in glob.glob("/sys/bus/usb/devices/*"):
        ctrl_path = f"{u}/power/control"
        if os.path.exists(ctrl_path) and read_sysfs(ctrl_path) != "auto":
            delay_path = f"{u}/power/autosuspend_delay_ms"
            try:
                if int(read_sysfs(delay_path)) < 0:
                    write_sysfs(delay_path, "0" if os.path.basename(u).startswith("usb") else "2000")
            except Exception:
                pass
            write_sysfs(ctrl_path, "auto")
PYEOF
end script
EOF
if [ "$?" -ne 0 ]; then ret=$((ret + 1)); fi
chmod 0644 "$UPSTART_CONF"
restore_selinux_file "$REF_INIT" "$UPSTART_CONF" "u:object_r:cros_init_conf_file:s0"

if [ "$LIVE" -eq 1 ]; then
    initctl reload-configuration 2>/dev/null || true
    stop lnl-s2idle 2>/dev/null || true
    start lnl-s2idle 2>/dev/null || true
fi

exit $ret
