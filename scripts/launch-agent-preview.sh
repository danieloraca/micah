#!/bin/sh
# Print only. This script does not install or activate anything.
set -eu
cd "$(dirname "$0")/.."
python3 - "$PWD" <<'PY'
import plistlib, sys
from pathlib import Path
root = Path(sys.argv[1])
plistlib.dump({
    "Label": "local.dan.desktop-companion",
    "ProgramArguments": [str(root / "dist/Mica.app/Contents/MacOS/desktop-companion")],
    "RunAtLoad": True,
    "ProcessType": "Interactive",
}, sys.stdout.buffer)
PY
