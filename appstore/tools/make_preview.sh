#!/bin/bash
# Joins the walkthrough and the live-run clip into an app preview that meets Apple's spec:
# 886x1920, 30 fps, H.264 High at level 4.0, capped at 12 Mbps, stereo AAC, 15-30 s. Mostly static
# dark screens need less than Apple's 10-12 Mbps target, and MP4 can't pad up to it.
# Apple requires an audio track, so it carries silence. Previews must be screen captures of the
# app, so nothing here adds footage. usage: make_preview.sh MAIN.mp4 LIVE.mp4 OUT.mp4
set -euo pipefail
ffmpeg -y -v error -ss 1.5 -i "$1" -i "$2" -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
  -filter_complex "[0:v]fps=30,scale=886:-2,crop=886:1920:0:0,setsar=1[a];[1:v]fps=30,scale=886:-2,crop=886:1920:0:0,setsar=1[b];[a][b]concat=n=2:v=1:a=0[v]" \
  -map "[v]" -map 2:a -shortest -c:v libx264 -profile:v high -level:v 4.0 -pix_fmt yuv420p \
  -crf 6 -maxrate 12M -bufsize 12M -r 30 -c:a aac -b:a 256k -ar 48000 -ac 2 -movflags +faststart "$3"
