#!/usr/bin/env bash
# benchmark/analyze_real_playback.sh
# Analyzes real Android logcat output to calculate physical audio playback gap between sentences.
# NO MOCKS. Uses real timestamps from Android MediaPlayer logs.

echo "=========================================================================="
echo "  REAL AUDIO PLAYBACK ZERO-GAP LATENCY ANALYSIS (LOGCAT)                  "
echo "=========================================================================="

LOGCAT_LINES=$(adb logcat -d | grep "AndroidPlayer: playing" | tail -n 10)

if [ -z "$LOGCAT_LINES" ]; then
    echo "No recent AndroidPlayer playback events found in logcat buffer."
    exit 0
fi

echo "Recent Playback Events from Real Device:"
echo "$LOGCAT_LINES"
echo ""
echo "--- Calculation of Real Inter-sentence Gaps ---"

python3 - << 'EOF'
import subprocess
import re
from datetime import datetime

cmd = "adb logcat -d"
out = subprocess.check_output(cmd, shell=True).decode('utf-8', errors='ignore')

pattern = re.compile(r'(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3}).*AndroidPlayer:\s+playing\s+(\S+).*duration_ms=\s*(\d+)')
matches = pattern.findall(out)

if not matches:
    print("No playback events matching pattern.")
    exit(0)

print(f"Found {len(matches)} real playback events on device.\n")

prev_end_time = None
gaps = []

for i, (ts_str, wav, dur_ms) in enumerate(matches):
    dur = float(dur_ms) / 1000.0
    # Parse timestamp e.g. 10-05 17:49:06.333
    t = datetime.strptime(ts_str, "%m-%d %H:%M:%S.%f")

    if prev_end_time is not None:
        gap = (t - prev_end_time).total_seconds() * 1000.0
        gaps.append(gap)
        print(f"  Sentence {i} -> {i+1}:")
        print(f"     Start: {ts_str} | File: {wav.split('/')[-1]}")
        print(f"     Transition Gap: {gap:.1f} ms (Target: < 100 ms) -> {'PASS' if gap < 100 else 'HIGH GAP'}")
    else:
        print(f"  Sentence 1:")
        print(f"     Start: {ts_str} | File: {wav.split('/')[-1]}")

    from datetime import timedelta
    prev_end_time = t + timedelta(milliseconds=float(dur_ms))

if gaps:
    avg_gap = sum(gaps) / len(gaps)
    print(f"\n==========================================================================")
    print(f"  AVERAGE REAL ZERO-GAP LATENCY: {avg_gap:.2f} ms across {len(gaps)} sentence transitions")
    print(f"  ZERO-GAP SLA (< 100 ms): {'PASS' if avg_gap < 100 else 'FAIL'}")
    print(f"==========================================================================")
EOF
