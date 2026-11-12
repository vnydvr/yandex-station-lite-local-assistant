#!/bin/sh
# Local offline assistant manager for Yandex Station Lite 1 / Micro v1.2.
# All transient data and logs are stored in tmpfs. No device-side compilation.

CONFIG=${LOCAL_ASSISTANT_CONFIG:-/data/local-assistant.conf}
if [ ! -r "$CONFIG" ]; then
    echo "[ERROR] Config not found: $CONFIG" >&2
    exit 2
fi
. "$CONFIG" || { echo "[ERROR] Cannot read config: $CONFIG" >&2; exit 2; }

umask 077
DATA_DIR=${DATA_DIR:-/data}
INSTALL_DIR=${INSTALL_DIR:-/data/local-assistant}
BIN_DIR=${BIN_DIR:-$INSTALL_DIR/bin}
TMP_DIR=${TMP_DIR:-/tmp/local-assistant}
CAPTURE_TMP=${CAPTURE_TMP:-/tmp/alisa-capture}
CAPTURE_SOCKET=${CAPTURE_SOCKET:-$CAPTURE_TMP/microphone.sock}
HOOK_TMP=${HOOK_TMP:-/tmp/vqe_tap.so}

EVENTWATCH_BIN=${EVENTWATCH_BIN:-$BIN_DIR/eventwatch}
INPUT_EVENT_TYPE=${INPUT_EVENT_TYPE:-1}
INPUT_EVENT_CODE=${INPUT_EVENT_CODE:-103}
INPUT_EVENT_DEVICE=${INPUT_EVENT_DEVICE:-/dev/input/event2}

QUASAR_ROOT=${QUASAR_ROOT:-/system/vendor/quasar}
QUASAR_CTL=${QUASAR_CTL:-$QUASAR_ROOT/q}
QUASAR_LAUNCHER=${QUASAR_LAUNCHER:-$QUASAR_ROOT/quasar_launcher2}
CAPTURE_PROFILE=${CAPTURE_PROFILE:-$DATA_DIR/alisa-capture/launch.capture.json}
CAPTURE_HOOK=${CAPTURE_HOOK:-$DATA_DIR/alisa-capture/vqe_tap.so}
CAPTURE_HELPER_BIN=${CAPTURE_HELPER_BIN:-$BIN_DIR/vqe-whistle-capture}

WHISTLE_MIN_FREQ=${WHISTLE_MIN_FREQ:-1400}
WHISTLE_MAX_FREQ=${WHISTLE_MAX_FREQ:-1550}
WHISTLE_FREQ_STEP=${WHISTLE_FREQ_STEP:-25}
WHISTLE_MIN_RMS=${WHISTLE_MIN_RMS:-250}
WHISTLE_MIN_RATIO=${WHISTLE_MIN_RATIO:-0.30}
WHISTLE_WINDOW_FRAMES=${WHISTLE_WINDOW_FRAMES:-40}
WHISTLE_REQUIRED_MATCHES=${WHISTLE_REQUIRED_MATCHES:-28}
WHISTLE_RELEASE_FRAMES=${WHISTLE_RELEASE_FRAMES:-5}
VAD_START_RMS=${VAD_START_RMS:-430}
VAD_END_RMS=${VAD_END_RMS:-300}
VAD_SILENCE_MS=${VAD_SILENCE_MS:-1200}
VAD_MAX_SPEECH_MS=${VAD_MAX_SPEECH_MS:-25000}
VAD_WAIT_VOICE_MS=${VAD_WAIT_VOICE_MS:-8000}
VAD_MIN_VOICE_MS=${VAD_MIN_VOICE_MS:-150}

SHERPA_BIN=${SHERPA_BIN:-$DATA_DIR/sherpa-ncnn}
SHERPA_MODEL=${SHERPA_MODEL:-$DATA_DIR/sherpa-model}
SHERPA_THREADS=${SHERPA_THREADS:-2}
FALCON_BIN=${FALCON_BIN:-$DATA_DIR/llama-completion}
FALCON_MODEL=${FALCON_MODEL:-$DATA_DIR/falcon-q4.gguf}
LLAMA_THREADS=${LLAMA_THREADS:-2}
MAX_TOKENS=${MAX_TOKENS:-150}
LLAMA_TEMPERATURE=${LLAMA_TEMPERATURE:-0.1}
SYSTEM_PROMPT=${SYSTEM_PROMPT:-"You are a concise local voice assistant. Answer briefly and directly in English. Prefer one to three short sentences. Do not repeat the question or ramble. Explain details only when asked or essential."}
ESPEAK_BIN=${ESPEAK_BIN:-$DATA_DIR/espeak-ng}
ESPEAK_DATA_DIR=${ESPEAK_DATA_DIR:-$DATA_DIR/espeak-ng-data}
ESPEAK_VOICE=${ESPEAK_VOICE:-en-us}
APLAY_BIN=${APLAY_BIN:-aplay}
APLAY_DEVICE=${APLAY_DEVICE:-default}
LED_SCRIPT=${LED_SCRIPT:-$INSTALL_DIR/led.sh}

