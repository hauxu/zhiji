/// 情侣同步服务配置，构建时通过 --dart-define 注入；
/// 未注入时同步功能不可用。构建参数见 README 与 build_local.ps1.example。
class SyncConfig {
  static const host = String.fromEnvironment('ZHIZI_SYNC_HOST');
  static const port = int.fromEnvironment('ZHIZI_SYNC_PORT', defaultValue: 8443);
  static const appKey = String.fromEnvironment('ZHIZI_SYNC_APPKEY');

  /// 服务端自签名证书指纹（SHA-256），用于证书锁定。
  static const certSha256 = String.fromEnvironment('ZHIZI_SYNC_CERT');

  /// 本地联调开关：允许指向 127.0.0.1 等内网地址（仅测试构建注入，
  /// 正式构建不设置，SSRF 防护保持全开）。
  static const allowLocal =
      bool.fromEnvironment('ZHIZI_ALLOW_LOCAL', defaultValue: false);

  static bool get isConfigured => host.isNotEmpty && appKey.isNotEmpty;

  static String get effectiveHost => host;
}
