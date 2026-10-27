import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_config.dart';

/// AI 语义识别：分析用户输入的文本，调用 OpenAI 兼容 chat/completions
/// 接口，解析出条目类型与字段。不读取剪贴板。
///
/// 端点/模型/Key 全部来自 [AiConfig]（本机 SharedPreferences，设置页填写），
/// 不再使用构建期 --dart-define；未启用或未填写时 [recognize] 返回错误提示。
class AiService {
  AiService._();

  static const _connectTimeout = Duration(seconds: 15);
  static const _responseTimeout = Duration(seconds: 30);
  static const _readTimeout = Duration(seconds: 20);

  /// AI 识别结果。
  /// type: plan / countdown / habit / list；plan 附带 date/time/endTime/location。
  static Future<AiPick> recognize(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      return const AiPick.error('请先在输入框输入内容');
    }
    final config = await AiConfig.load();
    if (!config.isConfigured) {
      return const AiPick.error('AI 未启用：到「我的 → AI 助手」填写接口地址与 Key');
    }
    final now = DateTime.now();
    try {
      final json = await _chatCompletion(
        config,
        messages: [
          {'role': 'system', 'content': _buildSystemPrompt(now)},
          {'role': 'user', 'content': text},
        ],
        temperature: 0.2,
        maxTokens: 400,
        jsonMode: true,
        // 千问网关默认开深度思考，识别任务不需要，关掉可明显降低延迟。
        extraBody:
            _isQwen(config) ? const {'enable_thinking': false} : null,
        responseTimeout: const Duration(seconds: 60),
      );
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        return const AiPick.error('AI 未返回结果');
      }
      final first = choices.first;
      final message = first is Map ? first['message'] : null;
      final content =
          (message is Map ? (message['content'] as String? ?? '') : '').trim();
      if (content.isEmpty) {
        return const AiPick.error('AI 未返回结果');
      }
      return parseRecognition(content, fallbackTitle: text, now: now);
    } on _AiRequestException catch (e) {
      return AiPick.error(e.message);
    } catch (_) {
      return const AiPick.error('AI 识别失败，请稍后再试');
    }
  }

  /// 是否千问网关（只对它附加 enable_thinking 这类非标准参数）。
  static bool _isQwen(AiConfig config) =>
      config.model.toLowerCase().contains('qwen') ||
      config.baseUrl.toLowerCase().contains('qianwen');

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _buildSystemPrompt(DateTime now) {
    final date = '${now.year}-${_two(now.month)}-${_two(now.day)}';
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final week = weekdays[now.weekday - 1];
    final hhmm = '${_two(now.hour)}:${_two(now.minute)}';
    return '你是「之计」App 的日程信息提取器。把用户输入的一句话解析成 JSON，'
        '只输出一个 JSON 对象，不要 markdown、不要解释。\n'
        '字段：\n'
        'type: plan(具体要做的事) | countdown(纪念日/倒数日/生日) | '
        'habit(每天或每周重复的习惯) | list(购物或待办清单条目)\n'
        'title: 去掉时间词后的简洁标题，保留事件关键信息，≤20 字，不要编造；'
        'habit 的 title 去掉「每天/每周」等频率词与「30 分钟」等时长\n'
        'date: YYYY-MM-DD；没说日期就空字符串；相对日期按当前时间换算'
        '（今天/明天/后天/这周X/下周X/月底/下月X号）；'
        'countdown 只说了几月几号时，换算成今年该日期，若今天已过则用明年\n'
        'time: 24 小时制 HH:mm；没说具体时刻就空字符串；上午/下午/晚上要换算；'
        '时间段取开始时间\n'
        'endTime: HH:mm 或空字符串（例如「3 点到 5 点」）\n'
        'location: 地点或空字符串\n'
        'items: 字符串数组；list 类型把要买/要做的东西逐项拆开'
        '（如「买牛奶、鸡蛋」→["牛奶","鸡蛋"]），其它类型为空数组\n'
        '规则：不要臆造日期、时间或地点；不确定的字段一律留空字符串。\n'
        '当前时间：$date 星期$week $hhmm。';
  }

  /// 解析模型返回的 JSON 文本（剥离代码围栏、容忍前后多余文字）。
  /// 独立出来便于单测，不发起网络请求。
  static AiPick parseRecognition(String raw,
      {String fallbackTitle = '', DateTime? now}) {
    var content = raw.trim();
    if (content.isEmpty) return const AiPick.error('AI 未返回结果');
    content = _stripFences(content);
    var obj = _tryDecodeObject(content);
    if (obj == null) {
      final start = content.indexOf('{');
      final end = content.lastIndexOf('}');
      if (start >= 0 && end > start) {
        obj = _tryDecodeObject(content.substring(start, end + 1));
      }
    }
    if (obj == null) return const AiPick.error('AI 返回内容无法解析');

    final type = _normalizeType('${obj['type'] ?? ''}');
    var title = (obj['title'] as String? ?? '').trim();
    if (title.isEmpty) title = fallbackTitle.trim();
    if (title.isEmpty) return const AiPick.error('AI 未能识别出内容');
    if (title.length > 30) title = title.substring(0, 30);

    return AiPick(
      type: type,
      title: title,
      date: _strictDate(obj['date'] as String?, now ?? DateTime.now()),
      time: _strictTime(obj['time'] as String?),
      endTime: _strictTime(obj['endTime'] as String?),
      location: (obj['location'] as String? ?? '').trim(),
      items: _listItems(obj['items']),
    );
  }

  /// list 类型的拆分条目：只保留非空字符串，最多 8 条。
  static List<String> _listItems(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final e in raw) {
      if (e is String) {
        final s = e.trim();
        if (s.isNotEmpty && out.length < 8) out.add(s);
      }
    }
    return out;
  }

  static String _stripFences(String s) {
    if (!s.startsWith('```')) return s;
    return s
        .replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '')
        .replaceAll('```', '')
        .trim();
  }

  static Map<String, dynamic>? _tryDecodeObject(String s) {
    try {
      final v = jsonDecode(s);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
    } on FormatException {
      // 继续用首尾大括号兜底。
    }
    return null;
  }

  /// 把模型的类型别名归一成四种。
  static String _normalizeType(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'countdown':
      case 'anniversary':
      case 'birthday':
      case '倒数日':
      case '纪念日':
        return 'countdown';
      case 'habit':
      case '习惯':
        return 'habit';
      case 'list':
      case 'shopping':
      case 'todo':
      case '清单':
        return 'list';
      default:
        return 'plan';
    }
  }

  /// 测试连接：发一个最小的 chat/completions 请求（问一句 ping），
  /// 用于在设置页验证地址、模型与 Key，不要求 [AiConfig.enabled]。
  /// 返回的提示里不含 Key。
  static Future<AiTestResult> testConnection(AiConfig config) async {
    final baseUrl = config.baseUrl.trim();
    if (baseUrl.isEmpty) {
      return const AiTestResult.failure('请先填写接口地址');
    }
    final apiKey = config.apiKey.trim();
    if (apiKey.isEmpty) {
      return const AiTestResult.failure('请先填写 API Key');
    }
    final model =
        config.model.trim().isEmpty ? AiConfig.defaultModel : config.model.trim();
    final probe = AiConfig(
      enabled: true,
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKey,
    );
    if (probe.endpoint == null) {
      return const AiTestResult.failure(
          '接口地址格式不正确，需要以 http:// 或 https:// 开头');
    }
    try {
      final json = await _chatCompletion(
        probe,
        messages: const [
          {'role': 'user', 'content': 'ping'},
        ],
        temperature: 0,
        maxTokens: 8,
        extraBody: _isQwen(probe) ? const {'enable_thinking': false} : null,
        connectTimeout: const Duration(seconds: 10),
        responseTimeout: const Duration(seconds: 20),
      );
      final choices = json['choices'];
      if (choices is List && choices.isNotEmpty) {
        return AiTestResult.success('连接成功：$model 已能正常返回');
      }
      return const AiTestResult.failure(
          '接口可访问，但返回内容不含 choices，请确认是 OpenAI 兼容服务');
    } on _AiRequestException catch (e) {
      return AiTestResult.failure(e.message);
    } catch (_) {
      return const AiTestResult.failure('连接失败，请检查网络与接口地址');
    }
  }

  /// 请求一次 chat/completions（含 429/5xx/超时的两次退避重试）。
  static Future<Map<String, dynamic>> _chatCompletion(
    AiConfig config, {
    required List<Map<String, String>> messages,
    double temperature = 0.1,
    int? maxTokens,
    bool jsonMode = false,
    Map<String, Object?>? extraBody,
    Duration connectTimeout = _connectTimeout,
    Duration responseTimeout = _responseTimeout,
  }) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _chatOnce(
          config,
          messages: messages,
          temperature: temperature,
          maxTokens: maxTokens,
          jsonMode: jsonMode,
          extraBody: extraBody,
          connectTimeout: connectTimeout,
          responseTimeout: responseTimeout,
        );
      } on _AiRequestException catch (e) {
        if (!e.retryable || attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt + 1));
      }
    }
  }

  /// 单次请求，返回解析后的响应 JSON；失败抛 [_AiRequestException]。
  /// 消息中绝不含 Key。
  static Future<Map<String, dynamic>> _chatOnce(
    AiConfig config, {
    required List<Map<String, String>> messages,
    double temperature = 0.1,
    int? maxTokens,
    bool jsonMode = false,
    Map<String, Object?>? extraBody,
    Duration connectTimeout = _connectTimeout,
    Duration responseTimeout = _responseTimeout,
  }) async {
    final endpoint = config.endpoint;
    if (endpoint == null) {
      throw const _AiRequestException(
          '接口地址格式不正确，需要以 http:// 或 https:// 开头');
    }
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final req = await client.postUrl(endpoint).timeout(connectTimeout);
      req.headers.contentType = ContentType.json;
      req.headers.add('Authorization', 'Bearer ${config.apiKey}');
      final payload = <String, Object?>{
        'model': config.model,
        'messages': messages,
        'temperature': temperature,
      };
      if (maxTokens != null) payload['max_tokens'] = maxTokens;
      if (jsonMode) payload['response_format'] = const {'type': 'json_object'};
      if (extraBody != null) payload.addAll(extraBody);
      req.add(utf8.encode(jsonEncode(payload)));
      final res = await req.close().timeout(responseTimeout);
      final resText =
          await res.transform(utf8.decoder).join().timeout(_readTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw _AiRequestException(
            _httpError(res.statusCode, resText, config.apiKey),
            retryable: res.statusCode == 429 || res.statusCode >= 500);
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(resText);
      } on FormatException {
        throw const _AiRequestException('AI 服务返回内容无法解析');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const _AiRequestException('AI 服务返回内容无法解析');
      }
      return decoded;
    } on _AiRequestException {
      rethrow;
    } on TimeoutException {
      throw const _AiRequestException('AI 服务连接超时，请检查接口地址与网络',
          retryable: true);
    } catch (_) {
      throw const _AiRequestException('网络请求失败，请检查接口地址与网络',
          retryable: true);
    } finally {
      client.close();
    }
  }

  /// 把 HTTP 错误整理成用户可读的一句话；Key 一律打码。
  static String _httpError(int status, String body, String apiKey) {
    var detail = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          detail = (error['message'] as String).trim();
        } else if (error is String) {
          detail = error.trim();
        } else if (decoded['message'] is String) {
          detail = (decoded['message'] as String).trim();
        }
      }
    } on FormatException {
      // 非 JSON 错误体：只报状态码。
    }
    if (apiKey.isNotEmpty) detail = detail.replaceAll(apiKey, '***');
    if (detail.length > 120) detail = '${detail.substring(0, 120)}…';
    final hint = switch (status) {
      401 => '（Key 无效或未授权）',
      403 => '（无权限）',
      404 => '（接口地址或模型不存在）',
      429 => '（请求过于频繁或额度不足）',
      >= 500 => '（服务端异常）',
      _ => '',
    };
    return detail.isEmpty
        ? 'AI 服务返回错误（HTTP $status）$hint'
        : 'AI 服务返回错误（HTTP $status）$hint：$detail';
  }

  static final _dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _timeRe = RegExp(r'^\d{1,2}:\d{2}$');

  static String _strictDate(String? raw, DateTime now) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return '';
    if (_dateRe.hasMatch(s)) {
      final parts = s.split('-');
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      if (y == null || m == null || d == null) return '';
      final dt = DateTime(y, m, d);
      // DateTime 会把 13 月/40 日静默进位上一年/下一月，必须回读校验。
      if (dt.year != y || dt.month != m || dt.day != d) return '';
      return s;
    }
    // 模型偶尔直接回「今天/明天/后天」：兜底换算，其余不猜。
    final k = s.replaceAll(RegExp(r'[\s。，,.]'), '');
    final DateTime? d = switch (k) {
      '今天' || '今日' => now,
      '明天' || '明日' => now.add(const Duration(days: 1)),
      '后天' => now.add(const Duration(days: 2)),
      _ => null,
    };
    return d == null ? '' : '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static String _strictTime(String? raw) {
    final s = (raw ?? '').trim();
    if (!_timeRe.hasMatch(s)) return '';
    final parts = s.split(':');
    final h = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    return (h >= 0 && h < 24 && m >= 0 && m < 60)
        ? '${h.toString().padLeft(2, '0')}:${parts[1].padLeft(2, '0')}'
        : '';
  }
}

/// 请求失败原因（只含用户可读信息，不含 Key）。
class _AiRequestException implements Exception {
  const _AiRequestException(this.message, {this.retryable = false});

  final String message;

  /// 429/5xx/超时/网络错误可以退避重试。
  final bool retryable;
}

/// 测试连接结果。
class AiTestResult {
  const AiTestResult.success([this.message = '连接成功']) : ok = true;

  const AiTestResult.failure(this.message) : ok = false;

  final bool ok;
  final String message;
}

/// AI 识别结果；error 非 null 表示失败。
class AiPick {
  const AiPick({
    required this.type,
    required this.title,
    this.date = '',
    this.time = '',
    this.endTime = '',
    this.location = '',
    this.items = const [],
    this.message,
  });

  const AiPick.error(this.message)
      : type = '',
        title = '',
        date = '',
        time = '',
        endTime = '',
        location = '',
        items = const [];

  final String type;
  final String title;
  final String date;
  final String time;

  /// 时间段结束时间（HH:mm），没识别到为空。
  final String endTime;
  final String location;

  /// list 类型拆分出的条目；为空时用 title 作为单条。
  final List<String> items;

  /// 非 null 表示识别失败及原因。
  final String? message;
}