#!/bin/sh
# Brunch boot patch (/patches/99-install-updater.sh on /dev/nvme0n1p7)
# Installs /usr/local/bin/update if it is not already present.

write_update_script() {
    target="$1"
    mkdir -p "$(dirname "$target")"
    cat << 'UPDATER_EOF' > "$target"
#!/usr/bin/env bash
# Hardened Auto-Updater for ASUS X1607CA (jihanum/brunch-x1607ca + volteer)
# Uses POSIX sed and built-in python3 (no grep -P, unzip, jq, or busybox required).

set -euo pipefail

export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

GITHUB_REPO="jihanum/brunch-x1607ca"
CROS_BOARD="volteer"
CROS_CHANNEL="stable"               # "stable" or "beta"
REQUIRE_RECOVERY_SHA1="false"       # Set "true" to forbid cros.tech historical images without recovery2.json SHA-1

STATE_DIR="/mnt/stateful_partition/brunch/updater"
WORK_DIR="${STATE_DIR}/tmp"
MNT_CHECK="${STATE_DIR}/mnt_verify"
BRUNCH_STAGING_DIR="/mnt/stateful_partition/unencrypted/brunch_updater"
STATE_FILE="${STATE_DIR}/version_state.env"
LOG_FILE="${STATE_DIR}/updater.log"
LOCK_FILE="/run/brunch_updater.lock"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This updater must be run as root." >&2
    exit 1
fi

mkdir -p "$STATE_DIR" "$WORK_DIR" "$MNT_CHECK"
exec >> "$LOG_FILE" 2>&1

echo "=========================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting update check (Board: ${CROS_BOARD}, Channel: ${CROS_CHANNEL})..."

REQUIRED_CMDS=(curl python3 sed tar cgpt rootdev pv sha1sum sha256sum flock mount umount df)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updater is already running. Exiting."
    exit 0
fi

cleanup() {
    umount "$MNT_CHECK" 2>/dev/null || true
    rm -rf "$WORK_DIR" "$BRUNCH_STAGING_DIR" 2>/dev/null || true
    mkdir -p "$WORK_DIR"
}
trap cleanup EXIT

for i in {1..12}; do
    if curl -fsSI https://api.github.com >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 12 ]; then
        echo "ERROR: No network connection after 60 seconds. Aborting."
        exit 1
    fi
    sleep 5
done

# 6. Helper Functions (No grep -P used)
get_lsb_val() {
    local file="$1"
    local key="$2"
    local default_val="$3"
    local val=""
    if [ -f "$file" ]; then
        val=$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n1 | tr -d '\r\n"'"'" || true)
    fi
    if [ -n "$val" ]; then
        echo "$val"
    else
        echo "$default_val"
    fi
}

parse_brunch_info() {
    python3 - "$1" << 'PYEOF'
import datetime, re, sys

raw = sys.argv[1]
m_ms = re.search(r"(?:^|[^a-zA-Z0-9])r([0-9]{2,3})(?:[^0-9]|$)", raw)
milestone = m_ms.group(1) if m_ms else "0"

valid_dates = []
for d in re.findall(r"(20[0-9]{6})", raw):
    try:
        datetime.datetime.strptime(d, "%Y%m%d")
        valid_dates.append(d)
    except ValueError:
        pass

date_str = valid_dates[-1] if valid_dates else "0"
print(f"{milestone}|{date_str}")
PYEOF
}

is_newer_version() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

SYS_MILESTONE=$(get_lsb_val /etc/lsb-release "CHROMEOS_RELEASE_CHROME_MILESTONE" "0")
SYS_PLATFORM_VER=$(get_lsb_val /etc/lsb-release "CHROMEOS_RELEASE_VERSION" "0.0.0")
SYS_BRUNCH_RAW=$(cat /etc/brunch_version 2>/dev/null | tr -d '\r\n' || echo "none")

