#!/bin/bash
# =============================================================================
# 查看采集进度
# =============================================================================

OUTPUT_DIR="./output"

while [[ $# -gt 0 ]]; do
    case $1 in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

CSV_FILE="$OUTPUT_DIR/xhs_notes_data.csv"
LOG_FILE="$OUTPUT_DIR/crawl.log"

echo "=========================================="
echo "📊 小红书笔记采集进度"
echo "=========================================="

# 检查进程状态
RUNNING=$(ps aux | grep "crawl.sh" | grep -v grep | grep -v "progress.sh" | wc -l)
if [ "$RUNNING" -gt 0 ]; then
    echo "状态: 🟢 运行中"
    PID=$(ps aux | grep "crawl.sh" | grep -v grep | grep -v "progress.sh" | awk '{print $2}' | head -1)
    echo "PID: $PID"
else
    echo "状态: ⚪ 未运行"
fi

echo ""

# CSV 统计
if [ -f "$CSV_FILE" ]; then
    TOTAL_NOTES=$(( $(wc -l < "$CSV_FILE") - 1 ))
    echo "📝 已采集笔记: $TOTAL_NOTES 条"
    echo ""
    echo "各账号统计:"
    tail -n +2 "$CSV_FILE" | awk -F'","' '{gsub(/"/, "", $2); print $2}' | sort | uniq -c | sort -rn | head -20
else
    echo "📝 尚无采集数据"
fi

echo ""

# 失败统计
if [ -f "$OUTPUT_DIR/failed_notes.txt" ]; then
    FAIL_COUNT=$(wc -l < "$OUTPUT_DIR/failed_notes.txt")
    echo "❌ 失败笔记: $FAIL_COUNT 条"
else
    echo "❌ 失败笔记: 0 条"
fi

echo ""

# 最新日志
if [ -f "$LOG_FILE" ]; then
    echo "📋 最近日志:"
    tail -5 "$LOG_FILE"
fi

echo ""
echo "=========================================="
