#!/bin/sh

ret=0

if [ -d /roota/usr/share/power_manager ]; then
    echo 1 > /roota/usr/share/power_manager/suspend_to_idle
    echo s2idle > /roota/usr/share/power_manager/suspend_mode
    echo 1 > /roota/usr/share/power_manager/use_lid
    echo 1 > /roota/usr/share/power_manager/ignore_external_policy
    setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" /roota/usr/share/power_manager/suspend_to_idle 2>/dev/null || true
    setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" /roota/usr/share/power_manager/suspend_mode 2>/dev/null || true
    setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" /roota/usr/share/power_manager/use_lid 2>/dev/null || true
    setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" /roota/usr/share/power_manager/ignore_external_policy 2>/dev/null || true
    if [ -d /roota/usr/share/power_manager/board_specific ]; then
        echo 1 > /roota/usr/share/power_manager/board_specific/suspend_to_idle
        echo s2idle > /roota/usr/share/power_manager/board_specific/suspend_mode
        echo 1 > /roota/usr/share/power_manager/board_specific/use_lid
        echo 1 > /roota/usr/share/power_manager/board_specific/ignore_external_policy
        setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" /roota/usr/share/power_manager/board_specific/suspend_to_idle 2>/dev/null || true
        setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" /roota/usr/share/power_manager/board_specific/suspend_mode 2>/dev/null || true
        setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" /roota/usr/share/power_manager/board_specific/use_lid 2>/dev/null || true
        setfattr -n security.selinux -v "u:object_r:cros_system_file:s0" /roota/usr/share/power_manager/board_specific/ignore_external_policy 2>/dev/null || true
    fi
fi

cat > /roota/etc/init/lnl-s2idle.conf << 'EOF'
description "Arrow Lake s2idle, Package C10, and ACPI wakeup configuration"
author "brunch-arl-lnl"

start on starting powerd
task

script
    [ -w /sys/power/mem_sleep ] && echo s2idle > /sys/power/mem_sleep || true
    [ -w /sys/power/pm_test ] && echo none > /sys/power/pm_test || true
    [ -w /sys/power/pm_trace ] && echo 0 > /sys/power/pm_trace || true

    if [ -r /proc/acpi/wakeup ] && [ -w /proc/acpi/wakeup ]; then
        for dev in RP10 TXHC XHCI; do
            if grep -q "^${dev}[[:space:]].*\*enabled" /proc/acpi/wakeup; then
                echo "$dev" > /proc/acpi/wakeup || true
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

    (
        for i in $(seq 1 30); do
            [ -e /sys/kernel/debug/pmc_core/ltr_ignore ] && break
            sleep 0.5
        done

        if [ -w /sys/module/intel_pmc_core/parameters/ltr_ignore_all_suspend ]; then
            echo N > /sys/module/intel_pmc_core/parameters/ltr_ignore_all_suspend 2>/dev/null || true
        fi

        for idx in 3 4 6 9 10 11 12 15 17 21 22 24 31 32 34 37 38 39 40; do
            echo "$idx" > /sys/kernel/debug/pmc_core/ltr_ignore 2>/dev/null || true
        done

        if [ -w /sys/module/pcie_aspm/parameters/policy ]; then
            echo powersupersave > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
        fi
        if [ -w /sys/bus/pci/devices/0000:01:00.0/d3cold_allowed ]; then
            echo 0 > /sys/bus/pci/devices/0000:01:00.0/d3cold_allowed 2>/dev/null || true
        fi

        if [ -x /usr/local/bin/python3 ]; then
            /usr/local/bin/python3 - << 'PYEOF'
import os, struct

cfg_path = "/sys/bus/pci/devices/0000:00:08.0/config"
if os.path.exists(cfg_path) and not os.path.exists("/sys/bus/pci/devices/0000:00:08.0/driver"):
    fd = os.open(cfg_path, os.O_RDWR)
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
    os.close(fd)
PYEOF
        fi

        for ctrl in /sys/bus/usb/devices/*/power/control \
                    /sys/bus/pci/devices/*/power/control \
                    /sys/bus/i2c/devices/*/power/control \
                    /sys/bus/mei/devices/*/power/control; do
            [ -w "$ctrl" ] && echo auto > "$ctrl" 2>/dev/null || true
        done
    ) &
end script
EOF
if [ "$?" -ne 0 ]; then ret=$((ret + 1)); fi
chmod 0644 /roota/etc/init/lnl-s2idle.conf
setfattr -n security.selinux -v "u:object_r:cros_conf_file:s0" /roota/etc/init/lnl-s2idle.conf 2>/dev/null || true

exit $ret
