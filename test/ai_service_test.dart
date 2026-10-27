// AI 识别结果解析：不依赖网络，覆盖代码围栏、前后杂讯、别名、脏字段。
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/ai/ai_service.dart';

void main() {
  final now = DateTime(2026, 10, 21, 9, 0);

  test('标准 JSON：解析标题、日期、开始/结束时间、地点', () {
    final p = AiService.parseRecognition(
      '{"type":"plan","title":"和客户开会","date":"2026-10-22",'
      '"time":"15:00","endTime":"16:30","location":"公司 3 楼"}',
      now: now,
    );
    expect(p.message, isNull);
    expect(p.type, 'plan');
    expect(p.title, '和客户开会');
    expect(p.date, '2026-10-22');
    expect(p.time, '15:00');
    expect(p.endTime, '16:30');
    expect(p.location, '公司 3 楼');
  });

  test('代码围栏与前后杂讯中提取 JSON', () {
    final p = AiService.parseRecognition(
      '好的，结果如下：\n```json\n{"type":"list","title":"牛奶"}\n```\n请查收',
      now: now,
    );
    expect(p.message, isNull);
    expect(p.type, 'list');
    expect(p.title, '牛奶');
  });

  test('类型别名归一 + 相对日期换算 + 非法时间丢弃', () {
    final c = AiService.parseRecognition(
        '{"type":"anniversary","title":"在一起纪念日","date":"明天"}',
        now: now);
    expect(c.type, 'countdown');
    expect(c.date, '2026-10-22');

    final l =
        AiService.parseRecognition('{"type":"shopping","title":"鸡蛋"}', now: now);
    expect(l.type, 'list');

    final bad = AiService.parseRecognition(
        '{"type":"plan","title":"跑步","date":"2026-13-40","time":"25:99"}',
        now: now);
    expect(bad.date, '');
    expect(bad.time, '');
  });

  test('list 类型：拆出的条目只保留非空字符串', () {
    final p = AiService.parseRecognition(
        '{"type":"list","title":"","items":["牛奶","鸡蛋","  ","面包",123]}',
        fallbackTitle: '买牛奶、鸡蛋和面包', now: now);
    expect(p.type, 'list');
    expect(p.items, ['牛奶', '鸡蛋', '面包']);
    expect(p.title, '买牛奶、鸡蛋和面包');
  });

  test('标题缺失时回退到用户原文；无法解析时报错', () {
    final p = AiService.parseRecognition(
        '{"type":"plan","title":"","date":"2026-10-22"}',
        fallbackTitle: '下午三点开会', now: now);
    expect(p.title, '下午三点开会');

    final bad = AiService.parseRecognition('这不是 JSON', now: now);
    expect(bad.message, isNotNull);
  });
}