BOOT_MODE=${BOOT_MODE:-alice}
BOOT_MUTED_NEXT=${BOOT_MUTED_NEXT:-local}
QUASAR_WAIT_SECONDS=${QUASAR_WAIT_SECONDS:-25}
LOG_LEVEL=${LOG_LEVEL:-DEBUG}
LOG_CONSOLE=${LOCAL_ASSISTANT_LOG_CONSOLE:-${LOG_CONSOLE:-0}}
LOG_MAX_BYTES=${LOG_MAX_BYTES:-1048576}

mkdir -p "$TMP_DIR" "$CAPTURE_TMP" || { echo "Cannot create temporary directories" >&2; exit 2; }
LOG_FILE=$TMP_DIR/manager.log
PID_FILE=$TMP_DIR/manager.pid
STATE_FILE=$TMP_DIR/state
EVENT_FIFO=$TMP_DIR/eventwatch.fifo
SESSION_PID_FILE=$TMP_DIR/session.pid
SESSION_READY_FILE=$TMP_DIR/local.ready

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
SCRIPT=$SCRIPT_DIR/$(basename -- "$0")
[ -x "$LED_SCRIPT" ] || LED_SCRIPT="$SCRIPT_DIR/led.sh"

log_event() {
    lev=$1; comp=$2; shift 2
    case "$lev" in
        DEBUG) [ "$LOG_LEVEL" = DEBUG ] || return 0 ;;
    esac
    now=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    [ -n "$now" ] || now=unknown-time
    line="[$now] [$lev] [$comp] $*"
    printf '%s\n' "$line" >> "$LOG_FILE"
    if [ "$LOG_CONSOLE" = 1 ]; then printf '%s\n' "$line"; fi
}
log_info() { log_event INFO MAIN "$*"; }
log_warn() { log_event WARN MAIN "$*"; }
log_error() { log_event ERROR MAIN "$*"; }
log_debug() { log_event DEBUG MAIN "$*"; }
log_component() { lev=$1; comp=$2; shift 2; log_event "$lev" "$comp" "$*"; }

rotate_log_if_needed() {
    [ -f "$LOG_FILE" ] || return 0
    size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) return 0;; esac
    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        tail -n 4000 "$LOG_FILE" > "$LOG_FILE.new" 2>/dev/null && mv "$LOG_FILE.new" "$LOG_FILE"
    fi
}

write_state() {
    printf '%s\n%s\n' "$STATE" "$NEXT_ON_UNMUTE" > "$STATE_FILE.new" || { log_error "Cannot write state file"; return 1; }
    mv "$STATE_FILE.new" "$STATE_FILE" || { log_error "Cannot atomically update state file"; return 1; }
}
quasar_up() { pidof quasar_launcher2 >/dev/null 2>&1; }
wait_quasar_down() {
    n=0
    while [ "$n" -lt "$QUASAR_WAIT_SECONDS" ]; do
        if ! quasar_up; then return 0; fi
        sleep 1; n=$((n + 1))
    done
    return 1
}
wait_quasar_up() {
    n=0
    while [ "$n" -lt "$QUASAR_WAIT_SECONDS" ]; do
        if quasar_up; then return 0; fi
        sleep 1; n=$((n + 1))
    done
    return 1
}
quasar_stop() {
    if ! quasar_up; then log_debug "Quasar launcher is already stopped"; return 0; fi
    log_info "Requesting stock Quasar stop via $QUASAR_CTL"
    "$QUASAR_CTL" stop >> "$LOG_FILE" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then log_warn "Quasar stop returned nonzero (exit=$rc); checking launcher state"; fi
    if wait_quasar_down; then log_info "Quasar launcher stopped"; return 0; fi
    log_error "Quasar launcher did not stop within ${QUASAR_WAIT_SECONDS}s"
    return 1
}
quasar_restart() {
    log_info "Requesting stock Quasar restart"
    unset ALSA_CONFIG_PATH
    "$QUASAR_CTL" restart >> "$LOG_FILE" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then log_error "Quasar restart command failed (exit=$rc)"; return "$rc"; fi
    if wait_quasar_up; then log_info "Stock Quasar launcher is running"; return 0; fi
    log_error "Stock Quasar launcher did not return within ${QUASAR_WAIT_SECONDS}s"
    return 1
}
force_stock_quasar() {
    log_warn "Recovery: stopping any capture-only Quasar profile and restoring stock Alice"
    "$QUASAR_CTL" stop >> "$LOG_FILE" 2>&1 || log_warn "Quasar stop returned nonzero during recovery"
    wait_quasar_down || log_warn "Quasar launcher remained up before stock restart"
    quasar_restart
}

