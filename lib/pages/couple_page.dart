import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../widgets/responsive.dart';

import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/colors.dart';
import '../data/milestone_icons.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../sync/couple_models.dart';
import '../sync/notify.dart';
import '../sync/sync_service.dart';
import '../theme.dart';
import '../ui_prefs.dart';
import '../util/native_share.dart';
import '../widgets/m3e_progress.dart';
import '../util/dates.dart';
import '../widgets/empty_state.dart';
import '../widgets/partner_widgets.dart';
import '../widgets/m3_dialog.dart';
import '../widgets/recovery_codes.dart';
import '../main.dart' show globalRouteHandler;
import 'milestone_book_page.dart';
import '../widgets/top_toast.dart' show showTopToast;

/// 情侣页：登录、绑定码配对、概览与留言板
class CouplePage extends StatefulWidget {
  const CouplePage({super.key, this.background = false, this.initialTab = 0});

  /// true = 常驻后台实例，不触发启动副作用。
  final bool background;

  /// 初始 tab：0 概览，1 留言板（横幅点击直达）。
  final int initialTab;

  @override
  State<CouplePage> createState() => _CouplePageState();
}

class _CouplePageState extends State<CouplePage> {
  final _codeCtrl = TextEditingController();
  bool _creatingCode = false;
  bool _joining = false;
  // 生成绑定码失败后的退避时刻，避免 provider 通知把重试放大成风暴。
  DateTime? _nextCodeAttemptAt;

  /// 本次进程内已自动弹过指纹引导的指纹值；同一串不反复弹，
  /// 换配对（指纹变化）或重启 App 才会再次提示。
  static String? _promptedFingerprint;

  bool _fpPromptScheduled = false;