IFS='|' read -r SYS_BRUNCH_MILESTONE SYS_BRUNCH_DATE <<< "$(parse_brunch_info "$SYS_BRUNCH_RAW")"

if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
fi

if [ -z "${RECORDED_CROS_MILESTONE:-}" ] || [ "${RECORDED_CROS_MILESTONE}" = "0" ]; then
    RECORDED_CROS_MILESTONE="$SYS_MILESTONE"
fi
if [ -z "${RECORDED_CROS_PLATFORM_VERSION:-}" ] || [ "${RECORDED_CROS_PLATFORM_VERSION}" = "0.0.0" ]; then
    RECORDED_CROS_PLATFORM_VERSION="$SYS_PLATFORM_VER"
fi
RECORDED_BRUNCH_RELEASE="${RECORDED_BRUNCH_RELEASE:-$SYS_BRUNCH_RAW}"

IFS='|' read -r PARSED_REC_MS PARSED_REC_DATE <<< "$(parse_brunch_info "$RECORDED_BRUNCH_RELEASE")"
if [ -z "${RECORDED_BRUNCH_MILESTONE:-}" ] || [ "${RECORDED_BRUNCH_MILESTONE}" = "0" ]; then
    RECORDED_BRUNCH_MILESTONE="$PARSED_REC_MS"
fi
if [ -z "${RECORDED_BRUNCH_DATE:-}" ] || [ "${RECORDED_BRUNCH_DATE}" = "0" ]; then
    RECORDED_BRUNCH_DATE="$PARSED_REC_DATE"
fi

echo "Installed System    : ChromeOS r${SYS_MILESTONE} (${SYS_PLATFORM_VER}) | Brunch '${SYS_BRUNCH_RAW}' (r${SYS_BRUNCH_MILESTONE}, Date: ${SYS_BRUNCH_DATE})"
echo "Recorded State      : ChromeOS r${RECORDED_CROS_MILESTONE} (${RECORDED_CROS_PLATFORM_VERSION}) | Brunch '${RECORDED_BRUNCH_RELEASE}' (r${RECORDED_BRUNCH_MILESTONE}, Date: ${RECORDED_BRUNCH_DATE})"

GH_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
GH_JSON=$(curl -fsSL "$GH_API_URL")