check_path() {
    c_name=$1; c_path=$2; c_mode=$3
    case "$c_mode" in
        exec) [ -x "$c_path" ] ;;
        read) [ -r "$c_path" ] ;;
        dir) [ -d "$c_path" ] ;;
    esac
    rc=$?
    if [ "$rc" -eq 0 ]; then log_debug "Preflight OK: $c_name ($c_path)";
    else log_error "Preflight failed: $c_name ($c_path)"; fi
    return "$rc"
}
check_common() {
    log_info "Running preflight checks"
    bad=0
    check_path "AArch64 event watcher" "$EVENTWATCH_BIN" exec || bad=1
    check_path "input event device" "$INPUT_EVENT_DEVICE" read || bad=1
    check_path "Quasar control" "$QUASAR_CTL" exec || bad=1
    check_path "Quasar launcher" "$QUASAR_LAUNCHER" exec || bad=1
    check_path "capture profile" "$CAPTURE_PROFILE" read || bad=1
    check_path "VQE preload hook" "$CAPTURE_HOOK" read || bad=1
    check_path "AArch64 VQE whistle helper" "$CAPTURE_HELPER_BIN" exec || bad=1
    check_path "Sherpa executable" "$SHERPA_BIN" exec || bad=1
    check_path "Sherpa tokens" "$SHERPA_MODEL/tokens.txt" read || bad=1
    check_path "Sherpa encoder model" "$SHERPA_MODEL/encoder_jit_trace-pnnx.ncnn.int8.bin" read || bad=1
    check_path "Falcon runtime" "$FALCON_BIN" exec || bad=1
    check_path "Falcon model" "$FALCON_MODEL" read || bad=1
    check_path "eSpeak executable" "$ESPEAK_BIN" exec || bad=1
    check_path "eSpeak data" "$ESPEAK_DATA_DIR" dir || bad=1
    if ! command -v "$APLAY_BIN" >/dev/null 2>&1; then log_error "Preflight failed: aplay command not found ($APLAY_BIN)"; bad=1;
    else log_debug "Preflight OK: aplay ($(command -v "$APLAY_BIN"))"; fi
    if [ ! -w "$TMP_DIR" ] || [ ! -w "$CAPTURE_TMP" ]; then log_error "Preflight failed: tmpfs work directory is not writable"; bad=1; fi
    if [ ! -x "$LED_SCRIPT" ]; then log_warn "LED script unavailable; visual feedback disabled"; fi
    if [ "$bad" -eq 0 ]; then log_info "Preflight passed; all required files and paths are present"; return 0; fi
    log_error "Preflight failed; no mode switch was attempted"
    return 1
}

led_set() {
    led_state=$1
    if [ ! -x "$LED_SCRIPT" ]; then log_warn "LED command skipped: script not executable"; return 0; fi
    log_component INFO LED "State request: $led_state"
    LOCAL_ASSISTANT_TMP="$TMP_DIR" LOCAL_ASSISTANT_LOG_FILE="$LOG_FILE" LOCAL_ASSISTANT_LOG_CONSOLE="$LOG_CONSOLE" "$LED_SCRIPT" "$led_state" >/dev/null 2>&1
    led_rc=$?
    if [ "$led_rc" -ne 0 ]; then log_component WARN LED "State request failed: $led_state (exit=$led_rc)"; fi
    return 0
}

start_capture_profile() {
    log_component INFO AUDIO "Preparing VQE preload hook"
    cp "$CAPTURE_HOOK" "$HOOK_TMP" || { log_component ERROR AUDIO "Cannot copy VQE hook to $HOOK_TMP"; return 1; }
    chmod 755 "$HOOK_TMP" || { log_component ERROR AUDIO "Cannot chmod temporary VQE hook"; return 1; }
    log_component INFO QUASAR "Starting capture-only profile; maind --platformd and VQE tap must stay active"
    (
        cd "$DATA_DIR/quasar" || exit 1
        export CA_CERTIFICATES="$QUASAR_ROOT/ca-certificates.crt"
        export LD_LIBRARY_PATH="$QUASAR_ROOT/libs"
        ulimit -n 10240 2>/dev/null || :
        ulimit -s 1024 2>/dev/null || :
        nohup "$QUASAR_LAUNCHER" "$CAPTURE_PROFILE" > "$TMP_DIR/capture-launcher.log" 2>&1 </dev/null &
        echo $! > "$TMP_DIR/capture-launcher.pid"
    ) || { log_component ERROR QUASAR "Could not launch capture-only profile"; return 1; }
    n=0
    while [ "$n" -lt 30 ]; do
        for f in /proc/[0-9]*/maps; do
            if grep -q "$HOOK_TMP" "$f" 2>/dev/null; then
                log_component INFO AUDIO "VQE preload hook is mapped in $f"
                return 0
            fi
        done
        sleep 1; n=$((n + 1))
    done
    log_component ERROR AUDIO "VQE hook not observed in /proc/*/maps; inspect $TMP_DIR/capture-launcher.log"
    if [ -s "$TMP_DIR/capture-launcher.log" ]; then tail -n 12 "$TMP_DIR/capture-launcher.log" | while IFS= read -r l; do log_component ERROR QUASAR "$l"; done; fi
    return 1
}

