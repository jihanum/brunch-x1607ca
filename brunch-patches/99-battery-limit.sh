#!/bin/sh

set_battery_limit=0
for i in $(echo "$1" | sed 's#,# #g')
do
    if [ "$i" = "set-battery-limit" ] || [ "$i" = "set_battery_limit" ] || [ "$i" = "set-battery-limit=1" ]; then
        set_battery_limit=1
    fi
done

for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        set-battery-limit=1|set_battery_limit=1)
            set_battery_limit=1
            ;;
    esac
done

ret=0

if [ "$set_battery_limit" -eq 1 ]; then
    echo "brunch: $0 battery charge limit (80%) enabled" > /dev/kmsg

    cat > /roota/usr/sbin/battery-limit << 'SCRIPT'
#!/bin/bash

TARGET=80
FORCE=0

[ "${1:-}" = "--force" ] && FORCE=1

if [ ! -e /sys/class/power_supply/BAT1/charge_control_end_threshold ]; then
    modprobe asus_wmi 2>/dev/null || true
    modprobe asus_nb_wmi 2>/dev/null || true
fi

found=0
failed=0

for path in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
    [ -e "$path" ] || continue
    found=1

    current=$(cat "$path" 2>/dev/null)

    if [ "$FORCE" -eq 1 ]; then
        # Explicit EC refresh, rather than doing this every five minutes.
        if printf '100\n' > "$path"; then
            sleep 1
            printf '%s\n' "$TARGET" > "$path" || failed=1
        else
            failed=1
        fi
    elif [ "$current" != "$TARGET" ]; then
        printf '%s\n' "$TARGET" > "$path" || failed=1
    fi

    actual=$(cat "$path" 2>/dev/null)
    if [ "$actual" != "$TARGET" ]; then
        echo "Battery threshold verification failed: $actual" >&2
        failed=1
    fi
done

[ "$found" -eq 1 ] && [ "$failed" -eq 0 ]
SCRIPT
    if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi

    chmod 0755 /roota/usr/sbin/battery-limit
    if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi

    cat > /roota/etc/init/battery-limit.conf << 'INIT'
description "ASUS Vivobook X1607CA Battery Charge Limit Monitor"
author "brunch-patch"

start on started system-services
stop on stopping system-services

respawn

script
    /usr/sbin/battery-limit --force || true
    while sleep 300; do
        /usr/sbin/battery-limit || true
    done
end script
INIT
    if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 2))); fi
fi

exit $ret
