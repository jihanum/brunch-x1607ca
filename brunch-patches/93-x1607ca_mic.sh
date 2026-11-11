#!/bin/sh

ret=0

cp -a /roota/usr/sbin/chromeos-cleanup-logs /roota/usr/sbin/lnl-mic-daemon 2>/dev/null || true
cat > /roota/usr/sbin/lnl-mic-daemon << 'EOF'
#!/bin/bash

apply_alsa_mixer() {
    amixer -c 0 cset numid=49 on,on,on,on >/dev/null 2>&1 || true
    amixer -c 0 cset numid=48 45,45 >/dev/null 2>&1 || true

    amixer -c 0 cset numid=7 on,on >/dev/null 2>&1 || true
    amixer -c 0 cset numid=6 57,57 >/dev/null 2>&1 || true
}

select_internal_mic() {
    local target_node="$1"
    [ -z "$target_node" ] && return 0

    cras_test_client --select_input "$target_node" >/dev/null 2>&1 || true
    cras_test_client --capture_gain 500 >/dev/null 2>&1 || true

    local dev_id="${target_node%%:*}"
    local sub_id="${target_node#*:}"
    if [ -n "$dev_id" ] && [ -n "$sub_id" ]; then
        local node_uint64=$(( (dev_id << 32) | sub_id ))
        dbus-send --system --type=method_call --dest=org.chromium.cras \
            /org/chromium/cras org.chromium.cras.Control.SetInputNodeGain \
            "uint64:${node_uint64}" int32:63 >/dev/null 2>&1 || true
    fi
}

get_cras_input_state() {
    local diag="${1:-0}"
    cras_test_client --dump_server_info 2>/dev/null | awk -v diag="$diag" '
    /^[ \t]*Input Devices:/ { sec = "IDEV"; next }
    /^[ \t]*Input Nodes:/   { sec = "INODE"; next }
    /^[ \t]*Selected Input Node:/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+:[0-9]+$/ && $i != "0:0") {
                sel_node = $i
            }
        }
        sec = ""
        next
    }
    /^[ \t]*(Output Devices|Output Nodes|Attached clients|Selected Output Node|Num active|System |Capture |Audio Thread)/ {
        sec = ""
        next
    }

    sec == "IDEV" && $1 ~ /^[0-9]+$/ {
        dev_info[$1] = $0
        next
    }

    sec == "INODE" {
        id = ""
        id_idx = 0
        for (i = 1; i <= 3 && i <= NF; i++) {
            if ($i ~ /^[0-9]+:[0-9]+$/) {
                id = $i
                id_idx = i
                break
            }
        }
        if (id == "") next

        split(id, parts, ":")
        dev_id = parts[1]
        ui_gain = $(id_idx + 2)

        plugged = "no"
        plug_idx = id_idx + 3
        for (i = id_idx + 1; i <= NF; i++) {
            if ($i == "yes" || $i == "no") {
                plugged = $i
                plug_idx = i
                break
            }
        }

        type = ""
        type_idx = plug_idx + 3
        for (i = plug_idx + 2; i <= NF; i++) {
            if ($i ~ /^[A-Z][A-Z0-9_]+$/ && $i != "X") {
                type = $i
                type_idx = i
                break
            }
        }

        if (type ~ /LOOPBACK/) next

        is_active = 0
        node_name = ""
        for (i = type_idx + 1; i <= NF; i++) {
            tok = $i
            if (i == type_idx + 1) {
                if (tok == "X" || tok ~ /^[0-9]+$/) {
                    continue
                }
                if (tok ~ /^(X|[0-9]+)?\*/) {
                    is_active = 1
                    sub(/^(X|[0-9]+)?\*/, "", tok)
                }
            } else if (tok ~ /^\*/) {
                is_active = 1
                sub(/^\*/, "", tok)
            }
            if (tok != "") {
                node_name = (node_name == "" ? tok : node_name " " tok)
            }
        }
        if ($0 ~ /\*/) {
            is_active = 1
        }

        node_active[id] = is_active
        if (is_active) {
            any_active_count++
        }

        dinfo = dev_info[dev_id]
        is_sof = (dinfo ~ /sof-hda-dsp/)
        is_16k = (node_name ~ /16kHz/ || dinfo ~ /16kHz/)
        is_pcm06 = (dinfo ~ /(:|hw:)0,6([^0-9]|$)/ || node_name ~ /(:|hw:)0,6([^0-9]|$)/)
        is_pcm07 = (dinfo ~ /(:|hw:)0,7([^0-9]|$)/ || node_name ~ /(:|hw:)0,7([^0-9]|$)/)
        is_pcm00 = (dinfo ~ /(:|hw:)0,0([^0-9]|$)/ || node_name ~ /(:|hw:)0,0([^0-9]|$)/)
        is_dmic_name = (node_name ~ /^DMIC/ || dinfo ~ /DMIC/)

        if (type ~ /^BLUETOOTH/ || type == "USB" || type == "HEADPHONE") {
            is_ext[id] = 1
            if (is_active) {
                ext_active = 1
            }
        } else if (type == "MIC" && plugged == "yes" && !is_pcm06 && !is_pcm07 && !is_dmic_name) {
            is_ext[id] = 1
            ext_active = 1
        }

        score = 0
        if (is_sof && !is_16k && (is_pcm06 || is_dmic_name)) {
            score = 100
            if (is_pcm06 && is_dmic_name) score += 5
            if (plugged == "yes") score += 5
        }
        else if (plugged == "yes" && !is_16k && !is_pcm00 && (type == "INTERNAL_MIC" || type == "FRONT_MIC" || type == "REAR_MIC")) {
            score = 85
            if (is_sof) score += 5
        }
        else if (is_sof && (is_16k || is_pcm07)) {
            score = 40
        }
        else if (is_sof && is_pcm00 && !(type == "MIC" && plugged == "yes")) {
            score = 20
        }

        if (diag == "1") {
            printf "DIAG_NODE id=%s dev=%s plugged=%s active=%d ui_gain=%s type=%s score=%d name=\"%s\" dev_info=\"%s\"\n", \
                id, dev_id, plugged, is_active, ui_gain, type, score, node_name, dinfo
        }

        if (score > best_score) {
            best_score = score
            best_id = id
        }
        next
    }

    END {
        if (sel_node != "" && is_ext[sel_node]) {
            ext_active = 1
        }
        if (diag == "1") {
            printf "DIAG_SUMMARY sel_node=%s best_id=%s best_score=%d ext_active=%d\n", \
                sel_node, best_id, best_score, ext_active
        }
        if (ext_active) {
            print "EXTERNAL_ACTIVE:" best_id
        } else if (best_id == "") {
            print "NO_TARGET:"
        } else if (node_active[best_id] && any_active_count == 1 && (sel_node == "" || sel_node == best_id)) {
            print "INTERNAL_ACTIVE:" best_id
        } else {
            print "NEEDS_SWITCH:" best_id
        }
    }'
}

