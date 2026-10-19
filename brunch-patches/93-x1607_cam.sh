#!/bin/sh

# Install Lunar Lake SOF microphone ALSA mixer & CRAS input watchdog service.
# Runs during Brunch rootfs build; target ChromeOS rootfs is mounted at /roota.

ret=0

cp -a /roota/usr/sbin/chromeos-cleanup-logs /roota/usr/sbin/lnl-mic-daemon 2>/dev/null || true
cat > /roota/usr/sbin/lnl-mic-daemon << 'EOF'
#!/bin/bash

for i in $(seq 1 30); do
    [ -d /proc/asound/card0 ] && break
    sleep 1
done

apply_mic_settings() {
    amixer -c 0 cset numid=49 on,on,on,on >/dev/null 2>&1 || true
    amixer -c 0 cset numid=48 40,40 >/dev/null 2>&1 || true
    amixer -c 0 cset numid=7 on,on >/dev/null 2>&1 || true
    amixer -c 0 cset numid=6 50,50 >/dev/null 2>&1 || true
    cras_test_client --select_input 12:0 >/dev/null 2>&1 || true
}

for i in $(seq 1 30); do
    apply_mic_settings
    sleep 2
done

while true; do
    if amixer -c 0 cget numid=49 2>/dev/null | grep -q "values=off"; then
        apply_mic_settings
    fi
    if ! cras_test_client --dump_server_info 2>/dev/null | grep -E "12:0.*\*" >/dev/null; then
        cras_test_client --select_input 12:0 >/dev/null 2>&1 || true
    fi
    sleep 10
done
EOF
chmod 0755 /roota/usr/sbin/lnl-mic-daemon
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi

cp -a /roota/etc/init/cras.conf /roota/etc/init/lnl-mic.conf
cat > /roota/etc/init/lnl-mic.conf << 'EOF'
description "Lunar Lake SOF microphone mixer and CRAS input watchdog"
author "brunch-lunar-lake"

start on stopped startup
stop on starting halt or starting reboot
respawn

exec /usr/sbin/lnl-mic-daemon >/dev/null 2>&1
EOF
chmod 0644 /roota/etc/init/lnl-mic.conf
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi

exit $ret
