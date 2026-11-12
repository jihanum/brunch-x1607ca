#!/bin/sh
# 1. Attempts to add Chromebook Plus features
# 2. Fixes the "disable-gpu-sandbox" prompt on Chrome
# 3. Integrates Intel NPU (/dev/accel/accel0)

TARGET_ROOT="/roota"
if [ "$1" = "/" ] || [ ! -d "/roota/opt/google/chrome" ]; then
    TARGET_ROOT="/"
fi

MODE_ARG="${2:-all}"
CONF="$TARGET_ROOT/etc/chrome_dev.conf"
HELPER_PY="$TARGET_ROOT/usr/sbin/brunch-cbx-patch.py"
ret=0

rm -f "$TARGET_ROOT/etc/init/brunch-live-patch.conf"
if [ -L "$TARGET_ROOT/usr/share/chromeos-assets/animated_splash_screen/splash_200_percent" ]; then
    rm -rf "$TARGET_ROOT/usr/share/chromeos-assets/animated_splash_screen"
fi

for CONF_FILE in "$CONF" "$TARGET_ROOT/var/brunch/chrome_dev.conf"; do
    if [ -f "$CONF_FILE" ]; then
        grep -q "^[[:space:]]*--disable-gpu-sandbox" "$CONF_FILE" || echo "--disable-gpu-sandbox" >> "$CONF_FILE"
        sed -i '/# --- CBX_PATCH_START ---/,/# --- CBX_PATCH_END ---/d' "$CONF_FILE"
        cat <<'CBXEOF' >> "$CONF_FILE"
# --- CBX_PATCH_START ---
--feature-management-level=1
--feature-management-max-level=1
--feature-management-scope=1
enable-features=CameraEffectsSupportedByHardware,EnableDspHotword,EnableNeuralPalmDetectionFilter,FeatureManagement16Desks,FeatureManagementBorealis,FeatureManagementDriveFsBulkPinning,FeatureManagementFeatureAwareDeviceDemoMode,FeatureManagementGameDashboardRecordGame,FeatureManagementOrca,FeatureManagementSeaPen,FeatureManagementSystemLiveCaption,FeatureManagementTimeOfDayScreenSaver,FeatureManagementTimeOfDayWallpaper,FeatureManagementUpdateNotification,FeatureManagementVideoConference,ICASupportedByHardware,OnDeviceSpeechRecognition,Conch,ForestFeature,MagicBoost,Mahi,Orca,SeaPen,VcBackgroundReplace,VcRelighting,VcSegmentationModel,DriveFsBulkPinning
# --- CBX_PATCH_END ---
CBXEOF
    fi
done

if [ -d "$TARGET_ROOT/lib/udev/rules.d" ]; then
    cat <<'UDEVEOF' > "$TARGET_ROOT/lib/udev/rules.d/99-intel-vpu-accel.rules"
SUBSYSTEM=="accel", KERNEL=="accel*", GROUP="video", MODE="0666"
UDEVEOF
fi
chmod 0666 /dev/accel/accel* 2>/dev/null || true

for SANDBOX_CONF in \
    "$TARGET_ROOT/etc/init/cros-camera.conf" \
    "$TARGET_ROOT/etc/init/ml-service.conf" \
    "$TARGET_ROOT/usr/share/minijail/ml-core-cacher.conf"; do
    if [ -f "$SANDBOX_CONF" ] && ! grep -q "/dev/accel" "$SANDBOX_CONF"; then
        sed -i 's|-b /dev/dri|-b /dev/dri -b /dev/accel,,1|g' "$SANDBOX_CONF"
    fi
done

cat <<'PYEOF' > "$HELPER_PY"
import errno
import mmap
import os
import subprocess
import struct
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "all"

def parse_elf64_layout(mm):
    e_phoff, e_shoff = struct.unpack_from("<QQ", mm, 0x20)
    e_phentsize, e_phnum, e_shentsize, e_shnum, _ = struct.unpack_from("<HHHHH", mm, 0x36)

    pt_loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = (
            struct.unpack_from("<IIQQQQQQ", mm, off)
        )
        if p_type == 1:
            pt_loads.append((p_offset, p_filesz, p_vaddr))

    sections = []
    if e_shnum > 0 and e_shoff > 0:
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = (
                struct.unpack_from("<IIQQQQIIQQ", mm, off)
            )
            sections.append({
                "type": sh_type, "flags": sh_flags, "addr": sh_addr,
                "offset": sh_offset, "size": sh_size, "link": sh_link, "entsize": sh_entsize
            })
    return pt_loads, sections

def foff_to_vas(pt_loads, sections, foff):
    vas = set()
    for p_offset, p_filesz, p_vaddr in pt_loads:
        if p_offset <= foff < p_offset + p_filesz:
            vas.add(p_vaddr + (foff - p_offset))
    for s in sections:
        if (s["flags"] & 0x2) and s["offset"] <= foff < s["offset"] + s["size"]:
            vas.add(s["addr"] + (foff - s["offset"]))
    return vas