if [ "${1:-}" = "--diagnose" ]; then
    get_cras_input_state 1
    exit 0
fi

for i in $(seq 1 30); do
    [ -d /proc/asound/card0 ] && break
    sleep 1
done

prev_state=""
gain_initialized=0

for i in $(seq 1 30); do
    apply_alsa_mixer
    cras_out="$(get_cras_input_state)"
    state="${cras_out%%:*}"
    target_node="${cras_out#*:}"

    if [ "$state" = "NEEDS_SWITCH" ] && [ -n "$target_node" ]; then
        if [ "$prev_state" = "EXTERNAL_ACTIVE" ]; then
            sleep 3
            cras_out="$(get_cras_input_state)"
            state="${cras_out%%:*}"
            target_node="${cras_out#*:}"
        fi
        if [ "$state" = "NEEDS_SWITCH" ] && [ -n "$target_node" ]; then
            select_internal_mic "$target_node"
            state="INTERNAL_ACTIVE"
            gain_initialized=1
        fi
    elif [ "$state" = "INTERNAL_ACTIVE" ] && [ -n "$target_node" ] && [ "$gain_initialized" -eq 0 ]; then
        select_internal_mic "$target_node"
        gain_initialized=1
    fi

    [ -n "$state" ] && prev_state="$state"
    sleep 2
done

while true; do
    if amixer -c 0 cget numid=49 2>/dev/null | grep -q "values=off" || \
       ! amixer -c 0 cget numid=48 2>/dev/null | grep -q "values=45,45"; then
        apply_alsa_mixer
    fi

    cras_out="$(get_cras_input_state)"
    state="${cras_out%%:*}"
    target_node="${cras_out#*:}"

    if [ "$state" = "NEEDS_SWITCH" ] && [ -n "$target_node" ]; then
        if [ "$prev_state" = "EXTERNAL_ACTIVE" ]; then
            sleep 3
            cras_out="$(get_cras_input_state)"
            state="${cras_out%%:*}"
            target_node="${cras_out#*:}"
        fi
        if [ "$state" = "NEEDS_SWITCH" ] && [ -n "$target_node" ]; then
            select_internal_mic "$target_node"
            prev_state="INTERNAL_ACTIVE"
        else
            [ -n "$state" ] && prev_state="$state"
        fi
    else
        [ -n "$state" ] && prev_state="$state"
    fi

    sleep 10
done
EOF
chmod 0755 /roota/usr/sbin/lnl-mic-daemon
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi

cp -a /roota/etc/init/cras.conf /roota/etc/init/lnl-mic.conf 2>/dev/null || true
cat > /roota/etc/init/lnl-mic.conf << 'EOF'
description "Lunar Lake / Arrow Lake SOF microphone mixer and CRAS input watchdog"
author "brunch-lunar-lake"

start on stopped startup
stop on starting halt or starting reboot
respawn

exec /usr/sbin/lnl-mic-daemon >/dev/null 2>&1
EOF
chmod 0644 /roota/etc/init/lnl-mic.conf
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi

exit $ret
