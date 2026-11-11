#!/bin/sh
# Brunch initramfs patch: /patches/97-x1607ca-power.sh
# Injects x1607ca-power v3.1 and an SELinux-labeled Upstart service into /roota.

ret=0

mkdir -p /roota/usr/bin /roota/usr/libexec /roota/etc/init || ret=$((ret + 1))

# Clone existing files first with cp -a so security.selinux xattrs are preserved on the inodes
cp -a /roota/usr/bin/sh /roota/usr/libexec/x1607ca-power.py 2>/dev/null || true
cp -a /roota/usr/bin/sh /roota/usr/bin/x1607ca-power 2>/dev/null || true
cp -a /roota/etc/init/ui.conf /roota/etc/init/x1607ca-power.conf 2>/dev/null || true

cat > /roota/usr/libexec/x1607ca-power.py <<'X1607CA_V3_SOURCE'
#!/usr/local/bin/python3
"""ASUS X1607CA Brunch power profiles, event-driven v3.1."""
import fcntl
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import time

BASE = Path('/mnt/stateful_partition/brunch/power-profile')
MODE_FILE = BASE / 'selected_mode'
PROFILE = Path('/sys/firmware/acpi/platform_profile')
CHOICES = Path('/sys/firmware/acpi/platform_profile_choices')
SUPPLIES = Path('/sys/class/power_supply')
CPUFREQ = Path('/sys/devices/system/cpu/cpufreq')
LOCK_FILE = Path('/run/x1607ca-power-events.lock')
PID_FILE = Path('/run/x1607ca-power-events.pid')
RESUME_FLAG = Path('/run/x1607ca-power-resume-watcher')
MODES = {'auto', 'quiet', 'balanced', 'performance'}
EPP = {'quiet': 'balance_power', 'balanced': 'balance_performance', 'performance': 'performance'}


def read(path, default=''):
    try:
        return Path(path).read_text().strip()
    except (OSError, UnicodeError):
        return default


def log(message):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}", flush=True)


def supported_device():
    return any('X1607CA' in read('/sys/class/dmi/id/' + name).upper()
               for name in ('product_name', 'board_name'))


def mode():
    choice = read(MODE_FILE, 'auto')
    return choice if choice in MODES else 'auto'


def power_source():
    supplies = list(SUPPLIES.iterdir()) if SUPPLIES.is_dir() else []
    saw_supply = False
    for dev in supplies:
        kind = read(dev / 'type')
        if (kind == 'Mains' or kind == 'USB' or kind.startswith('USB_')) and (dev / 'online').exists():
            saw_supply = True
            if read(dev / 'online') == '1':
                return 'ac'
    if saw_supply:
        return 'battery'
    for dev in supplies:
        if read(dev / 'type') != 'Battery':
            continue
        battery_status = read(dev / 'status')
        if battery_status == 'Discharging':
            return 'battery'
        if battery_status in ('Charging', 'Full'):
            return 'ac'
    return 'unknown'


def desired():
    current_mode = mode()
    source = power_source()
    target = current_mode
    if current_mode == 'auto':
        target = {'battery': 'quiet', 'ac': 'balanced'}.get(source)
        if target is None:
            raise RuntimeError('Cannot determine AC/battery power source')
    return target, EPP[target], source, current_mode


def cpu_policies():
    return sorted(CPUFREQ.glob('policy*'))


def mismatches():
    target, epp, _, _ = desired()
    differences = []
    if read(PROFILE) != target:
        differences.append(f'ASUS: {read(PROFILE, "unavailable")} -> {target}')
    for policy in cpu_policies():
        preference = policy / 'energy_performance_preference'
        choices = (policy / 'energy_performance_available_preferences')
        if not preference.exists() or epp not in read(choices).split():
            continue
        current = read(preference)
        if current != epp:
            differences.append(f'{policy.name}: {current} -> {epp}')
    return differences


def apply():
    target, epp, source, selection = desired()
    if target not in read(CHOICES).split():
        raise RuntimeError(f'Unsupported ASUS profile {target} or choices not ready')
    if not os.access(PROFILE, os.W_OK):
        raise RuntimeError(f'ASUS profile not writable: {PROFILE}')
    previous = read(PROFILE)
    changed = 0
    if previous != target:
        PROFILE.write_text(target + '\n')
        if read(PROFILE) != target:
            raise RuntimeError(f'ASUS profile readback does not match {target}')
        changed += 1
        log(f'ASUS profile {previous} -> {target} ({selection}, {source})')
    failures = []
    for policy in cpu_policies():
        preference = policy / 'energy_performance_preference'
        options = (policy / 'energy_performance_available_preferences')
        if not preference.exists() or epp not in read(options).split():
            continue
        if read(preference) == epp:
            continue
        try:
            preference.write_text(epp + '\n')
            if read(preference) != epp:
                raise OSError(f'EPP readback did not match {epp}')
            changed += 1
        except OSError as exc:
            failures.append(f'{policy.name}: {exc}')
    if failures:
        raise RuntimeError('Unable to apply some CPU EPP values: ' + '; '.join(failures))
    if changed:
        log(f'Applied {selection} ({source}): {target}, EPP={epp}; updated {changed} setting(s)')
    return changed


