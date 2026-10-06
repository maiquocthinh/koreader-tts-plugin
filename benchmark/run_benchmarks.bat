@echo off
REM benchmark/run_benchmarks.bat - Run local device benchmarks on Windows (100% Offline)
echo ==========================================================================
echo   RUNNING KOReader TTS PLUGIN LOCAL DEVICE BENCHMARKS
echo   (100%% Offline - Zero Network Dependency)
echo ==========================================================================

luajit benchmark\benchmark_local_device.lua
if errorlevel 1 exit /b 1

luajit benchmark\benchmark_network.lua
if errorlevel 1 exit /b 1

luajit benchmark\benchmark_stress_memory.lua
if errorlevel 1 exit /b 1

echo ==========================================================================
echo   ALL LOCAL BENCHMARKS COMPLETED SUCCESSFULLY!
echo ==========================================================================
