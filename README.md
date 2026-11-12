# Local Whistle Assistant — Yandex Station Lite 1 / Micro v1.3

This is a revision of the local-assistant MVP. It adds structured, timestamped logging across the manager, button watcher, VQE whistle detector, ASR/LLM/TTS calls and LED state changes. It also removes the previous requirement to compile C programs on the speaker.

## What is included

| File | Purpose |
|---|---|
| `local-assistant.sh` | Mode manager, Quasar transitions, dialogue pipeline, unified log |
| `led.sh` | LED state animations and original brightness restoration |
| `local-assistant.conf.example` | Runtime configuration |
| `bin/eventwatch` | Static AArch64 button-event watcher |
| `bin/vqe-whistle-capture` | Static AArch64 VQE whistle/VAD/WAV helper |
| `src/*.c`, `src/*.h`, `src/*.S` | Complete source for the two native helpers |
| `build.sh` | Rebuilds the static AArch64 helpers on a Linux PC with Clang + LLD |
| `install.sh` | Copies only the integration scripts and new binaries to the speaker |
| `tests/` | Host-only synthetic VQE stream test |

The two new executables are **static AArch64 ELF binaries**. They have no dynamic interpreter and no unresolved external symbols. They do not need a C compiler, glibc, or another runtime library on the speaker. This architecture was chosen because the station already runs AArch64 static executables (`pcm_receiver` and `sherpa-ncnn`); the pre-existing `vqe_tap.so` remains the original ARMHF shared object loaded into the 32-bit `maind` process. No existing runtime binary or model is replaced.

## Runtime flow

1. `eventwatch` reads the configured `/dev/input/eventN` device and only forwards the configured Mute key events (default type `1`, code `113`). Other input events are ignored, so they do not flood the log or FIFO.
2. The manager applies the existing cycle: `ALICE -> MUTED -> LOCAL ASSISTANT -> MUTED -> ALICE`.
3. On entering Local mode, it stops the normal Quasar launcher, then starts the existing capture-only profile. That profile preserves `maind --platformd` and injects the existing `/data/alisa-capture/vqe_tap.so`; the manager does not kill `maind` or replace the profile.
4. The AArch64 VQE helper binds `/tmp/alisa-capture/microphone.sock` before the capture-only profile starts. It receives mono S16LE 16 kHz PCM datagrams.
5. Whistle Wake uses Goertzel over 1400–1550 Hz (25 Hz bins), with a 40-frame window and 28 required matches. Frames are 20 ms. It does not load a wake-word model or any additional library.
6. The helper waits for the whistle tail to clear, waits for speech onset, keeps 300 ms of preroll, records speech, and closes a mono 16 kHz/16-bit WAV on 1200 ms of silence or the configured maximum duration.
7. The microphone socket reader exits before Sherpa starts. Sherpa transcribes the completed WAV and exits; Falcon generates one response using the last five Q/A pairs; eSpeak creates a temporary speech WAV; `aplay` plays it. The helper binds again only after processing/playback is finished.
8. All transient files — recordings, answer WAVs, text, history, PID/state files and logs — are stored in `/tmp`. Only the small scripts and two small executable helpers are persistent under `/data/local-assistant`.

Barge-in while the assistant is speaking is intentionally not implemented in this MVP.

## Debug logging

Every significant stage writes a line with time, severity and component, for example:

```text
[2026-11-10 20:12:01] [INFO] [MODE] MUTED -> starting LOCAL ASSISTANT
[2026-11-10 20:12:02] [INFO] [QUASAR] Starting capture-only profile
[2026-11-10T17:12:03.015Z] [VQE] [INFO] VQE datagram socket bound; waiting for microphone packets
[2026-11-10T17:12:09.221Z] [VQE] [INFO] Whistle detected at 1500 Hz; Goertzel score 664/1000
[2026-11-10 20:12:09] [INFO] [ASR] Starting Sherpa-NCNN on completed WAV
[2026-11-10 20:12:11] [INFO] [LLM] Starting Falcon inference
[2026-11-10 20:12:16] [INFO] [TTS] Starting eSpeak synthesis
[2026-11-10 20:12:17] [INFO] [AUDIO] Playback finished
```

The shell manager uses device-local time. The freestanding C helper uses UTC (`Z`). `DEBUG` includes recognised text and the generated response text; no individual audio frames, Goertzel iterations or model tokens are logged. The helper logs only state transitions and errors, so logging overhead remains small.

Logs are stored at `/tmp/local-assistant/manager.log`. If a previous log exceeds 1 MiB, it is trimmed to the most recent 4000 lines on the next manager start. The helper appends directly to this same file; it does not spawn a logging daemon.

### Follow logs from ADB

Background mode:

```sh
adb shell /data/local-assistant/local-assistant.sh start
adb shell tail -f /tmp/local-assistant/manager.log
```

Or use the built-in command:

```sh
adb shell /data/local-assistant/local-assistant.sh logs
```

To see the manager and child-worker messages directly in the ADB session, first stop the background manager, then run foreground mode:

```sh
adb shell /data/local-assistant/local-assistant.sh stop
adb shell /data/local-assistant/local-assistant.sh foreground
```

Press `Ctrl+C` to stop foreground mode. The manager's cleanup attempts to stop the capture-only profile and restore stock Quasar. Do not start foreground mode while the daemon is already running.

