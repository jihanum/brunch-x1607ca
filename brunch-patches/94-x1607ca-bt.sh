#!/bin/sh
# ASUS Vivobook 16 (X1607CA) Bluetooth Fix for Floss (btadapterd uhid_hfp panic & config permission denied)
# Intel AX101

ret=0

mkdir -p /roota/lib/udev/rules.d
cat << 'UDEV' > /roota/lib/udev/rules.d/99-x1607ca-bluetooth.rules
KERNEL=="uhid", SUBSYSTEM=="misc", MODE="0666", GROUP="uhid"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0026", ATTR{power/control}="on", ATTR{power/autosuspend}="0"
UDEV
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi

mkdir -p /roota/etc/modprobe.d
cat << 'MODPROBE' > /roota/etc/modprobe.d/btusb-x1607ca.conf
options btusb enable_autosuspend=0
MODPROBE
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi

cat << 'UPSTART' > /roota/etc/init/bt-x1607ca-fix.conf
description "X1607CA Bluetooth UHID and Storage Permission Fix"
author "brunch-lunar-lake"

start on starting btmanagerd or starting btadapterd
task

script
  # Prevent Kernel 7.1 SELinux policy from denying /dev/uhid and socket operations
  setenforce 0 2>/dev/null || true

  # Ensure /dev/uhid exists and is writable by btadapterd (fixes uhid_hfp.rs:121 panic)
  modprobe uhid 2>/dev/null || true
  if [ -e /dev/uhid ]; then
    chown bluetooth:uhid /dev/uhid 2>/dev/null || true
    chmod 0666 /dev/uhid 2>/dev/null || true
  fi

  # Ensure /var/lib/bluetooth is writable and fix relative path 'bt_remote_dev_info.conf.new'
  mkdir -p /var/lib/bluetooth/btstack /var/lib/bluetooth/sysprops.conf.d
  touch /var/lib/bluetooth/bt_remote_dev_info.conf /var/lib/bluetooth/bt_remote_dev_info.conf.new
  chown -R bluetooth:bluetooth /var/lib/bluetooth 2>/dev/null || true
  chmod -R 0775 /var/lib/bluetooth 2>/dev/null || true

  # Disable btusb autosuspend live
  if [ -e /sys/module/btusb/parameters/enable_autosuspend ]; then
    echo N > /sys/module/btusb/parameters/enable_autosuspend 2>/dev/null || true
  fi
end script
UPSTART
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 2))); fi

if [ -f /roota/etc/init/btadapterd.conf ]; then
  sed -i 's|-b /dev/uhid\b|-b /dev/uhid,,1|g' /roota/etc/init/btadapterd.conf
  if ! grep -q "chdir /var/lib/bluetooth" /roota/etc/init/btadapterd.conf; then
    sed -i '/^expect /i chdir /var/lib/bluetooth' /roota/etc/init/btadapterd.conf
  fi
fi

ln -sf /var/lib/bluetooth/bt_remote_dev_info.conf /roota/bt_remote_dev_info.conf
ln -sf /var/lib/bluetooth/bt_remote_dev_info.conf.new /roota/bt_remote_dev_info.conf.new

exit $ret
