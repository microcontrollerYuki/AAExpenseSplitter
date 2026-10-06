import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/sync/aa_crypto.dart';

void main() {
  test('加解密往返保持数据一致', () async {
    final data = <String, Object?>{
      'format': 1,
      'fromName': '小明',
      'groups': [
        {'id': 'g1', 'totalAmount': 10000, 'note': '晚餐'},
      ],
      'nested': {'a': [1, 2.5, null, true]},
    };
    final enc = await encryptToAasContent(data, '口令123456');
    // 密文是 base64(nonce+密文+mac)，长度必然大于明文 JSON
    expect(enc.length, greaterThan(jsonEncode(data).length ~/ 2));
    final dec = await decryptAasContent(enc, '口令123456');
    expect(dec, data);
  });

  test('同一口令两次加密产生不同密文（随机 nonce）', () async {
    final a = await encryptToAasContent({'k': 1}, 'same-pass');
    final b = await encryptToAasContent({'k': 1}, 'same-pass');
    expect(a, isNot(b));
  });

  test('错误口令解密被 AES-GCM MAC 拒绝', () async {
    final enc = await encryptToAasContent({'k': 1}, '正确口令');
    expect(() => decryptAasContent(enc, '错误口令'), throwsA(isA<Exception>()));
  });

  test('口令前后空白被解密 trim 容忍（内容侧）', () async {
    final enc = await encryptToAasContent({'k': 1}, 'pass');
    // decryptAasContent 内部对 content.trim() 生效：带换行的 base64 也能解
    final dec = await decryptAasContent('  $enc\n', 'pass');
    expect(dec['k'], 1);
  });

  test('非法 base64 内容抛格式异常', () async {
    expect(
        () => decryptAasContent('!!!not-base64!!!', 'pass'), throwsA(anything));
  });

  test('合法 base64 但长度不足 SecretBox 拆分时抛错', () async {
    // base64('short') 只有 5 字节，不足以切出 nonce(12)+mac(16)
    expect(() => decryptAasContent(base64Encode('short'.codeUnits), 'pass'),
        throwsA(anything));
  });

  test('派生密钥确定性：同口令同盐得到相同 32 字节密钥', () async {
    final k1 = await deriveKey('abc123');
    final k2 = await deriveKey('abc123');
    final k3 = await deriveKey('other');
    expect(k1.length, 32);
    expect(k1, k2);
    expect(k1, isNot(k3));
  });
}
