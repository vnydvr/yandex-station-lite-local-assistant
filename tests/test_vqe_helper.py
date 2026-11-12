#!/usr/bin/env python3
"""Host-only synthetic VQE datagram test. Not used on the speaker."""
import math
import os
import socket
import struct
import subprocess
import tempfile
import time
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "tests", "bin", "vqe-whistle-capture-host")

def send_packet(sock, path, freq, amp, sample_offset):
    samples = []
    for i in range(320):
        value = 0.0 if freq is None else amp * math.sin(2.0 * math.pi * freq * (sample_offset + i) / 16000.0)
        samples.append(max(-32768, min(32767, int(value))))
    sock.sendto(struct.pack("<320h", *samples), path)
    return sample_offset + 320

def main():
    if not os.path.isfile(BIN):
        raise SystemExit("Run ./build.sh host-test first")
    base = tempfile.mkdtemp(prefix="vqe-synthetic-")
    sock_path = os.path.join(base, "microphone.sock")
    wav_path = os.path.join(base, "utterance.wav")
    marker = os.path.join(base, "wake.marker")
    log = os.path.join(base, "manager.log")
    proc = subprocess.Popen([BIN, sock_path, wav_path, marker, log], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    for _ in range(200):
        if os.path.exists(sock_path):
            break
        if proc.poll() is not None:
            raise RuntimeError("helper exited before bind: " + proc.stderr.read())
        time.sleep(0.01)
    else:
        proc.terminate()
        raise RuntimeError("helper did not bind its Unix socket")

    sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    offset = 0
    # Quiet but clear 1500 Hz whistle: 40 x 20 ms frames.
    for _ in range(40):
        offset = send_packet(sender, sock_path, 1500, 2200, offset)
    # Let the whistle tail clear before speech onset.
    for _ in range(6):
        if not os.path.exists(sock_path):
            break
        offset = send_packet(sender, sock_path, None, 0, offset)
    # Speech-like 220 Hz signal, followed by enough silence for 1200 ms endpoint.
    for _ in range(30):
        if not os.path.exists(sock_path):
            break
        offset = send_packet(sender, sock_path, 220, 4000, offset)
    for _ in range(70):
        if not os.path.exists(sock_path):
            break
        try:
            offset = send_packet(sender, sock_path, None, 0, offset)
        except (FileNotFoundError, ConnectionRefusedError):
            break

    try:
        rc = proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.terminate()
        rc = proc.wait(timeout=2)
    stderr = proc.stderr.read()
    sender.close()
    assert rc == 0, f"expected exit 0, got {rc}; stderr={stderr}"
    assert open(marker, encoding="utf-8").read().strip() == "UTTERANCE_DONE"
    log_text = open(log, encoding="utf-8").read()
    for item in ("Whistle detected at 1500 Hz", "Whistle tail cleared", "Speech detected", "Utterance WAV complete"):
        assert item in log_text, f"missing log item: {item}\n{log_text}"
    with wave.open(wav_path, "rb") as wav:
        assert wav.getnchannels() == 1
        assert wav.getframerate() == 16000
        assert wav.getsampwidth() == 2
        duration = wav.getnframes() / wav.getframerate()
        assert 1.7 <= duration <= 2.2, f"unexpected WAV duration: {duration}"
    print("PASS: whistle detected; tail excluded; speech captured; 1200 ms silence endpoint; valid mono 16 kHz PCM WAV")
    print("PASS: VQE helper emitted timestamped stage logs")

if __name__ == "__main__":
    main()
