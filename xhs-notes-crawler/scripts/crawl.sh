#!/bin/bash
# =============================================================================
# 小红书账号笔记批量采集脚本
# 功能：批量采集指定小红书账号的全部笔记数据，输出为 CSV
# 特性：失败自动重试（3次递增延迟）、增量模式、后台运行
# =============================================================================

set +e  # 不因单个命令失败而退出

# ======================== 默认配置 ========================
DEFAULT_MCP_URL="http://localhost:18060/mcp"
DEFAULT_INTERVAL=3
DEFAULT_RETRY=3
DEFAULT_RETRY_DELAY=5
DEFAULT_USER_INTERVAL=5

# ======================== 参数解析 ========================
INPUT_FILE=""
OUTPUT_DIR="./output"
LIMIT=""
MAX_RETRY=$DEFAULT_RETRY
SLEEP_BETWEEN_NOTES=$DEFAULT_INTERVAL
SLEEP_BETWEEN_USERS=$DEFAULT_USER_INTERVAL
RETRY_DELAY=$DEFAULT_RETRY_DELAY
MCP_URL="$DEFAULT_MCP_URL"
BACKGROUND=false

show_help() {
    cat << EOF
用法: $0 [OPTIONS]

小红书账号笔记批量采集工具

选项:
  --input FILE        账号列表文件路径（每行一个小红书主页URL），必填
  --output DIR        输出目录路径（默认: ./output）
  --limit N           只处理前N个账号（默认: 全部）
  --retry N           失败重试次数（默认: 3）
  --interval N        笔记请求间隔秒数（默认: 3）
  --background        后台运行模式
  --mcp-url URL       MCP服务地址（默认: http://localhost:18060/mcp）
  --help              显示本帮助信息

示例:
  # 采集前5个账号（测试）
  $0 --input accounts.txt --output ./data --limit 5

  # 后台采集全部账号
  $0 --input accounts.txt --output ./data --background

  # 自定义重试和间隔
  $0 --input accounts.txt --retry 5 --interval 4

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --input)     INPUT_FILE="$2"; shift 2 ;;
        --output)    OUTPUT_DIR="$2"; shift 2 ;;
        --limit)     LIMIT="$2"; shift 2 ;;
        --retry)     MAX_RETRY="$2"; shift 2 ;;
        --interval)  SLEEP_BETWEEN_NOTES="$2"; shift 2 ;;
        --background) BACKGROUND=true; shift ;;
        --mcp-url)   MCP_URL="$2"; shift 2 ;;
        --help)      show_help ;;
        *)           echo "未知参数: $1"; show_help ;;
    esac
done

# ======================== 参数校验 ========================
if [ -z "$INPUT_FILE" ]; then
    echo "错误: 必须指定 --input 参数"
    echo "使用 --help 查看帮助"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "错误: 输入文件不存在: $INPUT_FILE"
    exit 1
fi

# 检查依赖
for cmd in jq curl; do
    if ! command -v $cmd &> /dev/null; then
        echo "错误: 需要安装 $cmd"
        exit 1
    fi
done

# ======================== 后台模式 ========================
if [ "$BACKGROUND" = true ]; then
    LOG_FILE="$OUTPUT_DIR/crawl.log"
    mkdir -p "$OUTPUT_DIR"
    echo "🚀 后台模式启动..."
    echo "   输出目录: $OUTPUT_DIR"
    echo "   日志文件: $LOG_FILE"
    echo "   查看进度: $(dirname "$0")/progress.sh --output $OUTPUT_DIR"
    
    nohup bash "$0" --input "$INPUT_FILE" --output "$OUTPUT_DIR" \
        ${LIMIT:+--limit $LIMIT} --retry "$MAX_RETRY" --interval "$SLEEP_BETWEEN_NOTES" \
        --mcp-url "$MCP_URL" > /dev/null 2>&1 &
    
    echo "   PID: $!"
    exit 0
fi

