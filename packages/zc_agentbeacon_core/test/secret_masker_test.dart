import 'package:test/test.dart';
import 'package:zc_agentbeacon_core/zc_agentbeacon_core.dart';

void main() {
  test('masks common secret shapes', () {
    final masked = SecretMasker().mask(
      'api_key=sk-1234567890abcdefghijkl password=hunter2 token: tp-abcdef1234567890',
    );
    expect(masked, contains('[secret]'));
    expect(masked, isNot(contains('hunter2')));
    expect(masked, isNot(contains('sk-1234567890abcdefghijkl')));
  });

  test('truncates after masking', () {
    expect(SecretMasker(maxLength: 12).mask('a' * 40), hasLength(15));
  });
}

extension on String {
  String operator *(int times) => List.filled(times, this).join();
}
