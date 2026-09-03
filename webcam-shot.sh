#!/bin/bash
# Webcam photo for the screenshot widget, photobooth style.
# Usage: webcam-shot.sh [slurp|copy|save] [--no-preview]
#   Default flow: an mpv window shows the live feed so you can frame yourself;
#   SPACE / ENTER / left click takes the photo, Q / ESC cancels.
# Device override: WEBCAM_DEVICE=/dev/videoN

[[ -f ~/.config/user-dirs.dirs ]] && source ~/.config/user-dirs.dirs
OUTPUT_DIR="${OMARCHY_SCREENSHOT_DIR:-${XDG_PICTURES_DIR:-$HOME/Pictures}}"
mkdir -p "$OUTPUT_DIR"

PROCESSING="${1:-save}"
DEVICE="${WEBCAM_DEVICE:-/dev/video0}"
FILENAME="webcam-$(date +'%Y-%m-%d_%H-%M-%S').jpg"
FILEPATH="$OUTPUT_DIR/$FILENAME"

if [[ $2 != "--no-preview" ]]; then
  # Live viewfinder. mpv exits 0 on the shoot keys (quit 0) and 4 on the
  # cancel keys; anything but 0 aborts without touching the disk.
  mpv --really-quiet --profile=low-latency --untimed \
    --demuxer-lavf-o=video_size=1280x720 \
    --title="Webcam — SPACE: photo, Q: cancel" \
    --input-conf=<(printf '%s\n' "SPACE quit 0" "ENTER quit 0" "MBTN_LEFT quit 0" "q quit 4" "ESC quit 4") \
    "av://v4l2:$DEVICE"
  [[ $? -ne 0 ]] && exit 0
fi

# Read ~20 frames and keep only the last one (-update 1) so auto-exposure and
# white balance have settled; a cold camera's first frame is dark garbage.
# Retried briefly: right after the preview closes, mpv may not have released
# the device yet. 1080p first, then the camera's default size as fallback.
capture() {
  ffmpeg -hide_banner -loglevel error -f v4l2 -framerate 30 "$@" \
    -i "$DEVICE" -frames:v 20 -update 1 -y "$FILEPATH"
}
ok=""
for _ in 1 2 3; do
  if capture -video_size 1920x1080 2>/dev/null || capture; then
    ok=1
    break
  fi
  sleep 0.5
done
if [[ -z $ok ]]; then
  omarchy-notification-send "Webcam capture failed" "No usable camera on $DEVICE" || true
  exit 1
fi

case "$PROCESSING" in
copy)
  wl-copy --type image/jpeg <"$FILEPATH"
  rm -f "$FILEPATH"
  ;;
save) ;;
*)
  wl-copy --type image/jpeg <"$FILEPATH"
  omarchy-notification-send "Webcam photo saved and copied" "$FILENAME" --image "$FILEPATH" || true
  ;;
esac

echo "$FILEPATH"
