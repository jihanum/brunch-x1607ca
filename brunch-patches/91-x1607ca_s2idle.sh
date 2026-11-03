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
description "Arrow Lake s2idle and ACPI wakeup configuration"
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
end script
EOF
if [ "$?" -ne 0 ]; then ret=$((ret + 1)); fi
chmod 0644 /roota/etc/init/lnl-s2idle.conf
setfattr -n security.selinux -v "u:object_r:cros_conf_file:s0" /roota/etc/init/lnl-s2idle.conf 2>/dev/null || true

exit $ret
