#!/bin/bash
# Downloads the MPXJ .mpp reader that the Mac app bundles (the same reader the JavaScript app used), and optionally MPXJ's
# own test .mpp files for the smoke test. Every download is checked against a known checksum and the script stops if one differs.
#
#   Packaging/fetch-mpxj.sh <dir> [--samples]
#
# <dir>/package/bin/mpxj-convert   the reader (npm @byteink/mppjs-darwin-arm64, Apple silicon; LGPL-2.1-or-later)
# <dir>/package/LICENSE, NOTICE     its licence and notices (bundled with the app)
# <dir>/samples/*.mpp               with --samples: test files from MPXJ's repository (junit/data), at a fixed commit
set -euo pipefail
DIR="$1"; SAMPLES="${2:-}"
mkdir -p "$DIR"
cd "$DIR"

READER_VERSION=0.1.8
READER_URL="https://registry.npmjs.org/@byteink/mppjs-darwin-arm64/-/mppjs-darwin-arm64-${READER_VERSION}.tgz"
READER_SHA512="9GZ6aunFZMLU2m/t8PL974e8uWvMWEtll6jmChq2trZjOGNGuZ7Kk2yTG4rALbOwFkmU0XHrJI0a4TOwA+GfGQ=="   # npm "integrity"

curl -fsSL --retry 4 -o reader.tgz "$READER_URL"
GOT=$(openssl dgst -sha512 -binary reader.tgz | openssl base64 -A)
if [ "$GOT" != "$READER_SHA512" ]; then echo "reader checksum mismatch: $GOT"; exit 1; fi
rm -rf package && tar xzf reader.tgz
chmod 755 package/bin/mpxj-convert
echo "MPXJ reader ${READER_VERSION}: $(file package/bin/mpxj-convert | cut -d: -f2)"

if [ "$SAMPLES" = "--samples" ]; then
  COMMIT=27848ed312dfdac677adba3ba607b0a2e11597f3
  mkdir -p samples
  while read -r SHA PATHNAME; do
    OUT="samples/$(basename "$PATHNAME")"
    curl -fsSL --retry 4 -o "$OUT" "https://raw.githubusercontent.com/joniles/mpxj/${COMMIT}/${PATHNAME}"
    GOT=$(shasum -a 256 "$OUT" | cut -d' ' -f1)
    if [ "$GOT" != "$SHA" ]; then echo "sample checksum mismatch: $OUT"; exit 1; fi
  done <<'LIST'
a68a235a9dd6c30169f39c7154c1e9e249335e7968227dadfc0f779c7e4f29b8 junit/data/generated/calendar-recurring-exceptions/calendar-recurring-exceptions-project2016-mpp14.mpp
7be87e089502b7d7d9f11ee74016980319a45eedbc25c69b3ab06acba440ddf1 junit/data/generated/task-text/task-text-project2019-mpp14.mpp
9e8eb3f00269bdb183f4c58a3fa9e57061daa47f7f2c2ccfa3e9fc8e6e8f03cc junit/data/generated/task-numbers/task-numbers-project2019-mpp14.mpp
520c52e72973632063127ec2268847b3c2caedbf63a0ed06cfd5ef7987101cf4 junit/data/generated/task-flags/task-flags-project2019-mpp14.mpp
58c5f8dd40c012c354929d2604e94cc9ca3012feac1d8402fc49a06d5456e759 junit/data/generated/task-dates/task-dates-project2019-mpp14.mpp
801206e2b5976faf411e7b5de3bb829d105fddf79579417a793176b0055513a3 junit/data/generated/task-durations/task-durations-project2019-mpp14.mpp
aaef495dc99be1735de02940a6fb506573035e99de4acf0fa2ffe96344c8be4a junit/data/mpp14task.mpp
LIST
  echo "samples: $(ls samples | wc -l | tr -d ' ') files"
fi