run_sherpa() {
    sherpa_wav=$1; sherpa_output=$2
    sherpa_started=$(date +%s 2>/dev/null)
    log_component INFO ASR "Starting Sherpa-NCNN on completed WAV"
    "$SHERPA_BIN" \
        "$SHERPA_MODEL/tokens.txt" \
        "$SHERPA_MODEL/encoder_jit_trace-pnnx.ncnn.int8.param" \
        "$SHERPA_MODEL/encoder_jit_trace-pnnx.ncnn.int8.bin" \
        "$SHERPA_MODEL/decoder_jit_trace-pnnx.ncnn.param" \
        "$SHERPA_MODEL/decoder_jit_trace-pnnx.ncnn.bin" \
        "$SHERPA_MODEL/joiner_jit_trace-pnnx.ncnn.int8.param" \
        "$SHERPA_MODEL/joiner_jit_trace-pnnx.ncnn.int8.bin" \
        "$sherpa_wav" "$SHERPA_THREADS" greedy_search > "$sherpa_output" 2>&1
    sherpa_rc=$?
    sherpa_ended=$(date +%s 2>/dev/null)
    sherpa_elapsed=$((sherpa_ended - sherpa_started))
    if [ "$sherpa_rc" -eq 0 ]; then log_component INFO ASR "Sherpa finished successfully (${sherpa_elapsed}s)";
    else log_component ERROR ASR "Sherpa failed (exit=$sherpa_rc, ${sherpa_elapsed}s); last output follows"; tail -n 12 "$sherpa_output" 2>/dev/null | while IFS= read -r l; do log_component ERROR ASR "$l"; done; fi
    return "$sherpa_rc"
}
flat_text() {
    tr '\r\n' '  ' < "$1" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}
trim_history() {
    history_file=$1
    [ -f "$history_file" ] || : > "$history_file"
    tail -n 10 "$history_file" > "$history_file.new" 2>/dev/null || cp "$history_file" "$history_file.new"
    mv "$history_file.new" "$history_file"
}

start_whistle_helper() {
    rm -f "$TMP_DIR/wake.marker" "$TMP_DIR/utterance.wav" "$CAPTURE_SOCKET"
    log_component INFO WAKE "Starting AArch64 VQE whistle detector"
    WHISTLE_MIN_FREQ="$WHISTLE_MIN_FREQ" \
    WHISTLE_MAX_FREQ="$WHISTLE_MAX_FREQ" \
    WHISTLE_FREQ_STEP="$WHISTLE_FREQ_STEP" \
    WHISTLE_MIN_RMS="$WHISTLE_MIN_RMS" \
    WHISTLE_MIN_RATIO="$WHISTLE_MIN_RATIO" \
    WHISTLE_WINDOW_FRAMES="$WHISTLE_WINDOW_FRAMES" \
    WHISTLE_REQUIRED_MATCHES="$WHISTLE_REQUIRED_MATCHES" \
    WHISTLE_RELEASE_FRAMES="$WHISTLE_RELEASE_FRAMES" \
    VAD_START_RMS="$VAD_START_RMS" \
    VAD_END_RMS="$VAD_END_RMS" \
    VAD_SILENCE_MS="$VAD_SILENCE_MS" \
    VAD_MAX_SPEECH_MS="$VAD_MAX_SPEECH_MS" \
    VAD_WAIT_VOICE_MS="$VAD_WAIT_VOICE_MS" \
    VAD_MIN_VOICE_MS="$VAD_MIN_VOICE_MS" \
        "$CAPTURE_HELPER_BIN" "$CAPTURE_SOCKET" "$TMP_DIR/utterance.wav" "$TMP_DIR/wake.marker" "$LOG_FILE" &
    HELPER_PID=$!
    n=0
    while [ "$n" -lt 15 ]; do
        if [ -S "$CAPTURE_SOCKET" ]; then log_component INFO WAKE "Whistle detector ready (pid=$HELPER_PID; socket=$CAPTURE_SOCKET)"; return 0; fi
        if ! kill -0 "$HELPER_PID" 2>/dev/null; then
            wait "$HELPER_PID" 2>/dev/null; helper_start_rc=$?
            HELPER_PID=
            log_component ERROR WAKE "Whistle detector exited before socket bind (exit=$helper_start_rc)"
            return 1
        fi
        sleep 1; n=$((n + 1))
    done
    log_component ERROR WAKE "Whistle detector did not create its Unix socket within 15s"
    kill -TERM "$HELPER_PID" 2>/dev/null || :
    wait "$HELPER_PID" 2>/dev/null || :
    HELPER_PID=
    return 1
}

