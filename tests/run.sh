#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT/build.sh" host-test
python3 "$ROOT/tests/test_vqe_helper.py"
python3 "$ROOT/tests/test_eventwatch.py"
