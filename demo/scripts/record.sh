#!/usr/bin/env bash
# Record the examples, so they can be replayed in the deck (or when the live
# demo cannot run).
#
#   record.sh 1        record just `make example-1`
#   record.sh all      record all four
#
# For each example it writes two files in demo/record/:
#   example-N.cast     the asciinema recording (the source; replay with
#                      `asciinema play demo/record/example-1.cast`)
#   example-N.gif      what the slides embed
#
# The recordings are real: the same command the talk runs, captured from a real
# run against the cluster. Re-record after changing anything the examples print.
#
# Geometry is fixed (120x20) so the four GIFs share one shape and the slide
# layout does not move; the speed-up is what keeps a 70-second build watchable.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REC_DIR="${DEMO_DIR}/record"
COLS="${REC_COLS:-120}"
ROWS="${REC_ROWS:-20}"
SPEED="${REC_SPEED:-5}"
THEME="${REC_THEME:-solarized-light}"
IDLE="${REC_IDLE:-1}"

command -v asciinema >/dev/null || { warn "asciinema not installed: brew install asciinema agg"; exit 1; }
command -v agg >/dev/null || { warn "agg not installed: brew install agg"; exit 1; }
mkdir -p "${REC_DIR}"

record_one() { # record_one <scenario>
  local scenario="$1" cast="${REC_DIR}/example-$1.cast" gif="${REC_DIR}/example-$1.gif"

  log "Recording example ${scenario} (${COLS}x${ROWS}) — this runs for real"
  # The first line imitates the shell prompt: the GIF has to say what was run,
  # or it is just colours scrolling by.
  asciinema rec --headless --quiet --overwrite \
    --window-size "${COLS}x${ROWS}" \
    --idle-time-limit "${IDLE}" \
    --command "printf '\033[1;36m\$ make example-$1\033[0m\n'; make example-$1" \
    "${cast}"

  log "Converting to GIF (${SPEED}x)"
  agg --quiet \
    --speed "${SPEED}" --idle-time-limit "${IDLE}" --last-frame-duration 4 \
    --font-size 14 --cols "${COLS}" --rows "${ROWS}" --theme "${THEME}" \
    "${cast}" "${gif}"

  # A PDF export prints a GIF's first frame, which is only the prompt line. Keep
  # the settled screen next to it, so a print export has something to show.
  if python3 -c 'import PIL' 2>/dev/null; then
    python3 -c 'import sys
from PIL import Image
im = Image.open(sys.argv[1])
im.seek(im.n_frames - 1)
im.convert("RGB").save(sys.argv[2])' "${gif}" "${REC_DIR}/example-$1.png"
  else
    warn "Pillow not installed: no static poster for example-$1"
  fi

  printf '  %-28s %s\n' "record/example-$1.cast" "$(du -h "${cast}" | cut -f1)"
  printf '  %-28s %s\n' "record/example-$1.gif" "$(du -h "${gif}" | cut -f1)"
}

case "${1:-all}" in
  all) for s in 1 1b 2 3; do record_one "${s}"; done ;;
  1|1b|2|3) record_one "$1" ;;
  *) warn "usage: record.sh <1|1b|2|3|all>"; exit 1 ;;
esac

ok "Recordings in demo/record/ — replay one with: asciinema play demo/record/example-1.cast"