one_dialogue_turn() {
    wav=$TMP_DIR/utterance.wav
    sherpa_out=$TMP_DIR/sherpa.out
    question_file=$TMP_DIR/question.txt
    raw=$TMP_DIR/falcon.raw
    ferr=$TMP_DIR/falcon.err
    answer_file=$TMP_DIR/answer.txt
    answer_wav=$TMP_DIR/answer.wav
    history=$TMP_DIR/history.txt
    rm -f "$sherpa_out" "$question_file" "$raw" "$ferr" "$answer_file" "$answer_wav"

    led_set thinking
    if ! run_sherpa "$wav" "$sherpa_out"; then
        rm -f "$wav" "$sherpa_out"
        return 1
    fi
    transcript=$(sed -n 's/^text:[[:space:]]*//p' "$sherpa_out" | tail -n 1)
    printf '%s\n' "$transcript" > "$question_file"
    rm -f "$wav" "$sherpa_out"
    question=$(flat_text "$question_file")
    if [ -z "$question" ]; then
        log_component WARN ASR "Recognizer returned an empty transcript; skipping this turn"
        rm -f "$question_file"
        return 0
    fi
    log_component INFO ASR "Transcript received (${#question} characters)"
    log_component DEBUG ASR "Recognized text: $question"

    [ -f "$history" ] || : > "$history"
    history_context=$(cat "$history" 2>/dev/null)
    system_prompt=$SYSTEM_PROMPT
    if [ -n "$history_context" ]; then
        system_prompt="$SYSTEM_PROMPT
Recent conversation (oldest first; use only when relevant):
$history_context"
        log_component DEBUG LLM "Loaded conversation context ($(wc -l < "$history" | tr -d ' ') lines; maximum 5 Q/A pairs)"
    else
        log_component DEBUG LLM "No previous conversation context; starting with an empty history"
    fi

    led_set thinking
    log_component INFO LLM "Starting Falcon inference (threads=$LLAMA_THREADS, max_tokens=$MAX_TOKENS)"
    llm_started=$(date +%s 2>/dev/null)
    "$FALCON_BIN" \
        -m "$FALCON_MODEL" \
        -t "$LLAMA_THREADS" -n "$MAX_TOKENS" --temp "$LLAMA_TEMPERATURE" \
        --no-perf --log-verbosity 0 \
        -cnv -st --no-display-prompt \
        -sys "$system_prompt" \
        -p "$question" > "$raw" 2> "$ferr"
    llm_rc=$?
    llm_ended=$(date +%s 2>/dev/null)
    llm_elapsed=$((llm_ended - llm_started))
    if [ "$llm_rc" -ne 0 ]; then
        log_component ERROR LLM "Falcon failed (exit=$llm_rc, ${llm_elapsed}s); last stderr lines follow"
        tail -n 12 "$ferr" 2>/dev/null | while IFS= read -r l; do log_component ERROR LLM "$l"; done
        printf '%s\n' "Sorry, I couldn't process that request." > "$answer_file"
    else
        sed 's/\[end of text\]//g' "$raw" | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$answer_file"
        log_component INFO LLM "Falcon finished successfully (${llm_elapsed}s)"
    fi
    answer=$(flat_text "$answer_file")
    if [ -z "$answer" ]; then
        answer="Sorry, I don't have an answer for that."
        printf '%s\n' "$answer" > "$answer_file"
        log_component WARN LLM "Falcon produced an empty answer; using fallback text"
    fi
    log_component DEBUG LLM "Response text: $answer"

    printf 'User: %s\nAssistant: %s\n' "$question" "$answer" >> "$history"
    trim_history "$history"
    log_component DEBUG LLM "Conversation history updated (last 5 Q/A pairs retained)"
    rm -f "$question_file" "$raw" "$ferr"

    log_component INFO TTS "Starting eSpeak synthesis (voice=$ESPEAK_VOICE)"
    ESPEAK_DATA_PATH="$ESPEAK_DATA_DIR" "$ESPEAK_BIN" \
        -v "$ESPEAK_VOICE" -w "$answer_wav" -f "$answer_file" \
        >> "$TMP_DIR/espeak.log" 2>&1
    tts_rc=$?
    if [ "$tts_rc" -ne 0 ] || [ ! -s "$answer_wav" ]; then
        log_component ERROR TTS "eSpeak failed (exit=$tts_rc); inspect $TMP_DIR/espeak.log"
        if [ -s "$TMP_DIR/espeak.log" ]; then tail -n 12 "$TMP_DIR/espeak.log" | while IFS= read -r l; do log_component ERROR TTS "$l"; done; fi
        rm -f "$answer_file" "$answer_wav"
        return 1
    fi
    log_component INFO TTS "Speech WAV created ($(wc -c < "$answer_wav" | tr -d ' ') bytes)"
    led_set speaking
    log_component INFO AUDIO "Starting playback via ALSA device '$APLAY_DEVICE' (speaker Master volume is not changed)"
    "$APLAY_BIN" -D "$APLAY_DEVICE" -q "$answer_wav" >> "$TMP_DIR/aplay.log" 2>&1
    aplay_rc=$?
    if [ "$aplay_rc" -eq 0 ]; then log_component INFO AUDIO "Playback finished";
    else
        log_component ERROR AUDIO "Playback failed (exit=$aplay_rc); inspect $TMP_DIR/aplay.log"
        if [ -s "$TMP_DIR/aplay.log" ]; then tail -n 12 "$TMP_DIR/aplay.log" | while IFS= read -r l; do log_component ERROR AUDIO "$l"; done; fi
    fi
    rm -f "$answer_file" "$answer_wav"
    led_set idle
    return "$aplay_rc"
}

