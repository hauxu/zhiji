import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/widgets/entity_dialog.dart';

void main() {
  testWidgets('duplicate name should keep sheet open', (tester) async {
    var submitted = false;
    var existsCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showEntitySheet(
                  ctx,
                  title: '新建清单',
                  hint: '名称',
                  confirmLabel: '创建',
                  exists: (name) {
                    existsCalls++;
                    return true;
                  },
                  onSubmit: (_, _, _, _, _, _) => submitted = true,
                  suggestions: const [],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '读书');
    await tester.pump();
    final btnFinder = find.widgetWithText(FilledButton, '创建');
    expect(tester.widget<FilledButton>(btnFinder).onPressed, isNotNull);
    await tester.ensureVisible(btnFinder);
    await tester.pumpAndSettle();
    await tester.tap(btnFinder);
    await tester.pumpAndSettle();
    expect(existsCalls, 1);
    expect(find.byType(TextField), findsOneWidget,
        reason: '重名时弹层应保持打开，避免丢失已输入内容');
    expect(submitted, isFalse);
  });
}