# 之计 MCP 接口

之计内置一个 MCP 服务，本机的智能体可以直接读计划、清单、习惯、日记和留言；打开写入开关后也能新建、修改、勾选。

服务只在 `127.0.0.1` 上监听，必须是本机进程才能连，并且要带上应用里生成的 Token。

## 打开

「我的 → 智能体接入」：

1. 打开「启用 MCP 服务」，默认端口 `8787`
2. 复制 Token 或点「复制 MCP 配置」，得到一段现成的客户端配置
3. 需要智能体改数据时，再打开「允许写入」
4. 需要读日记和留言时，再打开「允许读取日记与留言」

关闭开关会立刻停止监听；重置 Token 后旧的立刻失效。

## 客户端配置

### 支持 HTTP 的客户端（Claude Code、Cursor、DSH 等）

```json
{
  "mcpServers": {
    "zhiji": {
      "type": "http",
      "url": "http://127.0.0.1:8787/mcp",
      "headers": {"Authorization": "Bearer <TOKEN>"}
    }
  }
}
```

### 只支持 stdio 的客户端（Claude Desktop 等）

```json
{
  "mcpServers": {
    "zhiji": {
      "command": "dart",
      "args": [
        "run", "F:/workspace/zcode/goalday/tools/mcp_stdio_bridge.dart",
        "--url", "http://127.0.0.1:8787/mcp",
        "--token", "<TOKEN>"
      ]
    }
  }
}
```

桥接脚本把 stdin 的 JSON-RPC 原样转发给应用，响应再写回 stdout。

## 工具

### 只读（服务开启即可）

| 工具 | 参数 | 说明 |
|---|---|---|
| `zhiji_app_info` | — | 版本、平台、登录与配对状态、待办数 |
| `zhiji_plan_list` | `date` / `from` / `to` / `includeMemos` / `includeDone` / `includeArchived` | 查计划，有日期的排在备忘录前 |
| `zhiji_plan_get` | `id` | 单条计划 |
| `zhiji_plan_stats` | `date` | 当天完成数、本周统计、备忘录数 |
| `zhiji_list_list` | — | 全部清单 |
| `zhiji_list_get` | `id` | 清单与条目 |
| `zhiji_habit_list` | `days` | 习惯与最近打卡 |
| `zhiji_habit_history` | `habitId` / `from` / `to` | 单个习惯的打卡区间 |
| `zhiji_countdown_list` | — | 倒数日本与剩余天数 |
| `zhiji_journal_list` | `limit` | 日记列表（需隐私授权） |
| `zhiji_journal_get` | `date` | 日记全文（需隐私授权） |
| `zhiji_couple_messages` | `limit` | 留言板（需隐私授权） |

### 写入（需「允许写入」）

| 工具 | 参数 |
|---|---|
| `zhiji_plan_create` | `title` / `date`（留空即备忘录）/ `start` / `end` / `note` / `remindBefore` |
| `zhiji_plan_update` | `id` + 要改的字段 |
| `zhiji_plan_complete` | `id` / `done` / `date` |
| `zhiji_plan_archive` | `id` / `archived` |
| `zhiji_list_create` | `name` / `color` |
| `zhiji_list_add_item` | `listId` / `title` |
| `zhiji_list_check_item` | `listId` / `itemId` / `done` |
| `zhiji_habit_check` | `habitId` / `date` / `done` |
| `zhiji_countdown_create` | `title` / `date` / `yearly` |

写入走应用自己的数据层，会正常落盘、标脏并同步给伴侣端。

## 协议

- 传输：MCP Streamable HTTP，`POST /mcp`，无状态，不提供服务端推送（`GET /mcp` 返回 405）
- 协议版本：`2025-06-18`
- 方法：`initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call`
- 鉴权：`Authorization: Bearer <TOKEN>`，也接受 `X-Zhiji-Token`
- 限流：每秒 60 次
- 调用日志：应用内保留最近 100 次，可在设置里清空

请求示例：

```sh
curl -s http://127.0.0.1:8787/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"zhiji_plan_list","arguments":{"includeMemos":true}}}'
```

## 边界

- 只监听回环地址，不做局域网或公网访问
- 日记与留言默认不可读，Token 泄露等于把这些内容交出去，用完记得关
- 手机端也能开，但只有本机进程能连；桌面智能体请连 Windows 上运行的应用
