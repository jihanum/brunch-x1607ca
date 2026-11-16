#!/bin/sh

set -e

if [ -d /roota/etc ]; then
    ROOT="/roota"
    LIVE=0
else
    ROOT=""
    LIVE=1
fi

CRAS_DIR="${ROOT}/etc/cras"
mkdir -p "${CRAS_DIR}"

write_speaker_curve() {
    cat << 'EOF'
volume_curve = explicit
db_at_0 = -5000
db_at_1 = -4594
db_at_2 = -3986
db_at_3 = -3628
db_at_4 = -3372
db_at_5 = -3172
db_at_6 = -3007
db_at_7 = -2868
db_at_8 = -2746
db_at_9 = -2638
db_at_10 = -2540
db_at_11 = -2451
db_at_12 = -2369
db_at_13 = -2294
db_at_14 = -2223
db_at_15 = -2158
db_at_16 = -2096
db_at_17 = -2037
db_at_18 = -1982
db_at_19 = -1929
db_at_20 = -1878
db_at_21 = -1830
db_at_22 = -1783
db_at_23 = -1739
db_at_24 = -1696
db_at_25 = -1654
db_at_26 = -1614
db_at_27 = -1575
db_at_28 = -1538
db_at_29 = -1501
db_at_30 = -1466
db_at_31 = -1431
db_at_32 = -1398
db_at_33 = -1365
db_at_34 = -1333
db_at_35 = -1302
db_at_36 = -1271
db_at_37 = -1242
db_at_38 = -1212
db_at_39 = -1184
db_at_40 = -1156
db_at_41 = -1128
db_at_42 = -1101
db_at_43 = -1075
db_at_44 = -1049
db_at_45 = -1024
db_at_46 = -999
db_at_47 = -974
db_at_48 = -950
db_at_49 = -926
db_at_50 = -902
db_at_51 = -879
db_at_52 = -856
db_at_53 = -833
db_at_54 = -811
db_at_55 = -790
db_at_56 = -768
db_at_57 = -746
db_at_58 = -725
db_at_59 = -705
db_at_60 = -684
db_at_61 = -664
db_at_62 = -644
db_at_63 = -624
db_at_64 = -604
db_at_65 = -584
db_at_66 = -565
db_at_67 = -546
db_at_68 = -527
db_at_69 = -509
db_at_70 = -490
db_at_71 = -472
db_at_72 = -453
db_at_73 = -435
db_at_74 = -418
db_at_75 = -400
db_at_76 = -382
db_at_77 = -365
db_at_78 = -348
db_at_79 = -331
db_at_80 = -314
db_at_81 = -297
db_at_82 = -280
db_at_83 = -264
db_at_84 = -248
db_at_85 = -231
db_at_86 = -215
db_at_87 = -199
db_at_88 = -183
db_at_89 = -168
db_at_90 = -152
db_at_91 = -136
db_at_92 = -121
db_at_93 = -105
db_at_94 = -90
db_at_95 = -75
db_at_96 = -59
db_at_97 = -44
db_at_98 = -29
db_at_99 = -15
db_at_100 = 0
EOF
}

write_default_curve() {
    cat << 'EOF'
volume_curve = simple_step
volume_step = 50
max_volume = 0
EOF
}

HAS_SPEAKER_CTL=0
if grep -rq 'PlaybackMixerElem.*"Speaker"' "${ROOT}/usr/share/alsa/ucm2" 2>/dev/null; then
    HAS_SPEAKER_CTL=1
elif [ "${LIVE}" -eq 1 ] && command -v amixer >/dev/null 2>&1; then
    if amixer -c 0 scontrols 2>/dev/null | grep -q "'Speaker'"; then
        HAS_SPEAKER_CTL=1
    fi
fi

TMP_CFG="${CRAS_DIR}/.sof-hda-dsp.tmp"

{
    for node in \
        "Speaker" \
        "Internal Speaker" \
        "Speaker Playback Volume"
    do
        echo "[${node}]"
        write_speaker_curve
        echo ""
    done

    echo "[Master]"
    if [ "${HAS_SPEAKER_CTL}" -eq 1 ]; then
        write_default_curve
    else
        write_speaker_curve
    fi
    echo ""

    for ext_node in \
        "Headphone" \
        "Headphones" \
        "Headphone Jack" \
        "Headphone Mic Jack" \
        "Headset" \
        "Line Out" \
        "External Mic" \
        "HDMI" \
        "HDMI/DP" \
        "HDMI1" \
        "HDMI2" \
        "HDMI3" \
        "HDMI4" \
        "HDMI / DisplayPort" \
        "DisplayPort" \
        "USB" \
        "Bluetooth"
    do
        echo "[${ext_node}]"
        write_default_curve
        echo ""
    done
} > "${TMP_CFG}"

chmod 0644 "${TMP_CFG}"
mv "${TMP_CFG}" "${CRAS_DIR}/sof-hda-dsp"

for dir in "${CRAS_DIR}"/*/; do
    if [ -d "${dir}" ]; then
        cp -f "${CRAS_DIR}/sof-hda-dsp" "${dir}/sof-hda-dsp"
        chmod 0644 "${dir}/sof-hda-dsp"
    fi
done

YAML_CFG="${ROOT}/usr/share/chromeos-config/yaml/config.yaml"
if [ -f "${YAML_CFG}" ]; then
    for subdir in $(awk '/cras-config-dir:/ {print $2}' "${YAML_CFG}" | tr -d "\"'" | sort -u); do
        if [ -n "${subdir}" ]; then
            mkdir -p "${CRAS_DIR}/${subdir}"
            cp -f "${CRAS_DIR}/sof-hda-dsp" "${CRAS_DIR}/${subdir}/sof-hda-dsp"
            chmod 0644 "${CRAS_DIR}/${subdir}/sof-hda-dsp"
        fi
    done
fi

if [ "${LIVE}" -eq 1 ] && command -v restart >/dev/null 2>&1; then
    restart cras || true
fi

exit 0