def process_matches(pid):
    if pid <= 1:
        return False
    raw = Path(f'/proc/{pid}/cmdline')
    try:
        parts = raw.read_bytes().decode(errors='replace').split('\0')
    except OSError:
        return False
    return any('x1607ca-power' in part for part in parts) and 'daemon' in parts


def daemon_pid():
    val = read(PID_FILE)
    if not val.isdigit():
        return None
    pid = int(val)
    return pid if process_matches(pid) else None


def status():
    print(f'Model: {read("/sys/class/dmi/id/board_name", read("/sys/class/dmi/id/product_name", "unknown"))}')
    print(f'Selected mode: {mode()}')
    print(f'Power source: {power_source()}')
    print(f'ASUS profile: {read(PROFILE, "unavailable")}')
    print(f'Available: {read(CHOICES, "unavailable")}')
    try:
        target, epp, _, _ = desired()
        print(f'Target: ASUS={target}, CPU EPP={epp}')
        differences = mismatches()
        print(f'Target mismatch: {"yes" if differences else "no"}')
        for item in differences[:5]:
            print(f'  {item}')
        if len(differences) > 5:
            print(f'  ...and {len(differences) - 5} more')
    except RuntimeError as exc:
        print(f'Target unavailable: {exc}')
    print('Current EPP distribution:')
    counts = {}
    for policy in cpu_policies():
        val = read(policy / 'energy_performance_preference')
        if val:
            counts[val] = counts.get(val, 0) + 1
    for key in sorted(counts):
        print(f'  {counts[key]:4} {key}')
    print(f'Turbo disabled (1=yes): {read("/sys/devices/system/cpu/intel_pstate/no_turbo", "unknown")}')
    pid = daemon_pid()
    print(f'Event monitor: {"running (PID " + str(pid) + ")" if pid else "not running"}')
    if pid:
        print('Resume listener: ' + ('active' if RESUME_FLAG.exists() else 'unavailable (power_supply only)'))


def set_mode(selection):
    BASE.mkdir(parents=True, exist_ok=True)
    tmp = MODE_FILE.with_name(f'{MODE_FILE.name}.{os.getpid()}')
    tmp.write_text(selection + '\n')
    os.replace(tmp, MODE_FILE)
    return apply()


def uevent_is_power_supply(payload):
    fields = {}
    for fragment in payload.split(b'\0'):
        if b'=' in fragment:
            key, value = fragment.split(b'=', 1)
            fields[key] = value
    return (fields.get(b'SUBSYSTEM') == b'power_supply'
            and fields.get(b'ACTION') in (b'change', b'add', b'remove'))


def stop():
    pid = daemon_pid()
    if not pid:
        print('Event monitor not running')
        return
    os.kill(pid, signal.SIGTERM)
    print(f'Sent stop request to event monitor PID {pid}')


