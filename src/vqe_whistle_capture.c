#include "raw_linux.h"

#define SAMPLE_RATE 16000
#define FRAME_SIZE 320
#define MAX_PACKET_SAMPLES 2048
#define MAX_BINS 32
#define PRE_ROLL_SAMPLES 4800
#define MAX_WINDOW 200
#define PATH_MAX_UNIX 108
#define PI 3.14159265358979323846

static volatile int stop_requested = 0;
static char **g_envp;
static int log_fd = -1;
static double window_fn[FRAME_SIZE];
static double goertzel_coeff[MAX_BINS];
static int bin_freq[MAX_BINS];
static int bin_count;

struct sockaddr_un_local { u16 family; char path[PATH_MAX_UNIX]; };
struct kernel_sigaction { void (*handler)(int); unsigned long flags; void (*restorer)(void); unsigned long mask; };

static void copy_bytes(void *dst, const void *src, usize n) {
    u8 *d = (u8 *)dst; const u8 *s = (const u8 *)src;
    for (usize i = 0; i < n; ++i) d[i] = s[i];
}
static void zero_bytes(void *dst, usize n) {
    u8 *d = (u8 *)dst; for (usize i = 0; i < n; ++i) d[i] = 0;
}
static usize str_len(const char *s) { usize n = 0; if (s) while (s[n]) ++n; return n; }
static const char *env_get(const char *name) {
    usize n = str_len(name);
    for (char **p = g_envp; p && *p; ++p) {
        usize i = 0; while (i < n && (*p)[i] == name[i]) ++i;
        if (i == n && (*p)[i] == '=') return *p + i + 1;
    }
    return 0;
}
static long parse_long(const char *s, long fallback) {
    if (!s || !*s) return fallback;
    long sign = 1, v = 0; usize i = 0;
    if (s[0] == '-') { sign = -1; i = 1; }
    if (!s[i]) return fallback;
    for (; s[i]; ++i) { if (s[i] < '0' || s[i] > '9') return fallback; v = v * 10 + (s[i] - '0'); }
    return v * sign;
}
static long parse_scaled(const char *s, long fallback) {
    if (!s || !*s) return fallback;
    long sign = 1, whole = 0, frac = 0, scale = 100, digits = 0; usize i = 0;
    if (s[0] == '-') { sign = -1; i = 1; }
    if (!s[i]) return fallback;
    while (s[i] >= '0' && s[i] <= '9') { whole = whole * 10 + (s[i] - '0'); ++i; }
    if (s[i] == '.') {
        ++i;
        while (s[i] >= '0' && s[i] <= '9' && digits < 3) { frac += (s[i] - '0') * scale; scale /= 10; ++digits; ++i; }
        while (s[i] >= '0' && s[i] <= '9') ++i;
    }
    if (s[i] != 0) return fallback;
    return sign * (whole * 1000 + frac);
}
static void append_char(char *b, usize cap, usize *n, char c) { if (*n + 1 < cap) b[(*n)++] = c; }
static void append_str(char *b, usize cap, usize *n, const char *s) { if (!s) return; while (*s) append_char(b, cap, n, *s++); }
static void append_uint(char *b, usize cap, usize *n, u64 v) {
    char t[24]; usize k = 0; do { t[k++] = (char)('0' + (v % 10)); v /= 10; } while (v && k < sizeof(t));
    while (k) append_char(b, cap, n, t[--k]);
}
static void append_int(char *b, usize cap, usize *n, s64 v) {
    if (v < 0) { append_char(b, cap, n, '-'); append_uint(b, cap, n, (u64)(-v)); }
    else append_uint(b, cap, n, (u64)v);
}
static void write_all(int fd, const char *p, usize n) {
    while (n) { isize r = sys_write(fd, p, n); if (r == -EINTR) continue; if (r <= 0) break; p += r; n -= (usize)r; }
}
static void append_fixed(char *b, usize cap, usize *n, long value, int width) {
    char t[24]; int k = 0;
    do { t[k++] = (char)('0' + (value % 10)); value /= 10; } while (value > 0 && k < (int)sizeof(t));
    while (k < width) t[k++] = '0';
    while (k) append_char(b, cap, n, t[--k]);
}
static void log_text(const char *level, const char *message) {
    char out[512]; usize n = 0;
    struct timespec64 ts; long sec = 0, ms = 0;
    long year = 1970, month = 1, day = 1, hour = 0, minute = 0, second = 0;
    if (sys_clock_gettime(CLOCK_REALTIME, &ts) == 0) {
        sec = ts.tv_sec; ms = ts.tv_nsec / 1000000;
        long days = sec / 86400; long rem = sec % 86400;
        if (rem < 0) { rem += 86400; --days; }
        long z = days + 719468;
        long era = (z >= 0 ? z : z - 146096) / 146097;
        unsigned doe = (unsigned)(z - era * 146097);
        unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        year = (long)yoe + era * 400;
        unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        unsigned mp = (5 * doy + 2) / 153;
        day = (long)(doy - (153 * mp + 2) / 5 + 1);
        month = (long)(mp + (mp < 10 ? 3 : -9));
        year += month <= 2;
        hour = rem / 3600; minute = (rem / 60) % 60; second = rem % 60;
    }
    append_char(out, sizeof(out), &n, '['); append_fixed(out, sizeof(out), &n, year, 4);
    append_char(out, sizeof(out), &n, '-'); append_fixed(out, sizeof(out), &n, month, 2);
    append_char(out, sizeof(out), &n, '-'); append_fixed(out, sizeof(out), &n, day, 2);
    append_char(out, sizeof(out), &n, 'T'); append_fixed(out, sizeof(out), &n, hour, 2);
    append_char(out, sizeof(out), &n, ':'); append_fixed(out, sizeof(out), &n, minute, 2);
    append_char(out, sizeof(out), &n, ':'); append_fixed(out, sizeof(out), &n, second, 2);
    append_char(out, sizeof(out), &n, '.'); append_fixed(out, sizeof(out), &n, ms, 3);
    append_str(out, sizeof(out), &n, "Z] [VQE] ["); append_str(out, sizeof(out), &n, level);
    append_str(out, sizeof(out), &n, "] "); append_str(out, sizeof(out), &n, message);
    append_char(out, sizeof(out), &n, '\n');
    write_all(2, out, n);
    if (log_fd >= 0) write_all(log_fd, out, n);
}
static void log_num(const char *level, const char *prefix, long value, const char *suffix) {
    char msg[256]; usize n = 0;
    append_str(msg, sizeof(msg), &n, prefix); append_int(msg, sizeof(msg), &n, value);
    append_str(msg, sizeof(msg), &n, suffix); msg[n] = 0; log_text(level, msg);
}
static void log_two_nums(const char *level, const char *prefix, long a, const char *middle, long b, const char *suffix) {
    char msg[256]; usize n = 0;
    append_str(msg, sizeof(msg), &n, prefix); append_int(msg, sizeof(msg), &n, a);
    append_str(msg, sizeof(msg), &n, middle); append_int(msg, sizeof(msg), &n, b);
    append_str(msg, sizeof(msg), &n, suffix); msg[n] = 0; log_text(level, msg);
}
static long monotonic_ms(void) {
    struct timespec64 ts; if (sys_clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (long)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}
static u64 isqrt_u64(u64 x) {
    u64 res = 0, bit = (u64)1 << 62;
    while (bit > x) bit >>= 2;
    while (bit) { if (x >= res + bit) { x -= res + bit; res = (res >> 1) + bit; } else res >>= 1; bit >>= 2; }
    return res;
}
static double cos_approx(double x) {
    const double two_pi = 6.28318530717958647692;
    while (x > PI) x -= two_pi;
    while (x < -PI) x += two_pi;
    double x2 = x * x;
    /* Taylor polynomial through x^14; the reduced interval is [-pi, pi]. */
    return 1.0 + x2 * (-0.5 + x2 * (0.041666666666666664 + x2 * (-0.001388888888888889 +
           x2 * (0.0000248015873015873 + x2 * (-0.0000002755731922398589 +
           x2 * (0.00000000208767569878681 + x2 * (-0.0000000000114707455977297)))))));
}
static void stop_handler(int sig) { (void)sig; stop_requested = 1; }
#if defined(__aarch64__)
__attribute__((naked)) static void sigreturn_trampoline(void) { __asm__ volatile("mov x8, #139; svc #0"); }
#else
__attribute__((naked)) static void sigreturn_trampoline(void) { __asm__ volatile("mov $15, %rax; syscall"); }
#endif
static void install_signals(void) {
    struct kernel_sigaction sa; sa.handler = stop_handler; sa.flags = 0x04000000UL;
    sa.restorer = sigreturn_trampoline; sa.mask = 0;
    (void)sc4(SYS_RT_SIGACTION, 2, (long)&sa, 0, 8);
    (void)sc4(SYS_RT_SIGACTION, 15, (long)&sa, 0, 8);
    (void)sc4(SYS_RT_SIGACTION, 1, (long)&sa, 0, 8);
}
static void marker_write(const char *path, const char *value) {
    isize fd = sys_openat(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { log_num("WARN", "Cannot write marker; errno=", -fd, " "); return; }
    write_all((int)fd, value, str_len(value)); write_all((int)fd, "\n", 1); sys_close((int)fd);
}
static void put_le16(u8 *p, u16 v) { p[0] = (u8)v; p[1] = (u8)(v >> 8); }
static void put_le32(u8 *p, u32 v) { p[0] = (u8)v; p[1] = (u8)(v >> 8); p[2] = (u8)(v >> 16); p[3] = (u8)(v >> 24); }
static void wav_header(u8 h[44], u32 data_bytes) {
    copy_bytes(h, "RIFF", 4); put_le32(h + 4, 36U + data_bytes); copy_bytes(h + 8, "WAVEfmt ", 8);
    put_le32(h + 16, 16); put_le16(h + 20, 1); put_le16(h + 22, 1); put_le32(h + 24, SAMPLE_RATE);
    put_le32(h + 28, SAMPLE_RATE * 2); put_le16(h + 32, 2); put_le16(h + 34, 16);
    copy_bytes(h + 36, "data", 4); put_le32(h + 40, data_bytes);
}
static isize open_wav(const char *path) {
    isize fd = sys_openat(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return fd;
    u8 h[44]; wav_header(h, 0); if (sys_write((int)fd, h, 44) != 44) { sys_close((int)fd); return -5; }
    return fd;
}
static int finish_wav(int fd, u32 bytes) {
    u8 h[8]; put_le32(h, 36U + bytes); put_le32(h + 4, bytes);
    if (sys_lseek(fd, 4, 0) < 0 || sys_write(fd, h, 4) != 4) return -1;
    if (sys_lseek(fd, 40, 0) < 0 || sys_write(fd, h + 4, 4) != 4) return -1;
    return 0;
}
static void append_preroll(s16 *pre, usize *used, const s16 *src, usize n) {
    if (n >= PRE_ROLL_SAMPLES) { copy_bytes(pre, src + n - PRE_ROLL_SAMPLES, PRE_ROLL_SAMPLES * 2); *used = PRE_ROLL_SAMPLES; return; }
    if (*used + n > PRE_ROLL_SAMPLES) {
        usize drop = *used + n - PRE_ROLL_SAMPLES;
        for (usize i = 0; i < *used - drop; ++i) pre[i] = pre[i + drop];
        *used -= drop;
    }
    copy_bytes(pre + *used, src, n * 2); *used += n;
}
static u64 rms_energy(const s16 *x, usize n) { u64 e = 0; for (usize i = 0; i < n; ++i) { s64 v = x[i]; e += (u64)(v * v); } return e; }
static long rms_value(const s16 *x, usize n) { if (!n) return 0; return (long)isqrt_u64(rms_energy(x, n) / n); }
static void init_detector(long min_freq, long max_freq, long step) {
    bin_count = 0;
    for (long f = min_freq; f <= max_freq && bin_count < MAX_BINS; f += step) {
        bin_freq[bin_count] = (int)f;
        goertzel_coeff[bin_count] = 2.0 * cos_approx(2.0 * PI * (double)f / SAMPLE_RATE);
        ++bin_count;
    }
    for (int i = 0; i < FRAME_SIZE; ++i) {
        double w = 0.5 - 0.5 * cos_approx(2.0 * PI * (double)i / (FRAME_SIZE - 1));
        window_fn[i] = w;
    }
}
static int whistle_frame_match(const s16 *frame, long min_rms, long min_ratio_milli,
                               long *best_freq, long *best_ratio_milli) {
    u64 e = rms_energy(frame, FRAME_SIZE);
    if (e < (u64)min_rms * (u64)min_rms * FRAME_SIZE) { *best_freq = 0; *best_ratio_milli = 0; return 0; }
    double windowed_energy = 0.0;
    double weighted[FRAME_SIZE];
    for (int i = 0; i < FRAME_SIZE; ++i) { weighted[i] = (double)frame[i] * window_fn[i]; windowed_energy += weighted[i] * weighted[i]; }
    if (windowed_energy < 1.0) { *best_freq = 0; *best_ratio_milli = 0; return 0; }
    double best_ratio = 0.0; int best = 0;
    for (int b = 0; b < bin_count; ++b) {
        double s1 = 0.0, s2 = 0.0, coeff = goertzel_coeff[b];
        for (int i = 0; i < FRAME_SIZE; ++i) { double s0 = weighted[i] + coeff * s1 - s2; s2 = s1; s1 = s0; }
        double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
        double ratio = (power * 2.0) / ((double)FRAME_SIZE * windowed_energy);
        if (ratio > best_ratio) { best_ratio = ratio; best = b; }
    }
    *best_freq = bin_freq[best]; *best_ratio_milli = (long)(best_ratio * 1000.0);
    return *best_ratio_milli >= min_ratio_milli;
}
static int write_samples(int fd, const s16 *samples, usize n) {
    s16 boosted[256];
    while (n) {
        usize count = n > 256 ? 256 : n;
        for (usize i = 0; i < count; ++i) {
            int v = (int)samples[i] * 16;
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            boosted[i] = (s16)v;
        }
        usize bytes = count * 2;
        const u8 *p = (const u8 *)boosted;
        while (bytes) {
            isize r = sys_write(fd, p, bytes);
            if (r == -EINTR) continue;
            if (r <= 0) return -1;
            p += r;
            bytes -= (usize)r;
        }
        samples += count;
        n -= count;
    }
    return 0;
}
static void cleanup_socket(int sock, const char *sock_path) { if (sock >= 0) sys_close(sock); if (sock_path) (void)sys_unlink(sock_path); }

int app_main(int argc, char **argv, char **envp) {
    g_envp = envp;
    if (argc != 4 && argc != 5) { log_text("ERROR", "Usage: vqe-whistle-capture SOCKET_PATH OUTPUT_WAV MARKER_PATH [LOG_FILE]"); return 2; }
    const char *sock_path = argv[1], *wav_path = argv[2], *marker_path = argv[3];
    if (str_len(sock_path) >= PATH_MAX_UNIX) { log_text("ERROR", "Unix socket path is too long"); return 2; }
    if (argc == 5 && argv[4][0]) {
        isize fd = sys_openat(argv[4], O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd >= 0) log_fd = (int)fd;
    }
    long min_freq = parse_long(env_get("WHISTLE_MIN_FREQ"), 1400);
    long max_freq = parse_long(env_get("WHISTLE_MAX_FREQ"), 1550);
    long freq_step = parse_long(env_get("WHISTLE_FREQ_STEP"), 25);
    long min_rms = parse_long(env_get("WHISTLE_MIN_RMS"), 250);
    long min_ratio = parse_scaled(env_get("WHISTLE_MIN_RATIO"), 300);
    long window_frames = parse_long(env_get("WHISTLE_WINDOW_FRAMES"), 40);
    long required_matches = parse_long(env_get("WHISTLE_REQUIRED_MATCHES"), 28);
    long release_frames = parse_long(env_get("WHISTLE_RELEASE_FRAMES"), 5);
    long vad_start = parse_long(env_get("VAD_START_RMS"), 430);
    long vad_end = parse_long(env_get("VAD_END_RMS"), 300);
    long silence_ms = parse_long(env_get("VAD_SILENCE_MS"), 1200);
    long max_speech_ms = parse_long(env_get("VAD_MAX_SPEECH_MS"), 25000);
    long wait_voice_ms = parse_long(env_get("VAD_WAIT_VOICE_MS"), 8000);
    long min_voice_ms = parse_long(env_get("VAD_MIN_VOICE_MS"), 150);
    if (min_freq < 100 || max_freq <= min_freq || freq_step <= 0 || (max_freq - min_freq) / freq_step + 1 > MAX_BINS ||
        min_rms < 0 || min_ratio <= 0 || min_ratio > 1000 || window_frames < 1 || window_frames > MAX_WINDOW ||
        required_matches < 1 || required_matches > window_frames || release_frames < 1 || release_frames > 30 ||
        vad_start <= 0 || vad_end < 0 || silence_ms < 200 || max_speech_ms < 1000 || wait_voice_ms < 1000 || min_voice_ms < 50) {
        log_text("ERROR", "Invalid detector/VAD configuration; check local-assistant.conf"); return 2;
    }
    init_detector(min_freq, max_freq, freq_step);
    char msg[256]; usize mn = 0;
    append_str(msg, sizeof(msg), &mn, "Starting; whistle band "); append_int(msg, sizeof(msg), &mn, min_freq);
    append_str(msg, sizeof(msg), &mn, "-"); append_int(msg, sizeof(msg), &mn, max_freq);
    append_str(msg, sizeof(msg), &mn, " Hz, step "); append_int(msg, sizeof(msg), &mn, freq_step);
    append_str(msg, sizeof(msg), &mn, " Hz, window "); append_int(msg, sizeof(msg), &mn, required_matches);
    append_char(msg, sizeof(msg), &mn, '/'); append_int(msg, sizeof(msg), &mn, window_frames); append_str(msg, sizeof(msg), &mn, " frames"); msg[mn] = 0;
    log_text("INFO", msg);

    isize sock = sc3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
    if (is_error(sock)) { log_num("ERROR", "socket() failed; errno=", -sock, ""); return 4; }
    int rcvbuf = 1024 * 1024;
    (void)sc5(SYS_SETSOCKOPT, sock, SOL_SOCKET, SO_RCVBUF, (long)&rcvbuf, sizeof(rcvbuf));
    struct timeval64 timeout; timeout.tv_sec = 0; timeout.tv_usec = 200000;
    (void)sc5(SYS_SETSOCKOPT, sock, SOL_SOCKET, SO_RCVTIMEO, (long)&timeout, sizeof(timeout));
    struct sockaddr_un_local addr; zero_bytes(&addr, sizeof(addr)); addr.family = AF_UNIX;
    copy_bytes(addr.path, sock_path, str_len(sock_path) + 1);
    (void)sys_unlink(sock_path);
    isize br = sc3(SYS_BIND, sock, (long)&addr, 2 + str_len(sock_path) + 1);
    if (is_error(br)) { log_num("ERROR", "bind() failed; errno=", -br, ""); sys_close((int)sock); return 4; }
    (void)sys_chmod(sock_path, 0660);
    marker_write(marker_path, "SOCKET_READY"); log_text("INFO", "VQE datagram socket bound; waiting for microphone packets");
    install_signals();

    s16 packet[MAX_PACKET_SAMPLES], frame[FRAME_SIZE], pre_roll[PRE_ROLL_SAMPLES];
    u8 history[MAX_WINDOW]; zero_bytes(history, sizeof(history));
    usize frame_used = 0, pre_used = 0; long history_pos = 0, matches = 0;
    int whistle_detected = 0, voice_active = 0, tone_cleared = 0;
    long non_tone_frames = 0, voice_wait_start = 0;
    isize wav_fd = -1; u32 wav_data_bytes = 0;
    usize silence_samples = 0, voiced_samples = 0, utterance_samples = 0;
    u8 raw[MAX_PACKET_SAMPLES * 2];
    long stream_started_ms = monotonic_ms();
    int first_packet_seen = 0, no_stream_warning = 0;

    while (!stop_requested) {
        isize got = sc6(SYS_RECVFROM, sock, (long)raw, sizeof(raw), 0, 0, 0);
        if (is_error(got)) {
            long err = -got;
            if (err == EINTR) continue;
            if (err == EAGAIN || err == EWOULDBLOCK) {
                if (!first_packet_seen && !no_stream_warning && monotonic_ms() - stream_started_ms >= 3000) {
                    log_text("WARN", "No VQE audio datagrams received 3 seconds after socket bind; check capture profile and VQE tap");
                    no_stream_warning = 1;
                }
                if (whistle_detected && !voice_active && wait_voice_ms > 0 && monotonic_ms() - voice_wait_start >= wait_voice_ms) {
                    log_num("WARN", "No speech after whistle; timeout ms=", wait_voice_ms, ""); break;
                }
                continue;
            }
            log_num("ERROR", "recvfrom() failed; errno=", err, ""); goto fail;
        }
        if (got < 2) continue;
        usize n = (usize)got / 2; if (n > MAX_PACKET_SAMPLES) n = MAX_PACKET_SAMPLES;
        if (!first_packet_seen) {
            log_two_nums("INFO", "VQE stream active; first datagram bytes=", (long)got, ", samples=", (long)n, "");
            first_packet_seen = 1;
        }
        for (usize i = 0; i < n; ++i) { u16 v = (u16)raw[i * 2] | ((u16)raw[i * 2 + 1] << 8); packet[i] = (s16)v; }

        if (!whistle_detected) {
            for (usize i = 0; i < n; ++i) {
                frame[frame_used++] = packet[i];
                if (frame_used == FRAME_SIZE) {
                    long best_freq = 0, best_ratio = 0;
                    int match = whistle_frame_match(frame, min_rms, min_ratio, &best_freq, &best_ratio);
                    matches -= history[history_pos]; history[history_pos] = (u8)match; matches += history[history_pos];
                    history_pos = (history_pos + 1) % window_frames; frame_used = 0;
                    if (matches >= required_matches) {
                        whistle_detected = 1; voice_wait_start = monotonic_ms(); pre_used = 0;
                        marker_write(marker_path, "WHISTLE_DETECTED");
                        char m[192]; usize z = 0; append_str(m, sizeof(m), &z, "Whistle detected at "); append_int(m, sizeof(m), &z, best_freq);
                        append_str(m, sizeof(m), &z, " Hz; Goertzel score "); append_int(m, sizeof(m), &z, best_ratio);
                        append_str(m, sizeof(m), &z, "/1000; window matches "); append_int(m, sizeof(m), &z, matches);
                        append_char(m, sizeof(m), &z, '/'); append_int(m, sizeof(m), &z, window_frames); m[z] = 0; log_text("INFO", m); break;
                    }
                }
            }
            continue;
        }

        long rms = rms_value(packet, n);
        if (!voice_active) {
            append_preroll(pre_roll, &pre_used, packet, n);
            if (!tone_cleared) {
                for (usize i = 0; i < n; ++i) {
                    frame[frame_used++] = packet[i];
                    if (frame_used == FRAME_SIZE) {
                        long post_freq = 0, post_ratio = 0;
                        int still_whistling = whistle_frame_match(frame, min_rms, min_ratio, &post_freq, &post_ratio);
                        frame_used = 0;
                        if (still_whistling) { non_tone_frames = 0; pre_used = 0; }
                        else { ++non_tone_frames; if (non_tone_frames >= release_frames) { tone_cleared = 1; log_text("INFO", "Whistle tail cleared; waiting for speech onset"); } }
                    }
                }
                if (!tone_cleared) {
                    if (monotonic_ms() - voice_wait_start >= wait_voice_ms) { log_num("WARN", "Whistle did not clear before timeout ms=", wait_voice_ms, ""); break; }
                    continue;
                }
            }
            if (rms >= vad_start) {
                wav_fd = open_wav(wav_path);
                if (wav_fd < 0) { log_num("ERROR", "Cannot create utterance WAV; errno=", -wav_fd, ""); goto fail; }
                if (pre_used && write_samples((int)wav_fd, pre_roll, pre_used) != 0) { log_text("ERROR", "Failed writing speech pre-roll to WAV"); goto fail; }
                wav_data_bytes = (u32)(pre_used * 2); utterance_samples = pre_used; voiced_samples = n; silence_samples = 0; voice_active = 1;
                log_num("INFO", "Speech detected; RMS=", rms, "; recording started");
            } else if (monotonic_ms() - voice_wait_start >= wait_voice_ms) {
                log_num("WARN", "No speech after whistle; timeout ms=", wait_voice_ms, ""); break;
            }
        } else {
            if (write_samples((int)wav_fd, packet, n) != 0) { log_text("ERROR", "Failed writing audio payload to WAV"); goto fail; }
            wav_data_bytes += (u32)(n * 2); utterance_samples += n;
            if (rms >= vad_end) { silence_samples = 0; voiced_samples += n; } else silence_samples += n;
            if ((silence_samples * 1000 >= (usize)silence_ms * SAMPLE_RATE && voiced_samples * 1000 >= (usize)min_voice_ms * SAMPLE_RATE) ||
                utterance_samples * 1000 >= (usize)max_speech_ms * SAMPLE_RATE) break;
        }
    }

    if (stop_requested) {
        log_text("WARN", "Capture interrupted by manager signal");
        if (wav_fd >= 0) sys_close((int)wav_fd);
        (void)sys_unlink(wav_path); cleanup_socket((int)sock, sock_path); if (log_fd >= 0) sys_close(log_fd); return 130;
    }
    if (wav_fd >= 0) {
        if (finish_wav((int)wav_fd, wav_data_bytes) != 0) { log_text("ERROR", "Failed to finalize WAV header"); sys_close((int)wav_fd); wav_fd = -1; goto fail; }
        sys_close((int)wav_fd); wav_fd = -1;
        if (wav_data_bytes > 0) {
            log_two_nums("INFO", "Utterance WAV complete; data bytes=", wav_data_bytes, ", duration ms=", (long)(utterance_samples * 1000 / SAMPLE_RATE), "");
            marker_write(marker_path, "UTTERANCE_DONE"); cleanup_socket((int)sock, sock_path); if (log_fd >= 0) sys_close(log_fd); return 0;
        }
    }
    log_text("INFO", "No utterance captured; rearming whistle detector");
    cleanup_socket((int)sock, sock_path); if (log_fd >= 0) sys_close(log_fd); return 3;

fail:
    if (wav_fd >= 0) sys_close((int)wav_fd);
    (void)sys_unlink(wav_path); cleanup_socket((int)sock, sock_path);
    log_text("ERROR", "Capture helper exiting after failure");
    if (log_fd >= 0) sys_close(log_fd); return 5;
}
