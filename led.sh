#!/bin/sh
# Yandex Station Lite 1 / Micro v1.2, sysfs LED controller.
# No writes to triggers or I2C; original brightness values are restored.

TMP_DIR=${LOCAL_ASSISTANT_TMP:-/tmp/local-assistant}
LOG_FILE=${LOCAL_ASSISTANT_LOG_FILE:-$TMP_DIR/manager.log}
LOG_CONSOLE=${LOCAL_ASSISTANT_LOG_CONSOLE:-0}
SAVE_FILE=$TMP_DIR/led.saved
PID_FILE=$TMP_DIR/led.pid
mkdir -p "$TMP_DIR" || exit 1

log_led() {
    led_now=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    led_line="[$led_now] [INFO] [LED] $*"
    printf '%s\n' "$led_line" >> "$LOG_FILE"
    [ "$LOG_CONSOLE" = 1 ] && printf '%s\n' "$led_line"
}

led_path() {
    color=$1; ring=$2
    printf '/sys/class/leds/micro:%s:ring%s/brightness' "$color" "$ring"
}

save_values() {
    [ -f "$SAVE_FILE" ] && return 0
    : > "$SAVE_FILE"
    found=0
    for ring in 1 2 3; do
        for color in red green blue; do
            p=$(led_path "$color" "$ring")
            if [ -r "$p" ]; then v=$(cat "$p" 2>/dev/null); found=$((found + 1)); else v=0; fi
            printf '%s\n' "${v:-0}" >> "$SAVE_FILE"
        done
    done
    if [ "$found" -eq 0 ]; then log_led "No writable LED brightness nodes found; animations may be unavailable"; fi
}

stop_anim() {
    if [ -f "$PID_FILE" ]; then
        p=$(cat "$PID_FILE" 2>/dev/null)
        case "$p" in *[!0-9]*|'') ;; *) kill "$p" 2>/dev/null || : ;; esac
        rm -f "$PID_FILE"
    fi
}

set_zone() {
    ring=$1; red=$2; green=$3; blue=$4
    for pair in "red:$red" "green:$green" "blue:$blue"; do
        c=${pair%%:*}; v=${pair#*:}
        p=$(led_path "$c" "$ring")
        [ -w "$p" ] && printf '%s\n' "$v" > "$p" 2>/dev/null || :
    done
}

frame() {
    set_zone 1 "$1" "$2" "$3"
    set_zone 2 "$4" "$5" "$6"
    set_zone 3 "$7" "$8" "$9"
}

animate() {
    state=$1
    case "$state" in
        idle)
            while :; do frame 0 0 10 0 0 10 0 0 10; sleep 1; done
            ;;
        listening)
            while :; do
                frame 0 35 70 0 8 16 0 8 16; sleep 0.22
                frame 0 8 16 0 35 70 0 8 16; sleep 0.22
                frame 0 8 16 0 8 16 0 35 70; sleep 0.22
            done
            ;;
        thinking)
            while :; do
                frame 65 0 100 18 0 28 18 0 28; sleep 0.24
                frame 18 0 28 65 0 100 18 0 28; sleep 0.24
                frame 18 0 28 18 0 28 65 0 100; sleep 0.24
            done
            ;;
        speaking)
            while :; do
                for b in 24 45 70 95 70 45; do frame 0 "$b" 0 0 "$b" 0 0 "$b" 0; sleep 0.12; done
            done
            ;;
        off)
            while :; do frame 0 0 0 0 0 0 0 0 0; sleep 1; done
            ;;
    esac
}

case "${1:-}" in
    idle|listening|thinking|speaking|off)
        log_led "State requested: $1"
        save_values
        stop_anim
        "$0" __animate "$1" >/dev/null 2>&1 &
        echo $! > "$PID_FILE"
        ;;
    __animate)
        animate "${2:-idle}"
        ;;
    restore)
        log_led "Restoring original LED brightness values"
        stop_anim
        if [ -f "$SAVE_FILE" ]; then
            i=1
            while IFS= read -r v; do
                ring=$(( (i - 1) / 3 + 1 )); slot=$(( (i - 1) % 3 ))
                case "$slot" in 0) c=red;; 1) c=green;; 2) c=blue;; esac
                p=$(led_path "$c" "$ring")
                [ -w "$p" ] && printf '%s\n' "$v" > "$p" 2>/dev/null || :
                i=$((i + 1))
            done < "$SAVE_FILE"
            rm -f "$SAVE_FILE"
        fi
        ;;
    *) echo "Usage: $0 {idle|listening|thinking|speaking|off|restore}" >&2; exit 2;;
esac
