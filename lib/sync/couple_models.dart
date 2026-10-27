import '../data/models.dart';

/// 对方同步数据快照，只读。
class PartnerData {
  PartnerData({
    required this.accountId,
    required this.name,
    required this.data,
    required this.updatedAt,
  });

  final String accountId;
  String name;
  AppData data;
  int updatedAt;

  factory PartnerData.fromJson(Map<String, dynamic> j) => PartnerData(
        accountId: (j['accountId'] ?? '') as String,
        name: (j['name'] ?? 'TA') as String,
        data: AppData.fromJson((j['data'] ?? const {}) as Map<String, dynamic>),
        updatedAt: (j['updatedAt'] ?? 0) as int,
      );

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'name': name,
        'data': data.toJson(),
        'updatedAt': updatedAt,
      };
}

/// 按条目的评价/备注。
class CoupleComment {
  CoupleComment({
    required this.id,
    required this.byAccountId,
    required this.targetOwnerAccountId,
    required this.targetId,
    required this.targetKind,
    required this.kind,
    this.emoji,
    this.text = '',
    required this.createdAt,
  });

  final String id;
  final String byAccountId;
  final String targetOwnerAccountId;
  final String targetId;

  /// task / habit / journal
  final String targetKind;

  /// emoji / text
  final String kind;
  final String? emoji;
  final String text;
  final int createdAt;

  factory CoupleComment.fromJson(Map<String, dynamic> j) => CoupleComment(
        id: (j['id'] ?? '') as String,
        byAccountId: (j['byAccountId'] ?? j['byUid'] ?? '') as String,
        targetOwnerAccountId:
            (j['targetOwnerAccountId'] ?? j['targetOwnerUid'] ?? '') as String,
        targetId: (j['targetId'] ?? '') as String,
        targetKind: (j['targetKind'] ?? 'task') as String,
        kind: (j['kind'] ?? 'text') as String,
        emoji: j['emoji'] as String?,
        text: (j['text'] ?? '') as String,
        createdAt: (j['createdAt'] ?? 0) as int,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'byAccountId': byAccountId,
        'targetOwnerAccountId': targetOwnerAccountId,
        'targetId': targetId,
        'targetKind': targetKind,
        'kind': kind,
        'emoji': emoji,
        'text': text,
        'createdAt': createdAt,
      };
}

/// 留言板消息：文字聊天 / 系统动态 / 撤回墓碑。
class CoupleMessage {
  CoupleMessage({
    required this.id,
    required this.byAccountId,
    required this.kind,
    required this.text,
    required this.createdAt,
    this.replyTo,
  });

  final String id;

  /// 对方账号 ID；'system' 表示动态。
  final String byAccountId;

  /// text / system / deleted（撤回墓碑）
  final String kind;
  final String text;
  final int createdAt;

  /// 被回复消息的 id，仅文字消息携带。
  final String? replyTo;

  bool get isSystem => kind == 'system' || byAccountId == 'system';

  bool get isDeleted => kind == 'deleted';

  factory CoupleMessage.fromJson(Map<String, dynamic> j) => CoupleMessage(
        id: (j['id'] ?? '') as String,
        byAccountId: (j['byAccountId'] ?? '') as String,
        kind: (j['kind'] ?? 'text') as String,
        text: (j['text'] ?? '') as String,
        createdAt: (j['createdAt'] ?? 0) as int,
        replyTo: j['replyTo'] is String && (j['replyTo'] as String).isNotEmpty
            ? j['replyTo'] as String
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'byAccountId': byAccountId,
        'kind': kind,
        'text': text,
        'createdAt': createdAt,
        'replyTo': ?((replyTo != null && replyTo!.isNotEmpty) ? replyTo : null),
      };
}

/// 同步过程中产生的、需要提示用户的事件。
class CoupleEvent {
  CoupleEvent(this.title, this.body,
      {this.route = 'couple', this.isMessage = false, this.dedupKey});

  final String title;
  final String body;

  /// 点击通知后要去的页面。
  final String route;

  /// 是否走留言通知通道。
  final bool isMessage;

  /// 去重键：同一条留言/评价只弹一次。没有稳定 id 的事件留空，
  /// 由调用方按内容去重。
  final String? dedupKey;
}

String reactionLabel(String? emojiOrKind) => switch (emojiOrKind) {
      'like' || '👍' => '赞',
      'cheer' || '🎉' => '祝贺',
      _ => '喜欢',
    };

const kindTask = 'task';
const kindHabit = 'habit';
const kindJournal = 'journal';
