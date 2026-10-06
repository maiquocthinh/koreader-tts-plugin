#!/usr/bin/env bash
# benchmark/run_benchmarks.sh - Run local device benchmarks (100% Offline)
set -e

echo "=========================================================================="
echo "  RUNNING KOReader TTS PLUGIN LOCAL DEVICE BENCHMARKS                     "
echo "  (100% Offline - Zero Network Dependency)                                "
echo "=========================================================================="

luajit benchmark/benchmark_local_device.lua
luajit benchmark/benchmark_network.lua
luajit benchmark/benchmark_stress_memory.lua

echo "=========================================================================="
echo "  ALL LOCAL BENCHMARKS COMPLETED SUCCESSFULLY!                            "
echo "=========================================================================="
