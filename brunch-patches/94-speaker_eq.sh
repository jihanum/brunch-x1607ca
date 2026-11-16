#!/bin/sh
echo "An audio EQ profile tailored for the ASUS Vivobook 16"

for UCM in /roota/usr/share/alsa/ucm2/conf.d/sof-hda-dsp/HiFi.conf \
           /roota/usr/share/alsa/ucm2/Intel/sof-hda-dsp/HiFi.conf; do
    if [ -f "$UCM" ] && ! grep -q 'DspName "speaker_eq"' "$UCM"; then
        awk '
        /SectionDevice\."Speaker"/ { s=1 }
        s && /^[ \t]*Value[ \t]*\{/ && !d { print; print "\t\tDspName \"speaker_eq\""; d=1; s=0; next }
        { print }
        ' "$UCM" > "${UCM}.tmp" && mv "${UCM}.tmp" "$UCM"
        chmod 0644 "$UCM"
    fi
done

mkdir -p /roota/etc/cras
cat << 'DSP' > /roota/etc/cras/dsp.ini
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
output_2={dst:0}
output_3={dst:1}
input_4=6
input_5=280
input_6=1.40
input_7=-4.8
input_8=6
input_9=280
input_10=1.40
input_11=-4.8
input_12=6
input_13=1350
input_14=1.10
input_15=-8.5
input_16=6
input_17=1350
input_18=1.10
input_19=-8.5
input_20=6
input_21=135
input_22=1.05
input_23=10.0
input_24=6
input_25=135
input_26=1.05
input_27=10.0
input_28=6
input_29=600
input_30=2.20
input_31=-8.0
input_32=6
input_33=600
input_34=2.20
input_35=-8.0
input_36=6
input_37=3200
input_38=1.60
input_39=-8.5
input_40=6
input_41=3200
input_42=1.60
input_43=-8.5
input_44=5
input_45=9000
input_46=0.707
input_47=8.0
input_48=5
input_49=9000
input_50=0.707
input_51=8.0

[output_sink]
library=builtin
label=sink
purpose=playback
input_0={dst:0}
input_1={dst:1}
DSP
chmod 0644 /roota/etc/cras/dsp.ini
exit 0