BRUNCH_PARSED=$(python3 -c '
import json, re, sys

data = json.loads(sys.stdin.read())
tag = data.get("tag_name", "")
name = data.get("name", "") or ""
body = data.get("body", "") or ""

m_body = re.search(r"release_sha256sum=([0-9a-fA-F]{64})", body)
body_sha256 = m_body.group(1).lower() if m_body else ""

assets = [a for a in data.get("assets", []) if a.get("name", "").endswith(".tar.gz")]
assets.sort(key=lambda a: 0 if a.get("name", "").lower().startswith("brunch") else 1)

if not tag or not assets:
    sys.exit(1)

asset = assets[0]
asset_name = asset.get("name", "")
url = asset.get("browser_download_url", "")
size = int(asset.get("size", 0))
digest = asset.get("digest", "") or ""
asset_sha256 = digest.split("sha256:", 1)[1].lower() if digest.startswith("sha256:") else ""

if body_sha256 and asset_sha256 and body_sha256 != asset_sha256:
    print("ERR_DIGEST_MISMATCH", file=sys.stderr)
    sys.exit(2)

final_sha256 = body_sha256 or asset_sha256
if not re.fullmatch(r"[0-9a-f]{64}", final_sha256):
    print("ERR_NO_VALID_SHA256", file=sys.stderr)
    sys.exit(3)

combined_meta = f"{tag} {name} {asset_name}"
print(f"{tag}|{url}|{size}|{final_sha256}|{combined_meta}")
' <<< "$GH_JSON")

IFS='|' read -r LATEST_BRUNCH_TAG BRUNCH_TAR_URL BRUNCH_TAR_SIZE BRUNCH_EXPECTED_SHA256 BRUNCH_COMBINED_META <<< "$BRUNCH_PARSED"
IFS='|' read -r BRUNCH_MILESTONE BRUNCH_DATE <<< "$(parse_brunch_info "$BRUNCH_COMBINED_META")"

if [ "$BRUNCH_MILESTONE" = "0" ] || [ "$BRUNCH_DATE" = "0" ]; then
    echo "ERROR: Could not extract valid milestone (rXXX) and build date (YYYYMMDD) from GitHub release '${LATEST_BRUNCH_TAG}'."
    exit 1
fi

echo "Latest GitHub Brunch: ${LATEST_BRUNCH_TAG} (Target: r${BRUNCH_MILESTONE}, Build Date: ${BRUNCH_DATE})"
echo "Brunch SHA-256      : ${BRUNCH_EXPECTED_SHA256}"

RECOVERY_JSON_FILE="${WORK_DIR}/recovery2.json"
CROS_HTML_FILE="${WORK_DIR}/cros_tech.html"

curl -fsSL "https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json" -o "$RECOVERY_JSON_FILE" || echo "[]" > "$RECOVERY_JSON_FILE"
curl -fsSL -A "Mozilla/5.0" "https://cros.tech/board/${CROS_BOARD}/" -o "$CROS_HTML_FILE" || touch "$CROS_HTML_FILE"

RECOVERY_AVAILABLE=true
RECOVERY_PARSED=$(python3 - "$RECOVERY_JSON_FILE" "$CROS_HTML_FILE" "$CROS_BOARD" "$CROS_CHANNEL" "$BRUNCH_MILESTONE" << 'PYEOF'
import json, re, sys
from html.parser import HTMLParser

rec_json_path, html_path, board, channel, target_ms = sys.argv[1:6]
channel_lower = channel.lower()

def ver_key(v):
    return [int(x) if x.isdigit() else 0 for x in v.split(".")]

with open(rec_json_path, "r", encoding="utf-8") as f:
    rec_data = json.load(f)

matches = []
for item in rec_data:
    url = item.get("url", "")
    c_ver = item.get("chrome_version", "")
    p_ver = item.get("version", "")
    ch = (item.get("channel", "") or "").lower()
    if (f"_{board}_recovery_" in url
        and c_ver.startswith(f"{target_ms}.")
        and ch == channel_lower
        and p_ver):
        matches.append(item)

if matches:
    matches.sort(key=lambda x: ver_key(x.get("version", "0.0.0")))
    best = matches[-1]
    print(f"recovery2.json|{best['url']}|{best['version']}|{best.get('sha1','')}|{best.get('filesize',0)}")
    sys.exit(0)

with open(html_path, "r", encoding="utf-8", errors="ignore") as f:
    html_text = f.read()

class CrosTechParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_a = False
        self.curr_href = ""
        self.curr_text = []
        self.links = []
    def handle_starttag(self, tag, attrs):
        if tag.lower() == "a":
            self.in_a = True
            self.curr_href = dict(attrs).get("href", "")
            self.curr_text = []
    def handle_data(self, data):
        if self.in_a:
            self.curr_text.append(data)
    def handle_endtag(self, tag):
        if tag.lower() == "a" and self.in_a:
            self.in_a = False
            self.links.append((self.curr_href, " ".join(self.curr_text).strip()))

parser = CrosTechParser()
parser.feed(html_text)

url_pattern = re.compile(
    rf"^https://dl\.google\.com/dl/edgedl/chromeos/recovery/chromeos_([0-9.]+)_{re.escape(board)}_recovery_{re.escape(channel_lower)}-channel_[^\s\"'<>]+\.bin\.zip$"
)

html_candidates = []
for href, text in parser.links:
    m_url = url_pattern.match(href)
    if not m_url:
        continue
    p_ver = m_url.group(1)
    if re.search(rf"\b{re.escape(target_ms)}\b", text):
        html_candidates.append((p_ver, href))

if html_candidates:
    html_candidates.sort(key=lambda x: ver_key(x[0]))
    best_p_ver, best_url = html_candidates[-1]
    print(f"cros.tech|{best_url}|{best_p_ver}||0")
    sys.exit(0)

sys.exit(1)
PYEOF
) || RECOVERY_AVAILABLE=false

CROS_IS_NEWER=false
BRUNCH_IS_NEWER=false

if [ "$BRUNCH_MILESTONE" -gt "$RECORDED_BRUNCH_MILESTONE" ]; then
    BRUNCH_IS_NEWER=true
elif [ "$BRUNCH_MILESTONE" -eq "$RECORDED_BRUNCH_MILESTONE" ] && [ "$BRUNCH_DATE" -gt "$RECORDED_BRUNCH_DATE" ]; then
    BRUNCH_IS_NEWER=true
fi

if [ "$RECOVERY_AVAILABLE" = "true" ]; then
    IFS='|' read -r RECOVERY_SOURCE RECOVERY_ZIP_URL LATEST_CROS_PLATFORM_VER RECOVERY_SHA1 RECOVERY_ZIP_SIZE <<< "$RECOVERY_PARSED"
    echo "Matched Recovery    : Milestone r${BRUNCH_MILESTONE} | Platform ${LATEST_CROS_PLATFORM_VER} (Source: ${RECOVERY_SOURCE})"

    if [ "$BRUNCH_MILESTONE" -gt "$RECORDED_CROS_MILESTONE" ] || \
       { [ "$BRUNCH_MILESTONE" -eq "$RECORDED_CROS_MILESTONE" ] && is_newer_version "$LATEST_CROS_PLATFORM_VER" "$RECORDED_CROS_PLATFORM_VERSION"; }; then
        CROS_IS_NEWER=true
    fi
else
    echo "Notice              : No recovery image found online for Milestone r${BRUNCH_MILESTONE}."
fi

DO_UPDATE_CROS=false
DO_UPDATE_BRUNCH=false

if [ "$CROS_IS_NEWER" = "true" ] && [ "$BRUNCH_IS_NEWER" = "true" ]; then
    DO_UPDATE_CROS=true
    DO_UPDATE_BRUNCH=true
elif [ "$BRUNCH_IS_NEWER" = "true" ] && \
     { [ "$BRUNCH_MILESTONE" -eq "$RECORDED_BRUNCH_MILESTONE" ] || [ "$BRUNCH_MILESTONE" -eq "$SYS_MILESTONE" ]; }; then
    DO_UPDATE_BRUNCH=true
fi

if [ "$DO_UPDATE_CROS" != "true" ] && [ "$DO_UPDATE_BRUNCH" != "true" ]; then
    echo "No update required (CROS_IS_NEWER=${CROS_IS_NEWER}, BRUNCH_IS_NEWER=${BRUNCH_IS_NEWER}). Exiting."
    exit 0
fi

if [ "$DO_UPDATE_CROS" = "true" ] && [ "$REQUIRE_RECOVERY_SHA1" = "true" ] && [ -z "${RECOVERY_SHA1:-}" ]; then
    echo "ERROR: Recovery image came from ${RECOVERY_SOURCE} without a recovery2.json SHA-1, and REQUIRE_RECOVERY_SHA1=true. Aborting."
    exit 1
fi

echo "Update Plan         : Flash ChromeOS=${DO_UPDATE_CROS} | Flash Brunch=${DO_UPDATE_BRUNCH}"

if [ "$DO_UPDATE_CROS" = "true" ]; then
    MIN_FREE_KB=$((16 * 1024 * 1024))
    DYNAMIC_REQ_KB=$(( (BRUNCH_TAR_SIZE + RECOVERY_ZIP_SIZE * 4) / 1024 + (6 * 1024 * 1024) ))
    if [ "$DYNAMIC_REQ_KB" -gt "$MIN_FREE_KB" ]; then
        MIN_FREE_KB="$DYNAMIC_REQ_KB"
    fi
else
    MIN_FREE_KB=$((6 * 1024 * 1024))
fi

STATE_AVAIL_KB=$(df -k --output=avail "$STATE_DIR" | tail -n1 | tr -d ' ')
if [ "$STATE_AVAIL_KB" -lt "$MIN_FREE_KB" ]; then
    echo "ERROR: Insufficient stateful partition space: $((STATE_AVAIL_KB / 1024)) MB free, need $((MIN_FREE_KB / 1024)) MB."
    exit 1
fi

UPDATE_ARGS=()

if [ "$DO_UPDATE_BRUNCH" = "true" ]; then
    BRUNCH_ARCHIVE="${WORK_DIR}/brunch_latest.tar.gz"
    echo "Downloading Brunch archive (${LATEST_BRUNCH_TAG})..."
    curl -fL --retry 3 -o "$BRUNCH_ARCHIVE" "$BRUNCH_TAR_URL"

    ACTUAL_SHA256=$(sha256sum "$BRUNCH_ARCHIVE" | awk '{print tolower($1)}')
    if [ "$ACTUAL_SHA256" != "$BRUNCH_EXPECTED_SHA256" ]; then
        echo "ERROR: Brunch SHA-256 mismatch! Expected ${BRUNCH_EXPECTED_SHA256}, got ${ACTUAL_SHA256}."
        exit 1
    fi
    echo "Brunch SHA-256 verified."

    if ! tar -tzf "$BRUNCH_ARCHIVE" rootc.img >/dev/null 2>&1 && ! tar -tzf "$BRUNCH_ARCHIVE" ./rootc.img >/dev/null 2>&1; then
        echo "ERROR: Brunch archive does not contain rootc.img."
        exit 1
    fi
    UPDATE_ARGS+=(-f "$BRUNCH_ARCHIVE")
fi

if [ "$DO_UPDATE_CROS" = "true" ]; then
    RECOVERY_ZIP="${WORK_DIR}/recovery.bin.zip"
    echo "Downloading ChromeOS recovery archive..."
    curl -fL --retry 3 -o "$RECOVERY_ZIP" "$RECOVERY_ZIP_URL"

    if [ -n "$RECOVERY_SHA1" ]; then
        ACTUAL_SHA1=$(sha1sum "$RECOVERY_ZIP" | awk '{print tolower($1)}')
        if [ "${RECOVERY_SHA1,,}" != "$ACTUAL_SHA1" ]; then
            echo "ERROR: Recovery ZIP SHA-1 mismatch! Expected ${RECOVERY_SHA1}, got ${ACTUAL_SHA1}."
            exit 1
        fi
        echo "Recovery ZIP SHA-1 checksum verified."
    fi

    echo "Verifying ZIP CRC integrity and extracting ChromeOS .bin via python3..."
    RECOVERY_BIN=$(python3 - "$RECOVERY_ZIP" "$WORK_DIR" << 'PYEOF'
import os, sys, zipfile

zip_path, out_dir = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path, "r") as zf:
    bad_file = zf.testzip()
    if bad_file is not None:
        raise RuntimeError(f"Corrupted file inside ZIP archive: {bad_file}")
    bin_members = [m for m in zf.namelist() if m.endswith(".bin") and "/" not in m]
    if len(bin_members) != 1:
        raise RuntimeError(f"Expected exactly 1 .bin file in ZIP, found: {bin_members}")
    target_member = bin_members[0]
    zf.extract(target_member, out_dir)
    print(os.path.join(out_dir, target_member))
PYEOF
    )
    rm -f "$RECOVERY_ZIP"

    if [ -z "$RECOVERY_BIN" ] || [ ! -f "$RECOVERY_BIN" ]; then
        echo "ERROR: Failed to extract recovery .bin file."
        exit 1
    fi

    if [ "$(cgpt show -i 3 -l "$RECOVERY_BIN" 2>/dev/null || true)" != "ROOT-A" ]; then
        echo "ERROR: Extracted recovery .bin does not contain a valid ROOT-A partition at index 3."
        exit 1
    fi

    ROOTA_START_SECTOR=$(cgpt show -i 3 -b "$RECOVERY_BIN")
    ROOTA_OFFSET=$(( ROOTA_START_SECTOR * 512 ))
    mount -t ext2 -o ro,loop,offset="$ROOTA_OFFSET" "$RECOVERY_BIN" "$MNT_CHECK"
    BIN_MILESTONE=$(get_lsb_val "${MNT_CHECK}/etc/lsb-release" "CHROMEOS_RELEASE_CHROME_MILESTONE" "0")
    BIN_PLATFORM_VER=$(get_lsb_val "${MNT_CHECK}/etc/lsb-release" "CHROMEOS_RELEASE_VERSION" "none")
    BIN_BOARD=$(get_lsb_val "${MNT_CHECK}/etc/lsb-release" "CHROMEOS_RELEASE_BOARD" "none")
    umount "$MNT_CHECK"

    if [ "${BIN_BOARD%%-*}" != "$CROS_BOARD" ] || [ "$BIN_MILESTONE" != "$BRUNCH_MILESTONE" ] || [ "$BIN_PLATFORM_VER" != "$LATEST_CROS_PLATFORM_VER" ]; then
        echo "ERROR: Pre-flash .bin inspection failed! Found board=${BIN_BOARD}, milestone=${BIN_MILESTONE}, platform=${BIN_PLATFORM_VER}."
        exit 1
    fi
    echo "Pre-flash .bin verified: board=${BIN_BOARD}, milestone=${BIN_MILESTONE}, platform=${BIN_PLATFORM_VER}."
    UPDATE_ARGS+=(-r "$RECOVERY_BIN")
