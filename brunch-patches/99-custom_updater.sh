#!/bin/sh
# Brunch patch: Safely installs the hardened custom updater to /usr/local/bin/update

set -eu

ret=0

if [ -n "${TARGET_ROOT:-}" ]; then
    :
elif [ "${1:-}" = "--live" ] || [ "${1:-}" = "/" ]; then
    TARGET_ROOT="/"
elif [ -d /roota/etc ]; then
    TARGET_ROOT="/roota"
else
    TARGET_ROOT="/"
fi

if [ ! -d "$TARGET_ROOT" ]; then
    echo "brunch: custom_updater: target root '$TARGET_ROOT' not found" >&2
    exit 1
fi

PREFIX="${TARGET_ROOT%/}"

restore_selinux_file() {
    ref="$1"
    dst="$2"
    ctx="$3"
    if [ -e "$ref" ] && command -v chcon >/dev/null 2>&1; then
        chcon --reference="$ref" "$dst" 2>/dev/null && return 0
    fi
    if command -v setfattr >/dev/null 2>&1; then
        setfattr -n security.selinux -v "$ctx" "$dst" 2>/dev/null || true
    fi
}

ensure_real_dir() {
    dir="$1"
    if [ -L "$dir" ]; then
        echo "brunch: custom_updater: refusing to follow symlink directory '$dir'" >&2
        return 1
    fi
    if [ ! -e "$dir" ]; then
        mkdir -p -m 0755 "$dir"
    fi
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        echo "brunch: custom_updater: '$dir' is not a valid directory" >&2
        return 1
    fi
    return 0
}

safe_install_payload() {
    src_payload="$1"
    dst_file="$2"
    mode="$3"
    ref_file="$4"
    selinux_ctx="$5"
    dst_dir="${dst_file%/*}"

    ensure_real_dir "$dst_dir" || return 1

    if [ -L "$dst_file" ]; then
        rm -f "$dst_file"
    fi

    tmp_file=$(mktemp "${dst_dir}/.${dst_file##*/}.tmp.XXXXXX")
    chmod "$mode" "$tmp_file"
    cat "$src_payload" > "$tmp_file"
    chmod "$mode" "$tmp_file"
    if [ "$(id -u)" -eq 0 ]; then
        chown 0:0 "$tmp_file"
    fi
    restore_selinux_file "$ref_file" "$tmp_file" "$selinux_ctx"
    mv -f "$tmp_file" "$dst_file"
}

STAGE_FILE=$(mktemp "/tmp/brunch_update_payload.XXXXXX")
trap 'rm -f "$STAGE_FILE"' EXIT

cat << 'BRUNCH_CUSTOM_UPDATE_EOF' > "$STAGE_FILE"
#!/usr/bin/env bash

set -euo pipefail
umask 077

export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

GITHUB_REPO="jihanum/brunch-x1607ca"
CROS_BOARD="volteer"
CROS_CHANNEL="stable"               # "stable" or "beta"
REQUIRE_RECOVERY_SHA1="false"       # Set "true" to prevent cros.tech historical .imgs without recovery2.json SHA-1

STATE_DIR="/mnt/stateful_partition/brunch/updater"
BRUNCH_STAGING_DIR="/mnt/stateful_partition/unencrypted/brunch_updater"
STATE_FILE="${STATE_DIR}/version_state.env"
LOG_FILE="${STATE_DIR}/updater.log"
LOCK_FILE="/run/brunch_updater.lock"
WORK_DIR=""
MNT_CHECK=""

