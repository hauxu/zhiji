import 'dart:io';

import 'package:flutter/services.dart';

/// 把图片存进系统相册。
///
/// Android 侧走 MediaStore（10+）或公共 Pictures 目录（9 及以下），
/// 不需要读相册权限；其它平台返回 null，调用方自己处理。
class GallerySaver {
  GallerySaver._();

  static const _channel = MethodChannel('judging/gallery');

  /// 成功返回相册里的 uri/路径，失败返回 null。
  static Future<String?> saveImage(String path, {String? name}) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('saveImage', {
        'path': path,
        'name': name ?? path.split(Platform.pathSeparator).last,
      });
    } catch (_) {
      return null;
    }
  }
}