def va_to_foff(pt_loads, sections, va):
    for p_offset, p_filesz, p_vaddr in pt_loads:
        if p_vaddr <= va < p_vaddr + p_filesz:
            return p_offset + (va - p_vaddr)
    for s in sections:
        if (s["flags"] & 0x2) and s["addr"] <= va < s["addr"] + s["size"]:
            return s["offset"] + (va - s["addr"])
    return None

def patch_libsegmentation(path):
    if not os.path.exists(path):
        return False
    tmp = path + ".brunch_tmp"
    subprocess.run(["cp", "-a", path, tmp], check=True)
    for attr in os.listxattr(path):
        try:
            os.setxattr(tmp, attr, os.getxattr(path, attr))
        except OSError:
            pass
    patched_count = 0
    with open(tmp, "r+b") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE)
        try:
            pt_loads, sections = parse_elf64_layout(mm)
            targets = (
                b"GetFeatureLevelEv",
                b"GetMaxFeatureLevelEv",
                b"GetScopeLevelEv",
                b"IsFeatureEnabledE",
            )
            patch_bytes = b"\x6a\x01\x58\xc3"  # push 1 ; pop rax ; ret
            for s in sections:
                if s["type"] in (2, 11) and s["entsize"] >= 24:
                    strtab = sections[s["link"]]
                    count = s["size"] // s["entsize"]
                    for i in range(count):
                        sym_off = s["offset"] + i * s["entsize"]
                        st_name, st_info, st_other, st_shndx, st_value, st_size = (
                            struct.unpack_from("<IBBHQQ", mm, sym_off)
                        )
                        if st_shndx == 0 or st_value == 0 or (0 < st_size < 4):
                            continue
                        n_start = strtab["offset"] + st_name
                        n_end = mm.find(b"\x00", n_start)
                        sym_name = bytes(mm[n_start:n_end])
                        if any(t in sym_name for t in targets):
                            foff = va_to_foff(pt_loads, sections, st_value)
                            if foff is not None:
                                mm[foff:foff + 4] = patch_bytes
                                patched_count += 1
            mm.flush()
        finally:
            mm.close()
    if patched_count > 0:
        os.replace(tmp, path)
        return True
    os.unlink(tmp)
    return False

def find_switch_vas(mm, pt_loads, sections, text):
    needle = text.encode("ascii") + b"\x00"
    vas = set()
    start = 0
    while True:
        idx = mm.find(needle, start)
        if idx == -1:
            break
        if idx == 0 or mm[idx - 1] in (0x00, 0x2D):
            vas |= foff_to_vas(pt_loads, sections, idx)
        start = idx + 1
    return vas