if [[ ! "$GITHUB_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || \
   [[ ! "$CROS_BOARD" =~ ^[a-z0-9_-]+$ ]] || \
   [[ "$CROS_CHANNEL" != "stable" && "$CROS_CHANNEL" != "beta" ]]; then
    echo "ERROR: Invalid updater configuration." >&2
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This updater must be run as root." >&2
    exit 1
fi

ensure_safe_dir() {
    local dir="$1"
    if [ -L "$dir" ]; then
        echo "ERROR: Unsafe symlink detected at directory path '$dir'." >&2
        exit 1
    fi
    if [ ! -e "$dir" ]; then
        mkdir -p -m 0700 "$dir"
    fi
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
        echo "ERROR: '$dir' is not a valid directory." >&2
        exit 1
    fi
    chown 0:0 "$dir"
    chmod 0700 "$dir"
}

ensure_safe_dir "/mnt/stateful_partition/brunch"
ensure_safe_dir "$STATE_DIR"

if [ -L "$LOG_FILE" ]; then
    echo "ERROR: Unsafe symlink detected at log file '$LOG_FILE'." >&2
    exit 1
fi
if [ ! -e "$LOG_FILE" ]; then
    : > "$LOG_FILE"
fi
chown 0:0 "$LOG_FILE"
chmod 0600 "$LOG_FILE"

exec >> "$LOG_FILE" 2>&1

echo "=========================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting update check (Board: ${CROS_BOARD}, Channel: ${CROS_CHANNEL})..."

REQUIRED_CMDS=(curl python3 tar cgpt rootdev pv sha1sum sha256sum flock mount umount df mktemp mountpoint)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

if [ -L "$LOCK_FILE" ]; then
    echo "ERROR: Unsafe symlink detected at lock file '$LOCK_FILE'."
    exit 1
fi
exec 9> "$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updater is already running. Exiting."
    exit 0
fi

cleanup() {
    if [ -n "${MNT_CHECK:-}" ] && [ -d "$MNT_CHECK" ]; then
        if mountpoint -q "$MNT_CHECK" 2>/dev/null; then
            umount "$MNT_CHECK" 2>/dev/null || umount -l "$MNT_CHECK" 2>/dev/null || true
        fi
        rmdir "$MNT_CHECK" 2>/dev/null || rm -rf "$MNT_CHECK" 2>/dev/null || true
    fi
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR" 2>/dev/null || true
    fi
    if [ -n "${BRUNCH_STAGING_DIR:-}" ] && [ ! -L "$BRUNCH_STAGING_DIR" ] && [ -d "$BRUNCH_STAGING_DIR" ]; then
        rm -rf "$BRUNCH_STAGING_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

WORK_DIR=$(mktemp -d "${STATE_DIR}/work.XXXXXX")
MNT_CHECK=$(mktemp -d "${STATE_DIR}/mnt.XXXXXX")
chmod 0700 "$WORK_DIR" "$MNT_CHECK"

for i in {1..12}; do
    if curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSI -- "https://api.github.com" >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 12 ]; then
        echo "ERROR: No network connection after 60 seconds. Aborting."
        exit 1
    fi
    sleep 5
done

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

load_state_file() {
    local state_path="$1"
    if [ ! -e "$state_path" ]; then
        return 0
    fi
    if [ -L "$state_path" ] || [ ! -f "$state_path" ]; then
        echo "ERROR: State file '$state_path' is not a regular file."
        exit 1
    fi

    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            ""|\#*) continue ;;
        esac
        if [[ "$line" != *=* ]]; then
            echo "WARNING: Ignoring malformed line in state file."
            continue
        fi
        key="${line%%=*}"
        val="${line#*=}"

        if [[ "$val" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi

        case "$key" in
            RECORDED_CROS_MILESTONE)
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    RECORDED_CROS_MILESTONE="$val"
                else
                    echo "WARNING: Invalid RECORDED_CROS_MILESTONE in state file; ignoring."
                fi
                ;;
            RECORDED_CROS_PLATFORM_VERSION)
                if [[ "$val" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
                    RECORDED_CROS_PLATFORM_VERSION="$val"
                else
                    echo "WARNING: Invalid RECORDED_CROS_PLATFORM_VERSION in state file; ignoring."
                fi
                ;;
            RECORDED_BRUNCH_RELEASE)
                if [[ "$val" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
                    RECORDED_BRUNCH_RELEASE="$val"
                else
                    echo "WARNING: Invalid RECORDED_BRUNCH_RELEASE in state file; ignoring."
                fi
                ;;
            RECORDED_BRUNCH_MILESTONE)
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    RECORDED_BRUNCH_MILESTONE="$val"
                else
                    echo "WARNING: Invalid RECORDED_BRUNCH_MILESTONE in state file; ignoring."
                fi
                ;;
            RECORDED_BRUNCH_DATE)
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    RECORDED_BRUNCH_DATE="$val"
                else
                    echo "WARNING: Invalid RECORDED_BRUNCH_DATE in state file; ignoring."
                fi
                ;;
            *)
                echo "WARNING: Ignoring unexpected key '$key' in state file."
                ;;
        esac
    done < "$state_path"
}

if [ ! -f /etc/lsb-release ] || [ -L /etc/lsb-release ]; then
    echo "ERROR: /etc/lsb-release is missing or unsafe."
    exit 1
fi
SYS_MILESTONE=$(grep -m1 -oP '(?<=^CHROMEOS_RELEASE_CHROME_MILESTONE=)[0-9]+' /etc/lsb-release || echo "0")
SYS_PLATFORM_VER=$(grep -m1 -oP '(?<=^CHROMEOS_RELEASE_VERSION=)[0-9.]+' /etc/lsb-release || echo "0.0.0")
if [[ ! "$SYS_MILESTONE" =~ ^[0-9]+$ ]]; then
    SYS_MILESTONE="0"
fi
if [[ ! "$SYS_PLATFORM_VER" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    SYS_PLATFORM_VER="0.0.0"
fi

if [ -f /etc/brunch_version ] && [ ! -L /etc/brunch_version ]; then
    SYS_BRUNCH_RAW=$(tr -d '\r\n' < /etc/brunch_version)
else
    SYS_BRUNCH_RAW="none"
fi
if [[ ! "$SYS_BRUNCH_RAW" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    SYS_BRUNCH_RAW="none"
fi

IFS='|' read -r SYS_BRUNCH_MILESTONE SYS_BRUNCH_DATE <<< "$(parse_brunch_info "$SYS_BRUNCH_RAW")"

RECORDED_CROS_MILESTONE=""
RECORDED_CROS_PLATFORM_VERSION=""
RECORDED_BRUNCH_RELEASE=""
RECORDED_BRUNCH_MILESTONE=""
RECORDED_BRUNCH_DATE=""

load_state_file "$STATE_FILE"

RECORDED_CROS_MILESTONE="${RECORDED_CROS_MILESTONE:-$SYS_MILESTONE}"
RECORDED_CROS_PLATFORM_VERSION="${RECORDED_CROS_PLATFORM_VERSION:-$SYS_PLATFORM_VER}"
RECORDED_BRUNCH_RELEASE="${RECORDED_BRUNCH_RELEASE:-$SYS_BRUNCH_RAW}"

IFS='|' read -r PARSED_REC_MS PARSED_REC_DATE <<< "$(parse_brunch_info "$RECORDED_BRUNCH_RELEASE")"
RECORDED_BRUNCH_MILESTONE="${RECORDED_BRUNCH_MILESTONE:-$PARSED_REC_MS}"
RECORDED_BRUNCH_DATE="${RECORDED_BRUNCH_DATE:-$PARSED_REC_DATE}"

if [[ ! "$RECORDED_CROS_MILESTONE" =~ ^[0-9]+$ ]] || \
   [[ ! "$RECORDED_BRUNCH_MILESTONE" =~ ^[0-9]+$ ]] || \
   [[ ! "$RECORDED_BRUNCH_DATE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid numeric version metadata in system or state."
    exit 1
fi

echo "Installed System   : ChromeOS r${SYS_MILESTONE} (${SYS_PLATFORM_VER}) | Brunch '${SYS_BRUNCH_RAW}' (r${SYS_BRUNCH_MILESTONE}, Date: ${SYS_BRUNCH_DATE})"
echo "Recorded State     : ChromeOS r${RECORDED_CROS_MILESTONE} (${RECORDED_CROS_PLATFORM_VERSION}) | Brunch '${RECORDED_BRUNCH_RELEASE}' (r${RECORDED_BRUNCH_MILESTONE}, Date: ${RECORDED_BRUNCH_DATE})"

GH_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
GH_JSON_FILE="${WORK_DIR}/gh_release.json"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL -- "$GH_API_URL" -o "$GH_JSON_FILE"

BRUNCH_PARSED=$(python3 - "$GH_JSON_FILE" "$GITHUB_REPO" << 'PYEOF'
import datetime, json, re, sys

json_path, repo = sys.argv[1], sys.argv[2]
with open(json_path, "r", encoding="utf-8") as f:
    data = json.load(f)

tag = (data.get("tag_name") or "").strip()
name = (data.get("name") or "").strip()
body = data.get("body") or ""

if not re.fullmatch(r"[A-Za-z0-9._-]+", tag):
    print("ERR_INVALID_TAG", file=sys.stderr)
    sys.exit(1)

m_body = re.search(r"release_sha256sum=([0-9a-fA-F]{64})", body)
body_sha256 = m_body.group(1).lower() if m_body else ""

assets = [a for a in data.get("assets", []) if (a.get("name") or "").endswith(".tar.gz")]
assets.sort(key=lambda a: 0 if (a.get("name") or "").lower().startswith("brunch") else 1)

if not assets:
    print("ERR_NO_TARBALL_ASSET", file=sys.stderr)
    sys.exit(1)

asset = assets[0]
asset_name = (asset.get("name") or "").strip()
url = (asset.get("browser_download_url") or "").strip()
try:
    size = int(asset.get("size", 0))
except (TypeError, ValueError):
    size = 0
digest = asset.get("digest", "") or ""
asset_sha256 = digest.split("sha256:", 1)[1].lower() if digest.startswith("sha256:") else ""

url_re = re.compile(
    rf"^https://(?:github\.com/{re.escape(repo)}/releases/download/|objects\.githubusercontent\.com/|release-assets\.githubusercontent\.com/)[^\s|\"'<>]+$"
)
if not url_re.fullmatch(url):
    print("ERR_INVALID_ASSET_URL", file=sys.stderr)
    sys.exit(1)

if size <= 0:
    print("ERR_INVALID_ASSET_SIZE", file=sys.stderr)
    sys.exit(1)

if body_sha256 and asset_sha256 and body_sha256 != asset_sha256:
    print("ERR_DIGEST_MISMATCH", file=sys.stderr)
    sys.exit(2)

final_sha256 = body_sha256 or asset_sha256
if not re.fullmatch(r"[0-9a-f]{64}", final_sha256):
    print("ERR_NO_VALID_SHA256", file=sys.stderr)
    sys.exit(3)

combined_meta = f"{tag} {name} {asset_name}"
m_ms = re.search(r"(?:^|[^a-zA-Z0-9])r([0-9]{2,3})(?:[^0-9]|$)", combined_meta)
milestone = m_ms.group(1) if m_ms else "0"

valid_dates = []
for d in re.findall(r"(20[0-9]{6})", combined_meta):
    try:
        datetime.datetime.strptime(d, "%Y%m%d")
        valid_dates.append(d)
    except ValueError:
        pass
date_str = valid_dates[-1] if valid_dates else "0"

fields = [tag, url, str(size), final_sha256, milestone, date_str]
if any("|" in x or "\n" in x or "\r" in x for x in fields):
    print("ERR_UNSAFE_FIELD", file=sys.stderr)
    sys.exit(4)

print("|".join(fields))
PYEOF
)

IFS='|' read -r LATEST_BRUNCH_TAG BRUNCH_TAR_URL BRUNCH_TAR_SIZE BRUNCH_EXPECTED_SHA256 BRUNCH_MILESTONE BRUNCH_DATE <<< "$BRUNCH_PARSED"

if [ "$BRUNCH_MILESTONE" = "0" ] || [ "$BRUNCH_DATE" = "0" ] || \
   [[ ! "$BRUNCH_MILESTONE" =~ ^[0-9]+$ ]] || [[ ! "$BRUNCH_DATE" =~ ^[0-9]+$ ]] || \
   [[ ! "$BRUNCH_TAR_SIZE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not extract valid milestone (rXXX) and build date (YYYYMMDD) from GitHub release '${LATEST_BRUNCH_TAG}'."
    exit 1
fi

echo "Latest GitHub Brunch: ${LATEST_BRUNCH_TAG} (Target: r${BRUNCH_MILESTONE}, Build Date: ${BRUNCH_DATE})"
echo "Brunch SHA-256      : ${BRUNCH_EXPECTED_SHA256}"

RECOVERY_JSON_FILE="${WORK_DIR}/recovery2.json"
CROS_HTML_FILE="${WORK_DIR}/cros_tech.html"

curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL -- "https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json" -o "$RECOVERY_JSON_FILE" || echo "[]" > "$RECOVERY_JSON_FILE"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL -A "Mozilla/5.0" -- "https://cros.tech/board/${CROS_BOARD}/" -o "$CROS_HTML_FILE" || : > "$CROS_HTML_FILE"

RECOVERY_AVAILABLE=true
RECOVERY_PARSED=$(python3 - "$RECOVERY_JSON_FILE" "$CROS_HTML_FILE" "$CROS_BOARD" "$CROS_CHANNEL" "$BRUNCH_MILESTONE" << 'PYEOF'
import json, re, sys
from html.parser import HTMLParser

rec_json_path, html_path, board, channel, target_ms = sys.argv[1:6]
channel_lower = channel.lower()

url_pattern = re.compile(
    rf"^https://dl\.google\.com/dl/edgedl/chromeos/recovery/chromeos_([0-9]+(?:\.[0-9]+)*)_{re.escape(board)}_recovery_{re.escape(channel_lower)}-channel_[^\s|\"'<>]+\.bin\.zip$"
)
ver_pattern = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")
sha1_pattern = re.compile(r"^[0-9a-fA-F]{40}$")

def ver_key(v):
    return [int(x) for x in v.split(".")]

with open(rec_json_path, "r", encoding="utf-8") as f:
    rec_data = json.load(f)

matches = []
for item in rec_data:
    url = (item.get("url") or "").strip()
    c_ver = (item.get("chrome_version") or "").strip()
    p_ver = (item.get("version") or "").strip()
    ch = (item.get("channel") or "").strip().lower()
    sha1 = (item.get("sha1") or "").strip().lower()
    try:
        filesize = int(item.get("filesize", 0))
    except (TypeError, ValueError):
        continue

    if (url_pattern.fullmatch(url)
        and ver_pattern.fullmatch(p_ver)
        and sha1_pattern.fullmatch(sha1)
        and filesize >= 0
        and c_ver.startswith(f"{target_ms}.")
        and ch == channel_lower):
        matches.append((p_ver, url, sha1, filesize))

if matches:
    matches.sort(key=lambda x: ver_key(x[0]))
    best_p_ver, best_url, best_sha1, best_size = matches[-1]
    fields = ["recovery2.json", best_url, best_p_ver, best_sha1, str(best_size)]
    if any("|" in x or "\n" in x or "\r" in x for x in fields):
        sys.exit(1)
    print("|".join(fields))
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
            self.curr_href = dict(attrs).get("href", "") or ""
            self.curr_text = []
    def handle_data(self, data):
        if self.in_a:
            self.curr_text.append(data)
    def handle_endtag(self, tag):
        if tag.lower() == "a" and self.in_a:
            self.in_a = False
            self.links.append((self.curr_href.strip(), " ".join(self.curr_text).strip()))

parser = CrosTechParser()
parser.feed(html_text)

html_candidates = []
for href, text in parser.links:
    m_url = url_pattern.fullmatch(href)
    if not m_url:
        continue
    p_ver = m_url.group(1)
    if not ver_pattern.fullmatch(p_ver):
        continue
    if re.search(rf"\b{re.escape(target_ms)}\b", text):
        html_candidates.append((p_ver, href))

if html_candidates:
    html_candidates.sort(key=lambda x: ver_key(x[0]))
    best_p_ver, best_url = html_candidates[-1]
    fields = ["cros.tech", best_url, best_p_ver, "", "0"]
    if any("|" in x or "\n" in x or "\r" in x for x in fields):
        sys.exit(1)
    print("|".join(fields))
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

RECOVERY_ZIP_SIZE=0
RECOVERY_SHA1=""
if [ "$RECOVERY_AVAILABLE" = "true" ]; then
    IFS='|' read -r RECOVERY_SOURCE RECOVERY_ZIP_URL LATEST_CROS_PLATFORM_VER RECOVERY_SHA1 RECOVERY_ZIP_SIZE <<< "$RECOVERY_PARSED"
    if [[ ! "$RECOVERY_ZIP_SIZE" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Invalid recovery zip size '$RECOVERY_ZIP_SIZE'."
        exit 1
    fi
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
elif [ "$BRUNCH_MILESTONE" -eq "$RECORDED_CROS_MILESTONE" ] && \
     [ "$BRUNCH_MILESTONE" -eq "$SYS_MILESTONE" ] && \
     [ "$BRUNCH_IS_NEWER" = "true" ]; then
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
if [[ ! "$STATE_AVAIL_KB" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Unable to determine available space on '$STATE_DIR'."
    exit 1
fi
if [ "$STATE_AVAIL_KB" -lt "$MIN_FREE_KB" ]; then
    echo "ERROR: Insufficient stateful partition space: $((STATE_AVAIL_KB / 1024)) MB free, need $((MIN_FREE_KB / 1024)) MB."
    exit 1
fi

UPDATE_ARGS=()

if [ "$DO_UPDATE_BRUNCH" = "true" ]; then
    BRUNCH_ARCHIVE="${WORK_DIR}/brunch_latest.tar.gz"
    echo "Downloading Brunch archive (${LATEST_BRUNCH_TAG})..."
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL --retry 3 -o "$BRUNCH_ARCHIVE" -- "$BRUNCH_TAR_URL"

    ACTUAL_SHA256=$(sha256sum "$BRUNCH_ARCHIVE" | awk '{print tolower($1)}')
    if [ "$ACTUAL_SHA256" != "$BRUNCH_EXPECTED_SHA256" ]; then
        echo "ERROR: Brunch SHA-256 mismatch! Expected ${BRUNCH_EXPECTED_SHA256}, got ${ACTUAL_SHA256}."
        exit 1
    fi
    echo "Brunch SHA-256 verified."

    python3 - "$BRUNCH_ARCHIVE" << 'PYEOF'
import posixpath, sys, tarfile

archive_path = sys.argv[1]
has_rootc = False
with tarfile.open(archive_path, "r:gz") as tf:
    for member in tf.getmembers():
        parts = member.name.split("/")
        norm = posixpath.normpath(member.name)
        if member.name.startswith("/") or ".." in parts or norm.startswith(".."):
            raise RuntimeError(f"Unsafe path in Brunch archive: {member.name}")
        if member.issym() or member.islnk() or member.ischr() or member.isblk() or member.isfifo() or member.isdev():
            raise RuntimeError(f"Unsafe symlink or special file in Brunch archive: {member.name}")
        if not (member.isreg() or member.isdir()):
            raise RuntimeError(f"Unsupported member type in Brunch archive: {member.name}")
        if norm == "rootc.img" and member.isreg() and member.size > 0:
            has_rootc = True
if not has_rootc:
    raise RuntimeError("Brunch archive does not contain a valid regular rootc.img.")
PYEOF

    UPDATE_ARGS+=(-f "$BRUNCH_ARCHIVE")
fi

if [ "$DO_UPDATE_CROS" = "true" ]; then
    RECOVERY_ZIP="${WORK_DIR}/recovery.bin.zip"
    echo "Downloading ChromeOS recovery archive..."
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL --retry 3 -o "$RECOVERY_ZIP" -- "$RECOVERY_ZIP_URL"

    if [ -n "$RECOVERY_SHA1" ]; then
        ACTUAL_SHA1=$(sha1sum "$RECOVERY_ZIP" | awk '{print tolower($1)}')
        if [ "${RECOVERY_SHA1,,}" != "$ACTUAL_SHA1" ]; then
            echo "ERROR: Recovery ZIP SHA-1 mismatch! Expected ${RECOVERY_SHA1}, got ${ACTUAL_SHA1}."
            exit 1
        fi
        echo "Recovery ZIP SHA-1 checksum verified."
    fi

    echo "Verifying ZIP CRC integrity and streaming ChromeOS .bin safely via python3..."
    RECOVERY_BIN=$(python3 - "$RECOVERY_ZIP" "$WORK_DIR" << 'PYEOF'
import os, shutil, sys, zipfile

zip_path, out_dir = sys.argv[1], sys.argv[2]
out_path = os.path.join(out_dir, "recovery_image.bin")
with zipfile.ZipFile(zip_path, "r") as zf:
    bad_file = zf.testzip()
    if bad_file is not None:
        raise RuntimeError(f"Corrupted file inside ZIP archive: {bad_file}")
    bin_members = [
        info for info in zf.infolist()
        if not info.is_dir()
        and info.filename.endswith(".bin")
        and "/" not in info.filename
        and "\\" not in info.filename
        and ".." not in info.filename
    ]
    if len(bin_members) != 1:
        raise RuntimeError(f"Expected exactly 1 flat .bin file in ZIP, found: {[i.filename for i in bin_members]}")
    target_info = bin_members[0]
    with zf.open(target_info, "r") as src:
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb") as dst:
                shutil.copyfileobj(src, dst, length=1024 * 1024)
        except Exception:
            if os.path.exists(out_path):
                os.unlink(out_path)
            raise
print(out_path)
PYEOF
    )
    rm -f "$RECOVERY_ZIP"

    if [ -z "$RECOVERY_BIN" ] || [ ! -f "$RECOVERY_BIN" ] || [ -L "$RECOVERY_BIN" ]; then
        echo "ERROR: Failed to extract recovery .bin file."
        exit 1
    fi

    if [ "$(cgpt show -i 3 -l "$RECOVERY_BIN" 2>/dev/null || true)" != "ROOT-A" ]; then
        echo "ERROR: Extracted recovery .bin does not contain a valid ROOT-A partition at index 3."
        exit 1
    fi

    ROOTA_START_SECTOR=$(cgpt show -i 3 -b "$RECOVERY_BIN")
    if [[ ! "$ROOTA_START_SECTOR" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Invalid ROOT-A start sector '$ROOTA_START_SECTOR'."
        exit 1
    fi
    ROOTA_OFFSET=$(( ROOTA_START_SECTOR * 512 ))
    mount -t ext2 -o ro,loop,nosuid,nodev,noexec,offset="$ROOTA_OFFSET" "$RECOVERY_BIN" "$MNT_CHECK"
    if [ ! -f "${MNT_CHECK}/etc/lsb-release" ] || [ -L "${MNT_CHECK}/etc/lsb-release" ]; then
        umount "$MNT_CHECK"
        echo "ERROR: Extracted recovery image missing regular /etc/lsb-release."
        exit 1
    fi
    BIN_MILESTONE=$(grep -m1 -oP '(?<=^CHROMEOS_RELEASE_CHROME_MILESTONE=)[0-9]+' "${MNT_CHECK}/etc/lsb-release" || echo "0")
    BIN_PLATFORM_VER=$(grep -m1 -oP '(?<=^CHROMEOS_RELEASE_VERSION=)[0-9.]+' "${MNT_CHECK}/etc/lsb-release" || echo "none")
    BIN_BOARD=$(grep -m1 -oP '(?<=^CHROMEOS_RELEASE_BOARD=)[a-z0-9_-]+' "${MNT_CHECK}/etc/lsb-release" || echo "none")
    umount "$MNT_CHECK"

    if [ "$BIN_BOARD" != "$CROS_BOARD" ] || [ "$BIN_MILESTONE" != "$BRUNCH_MILESTONE" ] || [ "$BIN_PLATFORM_VER" != "$LATEST_CROS_PLATFORM_VER" ]; then
        echo "ERROR: Pre-flash .bin inspection failed! Found board=${BIN_BOARD}, milestone=${BIN_MILESTONE}, platform=${BIN_PLATFORM_VER}."
        exit 1
    fi
    echo "Pre-flash .bin verified: board=${BIN_BOARD}, milestone=${BIN_MILESTONE}, platform=${BIN_PLATFORM_VER}."
    UPDATE_ARGS+=(-r "$RECOVERY_BIN")
fi

if [ "${#UPDATE_ARGS[@]}" -eq 0 ]; then
    echo "ERROR: Internal error - no update arguments built."
    exit 1
fi
if [ ! -x /usr/sbin/chromeos-update ] || [ -L /usr/sbin/chromeos-update ]; then
    echo "ERROR: /usr/sbin/chromeos-update is missing, not executable, or a symlink."
    exit 1
fi
if [ -L "$BRUNCH_STAGING_DIR" ]; then
    echo "ERROR: Unsafe symlink detected at staging directory '$BRUNCH_STAGING_DIR'."
    exit 1
fi

echo "Running: /usr/sbin/chromeos-update ${UPDATE_ARGS[*]}"
/usr/sbin/chromeos-update "${UPDATE_ARGS[@]}"

DEST_DISK=$(rootdev -d)
if [ -z "$DEST_DISK" ] || [ ! -b "$DEST_DISK" ]; then
    echo "ERROR: Invalid destination block device '$DEST_DISK'."
    exit 1
fi
if [[ "$DEST_DISK" =~ [0-9]$ ]]; then
    PART_PREFIX="${DEST_DISK}p"
else
    PART_PREFIX="${DEST_DISK}"
fi

if [ "$DO_UPDATE_CROS" = "true" ]; then
    KERN_B_PRIO=$(cgpt show -i 4 -P "$DEST_DISK")
    if [[ ! "$KERN_B_PRIO" =~ ^[0-9]+$ ]] || [ "$KERN_B_PRIO" -ne 15 ]; then
        echo "ERROR: Post-update verification failed: KERN-B priority is '${KERN_B_PRIO}' (expected 15)."
        exit 1
    fi

    mount -t ext2 -o ro,nosuid,nodev,noexec "${PART_PREFIX}5" "$MNT_CHECK"
    if [ ! -f "${MNT_CHECK}/etc/lsb-release" ] || [ -L "${MNT_CHECK}/etc/lsb-release" ]; then
        umount "$MNT_CHECK"
        echo "ERROR: Partition 5 missing regular /etc/lsb-release."
        exit 1
    fi
    FLASHED_PLATFORM_VER=$(grep -m1 -oP '(?<=^CHROMEOS_RELEASE_VERSION=)[0-9.]+' "${MNT_CHECK}/etc/lsb-release" || echo "none")
    FLASHED_MILESTONE=$(grep -m1 -oP '(?<=^CHROMEOS_RELEASE_CHROME_MILESTONE=)[0-9]+' "${MNT_CHECK}/etc/lsb-release" || echo "0")
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
    mount -o ro,nosuid,nodev,noexec "${PART_PREFIX}7" "$MNT_CHECK"
    if [ ! -f "${MNT_CHECK}/initramfs.img" ] || [ -L "${MNT_CHECK}/initramfs.img" ] || [ ! -s "${MNT_CHECK}/initramfs.img" ] || \
       [ ! -f "${MNT_CHECK}/packages/base.tar.gz" ] || [ -L "${MNT_CHECK}/packages/base.tar.gz" ] || [ ! -s "${MNT_CHECK}/packages/base.tar.gz" ] || \
       [ ! -f "${MNT_CHECK}/kernel" ] || [ -L "${MNT_CHECK}/kernel" ] || [ ! -s "${MNT_CHECK}/kernel" ]; then
        umount "$MNT_CHECK"
        echo "ERROR: Partition 7 (ROOTC) is missing valid regular core files (initramfs.img, kernel, or packages/base.tar.gz)."
        exit 1
    fi

    FLASHED_BRUNCH_VER=$(python3 - "${MNT_CHECK}/packages/base.tar.gz" << 'PYEOF' || true
import posixpath, sys, tarfile

with tarfile.open(sys.argv[1], "r:gz") as tf:
    for member in tf.getmembers():
        if posixpath.normpath(member.name) == "etc/brunch_version" and member.isreg():
            f = tf.extractfile(member)
            if f is not None:
                print(f.read().decode("utf-8", errors="ignore").strip("\r\n"))
            break
PYEOF
    )
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

if [[ ! "$RECORDED_CROS_MILESTONE" =~ ^[0-9]+$ ]] || \
   [[ ! "$RECORDED_CROS_PLATFORM_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || \
   [[ ! "$RECORDED_BRUNCH_RELEASE" =~ ^[A-Za-z0-9._\ -]+$ ]] || \
   [[ ! "$RECORDED_BRUNCH_MILESTONE" =~ ^[0-9]+$ ]] || \
   [[ ! "$RECORDED_BRUNCH_DATE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Refusing to persist invalid state metadata."
    exit 1
fi

TMP_STATE=$(mktemp "${STATE_DIR}/version_state.env.XXXXXX")
chmod 0600 "$TMP_STATE"
{
    printf 'RECORDED_CROS_MILESTONE="%s"\n' "$RECORDED_CROS_MILESTONE"
    printf 'RECORDED_CROS_PLATFORM_VERSION="%s"\n' "$RECORDED_CROS_PLATFORM_VERSION"
    printf 'RECORDED_BRUNCH_RELEASE="%s"\n' "$RECORDED_BRUNCH_RELEASE"
    printf 'RECORDED_BRUNCH_MILESTONE="%s"\n' "$RECORDED_BRUNCH_MILESTONE"
    printf 'RECORDED_BRUNCH_DATE="%s"\n' "$RECORDED_BRUNCH_DATE"
} > "$TMP_STATE"
chown 0:0 "$TMP_STATE"
mv -f "$TMP_STATE" "$STATE_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Update verified and recorded! Reboot manually whenever ready."
BRUNCH_CUSTOM_UPDATE_EOF

REF_BIN="${PREFIX}/usr/bin/mawk"
[ -e "$REF_BIN" ] || REF_BIN="${PREFIX}/bin/bash"
[ -e "$REF_BIN" ] || REF_BIN="${PREFIX}/bin/sh"

REF_INIT="${PREFIX}/etc/init/cras.conf"
[ -e "$REF_INIT" ] || REF_INIT="${PREFIX}/etc/init/ui.conf"

if ! safe_install_payload "$STAGE_FILE" "${PREFIX}/usr/local/bin/update" 0755 "$REF_BIN" "u:object_r:cros_system_file:s0"; then
    echo "brunch: custom_updater: ERROR installing ${PREFIX}/usr/local/bin/update" >&2
    ret=$((ret + 1))
fi

if ! safe_install_payload "$STAGE_FILE" "${PREFIX}/usr/share/brunch/update" 0755 "$REF_BIN" "u:object_r:cros_system_file:s0"; then
    echo "brunch: custom_updater: ERROR installing ${PREFIX}/usr/share/brunch/update" >&2
    ret=$((ret + 2))
fi

UPSTART_TMP=$(mktemp "/tmp/brunch_custom_updater_init.XXXXXX")
cat << 'INITEOF' > "$UPSTART_TMP"
description "Ensure hardened Brunch custom updater is installed at /usr/local/bin/update"
author "Brunch Patch"

start on started system-services
task

script
    set +e
    SRC="/usr/share/brunch/update"
    DST_DIR="/usr/local/bin"
    DST="${DST_DIR}/update"

    [ -f "$SRC" ] || exit 0
    [ -L "$DST_DIR" ] && exit 1

    if [ ! -d "$DST_DIR" ]; then
        mkdir -p -m 0755 "$DST_DIR" || exit 1
    fi

    if [ -L "$DST" ]; then
        rm -f "$DST"
    fi

    if [ ! -f "$DST" ] || [ ! -x "$DST" ] || ! cmp -s "$SRC" "$DST"; then
        TMP_BIN=$(mktemp "${DST_DIR}/.update.tmp.XXXXXX") || exit 1
        chmod 0755 "$TMP_BIN"
        cat "$SRC" > "$TMP_BIN" || { rm -f "$TMP_BIN"; exit 1; }
        chmod 0755 "$TMP_BIN"
        chown 0:0 "$TMP_BIN" 2>/dev/null || true
        mv -f "$TMP_BIN" "$DST" || { rm -f "$TMP_BIN"; exit 1; }
    else
        chmod 0755 "$DST" 2>/dev/null || true
        chown 0:0 "$DST" 2>/dev/null || true
    fi
end script
INITEOF

if ! safe_install_payload "$UPSTART_TMP" "${PREFIX}/etc/init/brunch-custom-updater.conf" 0644 "$REF_INIT" "u:object_r:cros_init_conf_file:s0"; then
    echo "brunch: custom_updater: ERROR installing ${PREFIX}/etc/init/brunch-custom-updater.conf" >&2
    ret=$((ret + 4))
fi
rm -f "$UPSTART_TMP"

if [ "$TARGET_ROOT" = "/" ] && command -v initctl >/dev/null 2>&1; then
    initctl reload-configuration 2>/dev/null || true
fi

if [ ! -x "${PREFIX}/usr/local/bin/update" ] || [ -L "${PREFIX}/usr/local/bin/update" ]; then
    echo "brunch: custom_updater: verification failed for ${PREFIX}/usr/local/bin/update" >&2
    ret=$((ret + 8))
fi

exit "$ret"