def run_daemon():
    lock_fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Event monitor already running', file=sys.stderr)
        os.close(lock_fd)
        return 0

    selector = selectors.DefaultSelector()
    dbus_proc = None
    netlink = None
    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_w, False)
    selector.register(wake_r, selectors.EVENT_READ, 'signal')
    exit_requested = False
    deferred_at = None

    def request_exit(_sig, _frame):
        nonlocal exit_requested
        exit_requested = True
        try:
            os.write(wake_w, b'!')
        except OSError:
            pass

    signal.signal(signal.SIGTERM, request_exit)
    signal.signal(signal.SIGINT, request_exit)

    def handle_event(origin):
        nonlocal deferred_at
        try:
            changes = mismatches()
            if changes:
                log(f'{origin}: {len(changes)} mismatch(es); applying')
                apply()
            else:
                log(f'{origin}: policy already matches target')
        except (OSError, RuntimeError) as exc:
            log(f'WARNING {origin}: {exc}')
        deferred_at = time.monotonic() + 3.0

    try:
        netlink = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, 15)
        netlink.setblocking(False)
        netlink.bind((os.getpid(), 1))
        selector.register(netlink, selectors.EVENT_READ, 'uevent')

        tool = shutil.which('dbus-monitor')
        if tool:
            dbus_proc = subprocess.Popen(
                [tool, '--system', "type='signal',interface='org.chromium.PowerManager',member='SuspendDone'"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
            os.set_blocking(dbus_proc.stdout.fileno(), False)
            selector.register(dbus_proc.stdout, selectors.EVENT_READ, 'dbus')
            RESUME_FLAG.write_text('dbus-monitor started\n')
        else:
            log('WARNING: dbus-monitor unavailable; automatic reapply on resume is not guaranteed')

        PID_FILE.write_text(str(os.getpid()) + '\n')
        log('Started event-driven monitor (kernel power_supply uevents, powerd resume if available)')
        try:
            apply()
        except (OSError, RuntimeError) as exc:
            log(f'WARNING initial apply: {exc}')

        dbus_buffer = b''
        while not exit_requested:
            timeout = None if deferred_at is None else max(0, deferred_at - time.monotonic())
            events = selector.select(timeout)
            if deferred_at is not None and time.monotonic() >= deferred_at:
                deferred_at = None
                try:
                    if mismatches():
                        log('Post-event verification found drift; reapplying once')
                        apply()
                except (OSError, RuntimeError) as exc:
                    log(f'WARNING post-event verification: {exc}')
            for key, _ in events:
                if key.data == 'signal':
                    os.read(wake_r, 4096)
                    continue
                if key.data == 'uevent':
                    try:
                        payload = netlink.recv(65536)
                    except BlockingIOError:
                        continue
                    if uevent_is_power_supply(payload):
                        handle_event('power_supply event')
                elif key.data == 'dbus':
                    chunk = os.read(dbus_proc.stdout.fileno(), 8192)
                    if not chunk:
                        selector.unregister(dbus_proc.stdout)
                        dbus_proc.stdout.close()
                        RESUME_FLAG.unlink(missing_ok=True)
                        log('WARNING: dbus-monitor exited; resume notifications unavailable')
                        continue
                    dbus_buffer += chunk
                    while b'\n' in dbus_buffer:
                        line, dbus_buffer = dbus_buffer.split(b'\n', 1)
                        if b'member=SuspendDone' in line:
                            handle_event('powerd SuspendDone')
                    if len(dbus_buffer) > 65536:
                        dbus_buffer = dbus_buffer[-4096:]
        return 0
    finally:
        if dbus_proc is not None:
            dbus_proc.terminate() if dbus_proc.poll() is None else None
            try:
                dbus_proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                dbus_proc.kill()
            if dbus_proc.stdout and not dbus_proc.stdout.closed:
                dbus_proc.stdout.close()
        if netlink is not None:
            netlink.close()
        selector.close()
        os.close(wake_r)
        os.close(wake_w)
        PID_FILE.unlink(missing_ok=True)
        RESUME_FLAG.unlink(missing_ok=True)
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
        log('Event-driven monitor stopped')


def main():
    if os.geteuid() != 0 and sys.argv[1:2] != ['status']:
        raise RuntimeError('Run this controller as root (sudo)')
    if not supported_device():
        raise RuntimeError('Restricted to ASUS X1607CA (check DMI product_name/board_name)')
    operation = sys.argv[1] if len(sys.argv) > 1 else ''
    if operation == 'status':
        status()
    elif operation in ('auto', 'quiet', 'balanced', 'performance'):
        set_mode(operation)
    elif operation == 'apply':
        apply()
    elif operation == 'daemon':
        return run_daemon()
    elif operation == 'stop':
        stop()
    else:
        print('Usage: x1607ca-power {status|auto|quiet|balanced|performance|apply|daemon|stop}')
        return 2
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
X1607CA_V3_SOURCE
[ $? -eq 0 ] || ret=$((ret + 1))

chmod 0644 /roota/usr/libexec/x1607ca-power.py
chown 0:0 /roota/usr/libexec/x1607ca-power.py

cat > /roota/usr/bin/x1607ca-power <<'EOF'
#!/bin/sh
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib"
exec /usr/local/bin/python3 /usr/libexec/x1607ca-power.py "$@"
EOF
[ $? -eq 0 ] || ret=$((ret + 1))

chmod 0755 /roota/usr/bin/x1607ca-power
chown 0:0 /roota/usr/bin/x1607ca-power

cat > /roota/etc/init/x1607ca-power.conf <<'EOF'
description "ASUS X1607CA event-driven power profile daemon"
author "Brunch rootc patch"

start on started ui
stop on stopping ui

respawn
respawn limit 5 60

script
    export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
    export LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/lib"

    # Wait up to 30s for /usr/local (dev_image) and D-Bus to become ready
    for i in $(seq 1 60); do
        if [ -x /usr/local/bin/python3 ] && [ -S /run/dbus/system_bus_socket ]; then
            break
        fi
        sleep 0.5
    done

    mkdir -p /mnt/stateful_partition/brunch/power-profile
    chmod 0700 /mnt/stateful_partition/brunch/power-profile
    if [ ! -e /mnt/stateful_partition/brunch/power-profile/selected_mode ]; then
        printf 'auto\n' > /mnt/stateful_partition/brunch/power-profile/selected_mode
        chmod 0600 /mnt/stateful_partition/brunch/power-profile/selected_mode
    fi

    exec /usr/local/bin/python3 /usr/libexec/x1607ca-power.py daemon >> /mnt/stateful_partition/brunch/power-profile/daemon.log 2>&1
end script
EOF
[ $? -eq 0 ] || ret=$((ret + 1))

chmod 0644 /roota/etc/init/x1607ca-power.conf
chown 0:0 /roota/etc/init/x1607ca-power.conf

exit $ret
