#!/bin/sh
echo "An audio EQ profile tailored for the ASUS Vivobook 16"

ROOT="${ROOT:-/roota}"
if [ ! -d "$ROOT/etc" ]; then
    ROOT=""
fi

for UCM in "$ROOT/usr/share/alsa/ucm2/conf.d/sof-hda-dsp/HiFi.conf" \
           "$ROOT/usr/share/alsa/ucm2/Intel/sof-hda-dsp/HiFi.conf"; do
    if [ -f "$UCM" ] && ! grep -q 'DspName "speaker_eq"' "$UCM"; then
        awk '
        /SectionDevice\."Speaker"/ { s=1 }
        s && /^[ \t]*Value[ \t]*\{/ && !d { print; print "\t\tDspName \"speaker_eq\""; d=1; s=0; next }
        { print }
        ' "$UCM" > "${UCM}.tmp" && mv "${UCM}.tmp" "$UCM"
        chmod 0644 "$UCM"
    fi
done

mkdir -p "$ROOT/etc/cras"
cat << 'DSP' > "$ROOT/etc/cras/dsp.ini"
[output_source]
library=builtin
label=source
purpose=playback
output_0={src:0}
output_1={src:1}

[speaker_eq]
library=builtin
label=eq2
disable_expr=!equal(dsp_name, "speaker_eq")
input_0={src:0}
input_1={src:1}
output_2={eq_out:0}
output_3={eq_out:1}
input_4=2
input_5=70
input_6=0.707
input_7=0.0
input_8=2
input_9=70
input_10=0.707
input_11=0.0
input_12=6
input_13=115
input_14=1.15
input_15=6.0
input_16=6
input_17=115
input_18=1.15
input_19=6.0
input_20=6
input_21=190
input_22=1.40
input_23=2.5
input_24=6
input_25=190
input_26=1.40
input_27=2.5
input_28=6
input_29=380
input_30=2.40
input_31=-4.5
input_32=6
input_33=380
input_34=2.40
input_35=-4.5
input_36=6
input_37=580
input_38=3.00
input_39=-3.0
input_40=6
input_41=580
input_42=3.00
input_43=-3.0
input_44=6
input_45=1000
input_46=2.60
input_47=-4.2
input_48=6
input_49=1000
input_50=2.60
input_51=-4.2
input_52=6
input_53=2600
input_54=1.80
input_55=-1.5
input_56=6
input_57=2600
input_58=1.80
input_59=-1.5
input_60=5
input_61=10500
input_62=0.707
input_63=3.5
input_64=5
input_65=10500
input_66=0.707
input_67=3.5

[speaker_drc]
library=builtin
label=drc
disable_expr=!equal(dsp_name, "speaker_eq")
input_0={eq_out:0}
input_1={eq_out:1}
output_2={dst:0}
output_3={dst:1}
input_4=1
input_5=0
input_6=1
input_7=-28.0
input_8=22.0
input_9=8.0
input_10=0.005
input_11=0.20
input_12=4.5
input_13=220
input_14=1
input_15=-22.0
input_16=20.0
input_17=4.0
input_18=0.003
input_19=0.20
input_20=1.0
input_21=2400
input_22=1
input_23=-25.0
input_24=24.0
input_25=5.0
input_26=0.002
input_27=0.15
input_28=2.0

[output_sink]
library=builtin
label=sink
purpose=playback
input_0={dst:0}
input_1={dst:1}
DSP
chmod 0644 "$ROOT/etc/cras/dsp.ini"
exit 0
