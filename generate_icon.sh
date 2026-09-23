#!/bin/bash
# Build a real multi-resolution ICNS from the checked-in source artwork.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$PROJECT_DIR/Sources/ScreenshotTool/AppIconSource.png"
DEST="$PROJECT_DIR/Sources/ScreenshotTool/AppIcon.icns"
WORK_DIR="${TMPDIR:-/tmp}/ScreenshotTool-AppIcon"
ICONSET="$WORK_DIR.iconset"

rm -rf "$WORK_DIR" "$ICONSET"
mkdir -p "$ICONSET"

python3 - "$SOURCE" "$WORK_DIR-1024.png" <<'PY'
from PIL import Image
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
image = Image.open(source).convert("RGBA")
image.resize((1024, 1024), Image.Resampling.LANCZOS).save(output)
PY

MASTER="$WORK_DIR-1024.png"
sips -z 16 16 "$MASTER" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$MASTER" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$MASTER" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$MASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$MASTER" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$MASTER" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$MASTER" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

# Package PNG chunks directly. The Command Line Tools version of iconutil can
# reject valid iconsets when its SDK and compiler versions differ.
python3 - "$ICONSET" "$DEST" <<'PY'
from pathlib import Path
import struct
import sys

iconset, destination = map(Path, sys.argv[1:])
chunks = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]
body = b""
for kind, filename in chunks:
    data = (iconset / filename).read_bytes()
    body += kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data
destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY

echo "✅ Icon created: $DEST"
