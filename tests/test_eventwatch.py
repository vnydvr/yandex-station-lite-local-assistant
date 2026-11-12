#!/usr/bin/env python3
"""Host-only eventwatch test using a regular file as synthetic input_event stream."""
import os
import struct
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "tests", "bin", "eventwatch-host")


def pack_event(sec, usec, event_type, code, value):
    # 64-bit Linux input_event ABI: timeval (2x s64), type/code (2x u16), value (s32)
    return struct.pack("<qqHHi", sec, usec, event_type, code, value)


def main():
    if not os.path.isfile(BIN):
        raise SystemExit("Run ./build.sh host-test first")

    with tempfile.TemporaryDirectory(prefix="eventwatch-test-") as tmp:
        path = os.path.join(tmp, "events.bin")
        with open(path, "wb") as stream:
            stream.write(pack_event(1, 0, 1, 103, 1))
            stream.write(pack_event(1, 1000, 1, 103, 0))
            stream.write(pack_event(1, 2000, 1, 102, 1))  # wrong key
            stream.write(pack_event(1, 3000, 4, 103, 1))  # wrong event type
            stream.write(pack_event(1, 4000, 1, 103, 2))  # repeat, not press/release

        proc = subprocess.run([BIN, path, "1", "103"], capture_output=True, text=True, check=False)
        assert proc.returncode == 3, f"expected EOF exit 3, got {proc.returncode}; stderr={proc.stderr}"
        lines = [line for line in proc.stdout.splitlines() if line]
        assert lines == ["type=1 code=103 value=1", "type=1 code=103 value=0"], lines
        assert "[BUTTON] [INFO]" in proc.stderr, proc.stderr
        assert "[BUTTON] [ERROR] Input device returned EOF; errno=0" in proc.stderr, proc.stderr

    print("PASS: eventwatch forwards only Mute press/release and timestamps diagnostics")


if __name__ == "__main__":
    main()