fi

echo "Running: /usr/sbin/chromeos-update ${UPDATE_ARGS[*]}"
/usr/sbin/chromeos-update "${UPDATE_ARGS[@]}"

DEST_DISK=$(rootdev -d)
if [[ "$DEST_DISK" =~ [0-9]$ ]]; then
    PART_PREFIX="${DEST_DISK}p"
else
    PART_PREFIX="${DEST_DISK}"
fi

if [ "$DO_UPDATE_CROS" = "true" ]; then
    KERN_B_PRIO=$(cgpt show -i 4 -P "$DEST_DISK")
    if [ "$KERN_B_PRIO" -ne 15 ]; then
        echo "ERROR: Post-update verification failed: KERN-B priority is ${KERN_B_PRIO} (expected 15)."
        exit 1
    fi

    mount -t ext2 -o ro "${PART_PREFIX}5" "$MNT_CHECK"
    FLASHED_PLATFORM_VER=$(get_lsb_val "${MNT_CHECK}/etc/lsb-release" "CHROMEOS_RELEASE_VERSION" "none")
    FLASHED_MILESTONE=$(get_lsb_val "${MNT_CHECK}/etc/lsb-release" "CHROMEOS_RELEASE_CHROME_MILESTONE" "0")
    umount "$MNT_CHECK"

    if [ "$FLASHED_PLATFORM_VER" != "$LATEST_CROS_PLATFORM_VER" ] || [ "$FLASHED_MILESTONE" != "$BRUNCH_MILESTONE" ]; then
        echo "ERROR: Partition 5 verification failed! Found ${FLASHED_MILESTONE} (${FLASHED_PLATFORM_VER}), expected ${BRUNCH_MILESTONE} (${LATEST_CROS_PLATFORM_VER})."
        exit 1
    fi
    echo "Verified Partition 5 (ROOT-B): ChromeOS ${FLASHED_MILESTONE} (${FLASHED_PLATFORM_VER})."
    RECORDED_CROS_MILESTONE="$BRUNCH_MILESTONE"
    RECORDED_CROS_PLATFORM_VERSION="$LATEST_CROS_PLATFORM_VER"
