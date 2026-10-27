import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../util/dates.dart';
import 'api.dart';
import 'couple_models.dart';
import 'keep_alive.dart';
import '../crypto/journal_crypto.dart';
import 'notify.dart';

enum CoupleStatus { unbound, waiting, bound }

// ---- PBKDF2 后台 isolate 派生 ----
// PBKDF2-HMAC-SHA256 在 AOT 下 100k≈0.8s、210k≈1.8s，跑在主 isolate 会卡住
// 界面；这里用 compute() 放到独立 isolate，主线程只等结果。
//
// 严禁改动 KDF 参数与 salt（恢复码：zhiji-journal-v1 + 100000；情侣密钥：
// 'zhiji-couple-v1:<双方账号 id>' + 210000），否则已发放的恢复码与云端历史
// 数据都解不开。worker 里直接调用 JournalCrypto 的派生函数，不另写一份。
//
// JournalCrypto 的同步派生 API 保留：isolate 起不来时回退主线程，单测也在用。

/// 通用 PBKDF2 派生（后台 isolate），返回 base64 密钥。
Future<String> pbkdf2Base64InIsolate(
    String secret, String salt, int iterations) async {
  try {
    return await compute(_pbkdf2Worker, <String>[secret, salt, '$iterations']);
  } catch (_) {
    // isolate 创建/通信失败时回退主线程派生，保证功能不中断。
    final key =
        await JournalCrypto.deriveKeyFromSecret(secret, salt, iterations);
    return JournalCrypto.keyToBase64(key);
  }
}

/// 恢复码派生（16 组数字 → 固定 zhiji-journal-v1/100000，后台 isolate）。
Future<String> recoveryKeyBase64InIsolate(String input) async {
  try {
    return await compute(_recoveryKeyWorker, input);
  } catch (_) {
    final key = await JournalCrypto.deriveKeyFromRecovery(input);
    return JournalCrypto.keyToBase64(key);
  }
}

Future<String> _pbkdf2Worker(List<String> args) async {
  final key = await JournalCrypto.deriveKeyFromSecret(
      args[0], args[1], int.parse(args[2]));
  return JournalCrypto.keyToBase64(key);
}

Future<String> _recoveryKeyWorker(String input) async {
  final key = await JournalCrypto.deriveKeyFromRecovery(input);
  return JournalCrypto.keyToBase64(key);
}

/// 同步链路健康度；由网络状态与最近一次同步结果推导。
enum SyncHealth { ok, syncing, offline, serverDown, authFailed, error }

class SyncService extends ChangeNotifier {
  SyncService(this._store);

  final AppStore _store;
  final Random _rng = Random.secure();
  Timer? _pollTimer;
  Timer? _pushDebounce;
  // 已读回执待上行：markSeen 时若有同步在途，本次结束后立刻短请求补发。
  bool _readReceiptPending = false;
  bool _syncing = false;
  // 本轮加密时发现共享密钥缺失：置位后放弃上传，防止明文共享包外泄。
  bool _sharedKeyMissing = false;
  bool _dirty = false;
  DateTime? _createGraceUntil;
  final Map<String, bool> _prevDoneState = {};
  final Map<String, int> _prevRecurCount = {};

  static const _baseForeground = Duration(seconds: 1);
  static const alarmCallbackId = 20260101;
  static const _baseBackground = Duration(seconds: 15);
  /// 保活服务在跑时的后台间隔：配合服务端 20s 长轮询，等效秒级抵达。
  static const _baseKeepAlive = Duration(seconds: 3);
  static const _baseBoard = Duration(seconds: 2);
  // 失败退避上限收紧：服务器恢复后最多 15/45 秒内自动回连。
  static const _maxBackoff = Duration(seconds: 45);
  // connectivity 误报 offline 时仍按此节奏试探。
  static const _offlineProbe = Duration(seconds: 30);
  static const _maxBackoffForeground = Duration(seconds: 15);
  /// 客户端版本：随 sync 请求上报；服务端在账号有加密备份时据此拒绝旧版 push。
  /// 发版时须与 pubspec.yaml 的 version 保持一致（只取 x.y.z）。
  static const clientVersion = '5.16.20';
  int _failStreak = 0; // 连续网络类失败次数，驱动指数退避
  bool _offline = false;
  bool _boardVisible = false;
  StreamSubscription<List<ConnectivityResult>>? _netSub;
  DateTime? _pushCooldownUntil; // 快照超限后暂停推送的截止时刻

  String? token;
  String? accountId;
  String username = '';
  String myName = '我';
  CoupleStatus status = CoupleStatus.unbound;
  String? roomId;
  int serverUpdatedAt = 0;
  String? partnerAccountId;
  String partnerName = 'TA';
  String? myCode;
  PartnerData? partner;
  List<CoupleComment> comments = [];
  List<CoupleMessage> messages = [];
  int lastSyncAt = 0;
  int cloudBackupAt = 0;
  String? lastError;
  int unseenCount = 0;
  int unreadMessages = 0;
  String journalKeyBase64 = '';

  /// 上一把数据密钥：生成新恢复码后保留，用于解开仍用旧密钥加密的云端数据。
  String journalKeyPrevBase64 = '';

  /// 本设备标识（多端分槽同步；首次生成后持久化）。
  String deviceId = '';

  /// 情侣共享密钥（由绑定码派生，仅存双方本机；解绑即弃）。
  String coupleKeyBase64 = '';

  /// 本机为当前配对生成的 X25519 协商密钥对（仅新配对生成；旧配对为空）。
  String _couplePrivB64 = '';
  String _couplePubB64 = '';

  /// 旧版（绑定码派生）密钥：升级为 X25519 后用于解密历史密文。
  String coupleKeyLegacyB64 = '';

  /// 快照里 shared 用的是哪把共享密钥。对端用哪把，我们下轮就跟着用哪把，
  /// 两边才能各自推各自的主密钥时仍然相互可读。
  String _peerSharedKid = '';

  /// 历史协商出来的其它共享密钥（只用于解密）。切换过密钥对以后，
  /// 对方可能还在用上一代，光有主密钥和一把备用不够用。
  final List<String> coupleKeyExtras = [];

  /// 用户是否已经当面核对过配对指纹。核对过就不再提示。
  bool pairFingerprintConfirmed = false;

  Future<void> confirmPairFingerprint() async {
    pairFingerprintConfirmed = true;
    await _persist();
    notifyListeners();
  }

  /// 配对指纹：把双方公钥排序后取哈希，两台设备算出来一样。
  /// 当面核对这串就能发现公钥在中途被换过。
  String get pairingFingerprint {
    final a = _couplePubB64;
    final b = _couplePeerPubPinned;
    if (a.isEmpty || b.isEmpty) return '';
    final pair = [a, b]..sort();
    final d = sha256.convert(utf8.encode('zhiji-pair:${pair.join('|')}')).bytes;
    final hex = d
        .take(4)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '${hex.substring(0, 4)}-${hex.substring(4)}';
  }

  /// 账号级长期身份密钥（Ed25519）。私钥只在本机/云备份里，
  /// 用来给上报的 X25519 公钥签名，服务端伪造不了。
  String _identityPrivB64 = '';
  String _identityPubB64 = '';

  /// 对方的身份公钥，以及是否已固定（TOFU）。
  String _peerIdentityPubB64 = '';
  bool identityKeyChanged = false;

  /// 双方身份公钥算出的安全码，用于当面核对。
  String get safetyNumber {
    if (_identityPubB64.isEmpty || _peerIdentityPubB64.isEmpty) return '';
    return JournalCrypto.safetyNumber(_identityPubB64, _peerIdentityPubB64);
  }

  Future<void> _ensureIdentityKeyPair() async {
    if (_identityPrivB64.isNotEmpty && _identityPubB64.isNotEmpty) return;
    try {
      final (priv, pub) = await JournalCrypto.generateIdentityKeyPair();
      _identityPrivB64 = priv;
      _identityPubB64 = pub;
      await _persist();
    } catch (_) {}
  }

  /// 绑定当时记下的对方公钥（TOFU）。之后对方公钥再变就不自动跟随了，
  /// 只标记出来让用户确认，防止伪造公钥把共享数据引到别人手上。
  String _couplePeerPubPinned = '';

  /// 对方公钥变过、还没被用户确认。
  bool peerKeyChanged = false;

  /// 上次同步时服务端提示过「只回了一部分」。
  bool lastSyncTruncated = false;

  /// 还要往前翻的游标：服务端截断时给的（时间戳 + 同一毫秒内的 id）。
  int _olderBeforeAt = 0;
  String _olderBeforeId = '';
  int _olderRounds = 0;

  /// 分页页里设备槽被裁剪过（说明本次快照不全）。
  bool lastSnapshotsTruncated = false;
  bool _snapshotRefetching = false;

