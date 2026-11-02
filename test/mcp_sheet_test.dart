import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goalday/data/models.dart';
import 'package:goalday/data/store.dart';
import 'package:goalday/sync/sync_service.dart';
import 'package:goalday/widgets/mcp_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('智能体接入面板能打开并显示开关', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore();
    store.replaceData(
      AppData(
        lists: <TaskList>[],
        tasks: <PlanTask>[],
        habits: <Habit>[],
        journal: <String, JournalEntry>{},
      ),
    );
    final sync = SyncService(store);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStore>.value(value: store),
          ChangeNotifierProvider<SyncService>.value(value: sync),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMcpSheet(context),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('智能体接入'), findsWidgets);
    expect(find.text('启用 MCP 服务'), findsOneWidget);
    expect(find.text('允许写入'), findsOneWidget);
    expect(find.text('允许读取日记与留言'), findsOneWidget);
    expect(find.text('复制 MCP 配置'), findsOneWidget);
  });
}
