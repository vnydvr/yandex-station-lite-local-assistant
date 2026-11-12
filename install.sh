#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ADB=${ADB:-adb}
command -v "$ADB" >/dev/null 2>&1 || { echo "adb not found" >&2; exit 1; }

"$ADB" wait-for-device
"$ADB" shell mkdir -p /data/local-assistant/bin
"$ADB" push "$ROOT/local-assistant.sh" /data/local-assistant/local-assistant.sh
"$ADB" push "$ROOT/led.sh" /data/local-assistant/led.sh
"$ADB" push "$ROOT/bin/eventwatch" /data/local-assistant/bin/eventwatch
"$ADB" push "$ROOT/bin/vqe-whistle-capture" /data/local-assistant/bin/vqe-whistle-capture
"$ADB" shell chmod 755 /data/local-assistant/local-assistant.sh /data/local-assistant/led.sh /data/local-assistant/bin/eventwatch /data/local-assistant/bin/vqe-whistle-capture

if "$ADB" shell '[ -e /data/local-assistant.conf ]'; then
    echo "Existing /data/local-assistant.conf found; left untouched. Compare it with local-assistant.conf.example manually."
else
    "$ADB" push "$ROOT/local-assistant.conf.example" /data/local-assistant.conf
    "$ADB" shell chmod 600 /data/local-assistant.conf
fi

echo "Installed integration files only. Existing models, /data/assistant.sh, /data/alisa-capture and Quasar data were not changed."
echo "Next: adb shell /data/local-assistant/local-assistant.sh check"
