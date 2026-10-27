// AI 助手配置：端点规范化、启用条件、本机存取往返。
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/ai/ai_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('endpoint 规范化：补 /chat/completions、去尾斜杠、拒绝非法地址', () {
    expect(AiConfig(baseUrl: 'https://api.x.com/v1/').endpoint.toString(),
        'https://api.x.com/v1/chat/completions');
    expect(
        AiConfig(baseUrl: 'https://api.x.com/v1/chat/completions')
            .endpoint
            .toString(),
        'https://api.x.com/v1/chat/completions');
    expect(AiConfig(baseUrl: 'ftp://api.x.com').endpoint, isNull);
    expect(AiConfig(baseUrl: 'not a url').endpoint, isNull);
  });

  test('isConfigured 需要启用 + Key + 地址齐全', () {
    expect(AiConfig().isConfigured, isFalse);
    expect(AiConfig(enabled: true, apiKey: 'k').isConfigured, isTrue);
    expect(AiConfig(enabled: false, apiKey: 'k').isConfigured, isFalse);
    expect(AiConfig(enabled: true).isConfigured, isFalse);
  });

  test('save/load 往返，API Key 去空白、空地址回落默认', () async {
    SharedPreferences.setMockInitialValues({});
    await AiConfig(
      enabled: true,
      baseUrl: '  ',
      model: '',
      apiKey: '  sk-test  ',
    ).save();
    final c = await AiConfig.load();
    expect(c.enabled, isTrue);
    expect(c.apiKey, 'sk-test');
    expect(c.baseUrl, AiConfig.defaultBaseUrl);
    expect(c.model, AiConfig.defaultModel);
    expect(AiConfig.cached.apiKey, 'sk-test');
  });
}