  /// 共享密钥的短标识（取 sha256 前 6 字节），写进快照便于双方对齐。
  static String coupleKid(String keyB64) {
    final bytes = sha256.convert(utf8.encode(keyB64)).bytes;
    return bytes
        .take(6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
  /// 上一次协商用的对方公钥；对方换密钥对后要据此重算备用密钥。
  String _couplePeerPubB64 = '';

  /// 共享密钥版本：0/1 = 旧绑定码派生，2 = X25519 协商。
  int _coupleKeyVer = 0;

  int get coupleKeyVer => _coupleKeyVer;

  /// 快照超过该体积时走 gzip 上传通道（服务端解压后按 2 MB 上限校验）。
  static const int _snapshotGzThreshold = 192 * 1024;

  /// 情侣「纪念日」本名称（存房间，双方同步；空=默认「纪念日」）。
  String coupleBookName = '';

  /// 绑定码缓存：配对成功后用于派生情侣共享密钥。
  String _lastBindCode = '';
  String avatarPath = '';
  String recoveryCodesHash = '';
  String recoveryCodesPlain = '';
  bool _pendingUnlock = false; // 云端数据待解锁时抑制自动推送
  // 云端有加密备份但本机解不开：期间禁止一切上传，避免用本机（可能为空）
  // 的数据连同新密钥一起覆盖云端。恢复成功后才解除。
  bool _restoreBlocked = false;
  // 上次解绑请求失败（断网/服务端异常）：等下一轮 sync 补发，别自动绑回去。
  bool _unbindPending = false;
  int _roomRev = 0; // 已应用的房间变更版本（轻量轮询 since 游标）
  int _lastSyncPersistedAt = 0; // 上次把 lastSyncAt 写盘的时刻（节流用）
  int _lastPushAt = 0; // 最近一次真正上传成功的时刻（判断「这次推没推成」）
  int _bindEpoch = 0; // 解绑/清空时递增，作废在途同步结果
  bool _suppressStoreEvents = false; // 恢复替换数据期间抑制监听器
  bool _suppressNextPush = false; // 本地重置后不自动推送一次
  bool _foreground = true;
  String myAvatarDataUrl = '';
  String partnerAvatarPath = '';
  String partnerEmail = '';
  String partnerAvatarDataUrl = '';
  bool swTaskReminders = true;
  bool swCoupleMessages = true;
  bool swCoupleEvents = true;
  bool swMilestoneReminders = true;

  /// 习惯打卡提醒总开关（个体开关在 Habit.reminder）。
  bool swHabitReminders = true;

  /// 绑定完成的服务端时间戳；0=旧服务端未提供。
  int boundAt = 0;

  /// 双方共用的纪念日日期键；空=按绑定日计。
  String anniversary = '';

  void Function(CoupleEvent event)? onEvent;
  bool get isBound => status == CoupleStatus.bound;
  bool get isSyncing => _syncing;
  bool get loggedIn => token != null && accountId != null;

  /// 是否有未推送的本地改动。
  bool get hasPendingChanges => _dirty;

  /// 应用是否在前台（通知降扰判断用）。
  /// 桌面端（Windows）窗口收进托盘时置 true：人看不到界面，
  /// 该走的系统通知要走，不能当成"在前台"吞掉。
  bool desktopWindowHidden = false;

  bool get isForeground =>
      _foreground && !(Platform.isWindows && desktopWindowHidden);

  /// 自动备份开关：关闭后本地改动不自动上传，仅手动备份/恢复码等路径上传。
  bool autoBackup = true;

  /// TA 已读到的时间戳；此后自己发出的消息显示已读。
  int partnerReadAt = 0;

  /// 同步链路健康度：离线/服务器不可达时界面据此降级文案而非报错。
  SyncHealth get health {
    if (!loggedIn) return SyncHealth.authFailed;
    if (_syncing) return SyncHealth.syncing;
    if (_offline) return SyncHealth.offline;
    final err = lastError;
    if (err == null || err.isEmpty) return SyncHealth.ok;
    if (err.contains('登录已失效')) return SyncHealth.authFailed;
    if (SyncApi.isTransientMessage(err)) return SyncHealth.serverDown;
    return SyncHealth.error;
  }

  /// 状态一句话，供情侣页头部与备份卡显示。
  String get syncStatusLine {
    switch (health) {
      case SyncHealth.ok:
      case SyncHealth.syncing:
        return lastSyncAt == 0
            ? '等待首次同步…'
            : '上次同步 ${timeAgoCn(lastSyncAt)}';
      case SyncHealth.offline:
        if (!autoBackup) return '离线中 · 联网后仅同步拉取';
        return _dirty ? '离线中 · 改动已保存，联网后自动同步' : '离线中 · 联网后自动同步';
      case SyncHealth.serverDown:
        // 带上具体原因（安全连接失败/连接超时/网络不可用…），方便定位。
        final e = lastError ?? '';
        return lastSyncAt == 0
            ? '暂时连不上服务器 · $e'
            : '上次同步 ${timeAgoCn(lastSyncAt)} · $e，自动重试中';
      case SyncHealth.authFailed:
        return '登录已过期，重新登录后会自动恢复同步';
      case SyncHealth.error:
        return '同步出错：${lastError ?? '未知原因'}';
    }
  }

  @override
  void dispose() {
    _stopLoop();
    _netSub?.cancel();
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  // ---- init / persist ----

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString('gd2_token');
    accountId = prefs.getString('gd2_account_id');
    username = prefs.getString('gd2_username') ?? '';
    myName = prefs.getString('gd2_name') ?? '我';
    myCode = prefs.getString('gd2_mycode');
    roomId = prefs.getString('gd2_room_id');
    partnerAccountId = prefs.getString('gd2_partner_account');
    partnerName = prefs.getString('gd2_partner_name') ?? 'TA';
    lastSyncAt = prefs.getInt('gd2_last_sync') ?? 0;
    serverUpdatedAt = prefs.getInt('gd2_server_updated') ?? 0;
    cloudBackupAt = prefs.getInt('gd2_backup_at') ?? 0;
    journalKeyBase64 = prefs.getString('gd2_journal_key') ?? '';
    journalKeyPrevBase64 = prefs.getString('gd2_journal_key_prev') ?? '';
    deviceId = prefs.getString('gd2_device_id') ?? '';
    if (deviceId.length < 16) {
      deviceId = DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
          DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      unawaited(prefs.setString('gd2_device_id', deviceId));
    }
    coupleKeyBase64 = prefs.getString('gd2_couple_key') ?? '';
    _couplePrivB64 = prefs.getString('gd2_couple_priv') ?? '';
    _couplePubB64 = prefs.getString('gd2_couple_pub') ?? '';
    coupleKeyLegacyB64 = prefs.getString('gd2_couple_legacy') ?? '';
    _couplePeerPubB64 = prefs.getString('gd2_couple_peer_pub') ?? '';
    _peerSharedKid = prefs.getString('gd2_peer_shared_kid') ?? '';
    _couplePeerPubPinned = prefs.getString('gd2_peer_pub_pinned') ?? '';
    _identityPrivB64 = prefs.getString('gd2_identity_priv') ?? '';
    _identityPubB64 = prefs.getString('gd2_identity_pub') ?? '';
    _peerIdentityPubB64 =
        prefs.getString('gd2_peer_identity_pub') ?? '';
    identityKeyChanged =
        prefs.getBool('gd2_identity_key_changed') ?? false;
    peerKeyChanged = prefs.getBool('gd2_peer_key_changed') ?? false;
    pairFingerprintConfirmed =
        prefs.getBool('gd2_pair_fp_confirmed') ?? false;
    coupleKeyExtras
      ..clear()
      ..addAll(prefs.getStringList('gd2_couple_extras') ?? const []);
    _coupleKeyVer = prefs.getInt('gd2_couple_key_ver') ?? 0;
    coupleBookName = prefs.getString('gd2_couple_book_name') ?? '';
    _dirty = prefs.getBool('gd2_dirty') ?? false;
    _lastBindCode = prefs.getString('gd2_last_bind_code') ?? '';
    avatarPath = prefs.getString('gd2_avatar_path') ?? '';
    recoveryCodesHash = prefs.getString('gd2_recovery_hash') ?? '';
    // 恢复码明文只在当前会话可查看。
    recoveryCodesPlain = '';
    unawaited(prefs.remove('gd2_recovery_codes'));
    myAvatarDataUrl = prefs.getString('gd2_avatar_data') ?? '';
    partnerAvatarPath = prefs.getString('gd2_partner_avatar') ?? '';
    partnerEmail = prefs.getString('gd2_partner_email') ?? '';
    partnerAvatarDataUrl = prefs.getString('gd2_partner_avatar_data') ?? '';
    // 设置页已去掉这些开关：功能恒开，忽略历史存下的 false。
    swTaskReminders = true;
    swCoupleMessages = true;
    swCoupleEvents = true;
    swMilestoneReminders = true;
    swHabitReminders = true;
    Notify.instance.coupleMessagesEnabled = true;
    Notify.instance.coupleEventsEnabled = true;
    boundAt = prefs.getInt('gd2_bound_at') ?? 0;
    partnerReadAt = prefs.getInt('gd2_partner_read_at') ?? 0;
    // 自动备份恒开（设置页已去掉开关，忽略历史 false）。
    autoBackup = true;
    anniversary = prefs.getString('gd2_anniversary') ?? '';
    partner = _loadJson(prefs, 'gd2_partner', PartnerData.fromJson);
    comments = _loadList(prefs, 'gd2_comments', CoupleComment.fromJson);
    messages = _loadList(prefs, 'gd2_messages', CoupleMessage.fromJson);
    await _loadMsgArchive();
    unseenCount = prefs.getInt('gd2_unseen') ?? 0;
    unreadMessages = prefs.getInt('gd2_unread_msg') ?? 0;
    _pendingUnlock = prefs.getBool('gd2_pending_unlock') ?? false;
    _restoreBlocked = prefs.getBool('gd2_restore_blocked') ?? false;
    _unbindPending = prefs.getBool('gd2_unbind_pending') ?? false;
    _resolveStatus();
    // 已登录即开轮询：未配对也保持低频 sync（15s），服务端若已有
    // 历史房间（换设备/重装登录）会经认领分支自动恢复绑定。
    //
    // 后台引擎例外：它只在界面引擎死后接管轮询（见 keepalive_entry.dart），
    // 这里不能再起一份，否则两边同时长轮询、同一条消息弹两次通知。
    if (loggedIn && !headless) {
      _startLoop();
      _store.addListener(_onStoreChanged);
      if (isBound) _seedPrevDoneState();
      // 冷启动时进程一定在前台；保活服务留到真正退后台再拉起，
      // 但若上次是被系统杀进程（有会话无前台），这里补一次自恢复。
      unawaited(syncKeepAliveWithSession());
    }
    _watchNetwork();
    notifyListeners();
  }

  void _resolveStatus() {
    if (!loggedIn || roomId == null) {
      status = CoupleStatus.unbound;
    } else if (partnerAccountId != null) {
      status = CoupleStatus.bound;
    } else {
      status = CoupleStatus.waiting;
    }
  }

  static T? _loadJson<T>(SharedPreferences prefs, String key,
      T Function(Map<String, dynamic>) from) {
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      if (v is Map) return from(Map<String, dynamic>.from(v));
    } catch (_) {}
    return null;
  }

  static List<T> _loadList<T>(SharedPreferences prefs, String key,
      T Function(Map<String, dynamic>) from) {
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      final v = jsonDecode(raw);
      if (v is List) {
        return v.whereType<Map>().map((e) => from(Map<String, dynamic>.from(e))).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    Future<void> put(String key, String? value) async {
      if (value != null) { await prefs.setString(key, value); } else { await prefs.remove(key); }
    }
    await put('gd2_token', token);
    await put('gd2_account_id', accountId);
    await put('gd2_username', username.isEmpty ? null : username);
    await put('gd2_name', myName);
    await put('gd2_mycode', myCode);
    await put('gd2_room_id', roomId);
    await put('gd2_partner_account', partnerAccountId);
    await prefs.setString('gd2_partner_name', partnerName);
    await prefs.setInt('gd2_last_sync', lastSyncAt);
    await prefs.setInt('gd2_server_updated', serverUpdatedAt);
    await prefs.setInt('gd2_backup_at', cloudBackupAt);
    await prefs.setString('gd2_journal_key', journalKeyBase64);
    await prefs.setString('gd2_journal_key_prev', journalKeyPrevBase64);
    if (coupleKeyBase64.isNotEmpty) {
      await prefs.setString('gd2_couple_key', coupleKeyBase64);
    } else {
      await prefs.remove('gd2_couple_key');
    }
    await put('gd2_couple_priv', _couplePrivB64.isEmpty ? null : _couplePrivB64);
    await put('gd2_couple_pub', _couplePubB64.isEmpty ? null : _couplePubB64);
    await put(
        'gd2_couple_legacy',
        coupleKeyLegacyB64.isEmpty ? null : coupleKeyLegacyB64);
    if (_couplePeerPubB64.isEmpty) {
      await prefs.remove('gd2_couple_peer_pub');
    } else {
      await prefs.setString('gd2_couple_peer_pub', _couplePeerPubB64);
    }
    if (_identityPrivB64.isEmpty) {
      await prefs.remove('gd2_identity_priv');
    } else {
      await prefs.setString('gd2_identity_priv', _identityPrivB64);
    }
    if (_identityPubB64.isEmpty) {
      await prefs.remove('gd2_identity_pub');
    } else {
      await prefs.setString('gd2_identity_pub', _identityPubB64);
    }
    if (_peerIdentityPubB64.isEmpty) {
      await prefs.remove('gd2_peer_identity_pub');
    } else {
      await prefs.setString('gd2_peer_identity_pub', _peerIdentityPubB64);
    }
    await prefs.setBool('gd2_identity_key_changed', identityKeyChanged);
    if (_couplePeerPubPinned.isEmpty) {
      await prefs.remove('gd2_peer_pub_pinned');
    } else {
      await prefs.setString('gd2_peer_pub_pinned', _couplePeerPubPinned);
    }
    await prefs.setBool('gd2_peer_key_changed', peerKeyChanged);
    await prefs.setBool(
        'gd2_pair_fp_confirmed', pairFingerprintConfirmed);
    if (_peerSharedKid.isEmpty) {
      await prefs.remove('gd2_peer_shared_kid');
    } else {
      await prefs.setString('gd2_peer_shared_kid', _peerSharedKid);
    }
    if (coupleKeyExtras.isEmpty) {
      await prefs.remove('gd2_couple_extras');
    } else {
      await prefs.setStringList('gd2_couple_extras', coupleKeyExtras);
    }
    if (_coupleKeyVer > 0) {
      await prefs.setInt('gd2_couple_key_ver', _coupleKeyVer);
    } else {
      await prefs.remove('gd2_couple_key_ver');
    }
    await prefs.setString('gd2_couple_book_name', coupleBookName);
    await prefs.setBool('gd2_dirty', _dirty);
    await prefs.setString('gd2_avatar_path', avatarPath);
    await prefs.setString('gd2_recovery_hash', recoveryCodesHash);
    await prefs.remove('gd2_recovery_codes');
    await prefs.setString('gd2_avatar_data', myAvatarDataUrl);
    await prefs.setString('gd2_partner_avatar', partnerAvatarPath);
    await prefs.setString('gd2_partner_email', partnerEmail);
    await prefs.setBool('gd2_sw_task', swTaskReminders);
    await prefs.setBool('gd2_sw_msg', swCoupleMessages);
    await prefs.setBool('gd2_sw_event', swCoupleEvents);
    await prefs.setBool('gd2_sw_ms', swMilestoneReminders);
    await prefs.setBool('gd2_sw_habit', swHabitReminders);
    await prefs.setInt('gd2_bound_at', boundAt);
    await prefs.setInt('gd2_partner_read_at', partnerReadAt);
    await prefs.setBool('gd2_auto_backup', autoBackup);
    await prefs.setString('gd2_anniversary', anniversary);
    if (partner != null) {
      await prefs.setString('gd2_partner', jsonEncode(partner!.toJson()));
    } else { await prefs.remove('gd2_partner'); }
    await prefs.setString('gd2_comments',
        jsonEncode(comments.take(300).map((c) => c.toJson()).toList()));
    await prefs.setString('gd2_messages',
        jsonEncode(messages.length > 2000
            ? messages.sublist(messages.length - 500).map((m) => m.toJson()).toList()
            : messages.map((m) => m.toJson()).toList()));
    await prefs.setInt('gd2_unseen', unseenCount);
    await prefs.setInt('gd2_unread_msg', unreadMessages);
    await prefs.setBool('gd2_pending_unlock', _pendingUnlock);
    await prefs.setBool('gd2_restore_blocked', _restoreBlocked);
    await prefs.setBool('gd2_unbind_pending', _unbindPending);
  }

  // ---- auth ----

  Future<bool> requestCode(String email) async {
    try {
      await SyncApi.post('requestCode', {'username': email.trim()});
      lastError = null; notifyListeners(); return true;
    } on SyncException catch (e) { lastError = e.message; notifyListeners(); return false; }
  }

  Future<void> register(String email, String password,
      {required String code, String? nickname}) async {
    await _auth('register', email, password, code: code, nickname: nickname);
  }

  Future<void> login(String email, String password) async {
    await _auth('login', email, password);
  }

  Future<void> _auth(String action, String email, String password,
      {String? code, String? nickname}) async {
    try {
      final result = await SyncApi.post(action, {
        'username': email.trim(), 'password': password,
        'code': code ?? '',
        'name': nickname ?? '',
        // 登录就把设备报上去：服务端据此认定「当前设备」，
        // 免得设备管理页在新登录、还没同步之前没有记录。
        'device': deviceId,
      });
      token = result['token'] as String?;
      accountId = result['accountId'] as String?;
      username = (result['username'] as String?) ?? email.trim();
      myName = (result['name'] as String?) ??
          (nickname != null && nickname.trim().isNotEmpty ? nickname.trim() : email.trim().split('@').first);
      lastError = null;
      await _persist();
      // 云端头像落地，本地头像上传。
      final serverAvatar = (result['avatar'] as String?) ?? '';
      if (serverAvatar.isNotEmpty) {
        await _storeDataUrlAsAvatar(serverAvatar);
      } else if (avatarPath.isNotEmpty && File(avatarPath).existsSync()) {
        await pushAvatarFile(avatarPath);
      }
      // 登录后先全量拉取，历史不弹事件。
      _roomRev = 0;
      _softLogoutDone = false;
      _historyAdopted = false;
      _suppressNextPush = false;
      _dirty = false; // 清掉登出前残留的待推送标记
      await syncNow(push: false);
      _startLoop(); _seedPrevDoneState();
      _attachStoreListener();
      unawaited(syncKeepAliveWithSession());
      onEvent?.call(CoupleEvent('登录成功', '欢迎你，$username', route: 'couple'));
    } on SyncException catch (e) { lastError = e.message; }
    notifyListeners();
  }

  bool _softLogoutDone = false;
  bool _historyAdopted = false; // 首次同步静默采纳历史

  /// 软登出：保留本地数据、数据密钥与情侣共享密钥
  /// （房间仍在服务端，重新登录后快照仍需 coupleKey 解密）。
  Future<void> _softLogout(String reason) async {
    _stopLoop(); _store.removeListener(_onStoreChanged);
    _clearCoupleLocally(keepCoupleKey: true);
    _historyAdopted = false;
    _suppressNextPush = false;
    _dirty = false;
    // 换账号后云端备份是另一份，旧的封锁状态与暂存密文不能带过去。
    _pendingUnlock = false;
    _restoreBlocked = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('gd2_locked_journal');
      await prefs.remove('gd2_pending_couple_key_enc');
      await prefs.remove('gd2_pending_couple_legacy_enc');
    } catch (_) {}
    token = null; accountId = null; username = '';
    lastError = null;
    _softLogoutDone = false; // 重新登录后允许再次触发
    await _persist(); notifyListeners();
    onEvent?.call(CoupleEvent(reason, '本地数据已保留，重新登录后会自动恢复同步'));
  }

  Future<void> logout() async {
    _historyAdopted = false;
    _dirty = false;
    // 先解绑再登出。
    if (roomId != null) {
      try { await SyncApi.post('unbind', {'token': token}); } on SyncException catch (_) {}
    }
    if (token != null) {
      try { await SyncApi.post('logout', {'token': token}); } on SyncException catch (_) {}
    }
    _stopLoop(); _store.removeListener(_onStoreChanged);
    _clearCoupleLocally();
    token = null; accountId = null; username = '';
    // 清理账号级数据：数据密钥/恢复码/头像。
    // 密钥另存到 last 键供解锁预填。
    try {
      final prefs = await SharedPreferences.getInstance();
      if (journalKeyBase64.isNotEmpty) {
        await prefs.setString('gd2_journal_key_last', journalKeyBase64);
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      // 上一账号的待解锁密文不能留给下一个账号。
      await prefs.remove('gd2_locked_journal');
      await prefs.remove('gd2_pending_couple_key_enc');
      await prefs.remove('gd2_pending_couple_legacy_enc');
    } catch (_) {}
    journalKeyBase64 = '';
    journalKeyPrevBase64 = '';
    _pendingUnlock = false;
    _restoreBlocked = false;
    recoveryCodesHash = '';
    recoveryCodesPlain = '';
    avatarPath = '';
    myAvatarDataUrl = '';
    partnerAvatarPath = '';
    partnerEmail = '';
    _keepAliveActive = false;
    await KeepAliveBridge.stop();
    await _persist(); notifyListeners();
  }

  // ---- binding ----

  Future<void> ensureMyCode() async {
    if (!loggedIn || isBound) return;
    if (status == CoupleStatus.waiting && myCode != null) { notifyListeners(); return; }
    try {
      await _ensureCoupleKeyPair();
      await _ensureIdentityKeyPair();
      final result = await SyncApi.post('createRoom',
          {'token': token, 'name': myName, 'pubKey': _couplePubB64});
      myCode = (result['code'] as String?) ?? myCode;
      // 绑定码缓存：配对成功后用于派生情侣共享密钥（本机保留）。
      if (myCode != null) _lastBindCode = myCode!;
      unawaited((await SharedPreferences.getInstance())
          .setString('gd2_last_bind_code', _lastBindCode));
      roomId = result['roomId'] as String?;
      status = CoupleStatus.waiting; lastError = null;
      _createGraceUntil = DateTime.now().add(const Duration(seconds: 20));
      await _persist();
    } on SyncException catch (e) {
      lastError = e.message;
      // 服务端已有房间（换设备/重装登录后未认领）：拉一次全量
      // 走认领分支自动恢复绑定，而不是反复报错。
      if (e.message.contains('请先解除')) {
        await syncNow(push: false);
      }
    }
    _startLoop();
    notifyListeners();
  }

  Future<void> join(String code) async {
    if (!loggedIn) return;
    final trimmed = code.trim().toUpperCase();
    if (trimmed.isEmpty) return;
    try {
      await _ensureCoupleKeyPair();
      await _ensureIdentityKeyPair();
      final result = await SyncApi.post('joinRoom',
          {'token': token, 'code': trimmed, 'name': myName,
           'pubKey': _couplePubB64});
      roomId = result['roomId'] as String?;
      partnerAccountId = result['partnerAccountId'] as String?;
      partnerName = (result['partnerName'] as String?) ?? 'TA';
      final boundMs = result['boundAt'];
      if (boundMs is int) boundAt = boundMs;
      myCode = null; status = CoupleStatus.bound; lastError = null;
      _unbindPending = false;
      unseenCount = 0; unreadMessages = 0; partner = null;
      _roomRev = 0; // 新房间从头拉全量
      _seedPrevDoneState(); // 绑定后首次完成也上报
      // 情侣共享密钥：由双方共知的绑定码在本地派生，不经网络传输。
      _lastBindCode = trimmed;
      final bindPrefs = await SharedPreferences.getInstance();
      await bindPrefs.setString('gd2_last_bind_code', _lastBindCode);
      await _deriveCoupleKey();
      await _persist();
      _attachStoreListener();
      // 换绑/重新绑定后必须恢复轮询（SyncService 只在失败恢复时才自动重启）。
      _startLoop();
      unawaited(syncKeepAliveWithSession());
      onEvent?.call(CoupleEvent('绑定成功', '你和 $partnerName 的内容开始同步了'));
      onEvent?.call(CoupleEvent('设备确认码', deviceVerifyCode));
      // 绑定是显式动作：即使关闭自动备份也要把首轮快照送上去。
      await syncNow(push: true, manual: true);
      return;
    } on SyncException catch (e) { lastError = e.message; }
    notifyListeners();
  }

  Future<void> unbind() async {
    if (roomId != null) {
      try {
        await SyncApi.post('unbind', {'token': token});
        _unbindPending = false;
      } on SyncException catch (_) {
        // 断网/服务端失败：标记待重试，否则下一轮 sync 会把用户自动绑回去。
        _unbindPending = true;
      }
    }
    _stopLoop(); _store.removeListener(_onStoreChanged); _clearCoupleLocally();
    coupleKeyBase64 = '';
    _lastBindCode = '';
    _keepAliveActive = false;
    await KeepAliveBridge.stop();
    // 解绑后本机设备槽里还是用共享密钥加密的旧快照：不重推一份个人密钥版，
    // 下一轮拉取会解不开，被守卫误判成「云端数据锁住了」，自动备份就停了。
    _dirty = true;
    _restoreBlocked = false;
    // 解绑后伴侣的待解锁密文与暂存的共享密钥都没有意义了，一并清掉，
    // 否则会一直卡在「备份未解锁」。
    _pendingUnlock = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('gd2_locked_journal');
      await prefs.remove('gd2_pending_couple_key_enc');
      await prefs.remove('gd2_pending_couple_legacy_enc');
    } catch (_) {}
    await _persist(); notifyListeners();
    unawaited(syncNow(push: true, manual: true));
  }

  /// 补发上次失败的解绑请求。
  Future<void> _retryUnbind() async {
    if (!loggedIn) return;
    try {
      await SyncApi.post('unbind', {'token': token});
      _unbindPending = false;
      await _persist();
      notifyListeners();
    } on SyncException catch (_) {}
  }

  /// 抑制下下一次本地变更的自动推送（本地重置为种子数据时用）。
  void suppressNextPush() { _suppressNextPush = true; }

  void _clearCoupleLocally({bool keepCoupleKey = false}) {
    roomId = null; partnerAccountId = null; myCode = null; partner = null;
    // 软登出保留共享密钥与绑定码：房间未销毁，重新登录后解密依赖它们。
    if (!keepCoupleKey) {
      coupleKeyBase64 = ''; _lastBindCode = '';
      _couplePrivB64 = ''; _couplePubB64 = '';
      coupleKeyLegacyB64 = ''; _coupleKeyVer = 0; _couplePeerPubB64 = '';
      coupleKeyExtras.clear(); _peerSharedKid = '';
      _couplePeerPubPinned = ''; peerKeyChanged = false;
      _peerIdentityPubB64 = ''; identityKeyChanged = false;
      pairFingerprintConfirmed = false;
    }
    comments = []; messages = []; status = CoupleStatus.unbound;
    lastSyncAt = 0; unseenCount = 0; unreadMessages = 0;
    partnerAvatarPath = ''; partnerAvatarDataUrl = ''; partnerEmail = '';
    boundAt = 0; anniversary = '';
    _roomRev = 0;
    _bindEpoch++;
  }

  // ---- sync ----

  /// 云端数据待解锁时抑制自动推送。
  bool get pendingUnlock => _pendingUnlock;

  /// 云端有加密备份但本机解不开：此时自动备份暂停，等一次成功恢复。
  bool get restoreBlocked => _restoreBlocked;

  /// 轮询间隔：留言板可见 2s；前台配合长轮询 1s 重连、后台 15s。
  /// 保活服务运行时后台也用 3s（配合服务端长轮询，等效秒级）。
  /// 网络类失败逐次翻倍，前台封顶 15s、后台封顶 45s。
  static Duration pollInterval(
      {required bool foreground,
      required int failStreak,
      bool boardVisible = false,
      bool keepAlive = false}) {
    final base = boardVisible
        ? _baseBoard
        : (foreground ? _baseForeground : (keepAlive ? _baseKeepAlive : _baseBackground));
    if (failStreak <= 0) return base;
    final factor = 1 << (failStreak > 5 ? 5 : failStreak);
    final ms = base.inMilliseconds * factor;
    final cap = foreground ? _maxBackoffForeground : _maxBackoff;
    return ms >= cap.inMilliseconds ? cap : Duration(milliseconds: ms);
  }

  /// 已读回执上报值：留言未读清零、留言板可见且前台才算「真的看到了」。
  /// 只看未读计数会误报——冷启动首同步静默采纳、后台闹钟都没真正展示消息。
  /// 只按未读留言判断：评价/完成动态（unseenCount）不该挡住留言已读。
  static int? readUpToValue({
    required int unreadMessages,
    required bool boardVisible,
    required bool foreground,
    required int lastMessageAt,
  }) {
    if (unreadMessages != 0) return null;
    if (!boardVisible || !foreground) return null;
    return lastMessageAt > 0 ? lastMessageAt : null;
  }

  /// 前台长轮询实时同步；退后台由常驻保活服务继续长轮询，
  /// 保活被关闭或系统不给跑时退回 15s 短同步 + 精确闹钟兜底。
  void setForeground(bool fg) {
    if (_foreground == fg) return;
    _foreground = fg;
    if (loggedIn) _startLoop();
    _setAlarmEnabled(!fg);
  }

  /// 保活服务是否在跑（在跑时后台也走长轮询）。
  bool _keepAliveActive = false;

  /// 当前实例是否跑在保活服务的后台引擎里（见 keepalive_entry.dart）。
  static bool headless = false;

  /// 主引擎心跳：后台引擎据此判断「界面还活着吗」，避免双份轮询。
  static int _lastBeatAt = 0;

  static Future<void> _beat() async {
    if (headless) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBeatAt < 10000) return;
    _lastBeatAt = now;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('gd2_main_beat', now);
    } catch (_) {}
  }

  /// 主引擎是否仍活着（后台引擎用）。45 秒没心跳视为已销毁。
  static Future<bool> mainEngineAlive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final beat = prefs.getInt('gd2_main_beat') ?? 0;
      if (beat <= 0) return false;
      return DateTime.now().millisecondsSinceEpoch - beat < 45000;
    } catch (_) {
      return false;
    }
  }

  /// 立即按当前状态启停保活。
  /// 保活常驻（而非只在退后台时拉起）是刻意的：Android 12+ 不允许
  /// 从后台启动前台服务，而「从最近任务划掉 App」时进程已无任何回调
  /// 时机；只有一直在跑的 START_STICKY 服务才可能在划掉后继续收消息。
  Future<void> _syncKeepAlive() async {
    if (!Platform.isAndroid) return;
    final shouldRun = KeepAliveBridge.enabled && loggedIn && isBound;
    if (shouldRun == _keepAliveActive) return;
    _keepAliveActive = shouldRun;
    if (shouldRun) {
      await KeepAliveBridge.start();
    } else {
      await KeepAliveBridge.stop();
    }
  }

  /// 退后台或进程被系统结束后的兜底：精确闹钟唤醒后台 isolate 轻量同步。
  /// 保活服务负责秒级送达；闹钟兜住「保活被系统或用户干掉」的情况，
  /// 周期保持 2 分钟——保活活着时它只是多唤醒一次，代价可接受。
  static const _alarmPeriodic = Duration(minutes: 2);

  /// 会话状态变化（登录/绑定/解绑/退出）后重算保活与轮询。
  Future<void> syncKeepAliveWithSession() async {
    if (!Platform.isAndroid) return;
    await _syncKeepAlive();
    if (loggedIn) {
      _startLoop();
      _setAlarmEnabled(true);
    }
  }

  /// 设置页开关切换后调用：立即按新开关生效。
  Future<void> applyKeepAliveSetting(bool enabled) async {
    await KeepAliveBridge.setEnabled(enabled);
    await _syncKeepAlive();
    if (loggedIn) _setAlarmEnabled(true);
  }

  Future<void> _setAlarmEnabled(bool on) async {
    if (!loggedIn) return;
    // 精确闹钟被拒（Android 14+ 新装默认拒绝）时降级为非精确——
    // 兜底同步晚几分钟到，也远好于静默丢失。
    var exact = true;
    try {
      final canExact = await Notify.instance.plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.canScheduleExactNotifications();
      if (canExact == false) exact = false;
    } catch (_) {}
    try {
      if (on) {
        await AndroidAlarmManager.periodic(
          _alarmPeriodic,
          alarmCallbackId,
          backgroundSyncAlarmEntry,
          allowWhileIdle: true,
          exact: exact,
          wakeup: true,
          rescheduleOnReboot: true,
        );
      } else {
        await AndroidAlarmManager.cancel(alarmCallbackId);
      }
    } catch (_) {}
  }

  /// 弹过的通知记在 prefs 里：主引擎和保活引擎是两个 isolate，同一条留言
  /// 会各收到一次，第二个据此跳过，避免通知栏出现两条一样的通知。
  /// 已通知过就返回 true，没通知过则登记并返回 false。
  ///
  /// 主引擎和闹钟引擎各自跑在独立进程里，用 SharedPreferences 读改写会互相
  /// 覆盖（两边同时读、各自加一条、后写的赢）。改成"一个 key 一个空文件"：
  /// 创建文件是原子操作，谁创建成功谁弹通知，天然没有竞态。
  Future<bool> _alreadyNotified(String key) async {
    try {
      final dir = await _notifiedDir();
      final name = sha1.convert(utf8.encode(key)).toString();
      final f = File('${dir.path}/$name');
      try {
        // exclusive 才是原子创建：两个引擎同时抢，只有一个成功，
        // 另一个拿到 EEXIST，按"已经通知过"处理，不会弹两条。
        await f.create(exclusive: true);
      } on FileSystemException catch (e) {
        // 只有"文件已存在"才算通知过；磁盘满/权限/文件名过长这些异常
        // 说明标记根本没写成，这时宁可多弹一次，也别把通知吞掉。
        final code = e.osError?.errorCode;
        if (code == 17 || code == 80 || code == 183) return true;
        return false;
      }
      // 顺手清掉两小时前的标记：一条通知的时效远小于这个值。
      _pruneNotified(dir);
      return false;
    } catch (_) {
      return false;
    }
  }

  Directory? _notifiedDirCache;

  Future<Directory> _notifiedDir() async {
    final cached = _notifiedDirCache;
    if (cached != null && await cached.exists()) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/notified');
    if (!await dir.exists()) await dir.create(recursive: true);
    _notifiedDirCache = dir;
    return dir;
  }

  /// 清理过期标记。失败无所谓，下次还会清。
  void _pruneNotified(Directory dir) {
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    unawaited(() async {
      try {
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final st = await e.stat();
          if (st.modified.millisecondsSinceEpoch < cutoff) {
            await e.delete();
          }
        }
      } catch (_) {}
    }());
  }

  /// 后台弹情侣通知（主引擎与保活引擎共用），同一个事件只弹一次。
  Future<bool> notifyCoupleEventOnce(CoupleEvent event, {String? dedupKey}) async {
    // 有稳定 id 就用 id：同一条消息重复文本也要各弹一次；
    // 没有 id 的系统事件才退回按内容去重。
    final key = event.dedupKey ?? dedupKey ?? 'evt:${event.title}:${event.body}';
    if (await _alreadyNotified(key)) return false;
    if (event.isMessage) {
      await Notify.instance.showCoupleMessage(event.title, event.body,
          dedupKey: key);
    } else {
      await Notify.instance.showCoupleEvent(event.title, event.body,
          dedupKey: key);
    }
    return true;
  }

  /// 闹钟回调（后台 isolate）：拉取一次，把留言与评价动态弹成系统通知。
  /// 任务/倒数日/习惯的到点提醒由本地精确闹钟调度，不经过这里。
  Future<void> alarmTick() async {
    if (!loggedIn || _syncing) return;
    // 主引擎活着时它自己会弹通知；这里再弹一次就是两条。
    if (await SyncService.mainEngineAlive()) return;
    final beforeMsgAt = messages.isEmpty ? 0 : messages.last.createdAt;
    final beforeCommentIds = comments.map((c) => c.id).toSet();
    try {
      await syncNow(push: _dirty);
    } catch (_) {
      return;
    }
    if (!isBound) return;
    // syncNow 内部已经通过 onEvent 把新留言/评价弹过了（界面引擎与保活
    // 引擎都挂了 onEvent）。只有独立的闹钟 isolate 没有 onEvent，
    // 才需要在这里自己弹——否则同一条留言会弹两三次。
    if (onEvent == null) {
      final fresh = messages
          .where((m) =>
              !m.isSystem &&
              m.byAccountId != accountId &&
              m.byAccountId == partnerAccountId &&
              m.createdAt > beforeMsgAt)
          .toList();
      var notifiedMessages = 0;
      for (final m in fresh.take(3)) {
        if (await _alreadyNotified('msg:${m.id}')) continue;
        await Notify.instance.showCoupleMessage(partnerName, m.text,
            dedupKey: 'msg:${m.id}');
        notifiedMessages++;
      }
      final newComments = comments
          .where((c) =>
              !beforeCommentIds.contains(c.id) &&
              c.byAccountId == partnerAccountId)
          .take(3)
          .toList();
      var notifiedComments = 0;
      for (final c in newComments) {
        final what = switch (c.targetKind) {
          kindJournal => '日记',
          kindHabit => '习惯',
          _ => '任务',
        };
        final body = c.kind == 'emoji'
            ? '${reactionLabel(c.emoji)} 了你的$what'
            : (c.text.isEmpty ? '点击查看' : c.text);
        final shown = await notifyCoupleEventOnce(
            CoupleEvent('$partnerName 评价了你的$what', body),
            dedupKey: 'cmt:${c.id}');
        if (shown) notifiedComments++;
      }
      final notified = notifiedMessages + notifiedComments;
      if (notified == 0) return;
      // 只把「已经弹出来」的那几条算已读：take(3) 之外的留言/评价仍在
      // 未读里，留到下次开 App 或下轮再弹，不能静默清 0。
      if (unreadMessages > 0) {
        if (unreadMessages > notifiedMessages) {
          unreadMessages -= notifiedMessages;
        } else {
          unreadMessages = 0;
        }
      }
      if (unseenCount > 0) {
        if (unseenCount > notified) {
          unseenCount -= notified;
        } else {
          unseenCount = 0;
        }
      }
      await _persist();
    } else {
      // 主引擎 onEvent 已把本次全部留言/评价实时弹过，后台通知代表看过。
      if (unreadMessages > 0 || unseenCount > 0) {
        unreadMessages = 0;
        unseenCount = 0;
        await _persist();
      }
    }
  }

  /// 手动立即重试一次同步（连接失败的状态行点击用）。
  void retryNow() => syncNow(push: _dirty);

  /// 留言板可见时切换到 2s 快轮，消息与已读回执接近实时。
  void setBoardVisible(bool visible) {
    if (_boardVisible == visible) return;
    _boardVisible = visible;
    if (loggedIn) _startLoop();
  }

  /// 留言板当前是否可见（应用内横幅据此决定是否弹新留言提醒）。
  bool get boardVisible => _boardVisible;

  void _startLoop() {
    _stopLoop();
    Duration nextInterval() {
      if (_offline) return _offlineProbe;
      // 未配对：sync 是空探活（服务端立即返回），低频即可。
      if (status == CoupleStatus.unbound) return const Duration(seconds: 15);
      return pollInterval(
          foreground: _foreground,
          failStreak: _failStreak,
          boardVisible: _boardVisible,
          keepAlive: _keepAliveActive);
    }
    void tick() {
      _pollTimer = Timer(nextInterval(), () {
        _pollTimer = null;
        // 心跳与同步成败无关：只要界面引擎还在跑，后台引擎就该让位。
        unawaited(_beat());
        if (status == CoupleStatus.waiting &&
            myCode == null &&
            roomId == null) {
          ensureMyCode();
        } else {
          syncNow(push: _dirty);
        }
        // 占位 Timer 到期后重走 tick 续接循环；syncNow 内部重排时
        // 已先 _stopLoop，这里的 ??= 不会重复挂上。
        _pollTimer ??= Timer(nextInterval(), tick);
      });
    }

    unawaited(_beat());
    tick();
  }

  /// 网络状态订阅：无网时轮询空转，恢复联网后立即补一次同步。
  void _watchNetwork() {
    try {
      _netSub = Connectivity().onConnectivityChanged.listen((results) {
        final offline = results.isEmpty ||
            results.every((r) => r == ConnectivityResult.none);
        if (offline == _offline) return;
        _offline = offline;
        if (!offline && loggedIn) {
          _failStreak = 0;
          _startLoop();
          syncNow(push: _dirty);
        }
        notifyListeners();
      });
    } catch (_) {
      // 平台不支持时保持常在线轮询，仅多打几次注定失败的请求。
    }
  }

  void _stopLoop() {
    _pollTimer?.cancel(); _pollTimer = null;
    _pushDebounce?.cancel(); _pushDebounce = null;
  }

  void _attachStoreListener() {
    _store.removeListener(_onStoreChanged);
    _store.addListener(_onStoreChanged);
  }

  void _onStoreChanged() {
    if (!loggedIn) return;
    if (_suppressStoreEvents) return;
    if (_suppressNextPush) {
      // 本地重置为种子数据后的一次变更不推送，云端备份维持不动。
      _suppressNextPush = false;
      return;
    }
    if (_pendingUnlock) {
      _dirty = true;
      return;
    }
    _reportCompletionEvents();
    _dirty = true;
    schedulePush();
  }

  void _reportCompletionEvents() {
    // 只刷新基线，不生成完成动态。
    for (final t in _store.data.tasks) {
      if (t.isRecurring) {
        _prevRecurCount[t.id] = t.doneDates.length;
        continue;
      }
      _prevDoneState[t.id] = t.done;
    }
  }

  void _seedPrevDoneState() {
    _prevDoneState.clear(); _prevRecurCount.clear();
    for (final t in _store.data.tasks) {
      if (t.isRecurring) { _prevRecurCount[t.id] = t.doneDates.length; }
      else { _prevDoneState[t.id] = t.done; }
    }
  }

  void schedulePush() {
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(seconds: 2), () {
      if (!loggedIn) return;
      if (!autoBackup) return; // 关闭自动备份：改动留在本机，等手动备份
      syncNow(push: true);
    });
  }

  Future<void> syncNow({required bool push, bool forceShort = false,
      bool manual = false, void Function(bool pushed)? onPushResult}) async {
    if (!loggedIn) {
      onPushResult?.call(false);
      return;
    }
    if (_pendingUnlock) push = false;
    // 云端备份解不开期间一律不推：本机可能是空数据，推上去会把备份盖掉。
    if (_restoreBlocked) push = false;
    // 关闭自动备份后只有显式手动动作才上传：轮询/退避重试/合并回推都不再绕过开关。
    if (push && !autoBackup && !manual) push = false;
    // 快照超限冷却期内只拉不推，防止反复撞 512KB 上限。
    if (push && _pushCooldownUntil != null) {
      if (DateTime.now().isBefore(_pushCooldownUntil!)) {
        push = false;
      } else {
        _pushCooldownUntil = null;
      }
    }
    if (_syncing) {
      // 跳过的推送保留脏标记重试；manual 必须一起带过去，
      // 否则「关闭自动备份后立即备份」会在长轮询期间被静默丢弃。
      if (push) {
        _dirty = true;
        _pushDebounce?.cancel();
        _pushDebounce = Timer(const Duration(seconds: 3), () {
          if (loggedIn) syncNow(push: true, manual: manual);
        });
      }
      onPushResult?.call(false);
      return;
    }
    if (status == CoupleStatus.waiting && _createGraceUntil != null &&
        DateTime.now().isBefore(_createGraceUntil!)) {
      return;
    }
    _syncing = true;
    // 登出/换号/解绑后作废在途结果。
    final sessionToken = token;
    final sessionAccount = accountId;
    final sessionEpoch = _bindEpoch;
    try {
      if (token != null) await _ensureIdentityKeyPair();
      Map<String, dynamic>? snapshot;
      if (push) {
        _sharedKeyMissing = false;
        try {
          snapshot = await _encryptSnapshot();
        } catch (e) {
          // 加密失败则只拉取。
          debugPrint('encrypt failed, pull-only this round: $e');
          lastError = '日记加密失败，这次先不备份';
          _dirty = true;
          snapshot = null;
          push = false;
        }
        // 共享密钥缺失：这轮不推共享包，避免把内容明文送到服务端。
        if (_sharedKeyMissing) {
          lastError = '共享密钥未就绪，已暂缓上传（在「我的 → 云端备份」里解锁备份，或重新登录后会自动补齐）';
          snapshot = null;
          push = false;
        }
      }
      // 前台或保活服务在跑时长轮询（服务端挂起至多 20 秒，有变化即回），
      // 消息接近实时；两者都没有时退回普通短同步。
      final longPoll =
          !push && (isForeground || _keepAliveActive) && !forceShort;
      final payload = <String, dynamic>{
        'token': token, 'name': myName,
        // 客户端版本：服务端据此拦住旧版对加密备份的覆盖写（新客户端必须 >= 5.15.2）。
        'ver': clientVersion,
        // 设备槽位：多设备同账号按此分槽存快照、互不覆盖。
        'device': deviceId,
        // 新配对双方互发 X25519 公钥；旧配对/旧客户端没有这一步，仍走绑定码派生。
        'pubKey': ?(_couplePubB64.isEmpty ? null : _couplePubB64),
        // 账号级身份公钥 + 它给上面 X25519 公钥做的签名。
        // 服务端只有公钥，伪造「对方换了公钥」会因为验签失败被拒。
        'identityPub': ?(_identityPubB64.isEmpty ? null : _identityPubB64),
        if (_couplePubB64.isNotEmpty && _identityPrivB64.isNotEmpty)
          'pubKeySig': await _signMyPubKey(),
        'since': _roomRev,
        // 服务端截断过（历史太多），带上游标把更早的一批要回来。
        if (_olderBeforeAt > 0) 'wantOlder': true,
        if (_olderBeforeAt > 0) 'olderBeforeAt': _olderBeforeAt,
        if (_olderBeforeAt > 0) 'olderBeforeId': _olderBeforeId,
        'wait': ?(longPoll ? 20 : null),
        // 已查看消息的最新时间（留言板可见且前台才上报，未真正看到不算已读）。
        'readUpTo': ?readUpToValue(
          unreadMessages: unreadMessages,
          boardVisible: _boardVisible,
          foreground: _foreground,
          lastMessageAt: messages.isEmpty ? 0 : messages.last.createdAt,
        ),
      };
      if (snapshot != null) {
        // 数据大了走 gzip：线上传省流量，服务端解压后按更大上限校验。
        final raw = jsonEncode(snapshot);
        if (utf8.encode(raw).length > _snapshotGzThreshold) {
          payload['snapshotGz'] = base64Encode(gzip.encode(utf8.encode(raw)));
        } else {
          payload['snapshot'] = snapshot;
        }
      }
      final result = await SyncApi.post('sync', payload,
          timeoutOverride: longPoll ? const Duration(seconds: 40) : null);
      // 服务端有响应即视为在线，恢复实时节奏。
      if (_failStreak > 0 || _offline) {
        _failStreak = 0;
        _offline = false;
        _startLoop();
      }

      // 会话已切换（登出/换号/解绑）：丢弃过期结果。
      if (sessionToken != token ||
          sessionAccount != accountId ||
          sessionEpoch != _bindEpoch) {
        return;
      }
      // 无变化：只推进游标。
      if (result['unchanged'] == true) {
        final roomRev = result['roomRev'];
        if (roomRev is int) _roomRev = roomRev;
        lastSyncAt = DateTime.now().millisecondsSinceEpoch;
        lastError = null;
        // 落盘要节流：长轮询每秒回来一次，不能每次都写 prefs。
        if (lastSyncAt - _lastSyncPersistedAt > 30000) {
          _lastSyncPersistedAt = lastSyncAt;
          unawaited(_persist());
        }
        // 仅服务端明确报告房间失效时才清空绑定状态。
        if (result['roomActive'] == false && status != CoupleStatus.unbound) {
          final wasBound = isBound;
          final name = partnerName;
          _stopLoop(); _store.removeListener(_onStoreChanged);
          _clearCoupleLocally();
          await _persist();
          onEvent?.call(wasBound
              ? CoupleEvent('绑定已解除',
                  '$name 解除了情侣绑定，重新输入 TA 的绑定码即可再次配对')
              : CoupleEvent('绑定码已失效', '请重新生成绑定码'));
        }
        notifyListeners();
        return;
      }
      // 长轮询唤醒信号：只带回新版本号、不带数据。保持旧游标不推进，
      // 下一轮（约 1 秒后）since 不匹配即取回全量——若在此推进游标，
      // 触发唤醒的那次变更将永远没有机会下发。
      if (result['woken'] == true) {
        lastSyncAt = DateTime.now().millisecondsSinceEpoch;
        lastError = null;
        notifyListeners();
        return;
      }
      if (result is Map) {
        await _applySyncResult(Map<String, dynamic>.from(result), pushed: push);
        if (push) _dirty = false;
        onPushResult?.call(push);
      }
    } on SyncException catch (e) {
      lastError = e.message;
      if (e.transient || SyncApi.isTransientMessage(e.message)) {
        // 网络类失败：计入退避，重排下一次轮询。
        _failStreak++;
        _startLoop();
      } else if (e.message.contains('内容过大')) {
        _pushCooldownUntil = DateTime.now().add(const Duration(minutes: 10));
        lastError = '同步内容太大，暂停 10 分钟；删掉一些内容后会自动恢复上传';
      }
      // 令牌失效：软登出。
      if (e.message.contains('登录已失效') && !_softLogoutDone) {
        _softLogoutDone = true;
        _softLogout('登录已过期');
      }
      notifyListeners();
    } catch (e, stack) { debugPrint('sync error: $e\n$stack'); lastError = '同步出错了，稍后会自动重试'; notifyListeners();
    } finally {
      _syncing = false;
      // 在途期间 markSeen 过：立即以短请求补发已读回执（不等下一轮询）。
      if (_readReceiptPending && loggedIn) {
        _readReceiptPending = false;
        unawaited(syncNow(push: _dirty, forceShort: true));
      }
    }
  }

  /// 各分区数据的未压缩体积估算（Byte），用于「数据体积」诊断。
  Future<Map<String, int>> snapshotSizeReport() async {
    final data = _store.data.toJson();
    int sizeOf(Object? v) =>
        utf8.encode(v == null ? '' : jsonEncode(v)).length;
    const own = {'tasks', 'lists', 'habits', 'journal'};
    final tasks = sizeOf(data['tasks']) + sizeOf(data['lists']);
    final habits = sizeOf(data['habits']);
    final journal = sizeOf(data['journal']);
    final rest = sizeOf({
      for (final k in data.keys)
        if (!own.contains(k)) k: data[k],
    });
    return {
      '任务与清单': tasks,
      '习惯': habits,
      '日记': journal,
      '其它（纪念日/回收站/墓碑等）': rest,
      '合计': tasks + habits + journal + rest,
    };
  }

  Future<Map<String, dynamic>?> _encryptSnapshot() async {
    final data = _store.data.toJson();
    final journal = Map<String, dynamic>.from((data['journal'] ?? {}) as Map);
    // 共享日记条目抽出，随 shared 包加密下发对方。
    final sharedJournal = <String, dynamic>{};
    journal.removeWhere((k, v) {
      if (v is Map && (v['shared'] ?? false) == true) {
        final copy = Map<String, dynamic>.from(v)..remove('images');
        sharedJournal[k] = copy;
        return true;
      }
      return false;
    });

    String journalCipher;
    try {
      final key = JournalCrypto.keyFromBase64(await getOrCreateJournalKey());
      journalCipher =
          await JournalCrypto.encrypt(jsonEncode(journal), key);
    } catch (e) {
      debugPrint('journal encrypt failed: $e');
      lastError = '日记加密失败，这次先不备份';
      _dirty = true;
      return null;
    }

    final shared = <String, dynamic>{
      'tasks': data['tasks'],
      'lists': data['lists'],
      'habits': data['habits'],
      'milestones': data['milestones'],
      'unfiledTrash': data['unfiledTrash'],
      // 清单回收站（按原清单归位）；旧客户端忽略未知键，旧字段照旧下发。
      'trash': data['trash'],
      // 共同编辑 overlay：TA 的勾选/新增经快照回流给清单所有者。
      if (data['coedits'] != null) 'coedits': data['coedits'],
      'tombs': _store.tombstones,
      'sharedJournal': sharedJournal,
    };

    final priv = <String, dynamic>{
      'journal': {'_encrypted': journalCipher},
    };
    // 恢复码能恢复全部数据的原因：coupleKey 用数据密钥加密后随私有包上传。
    // 换机时用恢复码派生出数据密钥，就能解开 coupleKey 和共享包，密钥不经过网络。
    if (coupleKeyBase64.isNotEmpty) {
      priv['coupleKeyEnc'] =
          await JournalCrypto.encryptWithBase64(
              journalKeyBase64, coupleKeyBase64);
    }
    // 协商出的备用密钥也一起备份，否则换机只恢复主密钥，对方用备用密钥
    // 加密的旧内容就再也解不开了。
    if (coupleKeyLegacyB64.isNotEmpty) {
      priv['coupleKeyLegacyEnc'] =
          await JournalCrypto.encryptWithBase64(
              journalKeyBase64, coupleKeyLegacyB64);
    }
    // 身份私钥随数据密钥加密备份：换机后身份不变，安全码仍然对得上。
    // 公钥不算秘密，直接明文放进去，恢复时省一次推导。
    if (_identityPrivB64.isNotEmpty && journalKeyBase64.isNotEmpty) {
      try {
        priv['identityPrivEnc'] = await JournalCrypto.encryptWithBase64(
            journalKeyBase64, _identityPrivB64);
        if (_identityPubB64.isNotEmpty) {
          priv['identityPub'] = _identityPubB64;
        }
      } catch (_) {}
    }
    // 更早几代的共享密钥也要能跟着恢复，否则换机后老内容就没钥匙了。
    if (coupleKeyExtras.isNotEmpty) {
      priv['coupleKeysExtraEnc'] = await JournalCrypto.encryptWithBase64(
          journalKeyBase64, jsonEncode(coupleKeyExtras));
    }
    final out = <String, dynamic>{
      'v': 2,
      'priv': priv,
    };
    if (coupleKeyBase64.isNotEmpty) {
      // 已配对：用双方共享密钥加密，对方也能解。
      out['shared_enc'] = true;
      out['shared_key'] = 'couple';
      out['shared'] = await JournalCrypto.encryptWithBase64(
          coupleKeyBase64, jsonEncode(shared));
      // 告诉对方这份密文是用哪把密钥加的，方便它对不上时补协商。
      out['shared_kid'] = coupleKid(coupleKeyBase64);
    } else if (isBound) {
      // 已配对但本机没有共享密钥（新设备还没解锁、或刚登出重登）：不能明文
      // 上传，也不能用本机数据密钥（对方解不开），这一轮不推。
      _sharedKeyMissing = true;
      out['shared_enc'] = false;
      out['shared'] = null;
    } else if (journalKeyBase64.isNotEmpty) {
      // 未配对：备份数据只有自己看，用本机数据密钥加密。代价是换机或
      // 重装后需要恢复码才能解开。
      out['shared_enc'] = true;
      out['shared_key'] = 'own';
      out['shared'] = await JournalCrypto.encryptWithBase64(
          journalKeyBase64, jsonEncode(shared));
    } else {
      _sharedKeyMissing = true;
      out['shared_enc'] = false;
      out['shared'] = null;
    }
    return out;
  }

  /// 解密快照为可读数据：
  /// - v2 双包：解 shared 包（coupleKey 或明文回退）；journal 为共享条目视图。
  /// - v1 旧格式：journal 密文信封 + 明文其余字段 + sharedJournal 明文旁路。
  /// 返回 null = 无法解读（如缺密钥），调用方按空数据处理。

  Future<void> _applySyncResult(Map<String, dynamic> result, {required bool pushed}) async {
    final events = <CoupleEvent>[];
    // 本方法内有多个 await（解密/派生/落盘），期间会话可能已切换
    // （登出/解绑）——认领分支前必须复核，防止已清状态被复活。
    final applyEpoch = _bindEpoch;
    final applyToken = token;
    bool sessionStale() => applyEpoch != _bindEpoch || applyToken != token;
    final roomActive = result['roomActive'] == true;
    final inCreateGrace = _createGraceUntil != null && DateTime.now().isBefore(_createGraceUntil!);
    // 云端有加密备份、本机却解不开：绝不能推。push 会用本机密钥重新加密
    // 原备份，密钥可能不同，旧恢复码从此解不开，等于毁掉备份。重装后没有
    // 密钥，或本机密钥与云端对不上（比如另一次生成恢复码后重装），都会走到
    // 这里；判断方式统一为实际试着解一次。
    if (!_pendingUnlock) {
      final own = result['serverSnapshot'];
      final ownRaw = (own is Map && own['data'] is Map) ? own['data'] : own;
      if (ownRaw is Map && ownRaw['v'] == 2 &&
          ownRaw['shared_enc'] == true &&
          ownRaw['shared'] is String) {
        final readable =
            await _tryDecryptShared(ownRaw['shared'] as String,
                allowOwnKey: true,
                hint: ownRaw['shared_key'] is String
                    ? ownRaw['shared_key'] as String
                    : null);
        if (readable == null) {
          // 注意：这里不能因为「本机看起来未配对」就覆盖云端。
          // 换新手机登录已绑定账号时，本地 status 在认领之前仍是 unbound，
          // 一旦放行就会用新的随机密钥把旧备份盖掉，旧恢复码从此作废。
          // 解绑后的重推交给 unbind() 和「检测到解绑」两条路径处理。
          _pendingUnlock = true;
          // 同步封锁上传：不解锁、不完成一次恢复，绝不推。否则本机
          // （换机后可能为空）的数据会连同新密钥一起盖掉云端备份。
          _restoreBlocked = true;
          final journalEnv = (ownRaw['priv'] as Map?)?['journal'];
          final lockedCipher =
              (journalEnv is Map && journalEnv['_encrypted'] is String)
                  ? journalEnv['_encrypted'] as String
                  : null;
          if (lockedCipher != null && lockedCipher.isNotEmpty) {
            try {
              final prefs1 = await SharedPreferences.getInstance();
              await prefs1.setString('gd2_locked_journal', lockedCipher);
            } catch (_) {}
          }
          lastError = '云端备份已加密，先用恢复码解锁才能继续备份';
          await _persist();
          notifyListeners();
        }
      }
    }
    // 同账号其他设备的快照合并对无房间账号同样有效（纯云备份用户
    // 也靠它做多设备收敛），放在 roomActive 早退之前。
    await _mergeDeviceSnapshots(result);
    if (!roomActive && status == CoupleStatus.waiting && inCreateGrace) {
      lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      notifyListeners(); return;
    }
    if (!roomActive) {
      var wasBound = false;
      if (status != CoupleStatus.unbound) {
        wasBound = isBound;
        _stopLoop(); _store.removeListener(_onStoreChanged); _clearCoupleLocally();
        await _persist();
        if (wasBound) {
          events.add(CoupleEvent('绑定已解除',
              '$partnerName 解除了情侣绑定，重新输入 TA 的绑定码即可再次配对'));
        } else {
          events.add(CoupleEvent('绑定码已失效', '请重新生成绑定码'));
        }
      }
      _restoreBlocked = false;
      _pendingUnlock = false;
      lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      await _persist(); notifyListeners();
      for (final e in events) { onEvent?.call(e); }
      // 只有确实从绑定态掉下来才立刻用本机密钥重推一次：云端那个槽还是
      // 共享密钥加密的，不重推的话下一轮会被守卫判成「备份锁住了」。
      // 本来就没有房间的账号（未配对、纯云备份）不能走这里——每轮拉取都
      // 置脏重推会变成每 3 秒一次的无限推送。
      if (wasBound) {
        _dirty = true;
        unawaited(syncNow(push: true, manual: true));
      }
      return;
    }
    final pAid = result['partnerAccountId'] as String?;
    // 已处于绑定态但本机没有共享密钥（换机恢复/登录态重建后）：
    // 只要用缓存的绑定码能派生就补上，否则消息与伴侣快照永远解不开。
    if (coupleKeyBase64.isEmpty &&
        _lastBindCode.isNotEmpty &&
        pAid != null &&
        status == CoupleStatus.bound) {
      await _deriveCoupleKey();
    }
    // 没有缓存的绑定码（码是别的设备生成的）时，绑定码派生这条路走不通。
    // 用 X25519 协商自救：先上报本机公钥，下一轮拿到对方公钥再派生。
    // 不做这一步的话，账号会一直停在「已绑定但没有共享密钥」，
    // 既同步不出去也解不开对方数据，只能解绑重绑。
    if (coupleKeyBase64.isEmpty &&
        pAid != null &&
        status == CoupleStatus.bound) {
      await _ensureCoupleKeyPair();
    }
    if (pAid != null && result['memberInfo'] is Map) {
      final info = Map<String, dynamic>.from(
          (result['memberInfo'] as Map)[pAid] as Map? ?? {});
      final email = (info['email'] as String?) ?? '';
      if (email != partnerEmail) {
        partnerEmail = email;
      }
      final avatarUrl = (info['avatar'] as String?) ?? '';
      if (avatarUrl.isNotEmpty && avatarUrl != partnerAvatarDataUrl) {
        await _cachePartnerAvatar(avatarUrl);
      }
    }
    if (sessionStale()) return;
    if (status == CoupleStatus.waiting && pAid != null) {
      partnerAccountId = pAid;
      partnerName = (result['partnerName'] as String?) ?? 'TA';
      status = CoupleStatus.bound; unseenCount = 0; unreadMessages = 0; myCode = null;
      // 发起方在首次拿到对方账号时派生共享密钥（绑定码已在本机缓存）。
      if (coupleKeyBase64.isEmpty) await _deriveCoupleKey();
      // 配对成立时补齐轮询、本地变更监听与完成态基线。
      _startLoop();
      _attachStoreListener();
      _seedPrevDoneState();
      unawaited(syncKeepAliveWithSession());
      events.add(CoupleEvent('绑定成功', '你和 $partnerName 的内容开始同步了'));
      final verifyCode = deviceVerifyCode;
      if (verifyCode.isNotEmpty) {
        events.add(CoupleEvent('设备确认码', verifyCode));
      }
      // 绑定前自己的快照是用个人密钥加密的，对方解不开。这里必须重新用
      // 共享密钥推一次，否则对方要等到本机下一次本地改动才看得到数据。
      _dirty = true;
      unawaited(syncNow(push: true, manual: true));
    }
    // 本地未绑定但房间仍在时直接认领。
    if (sessionStale()) return;
    if (status == CoupleStatus.unbound && pAid != null) {
      if (_unbindPending) {
        // 用户点过解绑但请求没成功：先补解绑，不要把人自动绑回去。
        unawaited(_retryUnbind());
        return;
      }
      roomId = (result['roomId'] as String?) ?? roomId;
      partnerAccountId = pAid;
      partnerName = (result['partnerName'] as String?) ?? 'TA';
      myCode = null;
      status = CoupleStatus.bound;
      // 会话丢失重登录后共享密钥可能缺失：用缓存的绑定码补派生。
      if (coupleKeyBase64.isEmpty) await _deriveCoupleKey();
      // 恢复轮询、本地变更监听与完成态基线。
      _startLoop();
      _attachStoreListener();
      _seedPrevDoneState();
      events.add(CoupleEvent('已恢复情侣绑定', '与 $partnerName 的同步已重新连接'));
      final verifyCode = deviceVerifyCode;
      if (verifyCode.isNotEmpty) {
        events.add(CoupleEvent('设备确认码', verifyCode));
      }
      // 同上：换回绑定态要把 shared 用共享密钥重推一份。
      _dirty = true;
      await _persist();
      unawaited(syncNow(push: true, manual: true));
    }
    // 双方都上报了协商公钥时升级为 X25519 派生密钥（旧配对没有私钥，保持不变）。
    final partnerIdPub = result['partnerIdentityPub'];
    if (partnerIdPub is String &&
        partnerIdPub.isNotEmpty &&
        isBound) {
      final peerPub = result['partnerPubKey'];
      final peerSig = result['partnerPubKeySig'];
      if (peerPub is String && peerPub.isNotEmpty && peerSig is String &&
          peerSig.isNotEmpty) {
        final ok = await JournalCrypto.verifyIdentity(
            partnerIdPub, base64Decode(peerPub), peerSig);
        if (!ok) {
          // 对方身份公钥对不上公钥签名：要么服务端改了公钥，要么数据坏了。
          // 这种情况绝不换密钥，只提示。
          identityKeyChanged = true;
          await _persist();
          notifyListeners();
          lastError = '对方公钥的签名验证失败，已暂停更新共享密钥';
          _raiseIdentityIssueOnce();
        } else {
          if (_peerIdentityPubB64.isEmpty) {
            _peerIdentityPubB64 = partnerIdPub;
            await _persist();
          } else if (_peerIdentityPubB64 != partnerIdPub) {
            // 身份公钥变了（换手机并重新生成身份），同样只提示不自动跟随。
            identityKeyChanged = true;
            await _persist();
            notifyListeners();
            _raiseIdentityIssueOnce();
          }
        }
      }
    }
    final partnerPub = result['partnerPubKey'];
    if (partnerPub is String && partnerPub.isNotEmpty) {
      // TOFU：第一次知道对方公钥就固定下来，不管密钥是哪条路径派生的。
      // 被邀请的一方（绑定码派生）以前没有基准，等于谁都能冒充。
      if (_couplePeerPubPinned.isEmpty && isBound) {
        _couplePeerPubPinned = partnerPub;
        await _persist();
      }
      await _upgradeToX25519Key(partnerPub);
    }
    if (status == CoupleStatus.waiting) {
      // 绑定码以服务端为准；服务端 24h 轮换后也要跟着更新缓存——
      // 配对时双方用同一码派生情侣密钥，旧码会导致密钥不一致。
      final serverCode = result['myCode'] as String?;
      if (serverCode != null && serverCode != myCode) {
        myCode = serverCode;
      }
      if (serverCode != null &&
          serverCode.isNotEmpty &&
          serverCode != _lastBindCode) {
        _lastBindCode = serverCode;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('gd2_last_bind_code', serverCode);
        } catch (_) {}
      }
    }
    // 上面几段含 await（派生密钥/持久化），期间可能已登出/解绑。
    if (sessionStale()) return;
    final roomRev = result['roomRev'];
    if (roomRev is int) _roomRev = roomRev;
    final pRead = result['partnerReadAt'];
    if (pRead is int && pRead > partnerReadAt) {
      partnerReadAt = pRead;
    }
    final boundMs = result['boundAt'];
    if (boundMs is int && boundMs > boundAt) boundAt = boundMs;
    final roomAnniversary = result['anniversary'];
    if (roomAnniversary is String && roomAnniversary != anniversary) {
      anniversary = roomAnniversary;
    }
    // 房间字段对齐（纪念日名称）。
    final roomBookName = result['bookName'];
    if (roomBookName is String && roomBookName != coupleBookName) {
      coupleBookName = roomBookName;
    }
    final srvUpdated = result['serverUpdatedAt'];
    if (srvUpdated is int && srvUpdated > serverUpdatedAt) {
      serverUpdatedAt = srvUpdated;
    }
    if (isBound && pAid != null) {
      final snapshot = result['partnerSnapshot'] as Map<String, dynamic>?;
      if (snapshot != null) {
        // 按 updatedAt 仅应用新快照。
        final stamp = (snapshot['updatedAt'] ?? 0) as int;
        var decryptedPartner = await _decryptSnapshot(snapshot);
        if (decryptedPartner == null) {
          // 密钥缺失（如派生时序问题）：补派生后重试一次。
          if (coupleKeyBase64.isEmpty) {
            await _deriveCoupleKey();
            decryptedPartner = await _decryptSnapshot(snapshot);
          }
        }
        if (decryptedPartner == null) {
          // 仍解不开（共享密钥丢失/密文损坏）：保留现有伴侣视图，
          // 绝不能用空数据覆盖，等下轮或密钥恢复后再应用。
          debugPrint('partner snapshot undecryptable, keep current view');
        } else {
          await _mirrorPeerSharedKid(snapshot, events);
          _applyPartnerSnapshot(
              decryptedPartner, stamp, pAid, result, events);
        }
      }
    }
    final adoptSilently = !_historyAdopted;
    _historyAdopted = true;
    final incomingComments = <CoupleComment>[];
    for (final e in ((result['comments'] as List?) ?? const []).whereType<Map>()) {
      final m = Map<String, dynamic>.from(e);
      // 评价正文是密文，先用共享密钥还原再展示。
      if ((m['enc'] ?? false) == true && m['text'] is String) {
        final plain = await _tryDecryptShared(m['text'] as String);
        if (plain != null) m['text'] = plain;
      }
      incomingComments.add(CoupleComment.fromJson(m));
    }
    final knownComments = comments.map((c) => c.id).toSet();
    for (final c in incomingComments) {
      if (knownComments.contains(c.id)) continue;
      if (adoptSilently) continue;
      if (c.byAccountId == partnerAccountId && c.targetOwnerAccountId == accountId) {
        final what = switch (c.targetKind) { kindJournal => '日记', kindHabit => '习惯', _ => '任务' };
        if (c.kind == 'emoji') {
          events.add(CoupleEvent('$partnerName ${reactionLabel(c.emoji)}了你的$what', '点击查看',
              isMessage: true, dedupKey: 'cmt:${c.id}'));
        } else {
          events.add(CoupleEvent('$partnerName 评价了你的$what',
              c.text.isEmpty ? '点击查看' : c.text,
              isMessage: true, dedupKey: 'cmt:${c.id}'));
        }
      }
    }
    final localComments = comments;
    comments = incomingComments.where((c) => c.byAccountId == partnerAccountId || c.byAccountId == accountId).toList();
    // 保留本地已回显但服务端列表尚未包含的条目（并发轮询的整表替换不能吃掉刚发的）。
    final incomingCommentIds = incomingComments.map((c) => c.id).toSet();
    comments.addAll(localComments.where((c) =>
        !incomingCommentIds.contains(c.id) &&
        (c.byAccountId == accountId || c.byAccountId == partnerAccountId)));
    comments.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (comments.length > 1200) comments = comments.sublist(0, 1200);
    final incomingMessages = ((result['messages'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    // 留言密文在入库前还原为明文（展示、通知、搜索都依赖明文）；
    // 明文消息解密必然失败，原样保留，历史消息自然兼容。
    for (final m in incomingMessages) {
      if (m['kind'] == 'deleted' || m['kind'] == 'system') continue;
      final t = m['text'];
      if (t is String && t.isNotEmpty) {
        m['text'] = await _decryptMessageText(t);
      }
    }
    // 逐条解密含 await，期间会话可能已切换，避免把旧房间消息写回。
    if (sessionStale()) return;
    final decodedMessages = incomingMessages
        .map((e) => CoupleMessage.fromJson(e))
        .toList();
    final knownMessages = messages.map((m) => m.id).toSet();
    for (final m in decodedMessages) {
      if (knownMessages.contains(m.id)) continue;
      if (adoptSilently) continue;
      if (m.byAccountId == accountId) continue; // 自己发的动态不回显
      if (m.isSystem) {
        events.add(CoupleEvent('$partnerName 的动态', m.text,
            dedupKey: 'sys:${m.id}'));
      } else if (m.byAccountId == partnerAccountId) {
        events.add(CoupleEvent(partnerName, m.text,
            isMessage: true, dedupKey: 'msg:${m.id}'));
        unreadMessages++;
      }
    }
    final localMessages = messages;
    messages = decodedMessages.toList();
    final incomingMessageIds = decodedMessages.map((m) => m.id).toSet();
    messages.addAll(localMessages
        .where((m) => !incomingMessageIds.contains(m.id) && !m.isSystem));
    messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (messages.length > 2000) {
      messages = messages.sublist(messages.length - 2000);
    }
    // 服务端为控制响应体积可能只回最近一部分（truncated）；本地已有数据
    // 不会被删，这里只记下来，界面好说明「更早的没拉全」。
    lastSyncTruncated = result['truncated'] == true;
    // 快照被裁掉的信号现在两种页面都会给：普通页也会丢 deviceSnapshots。
    lastSnapshotsTruncated = result['snapshotsTruncated'] == true;
    if (lastSnapshotsTruncated) _scheduleSnapshotRefetch();
    if (lastSyncTruncated) {
      // 游标用 (时间戳, id)：同一毫秒里有多条时也不会漏/重。
      final at = result['oldestMessageAt'] ?? result['oldestCommentAt'];
      final id = result['oldestMessageId'] ?? result['oldestCommentId'];
      final nextAt = at is int && at > 0 ? at : 0;
      final nextId = id is String ? id : '';
      final advanced = nextAt != _olderBeforeAt || nextId != _olderBeforeId;
      if (nextAt > 0 && advanced && _olderRounds < 20) {
        _olderBeforeAt = nextAt;
        _olderBeforeId = nextId;
        _olderRounds++;
        unawaited(Future<void>.delayed(const Duration(milliseconds: 800), () {
          if (loggedIn) syncNow(push: false);
        }));
      } else {
        _olderBeforeAt = 0;
        _olderBeforeId = '';
      }
    } else {
      _olderBeforeAt = 0;
      _olderBeforeId = '';
      _olderRounds = 0;

    }
    lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    if (pushed) {
      cloudBackupAt = lastSyncAt;
      _lastPushAt = DateTime.now().millisecondsSinceEpoch;
    }
    lastError = null;
    // 保活通知里显示「最近同步 HH:mm」；顺带写主引擎心跳。
    unawaited(KeepAliveBridge.touchLastSync());
    unawaited(_beat());
    if (!adoptSilently) unseenCount += events.length;
    // 处理期间会话已切换：不再把处理中途拼出的状态写回磁盘。
    if (sessionStale()) return;
    await _persist(); notifyListeners();
    // 会话在处理期间切换：事件不再派发（弹「绑定成功」到已登出界面）。
    if (!sessionStale()) {
      for (final e in events) { onEvent?.call(e); }
    }
  }

  /// 同账号其他设备的快照：按 id 合并进本地（updatedAt 新者胜、墓碑优先），
  /// 合并结果整体生效并回推到自己的设备槽。对无房间账号同样执行
  /// （纯云备份用户也靠它做多设备收敛）。
  Future<void> _mergeDeviceSnapshots(Map<String, dynamic> result) async {
    final deviceSnaps = result['deviceSnapshots'];
    if (deviceSnaps is! List || deviceSnaps.isEmpty) return;
    AppData merged = _store.data;
    var mergedTombs = Map<String, int>.from(_store.tombstones);
    for (final item in deviceSnaps) {
      if (item is! Map) continue;
      final data0 = item['data'];
      if (data0 is! Map) continue;
      final decrypted =
          await _decryptSnapshot(Map<String, dynamic>.from(data0));
      if (decrypted == null) continue;
      // 共享日记在 shared 包的并列键里，先并入 journal 供合并。
      final deviceSharedJournal = decrypted.remove('sharedJournal');
      if (deviceSharedJournal is Map && deviceSharedJournal.isNotEmpty) {
        decrypted['journal'] = {
          ...?(decrypted['journal'] as Map?),
          ...deviceSharedJournal,
        };
      }
      final theirTombs = ((decrypted['tombs'] ?? const {}) as Map)
          .map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
      final (m, tombs) = AppStore.mergeAppData(
        mine: merged,
        theirs: AppData.fromJson(decrypted),
        myTombs: mergedTombs,
        theirTombs: theirTombs,
      );
      merged = m;
      mergedTombs = tombs;
    }
    // 墓碑无论内容是否变化都要落地：丢弃会让其他设备删除的
    // 实体在本机复活。
    _store.tombstones..clear()..addAll(mergedTombs);
    // 合并结果与本地一致时不做无谓的 replaceData 与重推。
    final changed =
        jsonEncode(merged.toJson()) != jsonEncode(_store.data.toJson());
    if (changed) {
      _store.replaceData(merged);
      // 合并结果写回自己的槽，供本账号其他设备收敛。
      _dirty = true;
      unawaited(syncNow(push: true));
    }
  }

  /// 应用已解密的伴侣快照：仅当时间戳更新时替换，并派发完成事件、
  /// 回流共同编辑改动。解密失败时调用方跳过整个方法。
  void _applyPartnerSnapshot(
      Map<String, dynamic> decryptedPartner,
      int stamp,
      String pAid,
      Map<String, dynamic> result,
      List<CoupleEvent> events) {
    // 对方共享日记在解密后的数据里，并入 journal 供展示。
    final sharedMap = decryptedPartner.remove('sharedJournal');
    if (sharedMap is Map && sharedMap.isNotEmpty) {
      decryptedPartner['journal'] = {
        ...?(decryptedPartner['journal'] as Map?),
        ...sharedMap,
      };
    }
    final incoming = PartnerData(
      accountId: pAid,
      name: (result['partnerName'] as String?) ?? partnerName,
      data: AppData.fromJson(decryptedPartner),
      updatedAt: stamp,
    );
    final old = partner;
    if (old == null || incoming.updatedAt > old.updatedAt) {
      if (old != null) {
        for (final t in incoming.data.tasks) {
          final before = old.data.tasks.firstWhereOrNull((x) => x.id == t.id);
          if (before == null) continue;
          if (t.isRecurring) {
            if (t.doneDates.where((k) => !before.doneDates.contains(k)).isNotEmpty) {
              events.add(CoupleEvent('$partnerName 完成了一项', '「${t.title}」已打勾完成'));
            }
          } else if (t.done && !before.done) {
            events.add(CoupleEvent('$partnerName 完成了一项', '「${t.title}」已打勾完成'));
          }
        }
      }
      partner = incoming;
    }
    if (partner!.name != partnerName) partnerName = partner!.name;
    // 共同编辑回流：TA 的勾选/新增合并进本地清单后立刻推送，
    // TA 下次拉到新快照时修剪自己的 overlay。
    if (incoming.data.coedits.isNotEmpty &&
        _store.applyCoEdits(incoming.data.coedits)) {
      _dirty = true;
      unawaited(syncNow(push: true));
    } else {
      _store.pruneCoEdits(incoming.data);
    }
  }

  /// 留言密文还原为明文：有共享密钥时尝试解密；明文消息
  /// （未派生密钥期间发送的历史）解密必然失败而原样保留。
  Future<String> _decryptMessageText(String text) async {
    if (text.isEmpty) return text;
    if (coupleKeyBase64.isEmpty && coupleKeyLegacyB64.isEmpty) return text;
    final plain = await _tryDecryptShared(text);
    return (plain == null || plain.isEmpty) ? text : plain;
  }

  Future<Map<String, dynamic>?> _decryptSnapshot(dynamic serverSnapshot) async {
    if (serverSnapshot == null) return null;
    try {
      final snap = Map<String, dynamic>.from(serverSnapshot as Map);
      // 信封格式 {data, updatedAt}（伴侣视图）；裸快照（自身备份）无 data 键，
      // 本身就是应用数据，直接解密其中的日记。
      final raw = snap['data'] is Map ? snap['data'] : snap;
      if (raw is Map && raw['v'] == 2) {
        // v2 双包：对方视图 = shared 包（coupleKey 加密或明文）；
        // priv（私有日记/coupleKeyEnc）不进对方视图。
        if (raw['shared_enc'] == true) {
          if (coupleKeyBase64.isEmpty &&
              coupleKeyLegacyB64.isEmpty &&
              journalKeyBase64.isEmpty) {
            return null; // 上层补派生后重试
          }
          final plain = await _tryDecryptShared(raw['shared'] as String,
              allowOwnKey: true);
          if (plain == null) return null;
          try {
            return Map<String, dynamic>.from(jsonDecode(plain) as Map);
          } catch (_) {
            return null;
          }
        }
        return Map<String, dynamic>.from((raw['shared'] as Map?) ?? {});
      }
      final copy = Map<String, dynamic>.from(raw as Map);
      final journal = copy['journal'];
      if (journal is Map && journal.containsKey('_encrypted')) {
        final encrypted = journal['_encrypted'] as String?;
        if (encrypted == null || encrypted.isEmpty) {
          copy['journal'] = <String, dynamic>{};
        } else if (journalKeyBase64.isEmpty) {
          // 无密钥时保留密文标记。
          copy['_lockedJournal'] = encrypted;
          copy['journal'] = <String, dynamic>{};
        } else {
          try {
            final key = JournalCrypto.keyFromBase64(journalKeyBase64);
            final plain = await JournalCrypto.decrypt(encrypted, key);
            copy['journal'] = jsonDecode(plain) as Map<String, dynamic>;
          } catch (_) {
            copy['_lockedJournal'] = encrypted;
            copy['journal'] = <String, dynamic>{};
          }
        }
      }
      return copy;
    } catch (_) { return null; }
  }

  /// 自己账号的全量解密（恢复备份/解锁流程用，与 _decryptSnapshot 的
  /// 「对方视图」不同）：priv 的日记 + shared 的全部数据合并为一个 AppData；
  /// 顺带从 coupleKeyEnc 恢复情侣密钥（恢复码→dataKey→coupleKey）。
  /// 返回的数据 map 可能带 '_lockedJournal'（缺 dataKey）。
  Future<Map<String, dynamic>?> _decryptOwnSnapshot(dynamic snapshot) async {
    if (snapshot == null) return null;
    try {
      final snap = Map<String, dynamic>.from(snapshot as Map);
      final raw = Map<String, dynamic>.from(
          (snap['data'] is Map ? snap['data'] : snap) as Map);
      if (raw['v'] != 2) {
        return await _decryptSnapshot(snapshot);
      }
      // ---- priv：日记密文 ----
      final priv = Map<String, dynamic>.from((raw['priv'] ?? {}) as Map);
      final copy = <String, dynamic>{};
      final journalEnv = priv['journal'];
      if (journalEnv is Map && journalEnv['_encrypted'] is String) {
        final encrypted = journalEnv['_encrypted'] as String;
        // 换过恢复码时云端可能还是旧密钥加密的，两把都试。
        final plain = await _tryDecryptJournal(encrypted);
        if (plain != null) {
          try {
            copy['journal'] = jsonDecode(plain) as Map;
          } catch (_) {
            copy['_lockedJournal'] = encrypted;
            copy['journal'] = <String, dynamic>{};
          }
        } else {
          copy['_lockedJournal'] = encrypted;
          copy['journal'] = <String, dynamic>{};
        }
      } else {
        copy['journal'] = <String, dynamic>{};
      }
      // ---- 恢复身份密钥（换机后安全码仍然连续）----
      final idPrivEnc = priv['identityPrivEnc'];
      if (idPrivEnc is String && idPrivEnc.isNotEmpty &&
          journalKeyBase64.isNotEmpty) {
        try {
          final idPlain = await _tryDecryptJournal(idPrivEnc);
          if (idPlain != null && idPlain.isNotEmpty) {
            _identityPrivB64 = idPlain;
            final idPub = priv['identityPub'];
            _identityPubB64 = (idPub is String && idPub.isNotEmpty)
                ? idPub
                : await JournalCrypto.identityPublicFromPrivate(idPlain);
            await _persist();
          }
        } catch (_) {}
      }
      // ---- 先恢复 coupleKeyEnc（解不开则留 pending，解锁后再试）----
      // 必须放在解共享包之前：数据密钥可用时能救回 coupleKey，
      // 否则会把「本来能解」的共享包误判为解不开。
      final ckEnc = priv['coupleKeyEnc'];
      if (ckEnc is String && ckEnc.isNotEmpty) {
        var recovered = false;
        if (journalKeyBase64.isNotEmpty) {
          try {
            // 换过恢复码时 coupleKeyEnc 可能还是旧密钥加密的。
            final ckPlain = await _tryDecryptJournal(ckEnc);
            if (ckPlain != null) coupleKeyBase64 = ckPlain;
            await _persist();
            recovered = true;
          } catch (_) {}
        }
        if (!recovered) {
          copy['_coupleKeyEncPending'] = ckEnc;
        }
      }
      // 更早几代的共享密钥
      final extrasEnc = priv['coupleKeysExtraEnc'];
      if (extrasEnc is String && extrasEnc.isNotEmpty &&
          journalKeyBase64.isNotEmpty) {
        try {
          final plain = await _tryDecryptJournal(extrasEnc);
          if (plain != null) {
            final list = jsonDecode(plain);
            if (list is List) {
              coupleKeyExtras
                ..clear()
                ..addAll(list.whereType<String>());
              await _persist();
            }
          }
        } catch (_) {}
      }
      // 备用密钥（旧协商结果）同样要恢复，主密钥解不开的旧密文靠它。
      final ckLegacyEnc = priv['coupleKeyLegacyEnc'];
      if (ckLegacyEnc is String && ckLegacyEnc.isNotEmpty) {
        if (journalKeyBase64.isEmpty) {
          copy['_coupleKeyLegacyEncPending'] = ckLegacyEnc;
        } else {
          try {
            final legacyPlain = await _tryDecryptJournal(ckLegacyEnc);
            if (legacyPlain != null && legacyPlain != coupleKeyBase64) {
              coupleKeyLegacyB64 = legacyPlain;
              await _persist();
            }
          } catch (_) {
            copy['_coupleKeyLegacyEncPending'] = ckLegacyEnc;
          }
        }
      }
      // ---- shared：任务/清单/习惯/倒数日 ----
      Map<String, dynamic>? shared;
      if (raw['shared_enc'] == true) {
        final plain = await _tryDecryptShared(raw['shared'] as String,
            allowOwnKey: true);
        if (plain != null) {
          try {
            shared = Map<String, dynamic>.from(jsonDecode(plain) as Map);
          } catch (_) {
            shared = null;
          }
        }
        if (shared == null) {
          // 共享包解不开：不能静默丢掉任务/清单，交由调用方决定是否继续。
          copy['_sharedLocked'] = true;
          return copy;
        }
      } else {
        shared = Map<String, dynamic>.from((raw['shared'] ?? {}) as Map);
      }
      final sharedData = shared;
      // 共享日记条目并入视图。
      final sharedJournal = sharedData.remove('sharedJournal');
      if (sharedJournal is Map && sharedJournal.isNotEmpty) {
        final merged = Map<String, dynamic>.from(copy['journal'] as Map);
        merged.addAll(sharedJournal.cast<String, dynamic>());
        copy['journal'] = merged;
      }
      for (final k in const [
        'tasks',
        'lists',
        'habits',
        'milestones',
        'unfiledTrash',
        'trash',
        'tombs',
      ]) {
        if (sharedData[k] != null) copy[k] = sharedData[k];
      }
      return copy;
    } catch (_) {
      return null;
    }
  }

  // ---- backup / restore ----

  /// 手动备份。返回 false 表示这次并没有真正上传
  /// （正在解锁/等待恢复、断网、或已有同步在途）。
  Future<bool> backupNow() async {
    if (_pendingUnlock || _restoreBlocked) {
      lastError = '先解锁云端备份或完成一次恢复，再试手动备份';
      notifyListeners();
      return false;
    }
    final before = _lastPushAt;
    await syncNow(push: true, manual: true);
    return _lastPushAt != before;
  }

  /// 放弃云端旧备份，改用本机数据重建（危险操作，需二次确认）。
  ///
  /// 用于「云端备份解不开、又没有恢复码」的死角：不清的话自动备份会一直
  /// 停着，而这台设备上的数据其实是好的。调用后旧备份会被本机数据覆盖。
  Future<bool> rebuildCloudFromLocal() async {
    if (!loggedIn) return false;
    _pendingUnlock = false;
    _restoreBlocked = false;
    _sharedKeyMissing = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('gd2_locked_journal');
      await prefs.remove('gd2_pending_couple_key_enc');
      await prefs.remove('gd2_pending_couple_legacy_enc');
    } catch (_) {}
    // 起一把新的本机数据密钥：旧密钥可能根本解不开云端，留着没意义。
    journalKeyBase64 = '';
    journalKeyPrevBase64 = '';
    await getOrCreateJournalKey();
    lastError = null;
    _dirty = true;
    await _persist();
    notifyListeners();
    final before = _lastPushAt;
    await syncNow(push: true, manual: true);
    return _lastPushAt != before;
  }

  /// 恢复云端备份。null=云端无备份；false=失败；RestoreResult=成功。
  /// lockedJournal 非 null 表示未解密。
  Future<Object?> restoreFromCloud() async {
    if (!loggedIn) return false;
    if (_syncing) {
      lastError = '正在同步中，请稍后再试';
      notifyListeners();
      return false;
    }
    _syncing = true;
    // 与 syncNow 相同的会话守卫：登出/解绑后作废在途恢复结果。
    final sessionToken = token;
    final sessionEpoch = _bindEpoch;
    // 恢复不带 since，取全量快照。
    try {
      final result = await SyncApi.post('sync',
          {'token': token, 'name': myName, 'device': deviceId});
      if (result is! Map) return false;
      if (sessionToken != token || sessionEpoch != _bindEpoch) return false;
      final snap = result['serverSnapshot'];
      if (snap == null) return null;
      final decrypted = await _decryptOwnSnapshot(snap);
      if (decrypted == null) return false;
      if (decrypted['_sharedLocked'] == true) {
        // 任务/清单这部分解不开（未配对没带恢复码、或已配对但没取回共享密钥）。
        // 此时绝不能继续 replaceData：会用空数据覆盖本机与云端备份。
        // 先把日记密文留存，让用户解锁后自动补完这次恢复。
        final lockedCipher = decrypted['_lockedJournal'] as String?;
        if (lockedCipher != null && lockedCipher.isNotEmpty) {
          final prefs1 = await SharedPreferences.getInstance();
          await prefs1.setString('gd2_locked_journal', lockedCipher);
        }
        _pendingUnlock = true;   // 解锁前禁止自动上传
        _restoreBlocked = true;  // 恢复成功前一律不推，防止空数据盖掉云端
        await _persist();
        lastError = '云端备份已加密，需要恢复码解锁';
        notifyListeners();
        return RestoreResult(
          journalCount: 0,
          lockedJournal: (lockedCipher != null && lockedCipher.isNotEmpty)
              ? lockedCipher
              : null,
          needsUnlock: true,
        );
      }
      // coupleKeyEnc 待解锁（日记未解时）暂存，解锁成功后恢复情侣密钥。
      final prefs0 = await SharedPreferences.getInstance();
      final ckPending = decrypted['_coupleKeyEncPending'] as String?;
      final ckLegacyPending =
          decrypted['_coupleKeyLegacyEncPending'] as String?;
      if (ckPending != null && ckPending.isNotEmpty) {
        await prefs0.setString('gd2_pending_couple_key_enc', ckPending);
      } else {
        await prefs0.remove('gd2_pending_couple_key_enc');
      }
      if (ckLegacyPending != null && ckLegacyPending.isNotEmpty) {
        await prefs0.setString('gd2_pending_couple_legacy_enc', ckLegacyPending);
      } else {
        await prefs0.remove('gd2_pending_couple_legacy_enc');
      }
      // 恢复完成前抑制自动推送；未解密的日记密文留存，供设置页稍后解锁。
      final lockedCipher = decrypted['_lockedJournal'] as String?;
      _pendingUnlock = lockedCipher != null;
      if (lockedCipher != null) {
        await prefs0.setString('gd2_locked_journal', lockedCipher);
      } else {
        await prefs0.remove('gd2_locked_journal');
      }
      // 走到这里说明任务/清单已经解开了，之前的封锁可以解除。
      _restoreBlocked = false;
      await _persist(); // 持久化解锁守卫
      _suppressStoreEvents = true;
      try {
        _store.replaceData(AppData.fromJson(decrypted));
        _seedPrevDoneState();
        _suppressStoreEvents = false;
        await _applySyncResult(
            Map<String, dynamic>.from(result), pushed: false);
      } catch (_) {
        // 替换失败时也解除守卫。
        _suppressStoreEvents = false;
        _pendingUnlock = false;
        await prefs0.remove('gd2_locked_journal');
        return false;
      }
      return RestoreResult(
        journalCount: _store.data.journal.length,
        lockedJournal: decrypted['_lockedJournal'] as String?,
      );
    } on SyncException { return false; }
    catch (_) { return false; }
    finally { _syncing = false; }
  }

  /// 用恢复码或 Base64 密钥解锁云端日记，恢复码自动识别并派生密钥。
  Future<bool> unlockJournalWithKey(String input, String encrypted) async {
    try {
      String keyBase64;
      if (JournalCrypto.looksLikeRecoveryCodes(input)) {
        keyBase64 = await recoveryKeyBase64InIsolate(input);
      } else {
        keyBase64 = input.replaceAll(RegExp(r'\s+'), '');
      }
      final key = JournalCrypto.keyFromBase64(keyBase64);
      final plain = await JournalCrypto.decrypt(encrypted, key);
      final journal =
          AppData.fromJson({'journal': jsonDecode(plain)}).journal;
      journalKeyBase64 = keyBase64;
      if (JournalCrypto.looksLikeRecoveryCodes(input)) {
        recoveryCodesHash = _hashCodes(input);
        recoveryCodesPlain =
            JournalCrypto.normalizeRecoveryInput(input);
      }
      _pendingUnlock = false;
      // 只解锁日记还不足以恢复任务和清单：保持封锁，等真正的恢复完成，
      // 否则本机（可能为空）的下一轮推送会覆盖云端备份。
      _suppressStoreEvents = false;
      try {
        final prefsClear = await SharedPreferences.getInstance();
        await prefsClear.remove('gd2_locked_journal');
      } catch (_) {}
      // 日记解锁成功（dataKey 已恢复）→ 顺带恢复情侣共享密钥，
      // 恢复码由此成为「恢复一切账号数据」的唯一钥匙。
      try {
        final prefs1 = await SharedPreferences.getInstance();
        final ckEnc = prefs1.getString('gd2_pending_couple_key_enc');
        if (ckEnc != null && ckEnc.isNotEmpty) {
          coupleKeyBase64 =
              await JournalCrypto.decryptWithBase64(keyBase64, ckEnc);
          await prefs1.remove('gd2_pending_couple_key_enc');
        }
        final ckLegacyEnc = prefs1.getString('gd2_pending_couple_legacy_enc');
        if (ckLegacyEnc != null && ckLegacyEnc.isNotEmpty) {
          coupleKeyLegacyB64 =
              await JournalCrypto.decryptWithBase64(keyBase64, ckLegacyEnc);
          await prefs1.remove('gd2_pending_couple_legacy_enc');
        }
      } catch (_) {}
      await _persist();
      for (final e in journal.entries) {
        _store.data.journal[e.key] = e.value;
      }
      _store.notifyDataChangedExternally();
      await _persist();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 待解锁的云端备份密文（上次恢复时留存，供设置页稍后解锁）。
  Future<String?> lockedJournalCipher() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('gd2_locked_journal');
    } catch (_) {
      return null;
    }
  }

  /// 本机上次用过的数据密钥，用于解锁提示预填。
  Future<String> lastJournalKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('gd2_journal_key_last') ?? '';
    } catch (_) {
      return '';
    }
  }

  String _hashCodes(String input) =>
      sha256.convert(utf8.encode(JournalCrypto.normalizeRecoveryInput(input)))
          .toString();

  // ---- profile ----

  Future<bool> pushAvatarFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final dataUrl =
          'data:image/jpeg;base64,${base64Encode(bytes)}';
      final result = await SyncApi.post('profile',
          {'token': token, 'name': myName, 'avatar': dataUrl});
      myAvatarDataUrl = (result['avatar'] as String?) ?? dataUrl;
      await _persist();
      return true;
    } on SyncException catch (e) {
      lastError = e.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> _cachePartnerAvatar(String dataUrl) async {
    try {
      final b64 = dataUrl.split(',').last;
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/partner_avatar.jpg';
      await File(path).writeAsBytes(base64Decode(b64));
      partnerAvatarPath = path;
      partnerAvatarDataUrl = dataUrl;
      await _persist();
    } catch (_) {}
  }

  Future<void> _storeDataUrlAsAvatar(String dataUrl) async {
    try {
      final b64 = dataUrl.split(',').last;
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/avatar_cloud.jpg';
      await File(path).writeAsBytes(base64Decode(b64));
      myAvatarDataUrl = dataUrl;
      avatarPath = path;
      await _persist();
    } catch (_) {}
  }

  // ---- recovery codes ----

  bool get hasRecoveryCodes => recoveryCodesHash.isNotEmpty;

  /// 生成 16 组恢复码，并把数据密钥换成由恢复码派生的那把。
  Future<List<String>> generateRecoveryCodes() async {
    // 云端备份还没解开时换钥，只会让新码解不开旧备份。
    if (_pendingUnlock || _restoreBlocked) {
      throw SyncException('云端备份还没解锁或恢复，处理完再更换恢复码');
    }
    final codes = JournalCrypto.generateRecoveryCodes();
    if (journalKeyBase64.isNotEmpty && _store.data.journal.isEmpty) {
      throw SyncException('本地日记为空，请先在云端备份页恢复后再生成恢复码');
    }
    final newKeyBase64 = await recoveryKeyBase64InIsolate(codes.join());
    // 换码前先把旧状态记下来：推送不成功就整体回退。
    final prevKey = journalKeyBase64;
    final prevPrevKey = journalKeyPrevBase64;
    final prevHash = recoveryCodesHash;
    if (prevKey.isNotEmpty && prevKey != newKeyBase64) {
      journalKeyPrevBase64 = prevKey;
    }
    journalKeyBase64 = newKeyBase64;
    recoveryCodesHash = _hashCodes(codes.join());
    // 明文恢复码仅当前会话可再查看（_persist 不落盘）。
    recoveryCodesPlain = codes.join(' ');
    await _persist();
    _dirty = true;
    // 等到没有在途同步再推：syncNow 遇到 _syncing 只会把推送延后 3 秒返回，
    // 直接判成败会误判成「没推成」，长轮询期间生成恢复码就总会失败。
    for (var i = 0; i < 40 && _syncing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    var pushedNewKey = false;
    await syncNow(push: true, manual: true,
        onPushResult: (p) => pushedNewKey = p);
    // 被并发占住时再给一次机会。
    if (!pushedNewKey && lastError == null) {
      await Future<void>.delayed(const Duration(seconds: 3));
      await syncNow(push: true, manual: true,
          onPushResult: (p) => pushedNewKey = p);
    }
    // 只有确认这一次真的把新密钥的备份推上去了，才把新恢复码交给用户。
    // 否则同步在途/断网时会「假成功」：用户拿到新码，云端却还是旧密钥，
    // 一旦换机，新旧两套码都对不上。
    if (lastError != null || !pushedNewKey) {
      // 云端还是旧密钥的密文。这时候留着新码最危险：用户以为新码是唯一钥匙，
      // 换机后拿新码解不开旧备份，而旧码已经被覆盖了。所以宁可整体回退，
      // 让原来那套恢复码继续有效，提示用户网络好了再生成。
      journalKeyBase64 = prevKey;
      journalKeyPrevBase64 = prevPrevKey;
      recoveryCodesHash = prevHash;
      recoveryCodesPlain = '';
      _dirty = true; // 保留本来待推的改动
      await _persist();
      notifyListeners();
      throw SyncException('这次没有更换恢复码，原来那套仍然有效；'
          '等网络恢复后再试一次');
    }
    notifyListeners();
    return codes;
  }

  // ---- settings ----

  void setTaskReminders(bool v) { swTaskReminders = v; _persist(); notifyListeners(); }
  void setAutoBackup(bool v) { autoBackup = v; _persist(); notifyListeners(); }
  void setCoupleMessages(bool v) { swCoupleMessages = v; Notify.instance.coupleMessagesEnabled = v; _persist(); notifyListeners(); }
  void setCoupleEvents(bool v) { swCoupleEvents = v; Notify.instance.coupleEventsEnabled = v; _persist(); notifyListeners(); }
  void setMilestoneReminders(bool v) { swMilestoneReminders = v; _persist(); notifyListeners(); }
  void setHabitReminders(bool v) { swHabitReminders = v; _persist(); notifyListeners(); }

  // ---- 倒数本 / 纪念日 ----

  /// 在一起起始日期键：优先自定义纪念日，其次绑定日；空=未知。
  String get togetherSinceKey {
    if (anniversary.isNotEmpty) return anniversary;
    if (boundAt > 0) {
      return dateKey(DateTime.fromMillisecondsSinceEpoch(boundAt));
    }
    return '';
  }

  /// 在一起第 N 天（起始当天算第 1 天）；0=未知。
  int get togetherDays {
    final key = togetherSinceKey;
    final p = key.split('-');
    if (p.length != 3) return 0;
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return 0;
    final now = DateTime.now();
    final n = DateTime.utc(now.year, now.month, now.day)
            .difference(DateTime.utc(y, m, d))
            .inDays +
        1;
    return n > 0 ? n : 1;
  }

  /// 合并双方的倒数本（置顶与最近优先）；record 第二位标记是否来自 TA。
  List<(Milestone, bool)> mergedMilestones(DateTime today) {
    final out = <(Milestone, bool)>[
      for (final m in _store.data.milestones) (m, false),
      if (partner != null)
        for (final m in partner!.data.milestones) (m, true),
    ];
    out.sort((a, b) => Milestone.compare(a.$1, b.$1, today));
    return out;
  }

  /// 设置或清除房间纪念日（空串=清除，回退按绑定日计）。
  Future<bool> setAnniversary(String dateKeyStr) async {
    if (!isBound) return false;
    final prev = anniversary;
    anniversary = dateKeyStr;
    notifyListeners();
    try {
      final result = await SyncApi.post(
          'setAnniversary', {'token': token, 'date': dateKeyStr});
      final server = result['anniversary'];
      if (server is String) anniversary = server;
      lastError = null;
      await _persist();
      notifyListeners();
      return true;
    } on SyncException catch (e) {
      lastError = e.message;
      anniversary = prev;
      notifyListeners();
      return false;
    }
  }

  /// 设备确认码：由绑定码与双方账号确定性派生，绑定后两端显示同一串码，
  /// 用于当面或语音核对设备（旧实现各自随机，双方永远对不上）。
  String get deviceVerifyCode {
    final me = accountId;
    final partner = partnerAccountId;
    if (_lastBindCode.isEmpty ||
        me == null ||
        partner == null ||
        me.length < 8 ||
        partner.length < 8) {
      return '';
    }
    final ids = [me, partner]..sort();
    final digest = sha256.convert(utf8.encode(
        'zhiji-device-verify:$_lastBindCode:${ids.join(':')}'));
    final n = int.parse(digest.toString().substring(0, 12), radix: 16);
    return ((n % 900000) + 100000).toString();
  }

  /// 由绑定码派生情侣共享密钥（双方各算各的，结果一致）。
  Future<void> _deriveCoupleKey() async {
    if (_lastBindCode.isEmpty ||
        partnerAccountId == null ||
        partnerAccountId!.length < 8 ||
        accountId == null ||
        accountId!.length < 8) {
      return;
    }
    final pair = [accountId!, partnerAccountId!]..sort();
    final salt = 'zhiji-couple-v1:${pair.join(':')}';
    final legacy =
        await pbkdf2Base64InIsolate(_lastBindCode, salt, 210000);
    coupleKeyLegacyB64 = legacy;
    if (_coupleKeyVer != 2) coupleKeyBase64 = legacy;
    await _persist();
  }

  /// 生成并持久化本机的 X25519 协商密钥对（每个配对一份，解绑即弃）。
  Future<void> _ensureCoupleKeyPair() async {
    if (_couplePrivB64.isNotEmpty && _couplePubB64.isNotEmpty) return;
    try {
      final (priv, pub) = await JournalCrypto.generateCoupleKeyPair();
      _couplePrivB64 = priv;
      _couplePubB64 = pub;
      await _persist();
    } catch (_) {}
  }

  bool _isKnownCoupleKey(String key) =>
      key == coupleKeyBase64 ||
      key == coupleKeyLegacyB64 ||
      coupleKeyExtras.contains(key);

  /// 快照被裁掉时补一次普通同步，把其它设备的数据拿回来。
  /// 加防重入，避免和长轮询抢着跑。
  void _scheduleSnapshotRefetch() {
    if (_snapshotRefetching) return;
    _snapshotRefetching = true;
    unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
      _snapshotRefetching = false;
      if (loggedIn && !_syncing) await syncNow(push: false);
    }));
  }

  Future<String> _signMyPubKey() async {
    try {
      return await JournalCrypto.signWithIdentity(
          _identityPrivB64, base64Decode(_couplePubB64));
    } catch (_) {
      return '';
    }
  }

  /// 身份公钥有问题时只提醒一次。
  void _raiseIdentityIssueOnce() {
    final pin = _peerIdentityPubB64.isEmpty ? 'none' : _peerIdentityPubB64;
    unawaited(notifyCoupleEventOnce(
      CoupleEvent('配对安全码对不上',
          '对方的身份密钥和之前不一样。先核对情侣页的安全码，不一致就先解绑重配',
          dedupKey: 'idkey:$pin'),
    ));
  }

  /// 对方公钥变了只提醒一次，别每次同步都弹。
  void _raisePeerKeyChangedOnce() {
    final pin = _couplePeerPubPinned.isEmpty ? 'none' : _couplePeerPubPinned;
    unawaited(notifyCoupleEventOnce(
      CoupleEvent('对方的密钥变了',
          '如果不是对方换了手机，建议先解绑再重新绑定；现在两边还是各用各的密钥',
          dedupKey: 'pairkey:$pin'),
    ));
  }

  /// 对端快照用哪把密钥加的，我们下轮就用哪把推：
  /// 双方各自升级、主密钥不同时，只靠"我有你没有"会各推各的永远读不了对方。
  /// 按 kid 把对方那把换到主密钥位，两轮之后双方就都收敛到同一把。
  Future<void> _mirrorPeerSharedKid(
      Map<String, dynamic> snapshot, List<CoupleEvent> events) async {
    // partnerSnapshot 是 {"data": {...}, "updatedAt": n} 的信封，
    // shared_kid 在里层 data 里。之前直接读外层，导致这段逻辑从来没跑起来。
    final inner = snapshot['data'];
    final env = inner is Map ? inner : snapshot;
    final kid = env['shared_kid'];
    if (kid is! String || kid.isEmpty) return;
    if (kid == coupleKid(coupleKeyBase64)) {
      _peerSharedKid = kid;
      return;
    }
    // 对方用的正是我们的备用密钥：换到主密钥位。
    if (coupleKeyLegacyB64.isNotEmpty && kid == coupleKid(coupleKeyLegacyB64)) {
      final oldMain = coupleKeyBase64;
      coupleKeyBase64 = coupleKeyLegacyB64;
      coupleKeyLegacyB64 = oldMain;
      _peerSharedKid = kid;
      await _persist();
      notifyListeners();
      _dirty = true;
      unawaited(syncNow(push: true, manual: true));
      return;
    }
    // 两把都对不上：说明对方换了密钥（或我们缺一代），记录下来，
    // 下一轮 sync 会带新公钥，交给 _upgradeToX25519Key 补协商。
    _peerSharedKid = kid;
    await _persist();
  }

  /// 双方公钥齐备后派生 v2 共享密钥；旧密钥留作历史密文解密回退。
  Future<void> _upgradeToX25519Key(String partnerPubKey) async {
    if (accountId == null || partnerAccountId == null) return;
    // 对方换过密钥对（重装/换机）后协商结果会变：即便已经升到 v2，
    // 也要用新公钥重算一次，把结果放进备用密钥，否则对方新推的内容解不开。
    final peerChanged = _couplePeerPubB64 != partnerPubKey;
    if (_coupleKeyVer == 2 && !peerChanged) return;
    // 本机还没生成过密钥对（例如绑定码不是本机生成的）：补一对，
    // 下一轮 sync 会把公钥报上去，再往后就能协商出共享密钥。
    if (_couplePrivB64.isEmpty) {
      await _ensureCoupleKeyPair();
      if (_couplePrivB64.isEmpty) return;
    }
    try {
      final key = await JournalCrypto.deriveCoupleKeyX25519(
          _couplePrivB64, partnerPubKey, [accountId!, partnerAccountId!]);
      _couplePeerPubB64 = partnerPubKey;
      if (key == coupleKeyBase64) {
        _coupleKeyVer = 2;
        await _persist();
        return;
      }
      if (coupleKeyBase64.isEmpty) {
        // 第一次协商：直接采用协商结果。
        coupleKeyBase64 = key;
        _coupleKeyVer = 2;
        await _persist();
        notifyListeners();
        // 之前推的共享包用的是旧密钥，对方解不开；这里补推一次。
        _dirty = true;
        unawaited(syncNow(push: true, manual: true));
        return;
      }
      // 本机已经有共享密钥（例如换机后从 coupleKeyEnc 恢复出来的）。
      // 这时再切换成协商出的新密钥会造成单向分叉：对方那边 ver 已是 2，
      // 不会再重算，从此解不开我们推上去的数据。
      // 保留原密钥作主密钥，把协商结果当备用密钥，两个方向都还能读。
      // 对方换了密钥对：新协商结果先收进候选。
      if (!_isKnownCoupleKey(key)) {
        coupleKeyExtras.add(key);
        // 只留最近四代，避免列表无限长。
        while (coupleKeyExtras.length > 12) {
          coupleKeyExtras.removeAt(0);
        }
      }
      // 对方公钥变了：这是我们第一次见到它就直接记下来（绑定码是当面/当面
      // 转发的，这一次的信任作为基准）；之后如果又变了，不自动换密钥——
      // 恶意服务端可以伪造公钥，把共享数据变成它也能解的内容。改由用户确认。
      if (_couplePeerPubPinned.isEmpty) {
        _couplePeerPubPinned = partnerPubKey;
        await _persist();
      } else if (_couplePeerPubPinned != partnerPubKey) {
        peerKeyChanged = true;
        await _persist();
        notifyListeners();
        _raisePeerKeyChangedOnce();
      }
      if (coupleKeyLegacyB64 != key) {
        // 旧的备用密钥别直接丢掉：那上面可能还挂着对方没读完的历史密文。
        final oldLegacy = coupleKeyLegacyB64;
        if (oldLegacy.isNotEmpty &&
            oldLegacy != key &&
            !_isKnownCoupleKey(oldLegacy)) {
          coupleKeyExtras.add(oldLegacy);
          while (coupleKeyExtras.length > 12) {
            coupleKeyExtras.removeAt(0);
          }
        }
        coupleKeyLegacyB64 = key;
        _coupleKeyVer = 2;
        await _persist();
        notifyListeners();
        // 备用密钥要跟着云备份走（换机后靠它解旧密文），所以这里得补推一次。
        _dirty = true;
        unawaited(syncNow(push: true, manual: true));
      }
    } catch (_) {}
  }

  /// 用当前密钥解密，失败时回退旧版绑定码派生密钥。
  /// 解密共享包。已配对的用情侣密钥（v2 协商密钥 + v1 兼容密钥）；
