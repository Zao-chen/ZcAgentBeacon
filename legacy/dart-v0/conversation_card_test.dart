import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zc_agentbeacon/src/shared/agent_models.dart';
import 'package:zc_agentbeacon/src/ui/dashboard_app.dart';

void main() {
  testWidgets('renders tool running conversation details', (tester) async {
    final conversation = AgentConversation(
      conversationId: 'conv-1',
      title: 'Build dashboard',
      cwd: r'P:\Flutter\zc_agentbeacon',
      status: ConversationRuntimeStatus.toolRunning,
      turnId: 'turn-1',
      lastEventAt: DateTime.now().toUtc(),
      lastToolName: 'shell_command',
      lastCommand: 'flutter test',
      lastMessageSummary: 'Running tests',
      lastToolOutput: 'ok',
      deviceName: 'workstation',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationCard(
            conversation: conversation,
            showDetails: true,
          ),
        ),
      ),
    );

    expect(find.text('Build dashboard'), findsOneWidget);
    expect(find.text('TOOL'), findsOneWidget);
    expect(find.textContaining('flutter test'), findsOneWidget);
  });
}
