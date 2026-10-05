// 一次性验证脚本：dart run tool/crypto_roundtrip.dart
// ignore_for_file: avoid_print
import 'package:aa_expense_splitter/sync/aa_crypto.dart';

Future<void> main() async {
  final data = <String, Object?>{
    'format': 1,
    'fromName': '小明',
    'groups': [
      {'id': 'g1', 'totalAmount': 10000, 'note': '晚餐'}
    ],
  };
  final enc = await encryptToAasContent(data, '口令123456');
  print('密文长度: ${enc.length}');
  final dec = await decryptAasContent(enc, '口令123456');
  print('解密一致: ${dec['fromName'] == '小明' && (dec['groups'] as List).isNotEmpty}');
  try {
    await decryptAasContent(enc, '错误口令');
    print('错误口令被接受: 是(有严重问题)');
  } catch (_) {
    print('错误口令被拒绝: 是(预期)');
  }
}