local_session() {
    HELPER_PID=
    CAPTURE_STARTED=0
    SESSION_CLEANED=0
    cleanup_session() {
        [ "$SESSION_CLEANED" = 1 ] && return
        SESSION_CLEANED=1
        log_component INFO SESSION "Cleaning up local assistant worker"
        if [ -n "$HELPER_PID" ]; then
            log_component INFO WAKE "Stopping VQE detector pid=$HELPER_PID"
            kill -TERM "$HELPER_PID" 2>/dev/null || :
            wait "$HELPER_PID" 2>/dev/null || :
            HELPER_PID=
        fi
        led_set restore
        if [ "$CAPTURE_STARTED" = 1 ]; then
            log_component INFO QUASAR "Stopping capture-only profile"
            "$QUASAR_CTL" stop >> "$LOG_FILE" 2>&1 || log_component WARN QUASAR "q stop returned nonzero during cleanup"
            wait_quasar_down || log_component WARN QUASAR "Capture-only Quasar did not stop within timeout"
        fi
        rm -f "$SESSION_READY_FILE" "$CAPTURE_SOCKET" "$HOOK_TMP" "$TMP_DIR/capture-launcher.pid"
        log_component INFO SESSION "Local assistant worker cleanup complete"
    }
    trap 'cleanup_session; exit 0' HUP INT TERM
    trap 'cleanup_session' EXIT

    log_component INFO SESSION "Local worker starting"
    [ -x "$CAPTURE_HELPER_BIN" ] || { log_component ERROR WAKE "Missing VQE helper binary: $CAPTURE_HELPER_BIN"; return 1; }
    led_set restore
    start_whistle_helper || return 1

    CAPTURE_STARTED=1
    if ! start_capture_profile; then return 1; fi
    touch "$SESSION_READY_FILE" || { log_component ERROR SESSION "Cannot create ready marker"; return 1; }
    log_component INFO SESSION "Local VQE capture is ready; waiting for whistle (${WHISTLE_MIN_FREQ}-${WHISTLE_MAX_FREQ} Hz)"

    while :; do
        shown_listening=0
        led_set idle
        while kill -0 "$HELPER_PID" 2>/dev/null; do
            if [ "$shown_listening" = 0 ] && grep -q '^WHISTLE_DETECTED$' "$TMP_DIR/wake.marker" 2>/dev/null; then
                led_set listening
                shown_listening=1
                log_component INFO WAKE "Wake event confirmed; waiting for speech endpoint"
            fi
            sleep 0.1
        done
        wait "$HELPER_PID"
        helper_rc=$?
        HELPER_PID=
        if [ "$helper_rc" -eq 0 ]; then
            log_component INFO AUDIO "Utterance WAV finalized; microphone reader stopped before ASR"
            one_dialogue_turn || log_component WARN SESSION "Dialogue turn failed; listener will be restarted"
        elif [ "$helper_rc" -eq 3 ]; then
            log_component INFO WAKE "Whistle detected but no utterance followed; rearming"
        elif [ "$helper_rc" -eq 130 ]; then
            log_component INFO SESSION "VQE helper was interrupted during shutdown"
            return 0
        else
            log_component ERROR WAKE "VQE helper exited unexpectedly (exit=$helper_rc)"
            return 1
        fi
        rm -f "$TMP_DIR/wake.marker" "$TMP_DIR/utterance.wav"
        start_whistle_helper || return 1
    done
}

