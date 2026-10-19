#!/bin/sh

# Configure libgbm_m.so (for Lunar Lake / Arrow Lake Mesa) and libminigbm.so.1.0.0

chroot /roota /bin/bash -s <<'EOF'
ret=0

GBM_CUR="/usr/lib64/libgbm.so.1.0.0"
GBM_M="/usr/lib64/libgbm_m.so"
MINI="/usr/lib64/libminigbm.so.1.0.0"
EGL="/usr/lib64/libEGL_mesa.so.0.0.0"
DRI_GBM="/usr/lib64/gbm/dri_gbm.so"

REF_LIB="$MINI"
[ ! -f "$REF_LIB" ] && REF_LIB="/lib64/libc.so.6"

restore_selinux_file() {
	local ref="$1"
	local dst="$2"
	local ctx="$3"
	chcon --reference="$ref" "$dst" 2>/dev/null || true
	if command -v setfattr >/dev/null 2>&1; then
		setfattr -n security.selinux -v "$ctx" "$dst" 2>/dev/null || true
	fi
}

if [ -f "$GBM_CUR" ] && [ ! -L "$GBM_CUR" ]; then
	FILE_SIZE=$(wc -c < "$GBM_CUR" 2>/dev/null || echo 999999)
	if [ "$FILE_SIZE" -lt 60000 ]; then
		rm -f "$GBM_M"
		cp --preserve=all "$REF_LIB" "$GBM_M" 2>/dev/null || cp -a "$REF_LIB" "$GBM_M"
		chmod 0755 "$GBM_M"
		LC_ALL=C sed 's/libgbm\.so\.1\x00/libgbm_m.so\x00/g' "$GBM_CUR" > "$GBM_M"
		if [ "$?" -ne 0 ]; then ret=$((ret + 1)); fi
		restore_selinux_file "$REF_LIB" "$GBM_M" "u:object_r:cros_system_file:s0"
	fi
fi

for TARGET in "$EGL" "$DRI_GBM"; do
	if [ -f "$TARGET" ]; then
		chmod 0755 "$TARGET"
		LC_ALL=C sed 's/libgbm\.so\.1\x00/libgbm_m.so\x00/g' "$TARGET" > "${TARGET}.tmp"
		if [ "$?" -eq 0 ] && [ -s "${TARGET}.tmp" ]; then
			cat "${TARGET}.tmp" > "$TARGET"
			rm -f "${TARGET}.tmp"
			restore_selinux_file "$REF_LIB" "$TARGET" "u:object_r:cros_system_file:s0"
		else
			rm -f "${TARGET}.tmp"
			ret=$((ret + 2))
		fi
	fi
done

if [ -f "$MINI" ]; then
	chmod 0755 "$MINI"
	LC_ALL=C sed 's/\xd5\x7d/\xd1\x7d/g' "$MINI" > "${MINI}.tmp"
	if [ "$?" -eq 0 ] && [ -s "${MINI}.tmp" ]; then
		cat "${MINI}.tmp" > "$MINI"
		rm -f "${MINI}.tmp"
		restore_selinux_file "$REF_LIB" "$MINI" "u:object_r:cros_system_file:s0"
	else
		rm -f "${MINI}.tmp"
		ret=$((ret + 4))
	fi
fi

if [ -f "$MINI" ]; then
	ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so.1.0.0
	ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so.1
	ln -sf libminigbm.so.1.0.0 /usr/lib64/libgbm.so
	for LINK in /usr/lib64/libgbm.so /usr/lib64/libgbm.so.1 /usr/lib64/libgbm.so.1.0.0; do
		chcon -h --reference="$REF_LIB" "$LINK" 2>/dev/null || true
		if command -v setfattr >/dev/null 2>&1; then
			setfattr -h -n security.selinux -v "u:object_r:cros_system_file:s0" "$LINK" 2>/dev/null || true
		fi
	done
fi

CAMERA_CONF="/etc/init/cros-camera.conf"
if [ -f "$CAMERA_CONF" ]; then
	chmod 0644 "$CAMERA_CONF"
	grep -vE 'LIBGL_ALWAYS_SOFTWARE|MESA_LOADER_DRIVER_OVERRIDE|GALLIUM_DRIVER' "$CAMERA_CONF" | \
		sed -E 's|-S[[:space:]]+"\$\{SECCOMP_POLICY_FILE\}"||g' > "${CAMERA_CONF}.tmp"
	if [ "$?" -eq 0 ] && [ -s "${CAMERA_CONF}.tmp" ]; then
		cat "${CAMERA_CONF}.tmp" > "$CAMERA_CONF"
		rm -f "${CAMERA_CONF}.tmp"
		restore_selinux_file "/etc/init/cras.conf" "$CAMERA_CONF" "u:object_r:cros_conf_file:s0"
	else
		rm -f "${CAMERA_CONF}.tmp"
		ret=$((ret + 8))
	fi
fi

exit $ret
EOF

exit $?