Use `LOG_LEVEL=INFO` in `/data/local-assistant.conf` to hide verbose debug lines. `DEBUG` is the default and logs ASR transcription and answer text locally in `/tmp`; the log is not uploaded anywhere.

## Speaker volume

`APLAY_DEVICE=default` is retained. The manager never runs `amixer set` and never changes the station's volume. The generated WAV is played through the existing ALSA default route. Perceived loudness may still differ from Alice because voice recordings can have different mastering, but the station's current output volume setting is not overwritten.

Read-only checks, if needed:

```sh
adb shell 'amixer get Master'
adb shell 'cat /etc/asound.conf'
```

## Install on the speaker

Unzip the archive on the Linux PC, `cd` into the `local-assistant-v2` folder and run:

```sh
./install.sh
```

The installer copies only:

- `/data/local-assistant/local-assistant.sh`
- `/data/local-assistant/led.sh`
- `/data/local-assistant/bin/eventwatch`
- `/data/local-assistant/bin/vqe-whistle-capture`
- `/data/local-assistant.conf` **only if it does not already exist**

It does **not** replace `/data/assistant.sh`, `/data/alisa-capture/*`, the models, `llama-completion`, Sherpa, eSpeak, Quasar configuration or any system file. If a configuration file already exists, the installer leaves it untouched.

The package adds roughly 26 KiB of AArch64 executables plus small scripts/configuration; it does not copy any model. All runtime logs and WAVs stay in tmpfs.

After installation, check the current physical speaker state in `/data/local-assistant.conf`:

- Use `BOOT_MODE=alice` only when stock Alice/Quasar is running and the physical mic is unmuted.
- Use `BOOT_MODE=muted` when the physical Mute state is active; set `BOOT_MUTED_NEXT` to match the next unmute target.
- Use `BOOT_MODE=local` only when starting directly in the capture-only local mode is intended.

Then run the non-destructive preflight:

```sh
adb shell /data/local-assistant/local-assistant.sh check
```

Only if preflight passes, start:

```sh
adb shell /data/local-assistant/local-assistant.sh start
adb shell /data/local-assistant/local-assistant.sh status
adb shell tail -n 100 /tmp/local-assistant/manager.log
```

Stop and restore the stock Quasar launcher:

```sh
adb shell /data/local-assistant/local-assistant.sh stop
```

## Build from source (optional; on the PC only)

The included binaries are already built. Rebuilding is not part of installation. The test command builds temporary x86-64 test executables under `tests/bin/`; they are only for the PC. On a Linux PC with Clang and LLD:

```sh
./build.sh
```

This emits static AArch64 binaries without depending on an AArch64 sysroot or device-side compiler. It does not use or need a libc at runtime. Host-only synthetic tests can be run with:

```sh
./tests/run.sh
```

Do not upload the host test binaries from `tests/bin/` to the speaker; they are x86-64.

## Repository scope and privacy

This repository contains the assistant integration code, native helper sources, and small prebuilt AArch64 helper binaries. It does **not** contain a full station dump, user/device configuration, Wi-Fi credentials, Yandex account data, Quasar databases or logs, private keys, model weights, Sherpa runtime, eSpeak data, or the proprietary VQE hook/profile. Those components must already exist on the target station or be obtained and installed separately under their respective terms.

Never commit `/data/local-assistant.conf`, Wi-Fi configuration, device logs, account databases, private keys, or full filesystem dumps. Start from `local-assistant.conf.example` and keep real device-specific values local.

## License

No open-source license is granted yet. Unless a license is added by the copyright holder, all rights remain reserved.

## Validation status

Validated in this build environment:

- Both target executables are AArch64 ELF files, static, with no `PT_INTERP` and no unresolved symbols.
- Both C sources compile with `-Wall -Wextra -Werror` for AArch64 and native x86-64.
- Host synthetic VQE test detects a 1500 Hz whistle, waits for its tail to clear, captures following speech, finalizes a valid mono 16 kHz/16-bit WAV on the silence endpoint, and logs each stage.
- Signal-stop test makes the VQE helper exit with status 130 and remove its socket.
- Host eventwatch test confirms filtering: only the configured type/code values are forwarded; startup and EOF diagnostics carry timestamps.
- `local-assistant.sh` and `led.sh` pass POSIX `sh -n` syntax checks.

Known limitations / environment-specific checks:

- Actual ability of the target kernel to execute the newly built AArch64 freestanding binaries (it is strongly indicated by the existing static AArch64 `pcm_receiver` and `sherpa-ncnn`, but still needs an on-device smoke test).
- Live VQE datagram timing and signal levels on the actual speaker.
- Actual `/dev/input/event2` device mapping and key events on this firmware state.
- Quasar start/stop recovery, live Sherpa/Falcon/eSpeak processing under the capture-only profile, and physical LED playback.

The `check` command verifies files and permissions only; it does not switch modes or start audio capture.


## Full runtime bundle

This release archive also includes the runtime payload under `runtime/`:
- Sherpa-NCNN executable and model files
- llama.cpp completion executable and Falcon GGUF model
- eSpeak NG executable and English voice data

The runtime payload is copied from the device data archive used during development.
It intentionally excludes the full device dump, Wi-Fi credentials, DHCP state,
Yandex account/device databases, logs, Bluetooth pairing data, and other private
or device-specific state. The stock Yandex `vqe_tap.so` is not redistributed.

Check the original licenses/notices of bundled third-party software and model
artifacts before redistributing this bundle. The repository's MIT license applies
only to the project's own original code, not to third-party components.