# ======================== 初始化 ========================
mkdir -p "$OUTPUT_DIR"

# 定位 MCP 调用脚本（查找 xiaohongshu skill）
SKILL_BASE=$(find "$(dirname "$0")/../.." -path "*/xiaohongshu/scripts/mcp-call.sh" 2>/dev/null | head -1)
if [ -z "$SKILL_BASE" ]; then
    # 尝试从工作区根目录查找
    WORKSPACE_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
    SKILL_BASE=$(find "$WORKSPACE_ROOT" -path "*/.agent/skills/xiaohongshu/scripts/mcp-call.sh" 2>/dev/null | head -1)
fi

if [ -z "$SKILL_BASE" ]; then
    echo "错误: 找不到 xiaohongshu skill 的 mcp-call.sh"
    echo "请确保已安装 xiaohongshu skill"
    exit 1
fi

MCP_CALL="$SKILL_BASE"
export MCP_URL

OUTPUT_CSV="$OUTPUT_DIR/xhs_notes_data.csv"
LOG_FILE="$OUTPUT_DIR/crawl.log"

# 获取总账号数
TOTAL_ACCOUNTS=$(wc -l < "$INPUT_FILE" | tr -d ' ')
if [ -n "$LIMIT" ]; then
    PROCESS_COUNT=$LIMIT
else
    PROCESS_COUNT=$TOTAL_ACCOUNTS
fi

# ======================== 工具函数 ========================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

timestamp_to_date() {
    local ts=$1
    if [ -z "$ts" ] || [ "$ts" = "null" ] || [ "$ts" = "0" ]; then echo ""; return; fi
    local sec=$((ts / 1000))
    date -d "@$sec" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo ""
}

# 获取 xsec_token（从推荐列表）
get_init_token() {
    local token=$("$MCP_CALL" list_feeds '{}' 2>/dev/null | \
        jq -r '.result.content[0].text' 2>/dev/null | \
        jq -r '.feeds[0].xsecToken // empty' 2>/dev/null)
    echo "$token"
}

# 获取笔记详情（带重试）
get_note_detail() {
    local feed_id="$1"
    local xsec_token="$2"
    local attempt=0
    local result=""
    
    while [ $attempt -lt $MAX_RETRY ]; do
        attempt=$((attempt + 1))
        
        result=$("$MCP_CALL" get_feed_detail "{\"feed_id\": \"$feed_id\", \"xsec_token\": \"$xsec_token\", \"load_all_comments\": false}" 2>/dev/null | jq -r '.result.content[0].text' 2>/dev/null)
        
        # 精确判断：检查返回的 JSON 中是否包含 .data.note.noteId
        if [ -n "$result" ] && [ "$result" != "null" ]; then
            local note_id=$(echo "$result" | jq -r '.data.note.noteId // empty' 2>/dev/null)
            if [ -n "$note_id" ]; then
                echo "$result"
                return 0
            fi
        fi
        
        # 重试前等待（递增延迟）
        if [ $attempt -lt $MAX_RETRY ]; then
            local delay=$((RETRY_DELAY * attempt))
            log "      ↻ 重试 $attempt/$MAX_RETRY（等待${delay}s）"
            sleep $delay
        fi
    done
    
    return 1
}

# 获取用户主页（带重试）
get_user_profile() {
    local user_id="$1"
    local init_token="$2"
    local user_data=""
    
    for try in 1 2 3; do
        user_data=$("$MCP_CALL" user_profile "{\"user_id\": \"$user_id\", \"xsec_token\": \"$init_token\"}" 2>/dev/null | jq -r '.result.content[0].text' 2>/dev/null)
        
        if [ -n "$user_data" ] && [ "$user_data" != "null" ]; then
            local feeds_count=$(echo "$user_data" | jq '.feeds | length' 2>/dev/null)
            if [ -n "$feeds_count" ] && [ "$feeds_count" != "null" ] && [ "$feeds_count" -gt 0 ] 2>/dev/null; then
                echo "$user_data"
                return 0
            fi
        fi
        
        [ $try -lt 3 ] && sleep 5
    done
    
    return 1
}

