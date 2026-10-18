#!/bin/bash
setsid /bin/bash -c '
  for i in $(seq 1 30); do
    [ -d /proc/asound/card0 ] && break
    sleep 1
  done

  apply_mic_settings() {
    amixer -c 0 cset numid=49 on,on,on,on >/dev/null 2>&1 || true
    amixer -c 0 cset numid=48 40,40 >/dev/null 2>&1 || true
    amixer -c 0 cset numid=7 on,on >/dev/null 2>&1 || true
    amixer -c 0 cset numid=6 50,50 >/dev/null 2>&1 || true
    cras_test_client --select_input 12:0 >/dev/null 2>&1 || true
  }

  for i in $(seq 1 30); do
    apply_mic_settings
    sleep 2
  done

  while true; do
    if amixer -c 0 cget numid=49 2>/dev/null | grep -q "values=off"; then
      apply_mic_settings
    fi
    if ! cras_test_client --dump_server_info 2>/dev/null | grep -E "12:0.*\*" >/dev/null; then
      cras_test_client --select_input 12:0 >/dev/null 2>&1 || true
    fi
    sleep 10
  done
' </dev/null >/dev/null 2>&1 &
