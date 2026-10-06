#!/usr/bin/env bash
# benchmark/test_real_network.sh
# Real Network & AI Synthesis Benchmark executed directly on Android device via ADB.
# NO MOCKS. Real network connection to Hugging Face TTS Space.

SERVER_URL="https://maiquocthinh-vieneu-tts.hf.space/v1/audio/speech"
VOICE="Đức Trí"
OUTPUT_DIR="/sdcard/koreader/cache/tts_bench_real"

echo "=========================================================================="
echo "  REAL NETWORK & AI SYNTHESIS BENCHMARK (ON-DEVICE VIA ADB)                "
echo "  Endpoint: $SERVER_URL"
echo "  Voice: $VOICE"
echo "=========================================================================="

adb shell "mkdir -p $OUTPUT_DIR"

# Test sentences with varying lengths
declare -a SENTENCES=(
    "Hôm nay tôi đi dạo trên bờ biển."
    "Ánh mặt trời buổi sớm len lỏi qua từng kẽ lá rừng thông bạt ngàn của vùng cao nguyên đại ngàn."
    "Trong một buổi chiều mùa thu mát mẻ, khi những chiếc lá vàng nhẹ nhàng rơi trên từng con phố cổ kính của thủ đô, người ta thường hoài niệm về những kỷ niệm đẹp đẽ đã qua trong cuộc đời dài đằng đẵng của mình."
)

declare -a LABELS=(
    "Short Sentence (33 chars)"
    "Medium Sentence (93 chars)"
    "Long Sentence (216 chars)"
)

FORMAT_STRING="DNS: %{time_namelookup}s | TCP: %{time_connect}s | TLS: %{time_appconnect}s | TTFB (AI Gen): %{time_starttransfer}s | Total: %{time_total}s | Size: %{size_download} bytes | HTTP: %{http_code}\n"

for i in "${!SENTENCES[@]}"; do
    echo ""
    echo "--- [TEST CASE $((i+1))] ${LABELS[$i]} ---"
    TEXT="${SENTENCES[$i]}"
    echo "  Text: \"$TEXT\""

    WAV_FILE="$OUTPUT_DIR/real_chunk_$i.wav"

    # Run curl directly inside Android shell and capture timing metrics
    adb shell "curl -s -k -w '$FORMAT_STRING' -X POST '$SERVER_URL' \
        -H 'Content-Type: application/json' \
        -d '{\"input\":\"$TEXT\",\"voice\":\"$VOICE\",\"speed\":1.0}' \
        -o '$WAV_FILE'"

    # Verify WAV header on device
    HEADER_CHECK=$(adb shell "head -c 4 '$WAV_FILE' 2>/dev/null")
    FILE_SIZE=$(adb shell "ls -l '$WAV_FILE' 2>/dev/null | awk '{print \$5}'")
    echo "  Header: '$HEADER_CHECK' | File size: $FILE_SIZE bytes"
done

echo ""
echo "=========================================================================="
echo "  REAL NETWORK BENCHMARK COMPLETED                                        "
echo "=========================================================================="
