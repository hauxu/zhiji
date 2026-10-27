import 'package:shared_preferences/shared_preferences.dart';

/// AI 语义识别配置：运行时由用户在本机「我的 → AI 助手」填写，
/// 默认关闭；API Key 只保存在本机 SharedPreferences。
///
/// 这里是唯一读写 AI 配置的地方：不要在日志、异常信息里输出 [apiKey]。
class AiConfig {
  AiConfig({
    this.enabled = false,
    this.baseUrl = defaultBaseUrl,
    this.model = defaultModel,
    this.apiKey = '',
  });

  /// 默认接口地址（千问 AI 平台 MaaS 的 OpenAI 兼容入口）。
  static const defaultBaseUrl =
      'https://maas.qianwenaiapi.com/compatible-mode/v1';

  /// 默认模型名（千问 3.8 Flash）。
  static const defaultModel = 'qwen3.8-flash';

  static const _kEnabled = 'gd2_ai_enabled';
  static const _kBaseUrl = 'gd2_ai_base_url';
  static const _kModel = 'gd2_ai_model';
  static const _kApiKey = 'gd2_ai_api_key';

  /// 是否启用 AI 识别（默认关闭）。
  bool enabled;

  /// OpenAI 兼容接口的 baseUrl，如 https://api.openai.com/v1。
  String baseUrl;

  /// 模型名，如 gpt-4o-mini。
  String model;

  /// API Key，只存本机，不写日志、不进错误信息。
  String apiKey;

  /// 三项齐全才允许调用：启用 + Key + 接口地址。
  bool get isConfigured =>
      enabled && apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  /// chat/completions 的完整端点；地址非法时返回 null。
  ///
  /// 允许 baseUrl 以 `/` 结尾，也兼容用户直接粘贴完整端点。
  Uri? get endpoint {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.isEmpty) return null;
    final full = base.endsWith('/chat/completions')
        ? base
        : '$base/chat/completions';
    final uri = Uri.tryParse(full);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri;
  }

  /// 进程内缓存：UI 的 build 只读这里，不要在 build 里读 prefs。
  static AiConfig _cached = AiConfig();

  /// 最近一次 [load] / [save] 的配置；从未加载过时为默认值（关闭）。
  static AiConfig get cached => _cached;

  static String _cleanBaseUrl(String? raw) {
    final s = (raw ?? '').trim();
    return s.isEmpty ? defaultBaseUrl : s;
  }

  static String _cleanModel(String? raw) {
    final s = (raw ?? '').trim();
    return s.isEmpty ? defaultModel : s;
  }

  /// 从本机读取配置，并更新 [cached]。
  static Future<AiConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final cfg = AiConfig(
      enabled: prefs.getBool(_kEnabled) ?? false,
      baseUrl: _cleanBaseUrl(prefs.getString(_kBaseUrl)),
      model: _cleanModel(prefs.getString(_kModel)),
      apiKey: (prefs.getString(_kApiKey) ?? '').trim(),
    );
    _cached = cfg;
    return cfg;
  }

  /// 写入本机并更新 [cached]；地址/模型为空时回落默认值。
  Future<void> save() async {
    baseUrl = _cleanBaseUrl(baseUrl);
    model = _cleanModel(model);
    apiKey = apiKey.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
    await prefs.setString(_kBaseUrl, baseUrl);
    await prefs.setString(_kModel, model);
    await prefs.setString(_kApiKey, apiKey);
    _cached = this;
  }
}