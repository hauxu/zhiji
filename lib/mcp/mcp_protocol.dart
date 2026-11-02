/// MCP 的 JSON-RPC 2.0 编解码与错误码。
/// 只覆盖用到的方法：initialize / tools/list / tools/call / ping。
library;

import 'dart:convert';

const int kParseError = -32700;
const int kInvalidRequest = -32600;
const int kMethodNotFound = -32601;
const int kInvalidParams = -32602;
const int kInternalError = -32603;

/// 业务错误统一用 -32000 区间，message 直接给智能体看。
const int kToolError = -32000;

Map<String, dynamic> rpcResult(Object? id, Object? result) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
};

Map<String, dynamic> rpcError(Object? id, int code, String message) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message},
};

/// tools/call 成功：内容是一段 JSON 文本，客户端好解析。
Map<String, dynamic> toolText(Object? data) => {
  'content': [
    {'type': 'text', 'text': jsonEncode(data)},
  ],
  'isError': false,
};

/// tools/call 失败：isError=true，消息直接展示。
Map<String, dynamic> toolError(String message) => {
  'content': [
    {'type': 'text', 'text': message},
  ],
  'isError': true,
};