start_local() {
    check_common || return 1
    rm -f "$SESSION_READY_FILE"
    quasar_stop || { log_error "Cannot enter local mode because stock Quasar did not stop"; return 1; }
    log_info "Launching local worker"
    if [ "$LOG_CONSOLE" = 1 ]; then
        "$SCRIPT" _session </dev/null &
    else
        nohup "$SCRIPT" _session >/dev/null 2>&1 </dev/null &
    fi
    SESSION_PID=$!
    echo "$SESSION_PID" > "$SESSION_PID_FILE"
    n=0
    while [ "$n" -lt 45 ]; do
        if [ -f "$SESSION_READY_FILE" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
            log_info "Local assistant mode is active (worker pid=$SESSION_PID)"
            return 0
        fi
        if ! kill -0 "$SESSION_PID" 2>/dev/null; then
            wait "$SESSION_PID" 2>/dev/null || :
            SESSION_PID=
            log_error "Local worker exited during startup; restoring stock Quasar"
            force_stock_quasar || :
            return 1
        fi
        sleep 1; n=$((n + 1))
    done
    log_error "Local worker startup timed out; stopping it and restoring stock Quasar"
    kill -TERM "$SESSION_PID" 2>/dev/null || :
    n=0
    while [ "$n" -lt 10 ] && kill -0 "$SESSION_PID" 2>/dev/null; do sleep 1; n=$((n + 1)); done
    kill -KILL "$SESSION_PID" 2>/dev/null || :
    wait "$SESSION_PID" 2>/dev/null || :
    SESSION_PID=
    force_stock_quasar || :
    return 1
}

stop_local() {
    if [ -n "${SESSION_PID:-}" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
        log_info "Stopping local worker pid=$SESSION_PID"
        kill -TERM "$SESSION_PID" 2>/dev/null || :
        n=0
        stop_timeout=$((QUASAR_WAIT_SECONDS + 5))
        while [ "$n" -lt "$stop_timeout" ] && kill -0 "$SESSION_PID" 2>/dev/null; do sleep 1; n=$((n + 1)); done
        if kill -0 "$SESSION_PID" 2>/dev/null; then
            log_warn "Local worker did not stop gracefully; sending SIGKILL"
            kill -KILL "$SESSION_PID" 2>/dev/null || :
        fi
        wait "$SESSION_PID" 2>/dev/null || :
    fi
    SESSION_PID=
    rm -f "$SESSION_PID_FILE" "$SESSION_READY_FILE"
    led_set restore
}

manager_cleanup() {
    log_info "Manager cleanup started"
    [ -n "${EVENT_PID:-}" ] && { kill "$EVENT_PID" 2>/dev/null || :; wait "$EVENT_PID" 2>/dev/null || :; }
    stop_local
    if [ "${STATE:-}" = local ] || [ "${STATE:-}" = muted ]; then force_stock_quasar || :; fi
    rm -f "$EVENT_FIFO" "$PID_FILE"
    log_info "Manager cleanup complete"
}

handle_event() {
    event_line=$1
    event_type=$(printf '%s\n' "$event_line" | sed -n 's/.*type=\([0-9][0-9]*\).*/\1/p')
    event_code=$(printf '%s\n' "$event_line" | sed -n 's/.*code=\([0-9][0-9]*\).*/\1/p')
    event_value=$(printf '%s\n' "$event_line" | sed -n 's/.*value=\(-*[0-9][0-9]*\).*/\1/p')
    [ "$event_type" = "$INPUT_EVENT_TYPE" ] || return 0
    [ "$event_code" = "$INPUT_EVENT_CODE" ] || return 0
    case "$event_value" in 0|1) ;; *) return 0;; esac
    log_component INFO BUTTON "Mute event: value=$event_value; current_state=$STATE; next_on_unmute=$NEXT_ON_UNMUTE"

    if [ "$event_value" = 1 ]; then
        case "$STATE" in
            alice)
                STATE=muted; NEXT_ON_UNMUTE=local; write_state
                log_component INFO MODE "ALICE -> MUTED; next unmute enters LOCAL ASSISTANT";;
            local)
                stop_local
                STATE=muted; NEXT_ON_UNMUTE=alice; write_state
                log_component INFO MODE "LOCAL ASSISTANT -> MUTED; next unmute returns to ALICE";;
            muted) log_component DEBUG MODE "Mute-on event ignored; already MUTED";;
        esac
        return 0
    fi

    if [ "$event_value" = 0 ] && [ "$STATE" = muted ]; then
        if [ "$NEXT_ON_UNMUTE" = local ]; then
            log_component INFO MODE "MUTED -> starting LOCAL ASSISTANT"
            if start_local; then
                STATE=local; NEXT_ON_UNMUTE=alice; write_state
                log_component INFO MODE "MUTED -> LOCAL ASSISTANT complete"
            else
                STATE=alice; NEXT_ON_UNMUTE=local; write_state
                log_component ERROR MODE "Local start failed; software state reset to ALICE"
            fi
        else
            log_component INFO MODE "MUTED -> restarting stock ALICE"
            if quasar_restart; then
                STATE=alice; NEXT_ON_UNMUTE=local; write_state
                log_component INFO MODE "MUTED -> ALICE complete"
            else log_component ERROR MODE "Stock Quasar restart failed; remaining MUTED"; fi
        fi
    fi
}