/// 未配对的云备份用本机数据密钥。三条都试，解不开返回 null。
  Future<String?> _tryDecryptShared(String cipher,
      {bool allowOwnKey = false, String? hint}) async {
    // shared_key 表明写这份快照时用的是共享密钥还是个人数据密钥，
    // 有就按它先试，省掉一次必然失败的解密（2 MB 快照约 190ms）。
    final coupleKeys = [coupleKeyBase64, coupleKeyLegacyB64,
        ...coupleKeyExtras];
    final ownKeys = allowOwnKey
        ? [journalKeyBase64, journalKeyPrevBase64]
        : const <String>[];
    final ordered = switch (hint) {
      'own' => [...ownKeys, ...coupleKeys],
      'couple' => [...coupleKeys, ...ownKeys],
      _ => [...coupleKeys, ...ownKeys],
    };
    for (final key in ordered) {
      if (key.isEmpty) continue;
      try {
        return await JournalCrypto.decryptWithBase64(key, cipher);
      } catch (_) {}
    }
    return null;
  }

  /// 解日记密文。换过恢复码时云端可能还是旧密钥加密的，两把都试。
  Future<String?> _tryDecryptJournal(String cipher) async {
    for (final k in [journalKeyBase64, journalKeyPrevBase64]) {
      if (k.isEmpty) continue;
      try {
        return await JournalCrypto.decryptWithBase64(k, cipher);
      } catch (_) {}
    }
    return null;
  }

  /// 设置情侣「纪念日」名称（存房间，双方同步；空串回退默认显示）。
  Future<bool> setCoupleBookName(String name) async {
    if (!isBound) return false;
    final prev = coupleBookName;
    coupleBookName = name;
    notifyListeners();
    try {
      final result =
          await SyncApi.post('setBookName', {'token': token, 'name': name});
      final server = result['bookName'];
      if (server is String) coupleBookName = server;
      lastError = null;
      await _persist();
      notifyListeners();
      return true;
    } on SyncException catch (e) {
      lastError = e.message;
      coupleBookName = prev;
      notifyListeners();
      return false;
    }
  }

  Future<void> clearLocalCache() async {
    comments = []; messages = []; unseenCount = 0; unreadMessages = 0;
    await _persist(); notifyListeners();
  }

  Future<void> setMyName(String name) async {
    myName = name;
    _persist();
    notifyListeners();
    if (loggedIn) {
      try {
        await SyncApi.post('profile', {'token': token, 'name': name});
      } on SyncException catch (_) {}
      notifyListeners();
    }
  }

  Future<bool> setAvatarPath(String path) async {
    avatarPath = path;
    _persist();
    notifyListeners();
    if (!loggedIn) return true;
    return pushAvatarFile(path);
  }

  // ---- journal key ----

  Future<String> getOrCreateJournalKey() async {
    if (journalKeyBase64.isNotEmpty) return journalKeyBase64;
    journalKeyBase64 = base64Encode(List.generate(32, (_) => _rng.nextInt(256)));
    // 必须落盘后再返回：否则进程被杀会导致云端日记用一个已经丢失的密钥加密。
    await _persist();
    return journalKeyBase64;
  }

  // ---- messages / comments ----

  // ---- 消息归档（收藏） ----

  /// 归档消息快照：独立于 300 条滚动窗口，被淘汰后归档页仍显示全文。
  List<Map<String, dynamic>> _msgArchive = [];

  /// 归档的消息（按归档时间倒序）。
  List<Map<String, dynamic>> get archivedMessages => _msgArchive;

  bool isMessageArchived(String messageId) =>
      _msgArchive.any((m) => m['id'] == messageId);

  Future<void> _loadMsgArchive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('gd2_msg_archive');
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      _msgArchive = list;
    } catch (_) {
      _msgArchive = [];
    }
  }

  Future<void> _saveMsgArchive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 上限 200 条，超出丢最旧的。
      if (_msgArchive.length > 200) {
        _msgArchive = _msgArchive.sublist(0, 200);
      }
      await prefs.setString('gd2_msg_archive', jsonEncode(_msgArchive));
    } catch (_) {}
  }

  /// 收藏一条留言：保存明文快照，消息滚出窗口后仍可查看。
  Future<void> archiveMessage(CoupleMessage m, String senderName) async {
    if (isMessageArchived(m.id)) return;
    _msgArchive.insert(0, {
      'id': m.id,
      'byAccountId': m.byAccountId,
      'sender': m.byAccountId == accountId ? '我' : senderName,
      'text': m.text,
      'createdAt': m.createdAt,
      'archivedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await _saveMsgArchive();
    notifyListeners();
  }

  Future<void> unarchiveMessage(String messageId) async {
    _msgArchive.removeWhere((m) => m['id'] == messageId);
    await _saveMsgArchive();
    notifyListeners();
  }

  Future<bool> sendMessage(String text, {String? replyTo}) async {
    final t = text.trim();
    if (t.isEmpty || !isBound) return false;
    // 已配对却没有共享密钥：不能明文发出去。返回 false 让调用方保留草稿，
    // 不要在这里抛异常——调用方会清输入框，用户打的字就没了。
    if (coupleKeyBase64.isEmpty) {
      lastError = '共享密钥还没就绪，先在「我的 → 云端备份」里解锁备份，或重新登录后再发';
      notifyListeners();
      return false;
    }
    try {
      // 留言文本以情侣共享密钥加密传输。
      final encText =
          await JournalCrypto.encryptWithBase64(coupleKeyBase64, t);
      final result = await SyncApi.post('sendMessage', {
        'token': token,
        'text': encText,
        'enc': true,
        'replyTo': ?((replyTo?.isEmpty ?? true) ? null : replyTo),
      });
      final raw = result['message'];
      if (raw is Map) {
        // 服务端回传的是密文，本地以明文保存展示。
        final m = Map<String, dynamic>.from(raw);
        if (m['kind'] != 'deleted' && m['kind'] != 'system') {
          m['text'] = await _decryptMessageText(m['text'] as String? ?? '');
        }
        messages.add(CoupleMessage.fromJson(m));
        lastError = null;
        await _persist(); notifyListeners();
        return true;
      }
      return false;
    } on SyncException catch (e) {
      lastError = e.message;
      notifyListeners();
      return false;
    }
  }

  /// 撤回自己的文字消息：本地先变墓碑，服务端拒绝则还原。
  Future<bool> recallMessage(String messageId) async {
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return false;
    final orig = messages[idx];
    if (orig.byAccountId != accountId || orig.isSystem || orig.isDeleted) {
      return false;
    }
    messages[idx] = CoupleMessage(
      id: orig.id,
      byAccountId: orig.byAccountId,
      kind: 'deleted',
      text: '撤回了一条消息',
      createdAt: orig.createdAt,
    );
    notifyListeners();
    try {
      await SyncApi.post(
          'deleteMessage', {'token': token, 'messageId': messageId});
      lastError = null;
      // 本机若收藏过该留言，撤回后同步移除（对方设备上的收藏为快照，无法远程清理）。
      if (isMessageArchived(messageId)) {
        await unarchiveMessage(messageId);
      }
      await _persist();
      return true;
    } on SyncException catch (e) {
      final i = messages.indexWhere((m) => m.id == messageId);
      if (i >= 0) messages[i] = orig;
      lastError = e.message;
      notifyListeners();
      return false;
    }
  }

  List<CoupleComment> myCommentsFor(String targetId, String targetKind) => comments
      .where((c) => c.byAccountId == accountId && c.targetOwnerAccountId == partnerAccountId &&
          c.targetId == targetId && c.targetKind == targetKind).toList();

  List<CoupleComment> commentsForMe(String targetId, String targetKind) => comments
      .where((c) => c.byAccountId == partnerAccountId && c.targetOwnerAccountId == accountId &&
          c.targetId == targetId && c.targetKind == targetKind).toList();

  Future<void> addComment({required String targetId, required String targetKind,
      required String displayTitle, String? emoji, String text = ''}) async {
    if (!isBound) return;
    // 评价正文和内容标题都只有双方该看到：用共享密钥加密后再发。
    // 没有密钥时宁可不发，也不把明文交出去。
    final canEncrypt = coupleKeyBase64.isNotEmpty;
    if (!canEncrypt && text.isNotEmpty) {
      lastError = '共享密钥还没就绪，先在「我的 → 云端备份」里解锁备份后再评价';
      notifyListeners();
      return;
    }
    try {
      final payload = <String, dynamic>{
        'token': token, 'targetOwnerAccountId': partnerAccountId,
        'targetId': targetId, 'targetKind': targetKind,
        'kind': emoji != null ? 'emoji' : 'text', 'emoji': ?emoji,
        'enc': canEncrypt,
      };
      if (canEncrypt) {
        payload['text'] = text.isEmpty
            ? ''
            : await JournalCrypto.encryptWithBase64(coupleKeyBase64, text);
        payload['displayTitle'] = displayTitle.isEmpty
            ? ''
            : await JournalCrypto.encryptWithBase64(
                coupleKeyBase64, displayTitle);
      } else {
        payload['text'] = text;
        payload['displayTitle'] = displayTitle;
      }
      final result = await SyncApi.post('addComment', payload);
      final raw = result['comment'];
      if (raw is Map) {
        final m = Map<String, dynamic>.from(raw);
        // 服务端回传的是密文，本地存明文用于展示。
        if ((m['enc'] ?? false) == true && m['text'] is String) {
          final plain = await _tryDecryptShared(m['text'] as String,
              allowOwnKey: false);
          if (plain != null) m['text'] = plain;
        }
        comments.insert(0, CoupleComment.fromJson(m));
        lastError = null;
        await _persist(); notifyListeners();
      }
    } on SyncException catch (e) { lastError = e.message; notifyListeners(); }
  }

  void markSeen() {
    if (unseenCount == 0 && unreadMessages == 0) return;
    unseenCount = 0; unreadMessages = 0; notifyListeners();
    // 立刻上行已读回执，不等下一个轮询 tick；
    // 若撞上在途同步（留言板常态是挂起中的长轮询），置位由其结束时补发。
    if (isBound) {
      // 只在真的撞上在途同步时挂起补发；否则本次请求已带 readUpTo。
      _readReceiptPending = _syncing;
      syncNow(push: _dirty, forceShort: true);
    }
  }

  /// 概览页看过评价/动态：只清事件未读，不动留言未读。
  void markEventsSeen() {
    if (unseenCount == 0) return;
    unseenCount = 0;
    notifyListeners();
    unawaited(_persist());
  }
}

class RestoreResult {
  RestoreResult({
    required this.journalCount,
    this.lockedJournal,
    this.needsUnlock = false,
  });

  final int journalCount;
  final String? lockedJournal;

  /// 云端有数据但本机缺密钥：先解锁，解锁后会自动补完恢复。
  final bool needsUnlock;
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) { if (test(element)) return element; }
    return null;
  }
}



/// 退后台兜底闹钟的后台 isolate 入口。
/// 独立 isolate 没有共享状态，需各自初始化 store 与同步服务。
@pragma('vm:entry-point')
Future<void> backgroundSyncAlarmEntry(int id, Map<String, dynamic> params) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.load();
  final sync = SyncService(store);
  await sync.init();
  await sync.alarmTick();
}