fi

if [ "$DO_UPDATE_BRUNCH" = "true" ]; then
    mount -o ro "${PART_PREFIX}7" "$MNT_CHECK"
    if [ ! -s "${MNT_CHECK}/initramfs.img" ] || [ ! -s "${MNT_CHECK}/packages/base.tar.gz" ] || [ ! -s "${MNT_CHECK}/kernel" ]; then
        umount "$MNT_CHECK"
        echo "ERROR: Partition 7 (ROOTC) is missing core files (initramfs.img, kernel, or packages/base.tar.gz)."
        exit 1
    fi

    FLASHED_BRUNCH_VER=$( { tar -xOzf "${MNT_CHECK}/packages/base.tar.gz" etc/brunch_version 2>/dev/null || \
                            tar -xOzf "${MNT_CHECK}/packages/base.tar.gz" ./etc/brunch_version 2>/dev/null; } | tr -d '\r\n' || true )
    umount "$MNT_CHECK"

    IFS='|' read -r FLASHED_BRUNCH_MS FLASHED_BRUNCH_DATE <<< "$(parse_brunch_info "$FLASHED_BRUNCH_VER")"
    if [ "$FLASHED_BRUNCH_MS" != "$BRUNCH_MILESTONE" ] || [ "$FLASHED_BRUNCH_DATE" != "$BRUNCH_DATE" ]; then
        echo "ERROR: Partition 7 (ROOTC) version mismatch! Found '${FLASHED_BRUNCH_VER}' (r${FLASHED_BRUNCH_MS}, ${FLASHED_BRUNCH_DATE}), expected '${LATEST_BRUNCH_TAG}' (r${BRUNCH_MILESTONE}, ${BRUNCH_DATE})."
        exit 1
    fi
    echo "Verified Partition 7 (ROOTC): '${FLASHED_BRUNCH_VER}' (r${FLASHED_BRUNCH_MS}, Date: ${FLASHED_BRUNCH_DATE}) installed."
    RECORDED_BRUNCH_RELEASE="$LATEST_BRUNCH_TAG"
    RECORDED_BRUNCH_MILESTONE="$BRUNCH_MILESTONE"
    RECORDED_BRUNCH_DATE="$BRUNCH_DATE"