  @override
  void initState() {
    super.initState();
    // 进入页面时才请求通知权限与绑定码；后台常驻实例不做任何副作用。
    if (widget.background) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Notify.instance.requestPermission();
      _maybeEnsureCode();
    });
  }

  void _maybeEnsureCode({bool force = false}) {
    final sync = context.read<SyncService>();
    if (!sync.loggedIn || sync.isBound || sync.myCode != null) return;
    if (_creatingCode) return;
    final now = DateTime.now();
    if (!force &&
        _nextCodeAttemptAt != null &&
        now.isBefore(_nextCodeAttemptAt!)) {
      return;
    }
    // 失败退避：didChangeDependencies 会随每次 provider 通知触发，
    // 不节流会在离线时按请求往返节奏反复 createRoom。
    _nextCodeAttemptAt = now.add(const Duration(seconds: 30));
    _creatingCode = true;
    sync.ensureMyCode().whenComplete(() => _creatingCode = false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.background) return;
    _maybeEnsureCode();
  }

  /// 绑定完成后自动引导一次：没核对过指纹就弹，避免用户从不去打开启页。
  /// 只在前台页面触发（background 常驻实例不弹）。
  void _maybePromptFingerprint(SyncService sync) {
    if (widget.background) return;
    if (!sync.loggedIn || !sync.isBound) return;
    if (sync.pairFingerprintConfirmed) return;
    final fp = sync.pairingFingerprint;
    if (fp.isEmpty || fp == _promptedFingerprint || _fpPromptScheduled) return;
    _fpPromptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fpPromptScheduled = false;
      if (!mounted) return;
      _promptedFingerprint = fp;
      _showFingerprintGuide(fp);
    });
  }

  Future<void> _showFingerprintGuide(String fp) async {
    final sync = context.read<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final agreed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('核对配对指纹'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '两台手机应显示同一串；不一致说明公钥被换过，'
              '建议解绑重配',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                fp,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('一致，继续'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (agreed == true) await sync.confirmPairFingerprint();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (_joining) return;
    _joining = true;
    final sync = context.read<SyncService>();
    try {
      await Notify.instance.requestPermission();
      await sync.join(_codeCtrl.text);
      if (!mounted) return;
      if (sync.isBound) {
        _codeCtrl.clear();
      } else if (sync.lastError != null) {
        showTopToast(sync.lastError!);
      }
    } finally {
      _joining = false;
    }
  }

  Future<void> _retryCreateCode() async {
    final sync = context.read<SyncService>();
    sync.lastError = null;
    _maybeEnsureCode(force: true);
  }

  Future<void> _unbindConfirm() async {
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('解除情侣绑定？'),
        content: const Text('解除后双方不再同步，云端房间将删除，本机数据不受影响'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<SyncService>().unbind();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    _maybePromptFingerprint(sync);
    return Scaffold(
      appBar: AppBar(title: const Text('情侣')),
      body: ResponsiveContent(
        maxWidth: 900,
        child: AnimatedSwitcher(
          // 登录、绑定、已绑定三态过渡
          duration: m3Medium,
          switchInCurve: m3CurveIn,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: !sync.loggedIn
              ? const _AccountView(key: ValueKey('account'))
              : !sync.isBound
              ? _UnboundView(
                  key: const ValueKey('unbound'),
                  codeCtrl: _codeCtrl,
                  onJoin: _join,
                  onRetryCreateCode: _retryCreateCode,
                )
              : _BoundView(
                  key: const ValueKey('bound'),
                  initialTab: widget.initialTab,
                  background: widget.background,
                  onUnbind: _unbindConfirm,
                ),
        ),
      ),
    );
  }
}

// ---------- 账号 ----------

class _AccountView extends StatefulWidget {
  const _AccountView({super.key});

  @override
  State<_AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends State<_AccountView> {
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  bool _register = false;
  int _countdown = 0;
  bool _requesting = false;
  bool _submitting = false;
  bool _obscure = true;
  String? _emailError;
  String? _passwordError;
  String? _codeError;
  Timer? _timer;

  bool get _emailValid {
    final e = _emailCtrl.text.trim();
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e);
  }

  void _clearFieldErrors() {
    _emailError = null;
    _passwordError = null;
    _codeError = null;
    context.read<SyncService>().lastError = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _passwordCtrl.dispose();
    _nicknameCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestCode() async {
    if (_requesting || _countdown > 0) return;
    if (!_emailValid) {
      setState(() => _emailError = '邮箱格式不对');
      return;
    }
    setState(() => _requesting = true);
    final sync = context.read<SyncService>();
    final ok = await sync.requestCode(_emailCtrl.text);
    if (!mounted) return;
    setState(() => _requesting = false);
    if (ok) {
      setState(() => _countdown = 60);
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _countdown--;
          if (_countdown <= 0) t.cancel();
        });
      });
      showTopToast('验证码已发送，请查收邮箱');
    } else {
      showTopToast(sync.lastError ?? '发送失败，请稍后再试');
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    var ok = true;
    if (!_emailValid) {
      _emailError = '邮箱格式不对';
      ok = false;
    }
    if (_passwordCtrl.text.length < 6) {
      _passwordError = '密码至少 6 位';
      ok = false;
    }
    if (_register && _codeCtrl.text.trim().length != 6) {
      _codeError = '请输入 6 位验证码';
      ok = false;
    }
    if (!ok) {
      setState(() {});
      return;
    }
    setState(() => _submitting = true);
    final sync = context.read<SyncService>();
    await Notify.instance.requestPermission();
    final nickname = _nicknameCtrl.text.trim();
    if (_register) {
      await sync.register(
        _emailCtrl.text.trim(),
        _passwordCtrl.text,
        code: _codeCtrl.text.trim(),
        nickname: nickname,
      );
    } else {
      await sync.login(_emailCtrl.text.trim(), _passwordCtrl.text);
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (sync.loggedIn) {
      showTopToast('已登录');
      // 首次注册：引导生成并下载保存备份恢复码。
      if (_register && !sync.hasRecoveryCodes && mounted) {
        // 注册成功后父级会立刻切走本视图，改用根导航器延后弹，不依赖本组件存活。
        final nav = Navigator.of(context);
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (nav.mounted) showRecoverySetupFlow(nav.context);
        });
      }
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.favorite_rounded, color: scheme.primary),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.favorite_border_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  '登录账号，开启同步',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '计划、清单、日记、习惯会同步到云端，换机登录可恢复',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.login_rounded, size: 16),
                      label: Text('登录'),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.person_add_rounded, size: 16),
                      label: Text('注册'),
                    ),
                  ],
                  selected: {_register},
                  onSelectionChanged: (s) {
                    m3HapticSelect();
                    setState(() => _register = s.first);
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _emailCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: '邮箱',
                    prefixIcon: const Icon(
                      Icons.mail_outline_rounded,
                      size: 20,
                    ),
                    errorText: _emailError,
                  ),
                  onChanged: (_) {
                    _clearFieldErrors();
                    setState(() {});
                  },
                ),
                if (_register) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _codeCtrl,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            labelText: '邮箱验证码',
                            counterText: '',
                            errorText: _codeError,
                          ),
                          onChanged: (_) {
                            _clearFieldErrors();
                            setState(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed:
                            (_emailValid && _countdown == 0 && !_requesting)
                            ? _requestCode
                            : null,
                        child: Text(
                          _countdown > 0
                              ? '$_countdown 秒'
                              : (_requesting ? '发送中…' : '获取验证码'),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordCtrl,
                  obscureText: _obscure,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: '密码（至少 6 位）',
                    prefixIcon: const Icon(
                      Icons.lock_outline_rounded,
                      size: 20,
                    ),
                    errorText: _passwordError,
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '显示密码' : '隐藏密码',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  onChanged: (_) {
                    _clearFieldErrors();
                    setState(() {});
                  },
                ),
                AnimatedSwitcher(
                  duration: m3Small,
                  switchInCurve: m3CurveIn,
                  switchOutCurve: m3CurveOut,
                  child: !_register
                      ? const SizedBox(width: double.infinity)
                      : KeyedSubtree(
                          key: const ValueKey('nickname'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 10),
                              TextField(
                                controller: _nicknameCtrl,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _submit(),
                                maxLength: 20,
                                decoration: const InputDecoration(
                                  labelText: '昵称（TA 看到的名字，可不填）',
                                  counterText: '',
                                  prefixIcon: Icon(
                                    Icons.badge_outlined,
                                    size: 20,
                                  ),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          ),
                        ),
                ),
                if (sync.lastError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    sync.lastError!,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    child: _submitting
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onPrimary,
                            ),
                          )
                        : Text(_register ? '注册并登录' : '登录'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '不登录也可使用本地功能；密码保存在同步服务器',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool get _canSubmit {
    if (!_emailValid || _passwordCtrl.text.length < 6) return false;
    if (_register && _codeCtrl.text.trim().length != 6) return false;
    return true;
  }
}

// ---------- 未绑定 ----------

class _UnboundView extends StatelessWidget {
  const _UnboundView({
    super.key,
    required this.codeCtrl,
    required this.onJoin,
    required this.onRetryCreateCode,
  });

  final TextEditingController codeCtrl;
  final VoidCallback onJoin;
  final VoidCallback onRetryCreateCode;

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: scheme.primaryContainer,
                  backgroundImage:
                      sync.avatarPath.isNotEmpty &&
                          File(sync.avatarPath).existsSync()
                      ? FileImage(File(sync.avatarPath))
                      : null,
                  child:
                      sync.avatarPath.isEmpty ||
                          !File(sync.avatarPath).existsSync()
                      ? Text(
                          sync.myName.isEmpty ? '我' : sync.myName[0],
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: scheme.primary,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sync.myName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        sync.username,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '已登录，自动同步',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    // 退出清除本机备份密钥，需确认。
                    final confirmed = await showM3Dialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('退出登录？'),
                        content: const Text('退出会清除本机备份密钥；未保存恢复码将无法解密云端备份'),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: Theme.of(dialogContext)
                                  .colorScheme
                                  .error,
                              foregroundColor: Theme.of(dialogContext)
                                  .colorScheme
                                  .onError,
                            ),
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child: const Text('退出'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true && context.mounted) {
                      await context.read<SyncService>().logout();
                    }
                  },
                  child: const Text('退出'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '我的绑定码',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '复制',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        if (sync.myCode == null) return;
                        m3HapticSelect();
                        Clipboard.setData(ClipboardData(text: sync.myCode!));
                        showTopToast('已复制');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Center(
                  // 绑定码到达时轻微放大入场；等待中显示呼吸省略号。
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: sync.myCode == null ? 0.86 : 1.0),
                    duration: m3Medium,
                    curve: m3CurveIn,
                    builder: (_, v, child) =>
                        Transform.scale(scale: v, child: child),
                    child: AnimatedOpacity(
                      duration: m3Medium,
                      opacity: sync.myCode == null ? 0.45 : 1,
                      child: Text(
                        sync.myCode ?? '······',
                        style: TextStyle(
                          fontSize: 34,
                          letterSpacing: 8,
                          fontWeight: FontWeight.bold,
                          color: scheme.primary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '让 TA 登录后输入这串码',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '输入 TA 的绑定码',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: codeCtrl,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9A-Za-z]'),
                          ),
                          LengthLimitingTextInputFormatter(6),
                        ],
                        maxLength: 6,
                        decoration: const InputDecoration(
                          hintText: '如 7K2M9X',
                          counterText: '',
                        ),
                        style: const TextStyle(
                          fontSize: 18,
                          letterSpacing: 4,
                          fontWeight: FontWeight.w600,
                        ),
                        onSubmitted: (_) => onJoin(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(onPressed: onJoin, child: const Text('绑定')),
                  ],
                ),
                if (sync.lastError != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          sync.lastError!.contains('绑定码')
                              ? '绑定码可能已过期，请查看最新绑定码'
                              : sync.lastError!,
                          style: TextStyle(fontSize: 12, color: scheme.error),
                        ),
                      ),
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: const Text('重试', style: TextStyle(fontSize: 11)),
                        onPressed: onRetryCreateCode,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '绑定后双方内容互相同步，可随时解绑',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------- 已绑定 ----------

class _BoundView extends StatefulWidget {
  const _BoundView({
    super.key,
    required this.onUnbind,
    this.initialTab = 0,
    this.background = false,
  });

  final VoidCallback onUnbind;

  /// 初始 tab：0 概览，1 留言板。
  final int initialTab;

  /// 后台常驻实例：不起周期同步定时器。
  final bool background;

  @override
  State<_BoundView> createState() => _BoundViewState();
}

class _BoundViewState extends State<_BoundView> with WidgetsBindingObserver {
  int _tab = 0; // 0 概览 1 留言板
  final _msgCtrl = TextEditingController();
  Timer? _autoSync;
  CoupleMessage? _replying;
  late final SyncService _sync = context.read<SyncService>();
  bool? _battCardVisible; // null=检测中
  bool _lifecycleResumed = true;
  // 已看过的留言 id 放在常驻的页面态里：切 tab 重建留言板时不重播入场动画。
  final Set<String> _boardSeen = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 横幅/通知直达留言板：初始 tab 由外部指定。
    _tab = widget.initialTab == 1 ? 1 : 0;
    if (_tab == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync.setBoardVisible(true);
      });
    }
    // 已读时机：只在留言板 tab 可见时标记（概览页/通知不算已读）。
    // 后台常驻实例（IndexedStack 不可达槽位）不产生任何同步副作用。
    if (!widget.background) {
      _autoSync = Timer.periodic(const Duration(minutes: 1), (_) {
        // 熄屏/退后台不推全量快照；这些场景由 SyncService 自己的轮询兜底。
        if (mounted && _lifecycleResumed) _sync.syncNow(push: true);
      });
    }
    _checkBatteryCard();
  }

  Future<void> _checkBatteryCard() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('gd2_batt_hint_done') == true) return;
    final ignored = await NativeShare.isIgnoringBatteryOptimizations();
    if (mounted) setState(() => _battCardVisible = !ignored);
  }

  void _dismissBatteryCard() async {
    setState(() => _battCardVisible = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('gd2_batt_hint_done', true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSync?.cancel();
    // 后台常驻实例不参与可见性标记，避免误清前台留言板的已读时机。
    if (!widget.background) _sync.setBoardVisible(false);
    _msgCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 熄屏/切后台时不再「停留留言板」：撤回可见标记让新留言照常
    // 弹横幅与通知，也不自动计已读；回到前台且停在留言板再恢复。
    final visible = state == AppLifecycleState.resumed;
    if (visible == _lifecycleResumed) return;
    _lifecycleResumed = visible;
    if (!widget.background) {
      _sync.setBoardVisible(visible && _tab == 1);
      if (visible && _tab == 1) setState(() {});
    }
  }

  Future<void> _send({String? replyTo}) async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    m3HapticSelect();
    final sync = context.read<SyncService>();
    // 失败时回复引用也要还原，否则重发会降级成普通留言。
    final hadReply = replyTo != null;
    _msgCtrl.clear();
    setState(() => _replying = null);
    await sync.sendMessage(text, replyTo: replyTo);
    if (!mounted) return;
    // 失败时把文字放回输入框（输入框已有新内容则不覆盖）。
    if (sync.lastError != null) {
      if (_msgCtrl.text.isEmpty) {
        _msgCtrl.text = text;
        _msgCtrl.selection = TextSelection.fromPosition(
          TextPosition(offset: text.length),
        );
      }
      if (hadReply) {
        CoupleMessage? original;
        for (final m in sync.messages) {
          if (m.id == replyTo) original = m;
        }
        setState(() => _replying = original);
      }
      showTopToast('发送失败：${sync.lastError}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final boardUnread = sync.unreadMessages + sync.unseenCount;
    if (_tab == 1 &&
        boardUnread > 0 &&
        !widget.background &&
        _lifecycleResumed) {
      // 停在留言板期间收到新消息：直接视为已读。
      // 熄屏/切后台不算（_lifecycleResumed=false），避免假已读吞通知。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _tab == 1 &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          context.read<SyncService>().markSeen();
        }
      });
    }
    if (_tab == 0 &&
        sync.unseenCount > 0 &&
        !widget.background &&
        _lifecycleResumed) {
      // 概览页就是评价与动态的落地页：看到即清未读角标（不动留言未读）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tab == 0) {
          context.read<SyncService>().markEventsSeen();
        }
      });
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SegmentedButton<int>(
            segments: [
              const ButtonSegment(
                value: 0,
                icon: Icon(Icons.space_dashboard_outlined, size: 16),
                label: Text('概览'),
              ),
              ButtonSegment(
                value: 1,
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('留言板'),
                    if (boardUnread > 0) ...[
                      const SizedBox(width: 5),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: scheme.error,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (s) {
              m3HapticSelect();
              if (s.first == 1) {
                // 先置可见标记再 markSeen：本次回执请求才带得上 readUpTo。
                sync.setBoardVisible(true);
                sync.markSeen();
              } else {
                sync.setBoardVisible(false);
              }
              setState(() => _tab = s.first);
            },
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
        ),
        if (_battCardVisible == true)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.battery_saver_rounded,
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '允许后台运行，同步更及时',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _dismissBatteryCard,
                      child: const Text('不再提醒', style: TextStyle(fontSize: 12)),
                    ),
                    FilledButton.tonal(
                      onPressed: () async {
                        await NativeShare.requestIgnoreBatteryOptimizations();
                        final ignored =
                            await NativeShare.isIgnoringBatteryOptimizations();
                        if (ignored) {
                          _dismissBatteryCard();
                        } else if (mounted) {
                          setState(() => _battCardVisible = true);
                        }
                      },
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('去设置', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: AnimatedSwitcher(
            duration: m3Duration,
            switchInCurve: m3Curve,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: _tab == 0
                ? _OverviewTab(
                    key: const ValueKey('overview'),
                    onUnbind: widget.onUnbind,
                  )
                : _MessageBoard(
                    key: const ValueKey('board'),
                    send: _send,
                    msgCtrl: _msgCtrl,
                    replying: _replying,
                    onPickReply: (m) => setState(() => _replying = m),
                    onCancelReply: () => setState(() => _replying = null),
                    seenIds: _boardSeen,
                  ),
          ),
        ),
      ],
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({super.key, required this.onUnbind});

  final VoidCallback onUnbind;

  String _describeComment(CoupleComment c, BuildContext context) {
    final store = context.read<AppStore>();
    final couple = context.read<SyncService>();
    String what;
    switch (c.targetKind) {
      case kindJournal:
        try {
          final p = c.targetId.split('-');
          final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
          what = '日记（${monthDay(d)}）';
        } catch (_) {
          what = '日记';
        }
      case kindHabit:
        final h = store.habitById(c.targetId);
        what = '习惯「${h?.name ?? '已删除'}」';
      default:
        final t = store.taskById(c.targetId);
        what = '任务「${t?.title ?? '已删除'}」';
    }
    if (c.kind == 'emoji') {
      return '${couple.partnerName} ${reactionLabel(c.emoji)}了你的$what';
    }
    return '${couple.partnerName} 评价了你的$what：${c.text}';
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;

    final weekStart = weekStartOf(today());
    final (myDone, myTotal) = store.weekStat(weekStart);
    var taDone = 0;
    var taTotal = 0;
    if (sync.partner != null) {
      final pd = sync.partner!.data;
      for (var i = 0; i < 7; i++) {
        final d = weekStart.add(Duration(days: i));
        for (final t in pd.tasks) {
          if (!t.archived && t.occursOn(d)) {
            taTotal++;
            if (t.isDoneOn(d)) taDone++;
          }
        }
      }
      for (final t in pd.tasks) {
        if (!t.archived && !t.hasDate && !t.isRecurring) {
          taTotal++;
          if (t.done) taDone++;
        }
      }
    }

    final received = sync.comments
        .where((c) => c.targetOwnerAccountId == sync.accountId)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        if (sync.pairingFingerprint.isNotEmpty) const _PairFingerprintLine(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.tertiaryContainer,
                  backgroundImage:
                      sync.partnerAvatarPath.isNotEmpty &&
                          File(sync.partnerAvatarPath).existsSync()
                      ? FileImage(File(sync.partnerAvatarPath))
                      : null,
                  child: sync.partnerAvatarPath.isEmpty
                      ? Icon(
                          Icons.favorite_rounded,
                          color: scheme.tertiary,
                          size: 24,
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '和 ${sync.partnerName} 在一起',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      _TogetherLine(sync: sync),
                      if (sync.partnerEmail.isNotEmpty)
                        Text(
                          sync.partnerEmail,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      // 连接失败时可点击立即重试；健康状态行平时不可点。
                      GestureDetector(
                        onTap:
                            sync.health == SyncHealth.serverDown ||
                                sync.health == SyncHealth.offline
                            ? () {
                                m3HapticSelect();
                                sync.retryNow();
                              }
                            : null,
                        child: Text(
                          sync.syncStatusLine,
                          style: TextStyle(
                            fontSize: 12,
                            color: sync.health == SyncHealth.error
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                            decoration:
                                sync.health == SyncHealth.serverDown ||
                                    sync.health == SyncHealth.offline
                                ? TextDecoration.underline
                                : TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const _SyncButton(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        AnniversaryCard(store: store, sync: sync),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '本周概览',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                _WeekRow(
                  label: '我',
                  done: myDone,
                  total: myTotal,
                  color: scheme.primary,
                ),
                const SizedBox(height: 10),
                _WeekRow(
                  label: sync.partnerName,
                  done: taDone,
                  total: taTotal,
                  color: scheme.tertiary,
                ),
              ],
            ),
          ),
        ),
        if (received.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '收到的评价',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  for (final c in received.take(20))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            c.kind == 'emoji'
                                ? reactionIcon(c.emoji)
                                : Icons.chat_bubble_rounded,
                            size: 14,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _describeComment(c, context),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (context.watch<SyncService>().isBound &&
            context.watch<SyncService>().coupleKeyVer < 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '更强加密需解绑后重新配对',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
          onPressed: onUnbind,
          child: const Text('解除绑定'),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 情侣概览的「纪念日」卡：名称可重命名（双方同步）；外显哪些条目
/// 按情侣纪念日自己的设置，与日子页倒数本的设置各自独立。
///
/// 每条一行：色块图标、标题与下次日期、右侧大数字天数。
/// 基线对齐靠 forceStrut，避免全角字符和 emoji 把两列顶歪。
class AnniversaryCard extends StatelessWidget {
  const AnniversaryCard({super.key, required this.store, required this.sync});

  final AppStore store;
  final SyncService sync;

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(
      text: sync.coupleBookName.isEmpty ? '纪念日' : sync.coupleBookName,
    );
    final name = await showM3Dialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('纪念日名称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '如：纪念日、我们的日子'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) {
      await sync.setCoupleBookName(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final prefs = context.watch<UiPrefs>();
    final name = sync.coupleBookName.isEmpty ? '纪念日' : sync.coupleBookName;
    var merged = sync.mergedMilestones(today());
    if (prefs.cbookHidePartner) {
      merged = merged.where((r) => !r.$2).toList();
    }
    final featured = merged.where((r) => r.$1.featured).toList();
    final shown = featured.take(prefs.cbookCollapsedCount).toList();

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MilestoneBookPage(
                merged: merged,
                partnerName: sync.partnerName,
                source: MilestoneBookSource.couple,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: scheme.tertiary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.favorite_rounded,
                      size: 15,
                      color: scheme.tertiary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _rename(context),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.edit_outlined,
                            size: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Text(
                    '${merged.length} 条',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '记录生日和重要日子',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                for (final r in shown) _milestoneLine(context, r, prefs),
              if (featured.length > shown.length)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '还有 ${featured.length - shown.length} 条 · 点开查看',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单条纪念日行：图标块 + 两行文本 + 右侧「大数字+单位」天数。
  Widget _milestoneLine(
    BuildContext context,
    (Milestone, bool) r,
    UiPrefs prefs,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final m = r.$1;
    final now = today();
    final color = colorFromHex(m.color);
    final daysLeft = m.daysUntil(now);
    final urgent = daysLeft >= 0 && daysLeft <= 3;
    final (numeral, unit) = m.daysParts(now);
    final hidePast = m.isPast(now) && !prefs.cbookPastDays;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Stack(
        children: [
          if (urgent)
            Positioned(
              left: 0,
              top: 6,
              bottom: 6,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(left: urgent ? 9 : 0),
            child: Row(
              // 图标、两行文字、右侧天数统一按行的垂直中线对齐：
              // 按基线对齐时图标和整块文字会被压到数字基线上，看着错位。
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  key: ValueKey('ms-icon-${m.id}'),
                  width: 30,
                  height: 30,
                  child: Container(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9),
                      border: urgent
                          ? Border.all(color: color.withValues(alpha: 0.55))
                          : null,
                    ),
                    child: Icon(milestoneIcon(m.icon), size: 16, color: color),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    key: ValueKey('ms-text-${m.id}'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          m.title,
                          if (r.$2) '${sync.partnerName} 添加',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        strutStyle: const StrutStyle(
                          fontSize: 13,
                          height: 1.35,
                          forceStrutHeight: true,
                        ),
                        style: TextStyle(
                          fontSize: 13,
                          color: r.$2
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (prefs.cbookLunar && m.lunarLabel().isNotEmpty)
                            '农历${m.lunarLabel()}'
                          else
                            m.occurrenceLabel,
                          if (m.repeatLabel.isNotEmpty) m.repeatLabel,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        strutStyle: const StrutStyle(
                          fontSize: 11,
                          height: 1.3,
                          forceStrutHeight: true,
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (hidePast)
                  Text(
                    '纪念日',
                    strutStyle: const StrutStyle(
                      fontSize: 12,
                      height: 1.35,
                      forceStrutHeight: true,
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                else
                  Row(
                    key: ValueKey('ms-days-${m.id}'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        numeral,
                        strutStyle: const StrutStyle(
                          fontSize: 17,
                          height: 1.2,
                          forceStrutHeight: true,
                        ),
                        style: TextStyle(
                          fontSize: 17,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: color,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (unit.isNotEmpty) ...[
                        const SizedBox(width: 2),
                        Text(
                          unit,
                          strutStyle: const StrutStyle(
                            fontSize: 11,
                            height: 1.3,
                            forceStrutHeight: true,
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TogetherLine extends StatelessWidget {
  const _TogetherLine({required this.sync});

  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final days = sync.togetherDays;
    if (days <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _editTogether(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '已在一起 ',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              Text(
                '$days',
                style: TextStyle(
                  fontSize: 19,
                  height: 1.15,
                  fontWeight: FontWeight.bold,
                  color: scheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                ' 天',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 4),
              Icon(Icons.edit_outlined, size: 12, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }

  /// 起始日设置入口：显示当前口径，动作面板替代隐蔽的长按。
  Future<void> _editTogether(BuildContext context) async {
    final boundKey = sync.boundAt > 0
        ? dateKey(DateTime.fromMillisecondsSinceEpoch(sync.boundAt))
        : '';
    await showM3Sheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '在一起从哪天算起',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                sync.anniversary.isNotEmpty
                    ? '纪念日 ${sync.anniversary}'
                    : boundKey.isEmpty
                    ? '尚未记录起始日'
                    : '按绑定日 $boundKey',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.favorite_rounded),
                title: const Text('设置纪念日'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _editAnniversary(context);
                },
              ),
              if (sync.anniversary.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.restart_alt_rounded),
                  title: const Text('恢复按绑定日计算'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _clearAnniversary(context);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editAnniversary(BuildContext context) async {
    final now = today();
    final base = sync.anniversary.isNotEmpty
        ? sync.anniversary
        : sync.boundAt > 0
        ? dateKey(DateTime.fromMillisecondsSinceEpoch(sync.boundAt))
        : dateKey(now);
    final p = base.split('-');
    DateTime initial = now;
    if (p.length == 3) {
      final y = int.tryParse(p[0]);
      final m = int.tryParse(p[1]);
      final d = int.tryParse(p[2]);
      if (y != null && m != null && d != null) {
        initial = DateTime(y, m, d);
      }
    }
    final first = DateTime(now.year - 100, now.month, now.day);
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(now)) initial = now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: now,
    );
    if (picked == null || !context.mounted) return;
    final ok = await sync.setAnniversary(dateKey(picked));
    if (!context.mounted) return;
    if (ok) {
      showTopToast('纪念日已更新，双方都会看到');
    } else if (sync.lastError != null) {
      showTopToast(sync.lastError!);
    }
  }

  Future<void> _clearAnniversary(BuildContext context) async {
    final confirmed = await showM3Dialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除自定义纪念日？'),
        content: const Text('改为按绑定日计算'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await sync.setAnniversary('');
    }
  }
}

class _WeekRow extends StatelessWidget {
  const _WeekRow({
    required this.label,
    required this.done,
    required this.total,
    required this.color,
  });

  final String label;
  final int done;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: M3EWavyProgress(
            value: total > 0 ? done / total : 0,
            color: color,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '$done/$total',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 留言板：聊天气泡 + 系统动态；倒序 Sliver 列表锚定底部，日期条吸顶。
class _MessageBoard extends StatefulWidget {
  const _MessageBoard({
    super.key,
    required this.send,
    required this.msgCtrl,
    required this.replying,
    required this.onPickReply,
    required this.onCancelReply,
    required this.seenIds,
  });

  final Future<void> Function({String? replyTo}) send;
  final TextEditingController msgCtrl;
  final CoupleMessage? replying;
  final ValueChanged<CoupleMessage> onPickReply;
  final VoidCallback onCancelReply;

  /// 由页面态持有：切 tab 后重建留言板也不重播旧消息入场动画。
  final Set<String> seenIds;

  @override
  State<_MessageBoard> createState() => _MessageBoardState();
}

class _MessageBoardState extends State<_MessageBoard> {
  Set<String> _fresh = const {};
  final ScrollController _scrollCtrl = ScrollController();
  bool _showJump = false;
  int _belowCount = 0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    // reverse 列表向旧消息方向滚动时 offset 可能取负，用绝对值判断是否在底部。
    final atBottom =
        !_scrollCtrl.hasClients || _scrollCtrl.position.pixels.abs() <= 48;
    if (atBottom) _belowCount = 0;
    // _showJump 的目标值是 !atBottom；当前与之相同才需要翻转。
    if (_showJump == atBottom) setState(() => _showJump = !atBottom);
  }

  void _markFresh() {
    final sync = context.read<SyncService>();
    final fresh = sync.messages
        .map((m) => m.id)
        .toSet()
        .difference(widget.seenIds);
    if (fresh.isEmpty) {
      _fresh = const {};
      return;
    }
    _fresh = fresh;
    // 上滑翻看历史时收到新消息：计入滚到底部按钮的角标。
    if (_showJump) _belowCount += fresh.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => widget.seenIds.addAll(fresh));
    });
  }

  void _jumpToLatest() {
    setState(() => _belowCount = 0);
    _scrollCtrl.animateTo(0, duration: m3Duration, curve: m3CurveIn);
  }

  Future<void> _showActions(CoupleMessage m) async {
    final sync = context.read<SyncService>();
    final mine = m.byAccountId == sync.accountId;
    final archived = sync.isMessageArchived(m.id);
    final action = await showM3Sheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply_rounded, size: 20),
              title: const Text('引用'),
              onTap: () => Navigator.pop(ctx, 'reply'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded, size: 20),
              title: const Text('复制'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded, size: 20),
              title: const Text('快速添加到…'),
              onTap: () => Navigator.pop(ctx, 'add'),
            ),
            ListTile(
              leading: Icon(
                archived ? Icons.archive_outlined : Icons.archive_rounded,
                size: 20,
              ),
              title: Text(archived ? '取消归档' : '归档'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            if (mine && m.kind == 'text')
              ListTile(
                leading: const Icon(Icons.undo_rounded, size: 20),
                title: const Text('撤回'),
                onTap: () => Navigator.pop(ctx, 'recall'),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'reply':
        widget.onPickReply(m);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) {
          showTopToast('已复制');
        }
      case 'add':
        await _quickAddFromMessage(m);
      case 'archive':
        if (archived) {
          await sync.unarchiveMessage(m.id);
          if (mounted) {
            showTopToast('已取消归档');
          }
        } else {
          await sync.archiveMessage(m, sync.partnerName);
          if (mounted) {
            showTopToast(
              '已归档',
              actionLabel: '查看',
              onAction: () => globalRouteHandler?.call('archive'),
            );
          }
        }
      case 'recall':
        final ok = await showM3Dialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('撤回这条消息？'),
            content: const Text('撤回后双方都看不到'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('撤回'),
              ),
            ],
          ),
        );
        if (ok == true) await sync.recallMessage(m.id);
    }
  }

  /// 把留言文本快速创建为计划/习惯/清单条目。
  Future<void> _quickAddFromMessage(CoupleMessage m) async {
    final store = context.read<AppStore>();
    final sync = context.read<SyncService>();
    final trimmed = m.text.trim();
    // 按字素截断，避免把 emoji 等组合字符截成半个。
    final title = trimmed.characters.length > 60
        ? '${trimmed.characters.take(60).join()}…'
        : trimmed;
    final target = await showM3Sheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '添加到',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.today_rounded, size: 20),
              title: const Text('计划', style: TextStyle(fontSize: 14)),
              subtitle: const Text('加为今天的任务', style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'plan'),
            ),
            ListTile(
              leading: const Icon(Icons.repeat_rounded, size: 20),
              title: const Text('习惯', style: TextStyle(fontSize: 14)),
              subtitle: const Text('创建每日习惯', style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'habit'),
            ),
            for (final l in [
              if (store.unfiled != null) store.unfiled!,
              ...store.data.lists.where((l) => l.id != store.unfiled?.id),
            ])
              ListTile(
                leading: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: colorFromHex(l.color),
                    shape: BoxShape.circle,
                  ),
                ),
                title: Text(l.name, style: const TextStyle(fontSize: 14)),
                subtitle: const Text('添加为清单条目', style: TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, 'list:${l.id}'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || target == null) return;
    switch (target) {
      case 'plan':
        store.addTask(title: title, date: dateKey(today()));
        showTopToast('已添加为今天的任务');
      case 'habit':
        store.addHabit(title, habitColors.first);
        showTopToast('已创建习惯「$title」');
      default:
        if (target.startsWith('list:')) {
          final listId = target.substring(5);
          final l = store.listById(listId);
          if (l == null) {
            showTopToast('该清单已不存在，未添加');
          } else {
            store.addListItem(listId, title);
            showTopToast('已加入「${l.name}」');
          }
        }
    }
    unawaited(sync.syncNow(push: true));
  }

  @override
  Widget build(BuildContext context) {
    _markFresh();
    final sync = context.watch<SyncService>();
    final scheme = Theme.of(context).colorScheme;
    final messages = sync.messages;
    final byId = {for (final m in messages) m.id: m};
    // 倒序平铺：index 0 最新，配合 reverse 列表锚定底部。
    final ordered = messages.reversed.toList();
    // 已发送勾只标在自己最后一条【普通文字】消息上；
    // 系统动态与撤回墓碑走系统气泡，不能占走勾。
    String? myLatestId;
    for (final m in messages) {
      if (!m.isSystem && !m.isDeleted && m.byAccountId == sync.accountId) {
        myLatestId = m.id;
      }
    }

    if (messages.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: EmptyState(
              icon: Icons.chat_bubble_outline_rounded,
              title: '和 ${sync.partnerName} 说点什么吧',
              subtitle: '文字留言和完成动态都会出现在这里',
            ),
          ),
          _MessageInput(
            msgCtrl: widget.msgCtrl,
            send: widget.send,
            replying: null,
            replyingByMe: false,
            partnerName: sync.partnerName,
            onCancelReply: widget.onCancelReply,
          ),
        ],
      );
    }

    return Column(
      children: [
        // 服务端为控制体积可能只回最近一部分；本地不会丢数据，但要说一声。
        if (sync.lastSyncTruncated)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 13,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '只加载了最近一部分留言',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 对方公钥变过（可能是换手机，也可能是有人在中间换钥匙）。
        if (sync.identityKeyChanged)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.key_off_rounded,
                    size: 14,
                    color: scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '对方身份密钥已变化，请核对顶部安全码；不一致请解绑重配',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              ListView.builder(
                controller: _scrollCtrl,
                reverse: true,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                itemCount: ordered.length,
                itemBuilder: (context, i) {
                  final m = ordered[i];
                  final newer = i > 0 ? ordered[i - 1] : null;
                  final older = i + 1 < ordered.length ? ordered[i + 1] : null;
                  final groupBottom = newer == null || _breaksGroup(m, newer);
                  final groupTop = older == null || _breaksGroup(m, older);
                  // 跨天处（更早一条是前一天）在上方插日期条。
                  Widget? dayDivider;
                  if (older == null ||
                      dateKey(
                            DateTime.fromMillisecondsSinceEpoch(
                              older.createdAt,
                            ),
                          ) !=
                          dateKey(
                            DateTime.fromMillisecondsSinceEpoch(m.createdAt),
                          )) {
                    dayDivider = _DayPill(
                      label: _dayLabel(
                        DateTime.fromMillisecondsSinceEpoch(m.createdAt),
                      ),
                    );
                  }
                  return Column(
                    key: ValueKey('msg-${m.id}'),
                    children: [
                      ?dayDivider,
                      _AppearOnce(
                        animate: _fresh.contains(m.id),
                        child: m.isSystem || m.isDeleted
                            ? _SystemBubble(
                                message: m,
                                scheme: scheme,
                                mine: m.byAccountId == sync.accountId,
                                partnerName: sync.partnerName,
                              )
                            : _SwipeToReply(
                                replyToCenter: m.byAccountId != sync.accountId,
                                onReply: () => widget.onPickReply(m),
                                child: _ChatBubble(
                                  message: m,
                                  accountId: sync.accountId ?? '',
                                  scheme: scheme,
                                  read: m.createdAt <= sync.partnerReadAt,
                                  showTick: m.id == myLatestId,
                                  partnerName: sync.partnerName,
                                  partnerAvatarPath: sync.partnerAvatarPath,
                                  myAvatarPath: sync.avatarPath,
                                  groupTop: groupTop,
                                  groupBottom: groupBottom,
                                  quoted: m.replyTo == null
                                      ? null
                                      : byId[m.replyTo],
                                  onLongPress: () => _showActions(m),
                                ),
                              ),
                      ),
                    ],
                  );
                },
              ),
              if (_showJump)
                Positioned(
                  right: 20,
                  bottom: 10,
                  child: _JumpButton(count: _belowCount, onTap: _jumpToLatest),
                ),
            ],
          ),
        ),
        _MessageInput(
          msgCtrl: widget.msgCtrl,
          send: widget.send,
          replying: widget.replying,
          replyingByMe: widget.replying?.byAccountId == sync.accountId,
          partnerName: sync.partnerName,
          onCancelReply: widget.onCancelReply,
        ),
      ],
    );
  }
}

/// 同一组连续对话的判定：同发送者的文字消息，系统动态与墓碑除外。
bool _breaksGroup(CoupleMessage a, CoupleMessage b) =>
    a.byAccountId != b.byAccountId ||
    a.isSystem ||
    b.isSystem ||
    a.isDeleted ||
    b.isDeleted;

String _dayLabel(DateTime d) {
  final now = today();
  final k = dateKey(d);
  if (dateKey(now) == k) return '今天';
  if (dateKey(now.subtract(const Duration(days: 1))) == k) return '昨天';
  if (d.year == now.year) return '${d.month}月${d.day}日';
  return '${d.year}年${d.month}月${d.day}日';
}

String _timeLabel(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String _fullTimeLabel(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

class _DayPill extends StatelessWidget {
  const _DayPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _JumpButton extends StatelessWidget {
  const _JumpButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingActionButton.small(
      heroTag: 'jumpToLatestMessage',
      backgroundColor: scheme.surfaceContainerHigh,
      foregroundColor: scheme.onSurface,
      elevation: 2,
      onPressed: onTap,
      child: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 99 ? '99+' : '$count'),
        backgroundColor: scheme.primary,
        child: const Icon(Icons.arrow_downward_rounded, size: 18),
      ),
    );
  }
}

/// 横滑出「回复」：靠左的消息向右滑，靠右的向左滑（滑向屏幕中央）。
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.child,
    required this.replyToCenter,
    required this.onReply,
  });

  final Widget child;
  final bool replyToCenter;
  final VoidCallback onReply;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _threshold = 52.0;
  static const _max = 72.0;
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: Align(
            alignment: widget.replyToCenter
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: Opacity(
              opacity: (_dx / _threshold).clamp(0.0, 1.0),
              child: Icon(Icons.reply_rounded, size: 18, color: scheme.primary),
            ),
          ),
        ),
        GestureDetector(
          onHorizontalDragUpdate: (d) {
            final delta = widget.replyToCenter ? d.delta.dx : -d.delta.dx;
            if (delta <= 0 && _dx <= 0) return;
            setState(() => _dx = (_dx + delta).clamp(0.0, _max));
          },
          onHorizontalDragEnd: (_) {
            if (_dx >= _threshold) {
              m3HapticSelect();
              widget.onReply();
            }
            if (_dx != 0) setState(() => _dx = 0);
          },
          onHorizontalDragCancel: () {
            if (_dx != 0) setState(() => _dx = 0);
          },
          child: Transform.translate(
            offset: Offset(widget.replyToCenter ? _dx : -_dx, 0),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _SystemBubble extends StatelessWidget {
  const _SystemBubble({
    required this.message,
    required this.scheme,
    this.mine = false,
    this.partnerName = 'TA',
  });

  final CoupleMessage message;
  final ColorScheme scheme;
  final bool mine;
  final String partnerName;

  @override
  Widget build(BuildContext context) {
    final text = message.isDeleted
        ? (mine ? '你撤回了一条消息' : '$partnerName撤回了一条消息')
        : message.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                message.isDeleted
                    ? Icons.undo_rounded
                    : Icons.campaign_outlined,
                size: 13,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.message,
    required this.accountId,
    required this.scheme,
    required this.read,
    required this.partnerName,
    required this.groupTop,
    required this.groupBottom,
    this.showTick = false,
    this.partnerAvatarPath,
    this.myAvatarPath,
    this.quoted,
    this.onLongPress,
  });

  final CoupleMessage message;
  final String accountId;
  final ColorScheme scheme;
  final bool read;
  final String partnerName;
  final String? partnerAvatarPath;
  final String? myAvatarPath;

  /// 是否显示发送状态勾（仅自己最后一条消息）。
  final bool showTick;

  /// 组内位置：groupTop=最上一条（更早无同发送者），groupBottom=最下一条。
  final bool groupTop;
  final bool groupBottom;
  final CoupleMessage? quoted;
  final VoidCallback? onLongPress;

  static const _radius = 15.0;

  bool get mine => message.byAccountId == accountId;

  @override
  Widget build(BuildContext context) {
    // 对方气泡原本用 surfaceContainerHigh，和米色页面几乎同色，看着像没有气泡。
    // 改成更亮的面色加一条极淡描边，两种主题下都能一眼看出边界。
    final bubbleColor = mine ? scheme.primary : scheme.surface;
    final bubbleBorder = mine
        ? null
        : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45));
    final textColor = mine ? scheme.onPrimary : scheme.onSurface;
    final metaColor = mine
        ? scheme.onPrimary.withValues(alpha: 0.65)
        : scheme.onSurfaceVariant;

    return Padding(
      padding: EdgeInsets.only(top: groupTop ? 10 : 3, bottom: 2),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 对方侧常驻头像位：仅组末条显示头像。
          if (!mine)
            SizedBox(
              width: 38,
              child: groupBottom
                  ? Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: CircleAvatar(
                        radius: 13,
                        backgroundColor: scheme.tertiaryContainer,
                        backgroundImage:
                            partnerAvatarPath != null &&
                                partnerAvatarPath!.isNotEmpty &&
                                File(partnerAvatarPath!).existsSync()
                            ? FileImage(File(partnerAvatarPath!))
                            : null,
                        child:
                            partnerAvatarPath == null ||
                                partnerAvatarPath!.isEmpty
                            ? Icon(
                                Icons.favorite_rounded,
                                size: 13,
                                color: scheme.tertiary,
                              )
                            : null,
                      ),
                    )
                  : null,
            ),
          Flexible(
            child: GestureDetector(
              onLongPress: onLongPress,
              child: Container(
                padding: const EdgeInsets.fromLTRB(13, 7, 13, 7),
                margin: EdgeInsets.only(
                  left: mine ? 6 : 0,
                  right: mine ? 0 : 2,
                ),
                constraints: const BoxConstraints(maxWidth: 300),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  border: bubbleBorder,
                  // 统一圆角：靠间距区分同一条人连发的消息，比削角更干净。
                  borderRadius: BorderRadius.circular(_radius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (quoted != null) _buildQuote(),
                    // 时间只在一条对话的最后一行显示，中间那几条不重复时间。
                    _buildBody(
                      textColor,
                      metaColor,
                      showMeta: groupBottom || quoted != null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 自己侧常驻头像位：与对方侧镜像，仅组末条显示。
          if (mine)
            SizedBox(
              width: 38,
              child: groupBottom
                  ? Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: CircleAvatar(
                        radius: 13,
                        backgroundColor: scheme.primaryContainer,
                        backgroundImage:
                            myAvatarPath != null &&
                                myAvatarPath!.isNotEmpty &&
                                File(myAvatarPath!).existsSync()
                            ? FileImage(File(myAvatarPath!))
                            : null,
                        child: myAvatarPath == null || myAvatarPath!.isEmpty
                            ? Icon(
                                Icons.person_rounded,
                                size: 13,
                                color: scheme.onPrimaryContainer,
                              )
                            : null,
                      ),
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _buildQuote() {
    final q = quoted!;
    final qByMe = q.byAccountId == accountId;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: mine
            ? scheme.onPrimary.withValues(alpha: 0.14)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            qByMe ? '我' : partnerName,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: mine
                  ? scheme.onPrimary.withValues(alpha: 0.95)
                  : scheme.primary,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            q.isDeleted ? '撤回了一条消息' : q.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: mine
                  ? scheme.onPrimary.withValues(alpha: 0.8)
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 正文 + 叠在末行右下角的时间/已读勾（Telegram 式内联）。
  Widget _buildBody(Color textColor, Color metaColor, {bool showMeta = true}) {
    // 不显示时间时把预留宽度收回，短消息就不会右侧空一块。
    final metaWidth = showMeta ? (mine ? 54.0 : 40.0) : 0.0;
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(right: metaWidth, bottom: 1),
          child: Text(
            message.text,
            style: TextStyle(fontSize: 14, height: 1.32, color: textColor),
          ),
        ),
        if (showMeta)
          Positioned(
            right: 0,
            bottom: 0,
            child: Tooltip(
              message: _fullTimeLabel(message.createdAt),
              triggerMode: TooltipTriggerMode.manual,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _timeLabel(message.createdAt),
                    style: TextStyle(fontSize: 10, color: metaColor),
                  ),
                  // 仅自己最后一条消息显示勾：单勾=已发送，双勾=对方已读。
                  if (mine && showTick) ...[
                    const SizedBox(width: 3),
                    Icon(
                      read ? Icons.done_all_rounded : Icons.done_rounded,
                      size: 13,
                      color: read
                          ? scheme.tertiary
                          : scheme.onPrimary.withValues(alpha: 0.6),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _AppearOnce extends StatefulWidget {
  const _AppearOnce({required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<_AppearOnce> createState() => _AppearOnceState();
}

class _AppearOnceState extends State<_AppearOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: m3Medium,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _ctrl.forward();
    } else {
      _ctrl.value = 1;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _ctrl, curve: m3CurveIn);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}

class _MessageInput extends StatelessWidget {
  const _MessageInput({
    required this.msgCtrl,
    required this.send,
    required this.replying,
    required this.replyingByMe,
    required this.partnerName,
    required this.onCancelReply,
  });

  final TextEditingController msgCtrl;
  final Future<void> Function({String? replyTo}) send;
  final CoupleMessage? replying;
  final bool replyingByMe;
  final String partnerName;
  final VoidCallback onCancelReply;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (replying != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        height: 30,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              replyingByMe ? '回复自己' : '回复 $partnerName',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              replying!.isDeleted ? '撤回了一条消息' : replying!.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '取消回复',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: onCancelReply,
                      ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: msgCtrl,
                      minLines: 1,
                      maxLines: 6,
                      // 密文随明文约 4/3 放大，服务端留言上限 1200，这里留出余量。
                      maxLength: 800,
                      buildCounter: (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => send(replyTo: replying?.id),
                      decoration: const InputDecoration(
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: '给 TA 留言…',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(5),
                    child: IconButton.filled(
                      tooltip: '发送',
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                        fixedSize: const Size(44, 44),
                        maximumSize: const Size(44, 44),
                      ),
                      onPressed: () => send(replyTo: replying?.id),
                      icon: const Icon(Icons.send_rounded, size: 20),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SyncButton extends StatefulWidget {
  const _SyncButton();

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    if (_spin.isAnimating) return;
    final sync = context.read<SyncService>();
    m3HapticSelect();
    _spin.repeat();
    try {
      await sync.syncNow(push: true);
    } finally {
      if (context.mounted && _spin.isAnimating) {
        _spin.stop();
        _spin.value = 0; // 复位角度，避免图标停在随机位置
      }
    }
    // 成功不弹提示：列表刷新本身就是反馈，每次都弹反而吵。
    if (sync.lastError != null) {
      showTopToast('同步失败：${sync.lastError}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '立即同步',
      onPressed: _sync,
      icon: AnimatedBuilder(
        animation: _spin,
        builder: (context, child) =>
            Transform.rotate(angle: _spin.value * 2 * 3.14159265, child: child),
        child: const Icon(Icons.sync_rounded),
      ),
    );
  }
}

/// 配对指纹：两台设备显示的应该是同一串，当面核对能发现公钥被换过。
class _PairFingerprintLine extends StatelessWidget {
  const _PairFingerprintLine();

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    // 有身份公钥就显示安全码（服务端伪造不了），没有则退回旧的公钥指纹。
    final safety = sync.safetyNumber;
    final fp = safety.isNotEmpty ? safety : sync.pairingFingerprint;
    final label = safety.isNotEmpty ? '安全码' : '配对指纹';
    if (fp.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('核对$label'),
            content: Text(
              '两台手机应显示同一串：\n\n$fp\n\n'
              '不一致说明密钥被换过，建议解绑重配',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.fingerprint_rounded,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              '$label $fp',
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.3,
              ),
            ),
            const Spacer(),
            // 没核对过就给个按钮，核对过一次就不再打扰。
            if (!sync.pairFingerprintConfirmed)
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 26),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () async {
                  await sync.confirmPairFingerprint();
                  if (context.mounted) showTopToast('已核对');
                },
                child: const Text('和对方一致', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }
}
