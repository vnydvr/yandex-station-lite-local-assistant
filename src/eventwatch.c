#include "raw_linux.h"

struct input_event_64 {
    s64 tv_sec;
    s64 tv_usec;
    u16 type;
    u16 code;
    s32 value;
};

static long parse_long_arg(const char *s, long fallback) {
    if (!s || !*s) return fallback;
    long v = 0, sign = 1; usize i = 0;
    if (s[0] == '-') { sign = -1; i = 1; }
    if (!s[i]) return fallback;
    for (; s[i]; ++i) { if (s[i] < '0' || s[i] > '9') return fallback; v = v * 10 + (s[i] - '0'); }
    return v * sign;
}

static void append_fixed(char *b, usize cap, usize *n, long value, int width) {
    char t[24]; int k = 0;
    do { t[k++] = (char)('0' + (value % 10)); value /= 10; } while (value > 0 && k < (int)sizeof(t));
    while (k < width) t[k++] = '0';
    while (k && *n + 1 < cap) b[(*n)++] = t[--k];
}

static void append_text(char *b, usize cap, usize *n, const char *s) {
    while (*s && *n + 1 < cap) b[(*n)++] = *s++;
}

static usize append_num(char *b, usize p, long v) {
    char t[24]; usize n = 0;
    if (v < 0) { b[p++] = '-'; v = -v; }
    do { t[n++] = (char)('0' + (v % 10)); v /= 10; } while (v && n < sizeof(t));
    while (n) b[p++] = t[--n];
    return p;
}

static void log_line(const char *level, const char *message, long err) {
    char b[256]; usize n = 0;
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
    append_text(b, sizeof(b), &n, "["); append_fixed(b, sizeof(b), &n, year, 4);
    append_text(b, sizeof(b), &n, "-"); append_fixed(b, sizeof(b), &n, month, 2);
    append_text(b, sizeof(b), &n, "-"); append_fixed(b, sizeof(b), &n, day, 2);
    append_text(b, sizeof(b), &n, "T"); append_fixed(b, sizeof(b), &n, hour, 2);
    append_text(b, sizeof(b), &n, ":"); append_fixed(b, sizeof(b), &n, minute, 2);
    append_text(b, sizeof(b), &n, ":"); append_fixed(b, sizeof(b), &n, second, 2);
    append_text(b, sizeof(b), &n, "."); append_fixed(b, sizeof(b), &n, ms, 3);
    append_text(b, sizeof(b), &n, "Z] [BUTTON] ["); append_text(b, sizeof(b), &n, level);
    append_text(b, sizeof(b), &n, "] "); append_text(b, sizeof(b), &n, message);
    if (err >= 0) {
        append_text(b, sizeof(b), &n, "; errno=");
        char t[24]; usize k = 0; do { t[k++] = (char)('0' + (err % 10)); err /= 10; } while (err && k < sizeof(t));
        while (k && n + 1 < sizeof(b)) b[n++] = t[--k];
    }
    if (n + 1 < sizeof(b)) b[n++] = '\n';
    (void)sys_write(2, b, n);
}

static void log_error(const char *what, long err) { log_line("ERROR", what, err); }

int app_main(int argc, char **argv, char **envp) {
    (void)envp;
    const char *device = argc > 1 ? argv[1] : "/dev/input/event2";
    long type_filter = argc > 2 ? parse_long_arg(argv[2], 1) : 1;
    long code_filter = argc > 3 ? parse_long_arg(argv[3], 103) : 103;
    isize fd = sys_openat(device, O_RDONLY, 0);
    if (fd < 0) { log_error("Cannot open input device", -fd); return 1; }
    log_line("INFO", "Input device opened; watching configured key only", -1);
    struct input_event_64 ev;
    u8 *dst = (u8 *)&ev;
    while (1) {
        usize have = 0;
        while (have < sizeof(ev)) {
            isize r = sys_read((int)fd, dst + have, sizeof(ev) - have);
            if (r == -EINTR) continue;
            if (r < 0) { log_error("Input read failed", -r); sys_close((int)fd); return 2; }
            if (r == 0) { log_error("Input device returned EOF", 0); sys_close((int)fd); return 3; }
            have += (usize)r;
        }
        if (ev.type != type_filter || ev.code != code_filter) continue;
        if (ev.value != 0 && ev.value != 1) continue;
        char line[96]; usize n = 0;
        const char *a = "type="; while (*a) line[n++] = *a++;
        n = append_num(line, n, ev.type);
        a = " code="; while (*a) line[n++] = *a++;
        n = append_num(line, n, ev.code);
        a = " value="; while (*a) line[n++] = *a++;
        n = append_num(line, n, ev.value); line[n++] = '\n';
        usize sent = 0; while (sent < n) { isize w = sys_write(1, line + sent, n - sent); if (w == -EINTR) continue; if (w <= 0) { sys_close((int)fd); return 4; } sent += (usize)w; }
    }
    sys_close((int)fd); return 0;
}
