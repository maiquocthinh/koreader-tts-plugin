# KOReader TTS Plugin - Internal Benchmark Suite

This directory contains internal benchmarking and performance profiling tools designed to measure quantitative KPIs and SLA thresholds for the KOReader TTS plugin across various hardware environments.

---

## 1. Benchmark Tools Overview

| Script / Tool | Measurement Purpose | Target SLA Threshold |
|---|---|:---:|
| `compare_before_after.lua` | Quantitative empirical comparison between unoptimized baseline and post-fix architecture | 100% SLA PASS |
| `benchmark_local_device.lua` | 100% offline local device optimization measuring CPU throughput, chunking, bounding boxes, WAV parsing, seek latency, and GC heap churn | Zero network dependency |
| `benchmark_performance.lua` | End-to-end quantitative KPIs: TTFA (Cold/Hit), zero-gap latency, network concurrency, and timer polling load | TTFA $\le 2.5$s, Zero-Gap $< 100$ms, Concurrency $\le 1$ |
| `benchmark_network.lua` | Network layer benchmarks: in-memory DNS cache efficiency, JSON parsing throughput, request cancellation hygiene | DNS Cache hit $< 5$ms, 0 unhandled timeouts |
| `benchmark_stress_memory.lua` | 50-chunk continuous stress test measuring heap allocation delta and temporary cache bounds | RAM Delta $< 1024$ KB, bounded page cache |
| `test_real_network.sh` | Real physical network & AI synthesis measurement on Android device via ADB (DNS, TCP, TLS, TTFB) | Physical on-device measurements (No Mocks) |
| `test_device_hardware.sh` | Real Android hardware resource tracking via ADB: CPU utilization, RAM PSS memory footprint, and `/data/anr/` crash log detection | Physical on-device measurements (No Mocks) |
| `analyze_real_playback.sh` | Real audio playback zero-gap latency calculation directly parsed from Android MediaPlayer logcat timestamps | Zero-Gap $< 100$ms |

---

## 2. Running Benchmarks

### Run all offline local device benchmarks:
- **Linux / macOS / Git Bash:**
  ```bash
  bash benchmark/run_benchmarks.sh
  ```
- **Windows Command Prompt / PowerShell:**
  ```cmd
  benchmark\run_benchmarks.bat
  ```

### Run individual benchmark suites:
```bash
luajit benchmark/compare_before_after.lua
luajit benchmark/benchmark_local_device.lua
luajit benchmark/benchmark_performance.lua
luajit benchmark/benchmark_network.lua
luajit benchmark/benchmark_stress_memory.lua
```

### Run real on-device hardware & network profiling via ADB:
```bash
bash benchmark/test_real_network.sh
bash benchmark/test_device_hardware.sh
bash benchmark/analyze_real_playback.sh
```

---

## 3. Quantitative KPIs & SLA Definitions

- **TTFA (Time to First Audio)**: Elapsed duration from tapping Play until the first audio chunk starts playback through speakers.
- **Zero-Gap Transition Latency**: Physical interval between the end of sentence $N$ and the start of sentence $N+1$ (target: $< 100$ ms for seamless natural speech).
- **In-Flight Network Concurrency**: Number of simultaneous HTTP requests dispatched to the neural TTS endpoint (strictly $\le 1$ for single-GPU stability).
- **Timer Polling Frequency (Hz)**: Number of Lua VM event-loop wakeups scheduled per second (adaptive $\le 15$ Hz to prevent CPU spikes and touch input lag on e-ink hardware).
- **GC Heap Allocation Churn**: Memory allocated per sentence cycle (target: $< 15$ KB/cycle to prevent Garbage Collector pauses).
- **RAM Footprint Delta**: Residual heap increase across 50 continuous playback cycles (target: $< 1024$ KB without memory leaks).