# 检查CSV中是否已存在某笔记（增量模式）
is_note_exists() {
    local feed_id="$1"
    if [ -f "$OUTPUT_CSV" ]; then
        grep -q "\"$feed_id\"" "$OUTPUT_CSV" 2>/dev/null && return 0
    fi
    return 1
}

# ======================== 主流程 ========================

# 如果CSV不存在，写入表头（带BOM）
if [ ! -f "$OUTPUT_CSV" ]; then
    printf '\xEF\xBB\xBF' > "$OUTPUT_CSV"
    echo "账号主页链接,账号ID,账号名称,笔记标题,笔记链接,笔记内容,点赞数,收藏数,转发数,笔记发布时间,数据记录时间" >> "$OUTPUT_CSV"
fi

log "=========================================="
log "🚀 小红书笔记批量采集"
log "   账号文件: $INPUT_FILE"
log "   处理数量: $PROCESS_COUNT / $TOTAL_ACCOUNTS"
log "   输出目录: $OUTPUT_DIR"
log "   重试次数: $MAX_RETRY | 间隔: ${SLEEP_BETWEEN_NOTES}s"
log "=========================================="

# 获取初始 token
log "获取初始 xsec_token..."
INIT_TOKEN=$(get_init_token)
if [ -z "$INIT_TOKEN" ]; then
    log "❌ 无法获取 xsec_token，请检查 xiaohongshu MCP 服务是否正常运行并已登录"
    log "   运行: cd <workspace>/.agent/skills/xiaohongshu/scripts && ./status.sh"
    exit 1
fi
log "✅ xsec_token 获取成功"

# 读取账号列表
if [ -n "$LIMIT" ]; then
    ACCOUNTS=$(head -n "$LIMIT" "$INPUT_FILE")
else
    ACCOUNTS=$(cat "$INPUT_FILE")
fi

ACCOUNT_NUM=0
TOTAL_NOTES=0
TOTAL_SKIP=0
TOTAL_FAIL=0