fi

cat <<EOF > "${STATE_FILE}.tmp"
RECORDED_CROS_MILESTONE="${RECORDED_CROS_MILESTONE}"
RECORDED_CROS_PLATFORM_VERSION="${RECORDED_CROS_PLATFORM_VERSION}"
RECORDED_BRUNCH_RELEASE="${RECORDED_BRUNCH_RELEASE}"
RECORDED_BRUNCH_MILESTONE="${RECORDED_BRUNCH_MILESTONE}"
RECORDED_BRUNCH_DATE="${RECORDED_BRUNCH_DATE}"
EOF
mv -f "${STATE_FILE}.tmp" "$STATE_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Update verified and recorded! Reboot manually whenever ready."
UPDATER_EOF
    chmod 0755 "$target"
}

write_update_script "/roota/usr/share/brunch-updater/update"

if [ ! -f "/roota/usr/local/bin/update" ]; then
    cp -p "/roota/usr/share/brunch-updater/update" "/roota/usr/local/bin/update"
fi

cat << 'UPSTART_EOF' > /roota/etc/init/brunch-install-update.conf
description "Ensure /usr/local/bin/update exists after stateful partition mount"
author "Brunch Patch"

start on started boot-services

task

script
    if [ ! -f /usr/local/bin/update ] && [ -f /usr/share/brunch-updater/update ]; then
        mkdir -p /usr/local/bin
        cp -p /usr/share/brunch-updater/update /usr/local/bin/update
        chmod 0755 /usr/local/bin/update
    fi
end script
UPSTART_EOF

exit 0
