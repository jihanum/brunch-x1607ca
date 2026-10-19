#!/bin/sh

# Configure Lunar Lake s2idle (S0ix) defaults and disable spurious ACPI wake triggers.

ret=0

if [ -d /roota/usr/share/power_manager ]; then
	echo 1 > /roota/usr/share/power_manager/suspend_to_idle
	echo s2idle > /roota/usr/share/power_manager/suspend_mode
	if [ -d /roota/usr/share/power_manager/board_specific ]; then
		echo 1 > /roota/usr/share/power_manager/board_specific/suspend_to_idle
		echo s2idle > /roota/usr/share/power_manager/board_specific/suspend_mode
	fi
fi

cp -a /roota/etc/init/cras.conf /roota/etc/init/lnl-s2idle.conf
cat > /roota/etc/init/lnl-s2idle.conf << 'EOF'
description "Lunar Lake s2idle and ACPI wakeup configuration"
author "brunch-lunar-lake"

start on starting powerd or stopped startup
task

script
    # 1. Ensure kernel sleep mode is s2idle and debug modes are off
    [ -w /sys/power/mem_sleep ] && echo s2idle > /sys/power/mem_sleep || true
    [ -w /sys/power/pm_test ] && echo none > /sys/power/pm_test || true
    [ -w /sys/power/pm_trace ] && echo 0 > /sys/power/pm_trace || true

    # 2. Disable NVMe (RP10) and USB/Thunderbolt (TXHC, XHCI) wake triggers
    if [ -r /proc/acpi/wakeup ] && [ -w /proc/acpi/wakeup ]; then
        for dev in RP10 TXHC XHCI; do
            if grep -q "^${dev}.*\*enabled" /proc/acpi/wakeup; then
                echo "$dev" > /proc/acpi/wakeup || true
            fi
        done
    fi

    # 3. Lock ChromeOS powerd to s2idle (S0ix) on stateful partition
    mkdir -p /var/lib/power_manager
    echo 1 > /var/lib/power_manager/suspend_to_idle
    echo s2idle > /var/lib/power_manager/suspend_mode
end script
EOF
chmod 0644 /roota/etc/init/lnl-s2idle.conf
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi

exit $ret
