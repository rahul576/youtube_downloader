#!/bin/bash
cd "$(dirname "$0")"
bash build.sh --install 2>&1 | tee build.log
echo "EXIT: ${PIPESTATUS[0]}" >> build.log
echo; echo "Finished. You can close this window."
