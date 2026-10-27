import 'dart:convert';
import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 天气获取：优先设备定位（需在设置中开启并授权），否则 IP 粗定位；
/// 再请求 Open-Meteo 免费 API，无需 key。
class WeatherService {
  WeatherService._();

  static String? _cachedWeather;
  static String? _cachedDate;

  /// 设置项：用设备定位取天气（关掉就走 IP 粗定位）。
  static const preciseKey = 'gd2_precise_weather';

  static Future<bool> _preciseEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(preciseKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 写入开关；返回关闭后的实际值（权限被拒时仍会开启，靠 IP 兜底）。
  static Future<void> setPreciseEnabled(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(preciseKey, value);
    } catch (_) {}
    invalidate();
  }

  /// 当前开关值，供设置页初始化。
  static Future<bool> preciseEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(preciseKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 设备定位；未授权、服务关闭或超时返回 null（调用方回退 IP）。
  static Future<(double, double)?> _deviceLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever ||
          perm == LocationPermission.unableToDetermine) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return (pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// IP 粗定位（主用 ipwho.is，回退 ipapi.co），各一次请求取回经纬度。
  static Future<(double, double)?> _ipLocation() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      for (final url in const ['https://ipwho.is/', 'https://ipapi.co/json/']) {
        final loc = await _fetchLatLng(client, url);
        if (loc != null) return loc;
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// 获取当日天气描述，如 "晴 23°C"。离线或失败返回 null。
  static Future<String?> getTodayWeather() async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (_cachedDate == today && _cachedWeather != null) return _cachedWeather;
    try {
      (double, double)? loc;
      if (await _preciseEnabled()) loc = await _deviceLocation();
      loc ??= await _ipLocation();
      if (loc == null) return null;
      final (lat, lon) = loc;

      final wxClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final wxReq = await wxClient
            .getUrl(Uri.parse('https://api.open-meteo.com/v1/forecast'
                '?latitude=$lat&longitude=$lon'
                '&current_weather=true'))
            .timeout(const Duration(seconds: 8));
        final wxRes = await wxReq.close().timeout(const Duration(seconds: 8));
        final wxBody = await wxRes.transform(utf8.decoder).join();
        final wxJson = jsonDecode(wxBody) as Map<String, dynamic>;
        final cw = wxJson['current_weather'] as Map<String, dynamic>?;
        if (cw == null) return null;
        final code = (cw['weathercode'] as num?)?.toInt() ?? 0;
        final temp = (cw['temperature'] as num?)?.round() ?? 0;
        _cachedWeather = '${_weatherCodeToCn(code)} $temp°C';
        _cachedDate = today;
        return _cachedWeather;
      } finally {
        wxClient.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// 清空按天缓存；精确定位开关变化后调用，下次进页面即按新方式取数。
  static void invalidate() {
    _cachedWeather = null;
    _cachedDate = null;
  }

  /// 设置开关里请求定位权限；返回是否已授权可用。
  static Future<bool> ensurePrecisePermission() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      return perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  static Future<(double, double)?> _fetchLatLng(
      HttpClient client, String url) async {
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      final res = await req.close().timeout(const Duration(seconds: 5));
      if (res.statusCode != 200 || res.contentLength > 1024 * 1024) return null;
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final lat = (json['latitude'] as num?)?.toDouble();
      final lon = (json['longitude'] as num?)?.toDouble();
      if (lat == null || lon == null) return null;
      return (lat, lon);
    } catch (_) {
      return null;
    }
  }

  static String _weatherCodeToCn(int code) {
    const map = {
      0: '晴', 1: '基本晴', 2: '多云', 3: '阴',
      45: '雾', 48: '雾凇',
      51: '毛毛雨', 53: '毛毛雨', 55: '毛毛雨',
      61: '小雨', 63: '中雨', 65: '大雨',
      71: '小雪', 73: '中雪', 75: '大雪',
      80: '阵雨', 81: '阵雨', 82: '强阵雨',
      95: '雷阵雨', 96: '雷阵雨', 99: '雷阵雨',
    };
    return map[code] ?? '天气';
  }
}
