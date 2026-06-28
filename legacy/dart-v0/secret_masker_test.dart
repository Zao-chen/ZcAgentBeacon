import 'package:flutter_test/flutter_test.dart';
import 'package:zc_agentbeacon/src/shared/secret_masker.dart';

void main() {
  test('masks common token and password shapes', () {
    final masker = SecretMasker();

    final masked = masker.mask(
      'api_key=sk-1234567890abcdefghijkl password=hunter2 token: tp-abcdef1234567890',
    );

    expect(masked, contains('[secret]'));
    expect(masked, isNot(contains('hunter2')));
    expect(masked, isNot(contains('sk-1234567890abcdefghijkl')));
  });

  test('truncates long values after masking', () {
    final masker = SecretMasker(maxLength: 12);

    expect(masker.mask(List.filled(40, 'a').join()), hasLength(15));
  });
}
