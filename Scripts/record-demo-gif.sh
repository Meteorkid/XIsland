#!/usr/bin/env bash
# Record the screen (or convert an existing .mov) into Assets/demo.gif for README.
#
# Prerequisites: ffmpeg (Homebrew), X Island running, optional: bash Scripts/demo-media.sh seed
#
# Usage:
#   bash Scripts/record-demo-gif.sh                    # record ~20s then write Assets/demo.gif
#   bash Scripts/record-demo-gif.sh --from-mov /path   # skip capture; only GIF encode
#
# If capture fails, list devices: ffmpeg -f avfoundation -list_devices true -i ""

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_GIF="$ROOT/Assets/demo.gif"
TMP_MOV="${TMP_MOV:-/tmp/ti_screen_record.mov}"

# AVFoundation: often "1:none" = main display; run -list_devices if this fails.
SCREEN_INPUT="${SCREEN_INPUT:-1:none}"
RECORD_SECONDS="${RECORD_SECONDS:-20}"
FRAMERATE="${FRAMERATE:-24}"
# Top-of-screen crop height (pixels in source video) before scaling to README width.
CROP_HEIGHT="${CROP_HEIGHT:-1500}"
GIF_FPS="${GIF_FPS:-12}"
GIF_WIDTH="${GIF_WIDTH:-560}"

FROM_MOV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-mov)
      FROM_MOV="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--from-mov /path/to/recording.mov]" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$FROM_MOV" ]]; then
  SRC="$FROM_MOV"
else
  SRC="$TMP_MOV"
  ffmpeg -y -f avfoundation -framerate "$FRAMERATE" -capture_cursor 1 -i "$SCREEN_INPUT" \
    -t "$RECORD_SECONDS" -pix_fmt yuv420p -c:v libx264 "$SRC"
fi

ffmpeg -y -i "$SRC" -vf "\
crop=iw:${CROP_HEIGHT}:0:0,fps=${GIF_FPS},scale=${GIF_WIDTH}:-1:flags=lanczos,\
split[s0][s1];[s0]palettegen=max_colors=256:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" \
  -loop 0 "$OUT_GIF"

echo "Wrote $OUT_GIF"
ls -lh "$OUT_GIF"
