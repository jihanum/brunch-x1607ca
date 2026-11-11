ret=0

cat > /roota/lib/udev/rules.d/99-x1607ca-uhid.rules << 'EOF'
KERNEL=="uhid", SUBSYSTEM=="misc", OWNER="bluetooth", GROUP="bluetooth", MODE="0660", RUN+="/bin/chcon u:object_r:uhid_device:s0 /dev/uhid"
EOF
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi

cat > /roota/etc/init/x1607ca-bt.conf << 'EOF'
start on started boot-services
stop on stopping boot-services

env BT_USB_AUTOSUSPEND_OFF=0

script
    if ! grep -qi "X1607CA" /sys/class/dmi/id/bios_version /sys/class/dmi/id/board_name 2>/dev/null; then
        exit 0
    fi

    # Fix /dev/uhid ownership, permissions (0660 instead of 0666), and SELinux label
    if [ -e /dev/uhid ]; then
        chown bluetooth:bluetooth /dev/uhid
        chmod 0660 /dev/uhid
        chcon u:object_r:uhid_device:s0 /dev/uhid 2>/dev/null || true
    fi

    # Preserve ChromeOS native u:object_r:cros_var_lib_bluetooth:s0 context
    if [ -d /var/lib/bluetooth ]; then
        chown -R bluetooth:bluetooth /var/lib/bluetooth
        find /var/lib/bluetooth -type d -exec chmod 0770 {} +
        find /var/lib/bluetooth -type f -exec chmod 0660 {} +
        chcon -R u:object_r:cros_var_lib_bluetooth:s0 /var/lib/bluetooth 2>/dev/null || true
    fi

    # Optional: Disable USB autosuspend for Intel Bluetooth (8087:*)
    if [ "${BT_USB_AUTOSUSPEND_OFF}" = "1" ]; then
        for dev in /sys/bus/usb/devices/*; do
            if [ -f "${dev}/idVendor" ] && [ "$(cat "${dev}/idVendor")" = "8087" ]; then
                [ -w "${dev}/power/control" ] && echo "on" > "${dev}/power/control"
            fi
        done
    fi
end script
EOF
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi

exit $ret
