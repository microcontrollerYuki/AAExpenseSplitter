import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 同步文件的端到端加密：双方使用相同配对口令，PBKDF2 派生 AES-256 密钥，
/// 文件内容 = base64( nonce(12) + AES-GCM 密文 + MAC(16) )，扩展名 .aas
const _kSalt = 'AAExpenseSplitter-v1';

Future<Uint8List> deriveKey(String password) async {
  final kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 120000,
    bits: 256,
  );
  final key = await kdf.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: utf8.encode(_kSalt),
  );
  final keyData = await key.extract();
  return Uint8List.fromList(keyData.bytes);
}

Future<String> encryptToAasContent(
    Map<String, Object?> data, String password) async {
  final key = await deriveKey(password);
  final algo = AesGcm.with256bits();
  final box = await algo.encrypt(
    utf8.encode(jsonEncode(data)),
    secretKey: SecretKey(key),
  );
  return base64Encode(box.concatenation());
}

Future<Map<String, Object?>> decryptAasContent(
    String content, String password) async {
  final key = await deriveKey(password);
  final algo = AesGcm.with256bits();
  final raw = base64Decode(content.trim());
  final box = SecretBox.fromConcatenation(raw, nonceLength: 12, macLength: 16);
  final clear = await algo.decrypt(box, secretKey: SecretKey(key));
  return jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
}
