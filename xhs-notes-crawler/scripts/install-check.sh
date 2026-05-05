#!/bin/bash
# =============================================================================
# 安装检查脚本 - 验证所有依赖是否就绪
# =============================================================================

echo "=========================================="
echo "🔍 xhs-notes-crawler 依赖检查"
echo "=========================================="

ERRORS=0

# 1. 检查系统工具
echo ""
echo "📦 系统工具:"

for cmd in jq curl bash grep sed awk; do
    if command -v $cmd &> /dev/null; then
        VERSION=$($cmd --version 2>&1 | head -1)
        echo "  ✅ $cmd: $VERSION"
    else
        echo "  ❌ $cmd: 未安装"
        ERRORS=$((ERRORS + 1))
    fi
done

# 2. 检查 xiaohongshu skill
echo ""
echo "📦 xiaohongshu skill:"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_BASE=$(find "$SCRIPT_DIR/../.." -path "*/xiaohongshu/scripts/mcp-call.sh" 2>/dev/null | head -1)
if [ -z "$SKILL_BASE" ]; then
    WORKSPACE_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
    SKILL_BASE=$(find "$WORKSPACE_ROOT" -path "*/.agent/skills/xiaohongshu/scripts/mcp-call.sh" 2>/dev/null | head -1)
fi

if [ -n "$SKILL_BASE" ]; then
    echo "  ✅ mcp-call.sh: $SKILL_BASE"
else
    echo "  ❌ xiaohongshu skill 未找到"
    echo "     请先安装 xiaohongshu skill（通过 Knot 技能市场）"
    ERRORS=$((ERRORS + 1))
fi

# 3. 检查 MCP 服务状态
echo ""
echo "📦 MCP 服务:"

MCP_URL="${MCP_URL:-http://localhost:18060/mcp}"
export no_proxy="${no_proxy:+$no_proxy,}localhost,127.0.0.1"

MCP_CHECK=$(curl --noproxy '*' -s --max-time 5 -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"check","version":"1.0"}}}' 2>/dev/null)

if echo "$MCP_CHECK" | jq -e '.result' > /dev/null 2>&1; then
    echo "  ✅ MCP 服务运行中 ($MCP_URL)"
else
    echo "  ❌ MCP 服务未运行"
    echo "     启动方式: cd <workspace>/.agent/skills/xiaohongshu/scripts && ./start-mcp.sh"
    ERRORS=$((ERRORS + 1))
fi

# 4. 检查登录状态
echo ""
echo "📦 小红书登录状态:"

if [ -n "$SKILL_BASE" ]; then
    XHS_SCRIPTS=$(dirname "$SKILL_BASE")
    LOGIN_STATUS=$("$XHS_SCRIPTS/../scripts/status.sh" 2>/dev/null | jq -r '.result.content[0].text' 2>/dev/null)
    if echo "$LOGIN_STATUS" | grep -q "已登录"; then
        USERNAME=$(echo "$LOGIN_STATUS" | grep "用户名" | awk -F: '{print $2}' | tr -d ' ')
        echo "  ✅ 已登录（$USERNAME）"
    else
        echo "  ❌ 未登录"
        echo "     扫码登录: cd <workspace>/.agent/skills/xiaohongshu/scripts && ./login.sh"
        ERRORS=$((ERRORS + 1))
    fi
fi

# 总结
echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo "✅ 所有依赖就绪，可以开始采集！"
    echo ""
    echo "运行示例:"
    echo "  $SCRIPT_DIR/crawl.sh --input accounts.txt --output ./data --limit 5"
else
    echo "❌ 发现 $ERRORS 个问题，请按提示修复后重试"
fi
echo "=========================================="

exit $ERRORS
