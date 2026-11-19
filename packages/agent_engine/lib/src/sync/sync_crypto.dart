// Kryptografie für den Abgleich – reines Dart, ohne Abhängigkeiten:
// SHA-256, HMAC-SHA256, PBKDF2 und ChaCha20 (RFC 8439).
// Verschlüsselung: ChaCha20 + HMAC-SHA256 (Encrypt-then-MAC, getrennte Schlüssel).

import 'dart:convert';
import 'dart:io' show GZipCodec;
import 'dart:math';
import 'dart:typed_data';

const _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

/// SHA-256 eines Byte-Arrays.
Uint8List sha256(List<int> data) {
  final h = Uint32List.fromList(
      [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  final bitLen = data.length * 8;
  final padLen = ((data.length + 9 + 63) ~/ 64) * 64;
  final msg = Uint8List(padLen)..setRange(0, data.length, data);
  msg[data.length] = 0x80;
  final bd = ByteData.sublistView(msg);
  bd.setUint32(padLen - 8, (bitLen ~/ 0x100000000) & 0xffffffff);
  bd.setUint32(padLen - 4, bitLen & 0xffffffff);
  final w = Uint32List(64);
  for (var off = 0; off < padLen; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getUint32(off + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  final out = Uint8List(32);
  final ob = ByteData.sublistView(out);
  for (var i = 0; i < 8; i++) {
    ob.setUint32(i * 4, h[i]);
  }
  return out;
}

String hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// HMAC-SHA256.
Uint8List hmacSha256(List<int> key, List<int> data) {
  var k = key.length > 64 ? sha256(key) : Uint8List.fromList(key);
  final kp = Uint8List(64)..setRange(0, k.length, k);
  final ipad = Uint8List(64 + data.length);
  final opad = Uint8List(64 + 32);
  for (var i = 0; i < 64; i++) {
    ipad[i] = kp[i] ^ 0x36;
    opad[i] = kp[i] ^ 0x5c;
  }
  ipad.setRange(64, 64 + data.length, data);
  opad.setRange(64, 96, sha256(ipad));
  return sha256(opad);
}

/// PBKDF2-HMAC-SHA256 (32 Byte Ausgabe je Block).
Uint8List pbkdf2(List<int> password, List<int> salt, int iterations, int length) {
  final out = BytesBuilder();
  for (var block = 1; out.length < length; block++) {
    final s = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
    ByteData.sublistView(s).setUint32(salt.length, block);
    var u = hmacSha256(password, s);
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmacSha256(password, u);
      for (var j = 0; j < 32; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
  }
  return Uint8List.fromList(out.takeBytes().sublist(0, length));
}

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;

/// ChaCha20 (RFC 8439): XOR des Schlüsselstroms über [data].
Uint8List chacha20(List<int> key, List<int> nonce, List<int> data, {int counter = 1}) {
  if (key.length != 32 || nonce.length != 12) throw ArgumentError('ChaCha20: Schlüssel 32, Nonce 12 Byte');
  final kd = ByteData.sublistView(Uint8List.fromList(key));
  final nd = ByteData.sublistView(Uint8List.fromList(nonce));
  final st = Uint32List(16);
  st[0] = 0x61707865;
  st[1] = 0x3320646e;
  st[2] = 0x79622d32;
  st[3] = 0x6b206574;
  for (var i = 0; i < 8; i++) {
    st[4 + i] = kd.getUint32(i * 4, Endian.little);
  }
  for (var i = 0; i < 3; i++) {
    st[13 + i] = nd.getUint32(i * 4, Endian.little);
  }
  final out = Uint8List(data.length);
  final x = Uint32List(16);
  final ks = Uint8List(64);
  final ksd = ByteData.sublistView(ks);
  void qr(int a, int b, int c, int d) {
    x[a] = (x[a] + x[b]) & 0xffffffff;
    x[d] = _rotl(x[d] ^ x[a], 16);
    x[c] = (x[c] + x[d]) & 0xffffffff;
    x[b] = _rotl(x[b] ^ x[c], 12);
    x[a] = (x[a] + x[b]) & 0xffffffff;
    x[d] = _rotl(x[d] ^ x[a], 8);
    x[c] = (x[c] + x[d]) & 0xffffffff;
    x[b] = _rotl(x[b] ^ x[c], 7);
  }

  for (var off = 0, ctr = counter; off < data.length; off += 64, ctr++) {
    st[12] = ctr & 0xffffffff;
    x.setAll(0, st);
    for (var r = 0; r < 10; r++) {
      qr(0, 4, 8, 12);
      qr(1, 5, 9, 13);
      qr(2, 6, 10, 14);
      qr(3, 7, 11, 15);
      qr(0, 5, 10, 15);
      qr(1, 6, 11, 12);
      qr(2, 7, 8, 13);
      qr(3, 4, 9, 14);
    }
    for (var i = 0; i < 16; i++) {
      ksd.setUint32(i * 4, (x[i] + st[i]) & 0xffffffff, Endian.little);
    }
    final n = min(64, data.length - off);
    for (var i = 0; i < n; i++) {
      out[off + i] = data[off + i] ^ ks[i];
    }
  }
  return out;
}

/// Hauptschlüssel aus dem Sync-Passwort (auf allen Geräten gleich).
Uint8List pbkdf2Master(String passphrase, {int iterations = 60000}) =>
    pbkdf2(utf8.encode(passphrase.trim()), utf8.encode('junels-sync-v1'), iterations, 32);

/// Schlüssel für den Abgleich, abgeleitet aus dem Sync-Passwort.
class SyncKeys {
  SyncKeys._(this.enc, this.mac, this.account);

  /// Ableitung (PBKDF2, 60 000 Runden – dauert auf dem Handy ca. 1 s).
  factory SyncKeys.fromPassphrase(String passphrase, {int iterations = 60000}) =>
      SyncKeys.fromMaster(pbkdf2Master(passphrase, iterations: iterations));

  factory SyncKeys.fromMaster(List<int> master) => SyncKeys._(
        hmacSha256(master, utf8.encode('enc')),
        hmacSha256(master, utf8.encode('mac')),
        hexOf(hmacSha256(master, utf8.encode('account'))),
      );

  final Uint8List enc;
  final Uint8List mac;

  /// Konto-Kennung für den Server (verrät nichts über das Passwort).
  final String account;

  static final _rnd = Random.secure();

  /// Verschlüsselt (gzip + ChaCha20 + HMAC) → Base64.
  String seal(String plain) {
    final nonce = Uint8List.fromList(List.generate(12, (_) => _rnd.nextInt(256)));
    final ct = chacha20(enc, nonce, GZipCodec(level: 6).encode(utf8.encode(plain)));
    final body = Uint8List(12 + ct.length)
      ..setRange(0, 12, nonce)
      ..setRange(12, 12 + ct.length, ct);
    final tag = hmacSha256(mac, body);
    return base64.encode([...body, ...tag]);
  }

  /// Entschlüsselt; wirft [FormatException] bei falschem Passwort oder manipulierten Daten.
  String open(String sealed) {
    final all = base64.decode(sealed);
    if (all.length < 12 + 32) throw const FormatException('zu kurz');
    final body = all.sublist(0, all.length - 32);
    final tag = all.sublist(all.length - 32);
    final want = hmacSha256(mac, body);
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= want[i] ^ tag[i];
    }
    if (diff != 0) throw const FormatException('falsches Sync-Passwort oder beschädigte Daten');
    final plain = chacha20(enc, body.sublist(0, 12), body.sublist(12));
    return utf8.decode(GZipCodec().decode(plain));
  }
}
