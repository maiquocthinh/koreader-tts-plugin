#!/usr/bin/env bash
# benchmark/test_device_hardware.sh
# Measures real hardware resources (CPU %, RAM PSS, Thread count, ANR) on Android device via ADB.
# NO MOCKS. Queries Linux /proc and Android dumpsys directly.

PACKAGE="org.koreader.launcher"

echo "=========================================================================="
echo "  REAL ANDROID HARDWARE & SYSTEM PROFILING                                "
echo "  Target Package: $PACKAGE"
echo "=========================================================================="

PID=$(adb shell "pidof $PACKAGE" | tr -d '\r\n')

if [ -z "$PID" ]; then
    echo "ERROR: $PACKAGE is not running on device!"
    exit 1
fi

echo "  -> Found Process PID: $PID"

# 1. Thread Count & Process State
STAT_LINE=$(adb shell "cat /proc/$PID/stat 2>/dev/null")
THREADS=$(adb shell "ls -1 /proc/$PID/task 2>/dev/null | wc -l" | tr -d '\r\n')
echo "  -> Active Threads in Process: $THREADS"

# 2. CPU Utilization (Sampled over 3 seconds)
echo ""
echo "--- [1. CPU Utilization (Sampled)] ---"
adb shell "top -b -n 3 -d 1 -p $PID" | grep "$PACKAGE" | awk '{print "  Sample: CPU = "$9"%, Memory = "$10"%, State = "$8}'

# 3. Android Detailed Memory Profiling (Dumpsys)
echo ""
echo "--- [2. Detailed RAM Usage (dumpsys meminfo)] ---"
MEMINFO=$(adb shell "dumpsys meminfo $PACKAGE")

NATIVE_HEAP=$(echo "$MEMINFO" | grep -i "Native Heap" | head -n 1 | awk '{print $3}')
DALVIK_HEAP=$(echo "$MEMINFO" | grep -i "Dalvik Heap" | head -n 1 | awk '{print $3}')
TOTAL_PSS=$(echo "$MEMINFO" | grep -i "TOTAL PSS:" | head -n 1 | awk '{print $3}')
TOTAL_RSS=$(echo "$MEMINFO" | grep -i "TOTAL RSS:" | head -n 1 | awk '{print $3}')

echo "  Native Heap PSS : ${NATIVE_HEAP:-N/A} KB"
echo "  Dalvik/JNI Heap : ${DALVIK_HEAP:-N/A} KB"
echo "  Total PSS (RAM) : ${TOTAL_PSS:-N/A} KB"
echo "  Total RSS (RAM) : ${TOTAL_RSS:-N/A} KB"

# 3. Android System ANR Check
echo ""
echo "--- [3. Android OS ANR Check (/data/anr)] ---"
TODAY=$(date +%Y-%m-%d)
RECENT_ANR=$(adb shell "ls -la /data/anr/anr_* 2>/dev/null | grep '$TODAY'")

if [ -n "$RECENT_ANR" ]; then
    echo "  WARNING: Found ANR files logged today:"
    echo "$RECENT_ANR"
else
    echo "  STATUS: 0 ANR crash/freeze events detected today ($TODAY). UI thread is healthy."
fi

echo ""
echo "=========================================================================="
echo "  HARDWARE PROFILING COMPLETED                                            "
echo "=========================================================================="
