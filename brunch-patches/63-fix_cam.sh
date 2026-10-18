#!/bin/bash
mount -o remount,rw / 2>/dev/null || true

SAVED="/mnt/stateful_partition/brunch/stock_camera"
GBM_CUR="/usr/lib64/libgbm.so.1.0.0"
GBM_M="/usr/lib64/libgbm_m.so"
MINI="/usr/lib64/libminigbm.so.1.0.0"
EGL="/usr/lib64/libEGL_mesa.so.0.0.0"
DRI_GBM="/usr/lib64/gbm/dri_gbm.so"

mkdir -p "$SAVED"

files_differ() {
  [ "$(md5sum < "$1")" != "$(md5sum < "$2")" ]
}

# 1. If a ChromeOS update + 85-lnl_mesa.sh placed the 28KB lnl_mesa libgbm at libgbm.so.1.0.0,
# convert its SONAME to libgbm_m.so and cache it; otherwise restore from SAVED if missing.
if [ -f "$GBM_CUR" ] && [ ! -L "$GBM_CUR" ]; then
  FILE_SIZE=$(stat -c %s "$GBM_CUR" 2>/dev/null || echo 999999)
  if [ "$FILE_SIZE" -lt 60000 ]; then
    LC_ALL=C sed 's/libgbm\.so\.1\x00/libgbm_m.so\x00/g' "$GBM_CUR" > "${GBM_M}.tmp"
    mv -f "${GBM_M}.tmp" "$GBM_M"
    chmod 0755 "$GBM_M"
    cp -a "$GBM_M" "$SAVED/libgbm_m.so"
  fi
elif [ ! -f "$GBM_M" ] && [ -f "$SAVED/libgbm_m.so" ]; then
  cp -a "$SAVED/libgbm_m.so" "$GBM_M"
  chmod 0755 "$GBM_M"
fi

# 2. Patch DT_NEEDED (libgbm.so.1\0 -> libgbm_m.so\0) in libEGL_mesa.so.0.0.0 and dri_gbm.so
for TARGET in "$EGL" "$DRI_GBM"; do
  if [ -f "$TARGET" ]; then
    LC_ALL=C sed 's/libgbm\.so\.1\x00/libgbm_m.so\x00/g' "$TARGET" > "${TARGET}.tmp"
    if files_differ "$TARGET" "${TARGET}.tmp"; then
      mv -f "${TARGET}.tmp" "$TARGET"
      chmod 0755 "$TARGET"
    else
      rm -f "${TARGET}.tmp"
    fi
  fi
done

# 3. Patch 0x7dd5 (\xd5\x7d) -> 0x7dd1 (\xd1\x7d) in libminigbm.so.1.0.0 for Intel Tile4 support
if [ -f "$MINI" ]; then
  LC_ALL=C sed 's/\xd5\x7d/\xd1\x7d/g' "$MINI" > "${MINI}.tmp"
  if files_differ "$MINI" "${MINI}.tmp"; then
    mv -f "${MINI}.tmp" "$MINI"
    chmod 0755 "$MINI"
  else
    rm -f "${MINI}.tmp"
  fi
fi

# 4. Point libgbm.so* symlinks to libminigbm.so.1.0.0 and restore SELinux labels
if [ -f "$MINI" ]; then
  ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so.1.0.0
  ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so.1
  ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so
  chcon --reference=/usr/lib64/libc.so.6 "$GBM_M" "$MINI" "$EGL" 2>/dev/null || true
  chcon -h --reference=/usr/lib64/libc.so.6 /usr/lib64/libgbm.so /usr/lib64/libgbm.so.1 /usr/lib64/libgbm.so.1.0.0 2>/dev/null || true
fi

# 5. Clean cros-camera.conf while preserving its cros_conf_file SELinux label
CAMERA_CONF="/etc/init/cros-camera.conf"
if [ -f "$CAMERA_CONF" ]; then
  grep -vE 'LIBGL_ALWAYS_SOFTWARE|MESA_LOADER_DRIVER_OVERRIDE|GALLIUM_DRIVER' "$CAMERA_CONF" | \
    sed -E 's|-S[[:space:]]+"\$\{SECCOMP_POLICY_FILE\}"||g' > "${CAMERA_CONF}.tmp"
  if files_differ "$CAMERA_CONF" "${CAMERA_CONF}.tmp"; then
    mv -f "${CAMERA_CONF}.tmp" "$CAMERA_CONF"
    chmod 0644 "$CAMERA_CONF"
    chcon --reference=/etc/init/cras.conf "$CAMERA_CONF" 2>/dev/null || true
    /sbin/initctl reload-configuration 2>/dev/null || true
  else
    rm -f "${CAMERA_CONF}.tmp"
  fi
fi