manager_run() {
    case "$BOOT_MODE" in alice|local|muted) ;; *) log_error "BOOT_MODE must be alice, local or muted"; return 2;; esac
    case "$BOOT_MUTED_NEXT" in alice|local) ;; *) log_error "BOOT_MUTED_NEXT must be alice or local"; return 2;; esac
    rotate_log_if_needed
    log_info "========== Local Assistant manager starting =========="
    log_info "Log level=$LOG_LEVEL; console=$LOG_CONSOLE; log=$LOG_FILE"
    check_common || return 1
    STATE=$BOOT_MODE
    NEXT_ON_UNMUTE=$BOOT_MUTED_NEXT
    EVENT_PID=
    SESSION_PID=
    trap 'manager_cleanup; exit 0' HUP INT TERM
    trap 'manager_cleanup' EXIT
    write_state || return 1
    log_component INFO MODE "Initial state=$STATE; next_on_unmute=$NEXT_ON_UNMUTE"

    if [ "$STATE" = local ]; then
        start_local || { STATE=alice; NEXT_ON_UNMUTE=local; write_state; log_component ERROR MODE "Could not start requested initial LOCAL mode; state set to ALICE"; }
    fi

    rm -f "$EVENT_FIFO"
    mkfifo "$EVENT_FIFO" || { log_error "Cannot create event FIFO"; return 1; }
    log_component INFO BUTTON "Starting event watcher ($INPUT_EVENT_DEVICE, type=$INPUT_EVENT_TYPE, code=$INPUT_EVENT_CODE)"
    "$EVENTWATCH_BIN" "$INPUT_EVENT_DEVICE" "$INPUT_EVENT_TYPE" "$INPUT_EVENT_CODE" > "$EVENT_FIFO" 2>> "$LOG_FILE" &
    EVENT_PID=$!
    exec 3< "$EVENT_FIFO"
    log_component INFO BUTTON "Event watcher started (pid=$EVENT_PID); waiting for physical Mute button"

    while :; do
        event_line=
        if IFS= read -r -t 1 event_line <&3; then
            [ -n "$event_line" ] && handle_event "$event_line"
        else
            if ! kill -0 "$EVENT_PID" 2>/dev/null; then
                log_component ERROR BUTTON "Event watcher stopped unexpectedly"
                break
            fi
            if [ "$STATE" = local ] && { [ -z "$SESSION_PID" ] || ! kill -0 "$SESSION_PID" 2>/dev/null; }; then
                log_component ERROR SESSION "Local worker died; restoring stock Alice"
                stop_local; force_stock_quasar || :
                STATE=alice; NEXT_ON_UNMUTE=local; write_state
            fi
        fi
    done
    return 1
}

case "${1:-}" in
    check)
        check_common
        ;;
    start)
        rotate_log_if_needed
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "Already running: $(cat "$PID_FILE")"; exit 0
        fi
        check_common || exit 1
        LOCAL_ASSISTANT_LOG_CONSOLE=0 nohup "$SCRIPT" run >/dev/null 2>&1 </dev/null &
        started_pid=$!
        echo "$started_pid" > "$PID_FILE"
        sleep 1
        if kill -0 "$started_pid" 2>/dev/null; then
            echo "Started local assistant manager pid=$started_pid"
            echo "Live log: adb shell tail -f $LOG_FILE"
            exit 0
        fi
        rm -f "$PID_FILE"
        echo "Manager exited during startup. Inspect: adb shell cat $LOG_FILE" >&2
        exit 1
        ;;
    foreground|console)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "Manager is already running. Use 'stop' first, then 'foreground'." >&2; exit 1
        fi
        LOG_CONSOLE=1
        LOCAL_ASSISTANT_LOG_CONSOLE=1
        export LOCAL_ASSISTANT_LOG_CONSOLE
        manager_run
        ;;
    stop)
        if [ -f "$PID_FILE" ]; then
            p=$(cat "$PID_FILE" 2>/dev/null)
            case "$p" in *[!0-9]*|'') log_error "Invalid manager PID file";; *) kill -TERM "$p" 2>/dev/null && echo "Stop requested for manager pid=$p" || echo "Manager process is not running";; esac
        else echo "Manager is not running"; fi
        ;;
    status)
        [ -f "$STATE_FILE" ] && { printf 'State: '; sed -n '1p' "$STATE_FILE"; printf 'Next unmute: '; sed -n '2p' "$STATE_FILE"; } || echo "No state file"
        [ -f "$PID_FILE" ] && echo "Manager PID: $(cat "$PID_FILE")"
        [ -f "$SESSION_PID_FILE" ] && echo "Local worker PID: $(cat "$SESSION_PID_FILE")"
        echo "Log: $LOG_FILE"
        echo "Event watcher: $EVENTWATCH_BIN"
        echo "VQE helper: $CAPTURE_HELPER_BIN"
        ;;
    logs|follow)
        [ -f "$LOG_FILE" ] || { echo "Log does not exist yet: $LOG_FILE"; exit 1; }
        tail -f "$LOG_FILE"
        ;;
    run)
        echo "$$" > "$PID_FILE"
        manager_run
        ;;
    _session)
        local_session
        ;;
    *)
        echo "Usage: $0 {check|start|stop|status|logs|foreground}" >&2
        exit 2
        ;;
esac
