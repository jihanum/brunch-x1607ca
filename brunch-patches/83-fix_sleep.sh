#!/bin/sh

# 1. Ensure kernel sleep mode is s2idle and debug modes are off
echo s2idle > /sys/power/mem_sleep
echo none > /sys/power/pm_test
echo 0 > /sys/power/pm_trace

# 2. Disable NVMe (RP10) and USB/Thunderbolt (TXHC, XHCI) wake triggers
for dev in RP10 TXHC XHCI; do
    if grep -q "^${dev}.*\*enabled" /proc/acpi/wakeup; then
        echo "$dev" > /proc/acpi/wakeup
    fi
done

# 3. Lock ChromeOS powerd to s2idle (S0ix)
mkdir -p /var/lib/power_manager
echo 1 > /var/lib/power_manager/suspend_to_idle
echo s2idle > /var/lib/power_manager/suspend_mode
