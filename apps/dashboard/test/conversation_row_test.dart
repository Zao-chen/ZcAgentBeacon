import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zc_agentbeacon_core/zc_agentbeacon_core.dart';
import 'package:zc_agentbeacon_dashboard/src/dashboard_app.dart';

void main() {
  testWidgets('renders Chinese list row with tool state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationRow(
            justCompleted: false,
            conversation: ConversationView(
              conversationId: 'conv-1',
              title: '构建面板',
              cwd: r'P:\Flutter\zc_agentbeacon',
              status: ConversationStatus.toolRunning,
              lastCommand: 'flutter test',
              deviceName: 'workstation',
              lastEventAt: DateTime.now().toUtc(),
            ),
          ),
        ),
      ),
    );

    expect(find.text('工具'), findsOneWidget);
    expect(find.text('构建面板'), findsOneWidget);
    expect(find.textContaining('flutter test'), findsOneWidget);
  });
}
