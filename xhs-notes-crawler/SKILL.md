---
name: xhs-notes-crawler
description: |
  小红书账号笔记批量采集工具。批量获取指定小红书账号的所有笔记数据，包括标题、正文、
  点赞/收藏/转发数、发布时间等，输出为 CSV 文件。
  
  核心特性：
  - 批量采集多个账号的全部笔记
  - 失败自动重试（最多3次，递增延迟）
  - 增量模式（跳过已采集笔记，支持断点续跑）
  - 支持定期调度（后台运行，不阻塞终端）
  
  触发词示例：
  - "帮我采集这些小红书账号的笔记"
  - "批量获取小红书用户的帖子数据"
  - "爬取小红书笔记数据"
  - "定期采集小红书账号内容"
  - "小红书账号笔记导出CSV"
---

# 小红书账号笔记批量采集 Skill

批量采集指定小红书账号的所有笔记内容和互动数据，输出为结构化 CSV 文件。

## 依赖

本 Skill 依赖 `xiaohongshu` 基础技能（MCP 服务），请确保已安装：

| 依赖 | 说明 | 安装方式 |
|------|------|----------|
| `xiaohongshu` skill | 小红书 MCP 服务（提供底层 API） | 通过 Knot 技能市场安装 |
| `jq` | JSON 命令行处理工具 | `apt-get install jq` |
| `curl` | HTTP 请求工具 | 系统自带 |
| `bash` 4.0+ | Shell 解释器 | 系统自带 |

## 快速开始

```bash
# 1. 确保 xiaohongshu MCP 服务已启动并登录
cd <workspace>/.agent/skills/xiaohongshu/scripts
./start-mcp.sh
./status.sh  # 确认显示"已登录"

# 2. 准备账号列表文件（每行一个小红书主页URL）
cat accounts.txt
# https://www.xiaohongshu.com/user/profile/5cf23af900000000180121ab
# https://www.xiaohongshu.com/user/profile/669f5b3c0000000024021819
# ...

# 3. 运行采集
cd <workspace>/.agent/skills/xhs-notes-crawler/scripts
./crawl.sh --input accounts.txt --output ./output

# 4. 后台运行（推荐，适合大批量）
./crawl.sh --input accounts.txt --output ./output --background

# 5. 查看进度
./progress.sh --output ./output
```

## 脚本说明

| 脚本 | 用途 | 主要参数 |
|------|------|----------|
| `crawl.sh` | 主采集脚本 | `--input`, `--output`, `--limit`, `--background` |
| `progress.sh` | 查看采集进度 | `--output` |
| `retry.sh` | 单独重试失败的笔记 | `--output` |

## 参数详细说明

### crawl.sh

```bash
./crawl.sh [OPTIONS]

选项:
  --input FILE        账号列表文件路径（每行一个URL），必填
  --output DIR        输出目录路径，默认 ./output
  --limit N           只处理前N个账号，默认处理全部
  --retry N           失败重试次数，默认 3
  --interval N        请求间隔秒数，默认 3
  --background        后台运行模式
  --mcp-url URL       MCP服务地址，默认 http://localhost:18060/mcp
  --help              显示帮助
```

### 输出格式

CSV 文件字段（UTF-8 with BOM，Excel 直接打开中文正常）：

| 字段 | 说明 | 示例 |
|------|------|------|
| 账号主页链接 | 用户主页URL | `https://www.xiaohongshu.com/user/profile/5cf23af900000000180121ab` |
| 账号ID | 小红书用户ID | `5cf23af900000000180121ab` |
| 账号名称 | 用户昵称 | `青岛海信广场大疆丨哈苏` |
| 笔记标题 | 笔记标题 | `Action6 万能参数来啦` |
| 笔记链接 | 笔记详情页URL | `https://www.xiaohongshu.com/explore/69e369d20000000022024a77` |
| 笔记内容 | 笔记正文（含话题标签） | `📸新手直接抄作业...` |
| 点赞数 | 点赞数量 | `370` |
| 收藏数 | 收藏数量 | `420` |
| 转发数 | 转发数量（接口常为空） | `` |
| 笔记发布时间 | 发布时间 | `2026-04-18 19:24:02` |
| 数据记录时间 | 采集时间 | `2026-05-05 19:45:27` |

## 定期调度

配合 Knot 定时任务，可实现定期采集：

```bash
# 每天早上9点采集一次（增量模式，只获取新笔记）
# 在 Knot 对话中设置定时任务即可
```

由于脚本支持增量模式，重复运行时会自动跳过已采集的笔记，只获取新增内容。

## 注意事项

1. **登录态有效期**：xiaohongshu MCP 的 cookies 约30天有效，过期需重新扫码登录
2. **采集速度**：每条笔记约3-5秒，100个账号×30条笔记 ≈ 3-5小时
3. **反爬风险**：间隔低于2秒可能触发限流，建议保持默认3秒
4. **每用户笔记上限**：API 一次最多返回约60条最近笔记（小红书限制）
5. **增量续跑**：脚本中途中断后重新运行会自动续跑，不会重复采集