for URL in $ACCOUNTS; do
    ACCOUNT_NUM=$((ACCOUNT_NUM + 1))
    
    # 从URL提取user_id
    USER_ID=$(echo "$URL" | grep -oP '(?<=profile/)[a-zA-Z0-9]+')
    [ -z "$USER_ID" ] && continue
    
    log "[$ACCOUNT_NUM/$PROCESS_COUNT] 用户: $USER_ID"
    
    # 获取用户主页
    USER_DATA=$(get_user_profile "$USER_ID" "$INIT_TOKEN")
    
    if [ $? -ne 0 ] || [ -z "$USER_DATA" ]; then
        log "  ❌ 获取用户主页失败（重试3次），跳过"
        continue
    fi
    
    NICKNAME=$(echo "$USER_DATA" | jq -r '.userBasicInfo.nickname // "未知"' 2>/dev/null)
    NOTE_COUNT=$(echo "$USER_DATA" | jq '.feeds | length' 2>/dev/null)
    log "  ✅ $NICKNAME | 笔记数: $NOTE_COUNT"
    
    [ "$NOTE_COUNT" = "0" ] || [ -z "$NOTE_COUNT" ] && continue
    
    # 保存用户原始数据
    echo "$USER_DATA" > "$OUTPUT_DIR/user_${USER_ID}.json"
    
    USER_SUCCESS=0
    USER_SKIP=0
    USER_FAIL=0
    
    for i in $(seq 0 $((NOTE_COUNT - 1))); do
        FEED_ID=$(echo "$USER_DATA" | jq -r ".feeds[$i].id" 2>/dev/null)
        FEED_TOKEN=$(echo "$USER_DATA" | jq -r ".feeds[$i].xsecToken" 2>/dev/null)
        FEED_TITLE=$(echo "$USER_DATA" | jq -r ".feeds[$i].noteCard.displayTitle // \"\"" 2>/dev/null)
        
        [ -z "$FEED_ID" ] || [ "$FEED_ID" = "null" ] && continue
        
        # 增量模式：跳过已采集的
        if is_note_exists "$FEED_ID"; then
            USER_SKIP=$((USER_SKIP + 1))
            continue
        fi
        
        sleep "$SLEEP_BETWEEN_NOTES"
        
        # 带重试获取详情
        DETAIL=$(get_note_detail "$FEED_ID" "$FEED_TOKEN")
        DETAIL_RC=$?
        
        if [ $DETAIL_RC -ne 0 ] || [ -z "$DETAIL" ]; then
            log "    ❌ [$((i+1))/$NOTE_COUNT] 失败(${MAX_RETRY}次重试): $FEED_TITLE"
            USER_FAIL=$((USER_FAIL + 1))
            # 记录失败的笔记到单独文件，方便后续重试
            echo "$USER_ID|$FEED_ID|$FEED_TOKEN|$FEED_TITLE" >> "$OUTPUT_DIR/failed_notes.txt"
            continue
        fi
        
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
        
        # CSV安全处理
        NOTE_TITLE_SAFE=$(echo "$NOTE_TITLE" | tr '\n\r' '  ' | sed 's/"/""/g')
        NOTE_CONTENT_SAFE=$(echo "$NOTE_CONTENT" | tr '\n\r' '  ' | sed 's/"/""/g' | head -c 2000)
        NICKNAME_SAFE=$(echo "$NICKNAME" | tr '\n\r' '  ' | sed 's/"/""/g')
        
        # 构造链接
        PROFILE_URL="https://www.xiaohongshu.com/user/profile/$USER_ID"
        NOTE_URL="https://www.xiaohongshu.com/explore/$FEED_ID"
        
        echo "\"$PROFILE_URL\",\"$USER_ID\",\"$NICKNAME_SAFE\",\"$NOTE_TITLE_SAFE\",\"$NOTE_URL\",\"$NOTE_CONTENT_SAFE\",\"$LIKED_COUNT\",\"$COLLECTED_COUNT\",\"$SHARED_COUNT\",\"$PUBLISH_TIME\",\"$RECORD_TIME\"" >> "$OUTPUT_CSV"
        
        USER_SUCCESS=$((USER_SUCCESS + 1))
        TOTAL_NOTES=$((TOTAL_NOTES + 1))
        log "    ✅ [$((i+1))/$NOTE_COUNT] 👍$LIKED_COUNT ⭐$COLLECTED_COUNT | $NOTE_TITLE_SAFE"
    done
    
    TOTAL_SKIP=$((TOTAL_SKIP + USER_SKIP))
    TOTAL_FAIL=$((TOTAL_FAIL + USER_FAIL))
    log "  完成: $NICKNAME | 新增:$USER_SUCCESS 跳过:$USER_SKIP 失败:$USER_FAIL"
    sleep "$SLEEP_BETWEEN_USERS"
done

# ======================== 汇总 ========================
TOTAL_CSV=$(( $(wc -l < "$OUTPUT_CSV") - 1 ))
SUCCESS_RATE=0
if [ $((TOTAL_NOTES + TOTAL_FAIL)) -gt 0 ]; then
    SUCCESS_RATE=$(( (TOTAL_NOTES * 100) / (TOTAL_NOTES + TOTAL_FAIL) ))
fi

log "=========================================="
log "✅ 采集完成！"
log "   账号处理: $ACCOUNT_NUM"
log "   本次新增: $TOTAL_NOTES 条"
log "   跳过(已有): $TOTAL_SKIP 条"
log "   失败: $TOTAL_FAIL 条"
log "   成功率: ${SUCCESS_RATE}%"
log "   CSV总记录: $TOTAL_CSV 条"
log "   输出文件: $OUTPUT_CSV"
log "=========================================="
