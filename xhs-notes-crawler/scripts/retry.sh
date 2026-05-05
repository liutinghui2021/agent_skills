#!/bin/bash
# =============================================================================
# 重试失败的笔记
# 读取 failed_notes.txt 中记录的失败笔记，逐个重新获取
# =============================================================================

set +e

OUTPUT_DIR="./output"
MCP_URL="${MCP_URL:-http://localhost:18060/mcp}"
MAX_RETRY=3
RETRY_DELAY=5
SLEEP_BETWEEN=4

while [[ $# -gt 0 ]]; do
    case $1 in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --mcp-url) MCP_URL="$2"; shift 2 ;;
        --retry) MAX_RETRY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

FAILED_FILE="$OUTPUT_DIR/failed_notes.txt"
OUTPUT_CSV="$OUTPUT_DIR/xhs_notes_data.csv"
LOG_FILE="$OUTPUT_DIR/crawl.log"

if [ ! -f "$FAILED_FILE" ]; then
    echo "✅ 没有失败记录，无需重试"
    exit 0
fi

FAIL_COUNT=$(wc -l < "$FAILED_FILE")
echo "🔄 开始重试 $FAIL_COUNT 条失败笔记..."

# 定位 MCP 调用脚本
SKILL_BASE=$(find "$(dirname "$0")/../.." -path "*/xiaohongshu/scripts/mcp-call.sh" 2>/dev/null | head -1)
if [ -z "$SKILL_BASE" ]; then
    WORKSPACE_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
    SKILL_BASE=$(find "$WORKSPACE_ROOT" -path "*/.agent/skills/xiaohongshu/scripts/mcp-call.sh" 2>/dev/null | head -1)
fi

if [ -z "$SKILL_BASE" ]; then
    echo "错误: 找不到 xiaohongshu skill 的 mcp-call.sh"
    exit 1
fi

MCP_CALL="$SKILL_BASE"
export MCP_URL

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

timestamp_to_date() {
    local ts=$1
    if [ -z "$ts" ] || [ "$ts" = "null" ] || [ "$ts" = "0" ]; then echo ""; return; fi
    local sec=$((ts / 1000))
    date -d "@$sec" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo ""
}

log "=========================================="
log "🔄 重试失败笔记: $FAIL_COUNT 条"
log "=========================================="

SUCCESS=0
STILL_FAIL=0
NEW_FAILED=""

while IFS='|' read -r USER_ID FEED_ID FEED_TOKEN FEED_TITLE; do
    [ -z "$FEED_ID" ] && continue
    
    # 跳过已存在的（可能之前已补采成功）
    if grep -q "\"$FEED_ID\"" "$OUTPUT_CSV" 2>/dev/null; then
        continue
    fi
    
    sleep "$SLEEP_BETWEEN"
    
    # 带重试获取
    DETAIL=""
    for attempt in $(seq 1 $MAX_RETRY); do
        DETAIL=$("$MCP_CALL" get_feed_detail "{\"feed_id\": \"$FEED_ID\", \"xsec_token\": \"$FEED_TOKEN\", \"load_all_comments\": false}" 2>/dev/null | jq -r '.result.content[0].text' 2>/dev/null)
        
        if [ -n "$DETAIL" ] && [ "$DETAIL" != "null" ]; then
            local_note_id=$(echo "$DETAIL" | jq -r '.data.note.noteId // empty' 2>/dev/null)
            if [ -n "$local_note_id" ]; then
                break
            fi
        fi
        DETAIL=""
        [ $attempt -lt $MAX_RETRY ] && sleep $((RETRY_DELAY * attempt))
    done
    
    if [ -z "$DETAIL" ]; then
        log "  ❌ 仍然失败: $FEED_TITLE"
        NEW_FAILED="${NEW_FAILED}${USER_ID}|${FEED_ID}|${FEED_TOKEN}|${FEED_TITLE}\n"
        STILL_FAIL=$((STILL_FAIL + 1))
        continue
    fi
    
    # 获取用户昵称
    NICKNAME=$(echo "$DETAIL" | jq -r '.data.note.user.nickname // "未知"' 2>/dev/null)
    
    # 提取数据
    NOTE_TITLE=$(echo "$DETAIL" | jq -r '.data.note.title // ""' 2>/dev/null)
    NOTE_CONTENT=$(echo "$DETAIL" | jq -r '.data.note.desc // ""' 2>/dev/null)
    LIKED_COUNT=$(echo "$DETAIL" | jq -r '.data.note.interactInfo.likedCount // "0"' 2>/dev/null)
    COLLECTED_COUNT=$(echo "$DETAIL" | jq -r '.data.note.interactInfo.collectedCount // "0"' 2>/dev/null)
    SHARED_COUNT=$(echo "$DETAIL" | jq -r '.data.note.interactInfo.sharedCount // "0"' 2>/dev/null)
    PUBLISH_TS=$(echo "$DETAIL" | jq -r '.data.note.time // 0' 2>/dev/null)
    
    [ -z "$NOTE_TITLE" ] || [ "$NOTE_TITLE" = "null" ] && NOTE_TITLE="$FEED_TITLE"
    
    PUBLISH_TIME=$(timestamp_to_date "$PUBLISH_TS")
    RECORD_TIME=$(date "+%Y-%m-%d %H:%M:%S")
    
    NOTE_TITLE_SAFE=$(echo "$NOTE_TITLE" | tr '\n\r' '  ' | sed 's/"/""/g')
    NOTE_CONTENT_SAFE=$(echo "$NOTE_CONTENT" | tr '\n\r' '  ' | sed 's/"/""/g' | head -c 2000)
    NICKNAME_SAFE=$(echo "$NICKNAME" | tr '\n\r' '  ' | sed 's/"/""/g')
    
    # 构造链接
    PROFILE_URL="https://www.xiaohongshu.com/user/profile/$USER_ID"
    NOTE_URL="https://www.xiaohongshu.com/explore/$FEED_ID"
    
    echo "\"$PROFILE_URL\",\"$USER_ID\",\"$NICKNAME_SAFE\",\"$NOTE_TITLE_SAFE\",\"$NOTE_URL\",\"$NOTE_CONTENT_SAFE\",\"$LIKED_COUNT\",\"$COLLECTED_COUNT\",\"$SHARED_COUNT\",\"$PUBLISH_TIME\",\"$RECORD_TIME\"" >> "$OUTPUT_CSV"
    
    SUCCESS=$((SUCCESS + 1))
    log "  ✅ 👍$LIKED_COUNT ⭐$COLLECTED_COUNT | $NOTE_TITLE_SAFE"
    
done < "$FAILED_FILE"

# 更新失败记录文件
if [ -n "$NEW_FAILED" ]; then
    echo -e "$NEW_FAILED" > "$FAILED_FILE"
else
    rm -f "$FAILED_FILE"
fi

log "=========================================="
log "🔄 重试完成: 成功 $SUCCESS | 仍失败 $STILL_FAIL"
log "=========================================="