def patch_chrome_kbadflags(path):
    if not os.path.exists(path):
        return False

    with open(path, "rb") as rf:
        rmm = mmap.mmap(rf.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            pt_loads, sections = parse_elf64_layout(rmm)
            gpu_vas = find_switch_vas(rmm, pt_loads, sections, "disable-gpu-sandbox")

            kbadflags_only_names = (
                "ignore-certificate-errors-spki-list",
                "disable-web-security",
                "extensions-on-chrome-urls",
                "translate-security-origin",
                "unsafely-treat-insecure-origin-as-secure",
            )
            kbadflags_only_vas = set()
            for name in kbadflags_only_names:
                kbadflags_only_vas |= find_switch_vas(rmm, pt_loads, sections, name)

            gpu_host_only_names = (
                "gpu-sandbox-allow-sysv-shm",
                "gpu-sandbox-failures-fatal",
            )
            gpu_host_only_vas = set()
            for name in gpu_host_only_names:
                gpu_host_only_vas |= find_switch_vas(rmm, pt_loads, sections, name)

            filesize = rmm.size()
            operations = []

            for va_gpu in sorted(gpu_vas):
                for candidate_va in (va_gpu, va_gpu + 1):
                    packed = struct.pack("<Q", candidate_va)
                    pos = rmm.find(packed)
                    while pos != -1:
                        has_kbadflags_nbr = False
                        has_gpu_host_nbr = False
                        for delta in range(-256, 264, 8):
                            if delta == 0:
                                continue
                            if 0 <= pos + delta <= filesize - 8:
                                val = struct.unpack_from("<Q", rmm, pos + delta)[0]
                                if val in kbadflags_only_vas:
                                    has_kbadflags_nbr = True
                                if val in gpu_host_only_vas:
                                    has_gpu_host_nbr = True

                        if has_kbadflags_nbr and not has_gpu_host_nbr:
                            operations.append((pos, candidate_va, va_gpu + 1, "kBadFlags"))
                        elif candidate_va == va_gpu + 1:
                            operations.append((pos, candidate_va, va_gpu, "restore_non_kBadFlags"))
                        pos = rmm.find(packed, pos + 1)
        finally:
            rmm.close()

    kbad_ops = [op for op in operations if op[3] == "kBadFlags"]
    if not kbad_ops:
        print("chrome: kBadFlags-exclusive slot not found")
        return False

    for pos, cur_val, new_val, label in operations:
        print(f"chrome: [{label}] slot at {hex(pos)}: current={hex(cur_val)} -> target={hex(new_val)}")

    if all(cur == new_val for _, cur, new_val, _ in operations):
        print("chrome: kBadFlags slot already patched cleanly")
        return True

    try:
        with open(path, "r+b") as wf:
            wmm = mmap.mmap(wf.fileno(), 0, access=mmap.ACCESS_WRITE)
            try:
                for pos, cur_val, new_val, label in operations:
                    if cur_val != new_val:
                        struct.pack_into("<Q", wmm, pos, new_val)
                        print(f"chrome: updated [{label}] at {hex(pos)} ({hex(cur_val)} -> {hex(new_val)})")
                wmm.flush()
                return True
            finally:
                wmm.close()
    except OSError as e:
        if e.errno == errno.ETXTBSY:
            print(f"chrome: busy (ETXTBSY); kBadFlags slot {[hex(op[0]) for op in kbad_ops]} queued for brunch-pre-ui.conf on boot")
            return "DEFERRED"
        raise

if mode in ("all", "seg_only"):
    ok_seg = patch_libsegmentation("/usr/lib64/libsegmentation.so")
    print(f"Segmentation patched: libsegmentation={ok_seg}")

if mode in ("all", "chrome_only"):
    ok_chrome = patch_chrome_kbadflags("/opt/google/chrome/chrome")
    print(f"Chrome kBadFlags patched: {ok_chrome}")
    if not ok_chrome:
        sys.exit(1)
PYEOF
chmod 0755 "$HELPER_PY"

if [ -d "$TARGET_ROOT/etc/init" ]; then
    cat <<'PREUIEOF' > "$TARGET_ROOT/etc/init/brunch-pre-ui.conf"
description "Ensure Chrome kBadFlags is patched in-place before session_manager starts Chrome"
start on starting ui
task
script
    chmod 0666 /dev/accel/accel* 2>/dev/null || true
    if [ -x /usr/local/bin/python3 ] && [ -f /usr/sbin/brunch-cbx-patch.py ]; then
        mount -o remount,rw / 2>/dev/null || true
        /usr/bin/env LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/usr/lib64:/usr/local/lib:/usr/local/usr/lib" \
            /usr/local/bin/python3 /usr/sbin/brunch-cbx-patch.py chrome_only >/var/log/brunch_chrome_patch.log 2>&1 || true
    fi
end script
PREUIEOF

    cat <<'DLCEOF' > "$TARGET_ROOT/etc/init/brunch-cbx-dlc.conf"
description "Automatically install ml-core-dlc if present in rootfs (/opt/google/dlc/ml-core-dlc)"
start on started system-services
script
    if [ ! -d /opt/google/dlc/ml-core-dlc ]; then
        echo "ml-core-dlc not bundled in this recovery image rootfs; skipping." >/var/log/brunch_ml_dlc.log
        exit 0
    fi
    for i in 1 2 3 4 5 6; do
        if [ -d /run/imageloader/ml-core-dlc/package/root ]; then
            exit 0
        fi
        if dlcservice_util --install --id=ml-core-dlc >/var/log/brunch_ml_dlc.log 2>&1; then
            restart cros-camera 2>/dev/null || true
            exit 0
        fi
        sleep 15
    done
end script
DLCEOF
fi

UMOUNT_USR_LOCAL=0
UMOUNT_STATEFUL=0
if [ ! -x "$TARGET_ROOT/usr/local/bin/python3" ]; then
    mkdir -p /tmp/brunch_stateful_p1
    if mount -o ro /dev/nvme0n1p1 /tmp/brunch_stateful_p1 2>/dev/null; then
        UMOUNT_STATEFUL=1
        if [ -d /tmp/brunch_stateful_p1/dev_image ]; then
            mount --bind /tmp/brunch_stateful_p1/dev_image "$TARGET_ROOT/usr/local" 2>/dev/null && UMOUNT_USR_LOCAL=1
        fi
    fi
fi

if [ -x "$TARGET_ROOT/usr/local/bin/python3" ]; then
    chroot "$TARGET_ROOT" /usr/bin/env \
        LD_LIBRARY_PATH="/usr/local/lib64:/usr/local/usr/lib64:/usr/local/lib:/usr/local/usr/lib" \
        /usr/local/bin/python3 /usr/sbin/brunch-cbx-patch.py "$MODE_ARG"
    if [ ! "$?" -eq 0 ]; then ret=$((ret + 1)); fi
fi

if [ "$UMOUNT_USR_LOCAL" -eq 1 ]; then
    umount "$TARGET_ROOT/usr/local" 2>/dev/null
fi
if [ "$UMOUNT_STATEFUL" -eq 1 ]; then
    umount /tmp/brunch_stateful_p1 2>/dev/null
fi

exit $ret
