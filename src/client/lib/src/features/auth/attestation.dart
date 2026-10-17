import 'dart:convert';
import 'dart:typed_data';

/// What the auth server needs from a new passkey's attestation object.
///
/// Legacy Auth stores the credential's public key as SubjectPublicKeyInfo
/// (`response.publicKey`, which browsers expose via `getPublicKey()`), but the
/// platform authenticators only hand back the attestation object, so the key
/// is read from it here.
class AttestedCredential {
  const AttestedCredential({required this.publicKey, required this.aaguid});

  /// Parses a base64url attestation object. Throws [FormatException] if it
  /// holds no credential, or one whose key type the server can't verify.
  factory AttestedCredential.parse(String attestationObject) {
    final attestation = _Cbor(_base64Url(attestationObject)).read();
    final authData = attestation is Map ? attestation['authData'] : null;
    if (authData is! Uint8List) {
      throw const FormatException('Attestation object has no authData');
    }
    // rpIdHash (32) · flags (1) · signCount (4) · attested credential data.
    const attestedFlag = 0x40;
    if (authData.length < 55 || authData[32] & attestedFlag == 0) {
      throw const FormatException('authData has no attested credential');
    }
    final aaguid = authData.sublist(37, 53);
    final idLength = authData[53] << 8 | authData[54];
    final coseKey = _Cbor(authData, 55 + idLength).read();
    if (coseKey is! Map) {
      throw const FormatException('Credential public key is not a COSE key');
    }
    return AttestedCredential(
      publicKey: base64Url.encode(_subjectPublicKeyInfo(coseKey)).replaceAll('=', ''),
      aaguid: _uuid(aaguid),
    );
  }

  /// SubjectPublicKeyInfo DER, base64url without padding.
  final String publicKey;

  /// Identifies the passkey provider; all zeros when it doesn't say.
  final String aaguid;

  /// The provider's name for well-known passkey providers, so the account's
  /// list reads "Google Password Manager" rather than a generic label.
  String? get providerName => _knownProviders[aaguid];

  static const _knownProviders = {
    'ea9b8d66-4d01-1d21-3ce4-b6b48cb575d4': 'Google Password Manager',
    'fbfc3007-154e-4ecc-8c0b-6e020557d7bd': 'iCloud Keychain',
    'dd4ec289-e01d-41c9-bb89-70fa845d4bf2': 'iCloud Keychain',
    '53414d53-554e-4700-0000-000000000000': 'Samsung Pass',
    'bada5566-a7aa-401f-bd96-45619a55120d': '1Password',
    'd548826e-79b4-db40-a3d8-11116f7e8349': 'Bitwarden',
    '531126d6-e717-415c-9320-3d9aa6981239': 'Dashlane',
    '0ea242b4-43c4-4a1b-8b17-dd6d0b6baec6': 'Keeper',
  };
}

/// COSE_Key (RFC 9053) to SubjectPublicKeyInfo, for the two algorithms the
/// auth server offers: ES256 (P-256) and RS256.
Uint8List _subjectPublicKeyInfo(Map<dynamic, dynamic> key) {
  switch (key[1]) {
    case 2 when key[-1] == 1: // EC2 on P-256
      final x = key[-2], y = key[-3];
      if (x is! Uint8List || y is! Uint8List || x.length != 32 || y.length != 32) {
        throw const FormatException('Malformed P-256 key');
      }
      return _der(0x30, [
        _der(0x30, [_ecPublicKeyOid, _p256Oid]),
        _bitString([0x04, ...x, ...y]),
      ]);
    case 3: // RSA
      final n = key[-1], e = key[-2];
      if (n is! Uint8List || e is! Uint8List) {
        throw const FormatException('Malformed RSA key');
      }
      return _der(0x30, [
        _der(0x30, [_rsaEncryptionOid, _derNull]),
        _bitString(_der(0x30, [_derInteger(n), _derInteger(e)])),
      ]);
    default:
      throw FormatException('Unsupported passkey key type ${key[1]}');
  }
}

// 1.2.840.10045.2.1, 1.2.840.10045.3.1.7 and 1.2.840.113549.1.1.1.
final _ecPublicKeyOid = Uint8List.fromList([0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]);
final _p256Oid = Uint8List.fromList([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]);
final _rsaEncryptionOid = Uint8List.fromList([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]);
final _derNull = Uint8List.fromList([0x05, 0x00]);

Uint8List _der(int tag, List<List<int>> children) {
  final content = [for (final child in children) ...child];
  final length = content.length;
  final lengthBytes = <int>[];
  if (length < 0x80) {
    lengthBytes.add(length);
  } else {
    for (var rest = length; rest > 0; rest >>= 8) {
      lengthBytes.insert(0, rest & 0xff);
    }
    lengthBytes.insert(0, 0x80 | lengthBytes.length);
  }
  return Uint8List.fromList([tag, ...lengthBytes, ...content]);
}

/// A BIT STRING with no unused bits.
Uint8List _bitString(List<int> bytes) => _der(0x03, [[0x00, ...bytes]]);

/// An unsigned big-endian integer as a DER INTEGER.
Uint8List _derInteger(List<int> bytes) {
  var start = 0;
  while (start < bytes.length - 1 && bytes[start] == 0) {
    start++;
  }
  final magnitude = bytes.sublist(start);
  return _der(0x02, [if (magnitude.first & 0x80 != 0) [0x00], magnitude]);
}

Uint8List _base64Url(String value) =>
    base64Url.decode(value.padRight((value.length + 3) ~/ 4 * 4, '='));

String _uuid(List<int> bytes) {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Just enough CBOR (RFC 8949) for attestation objects and COSE keys:
/// definite-length integers, byte and text strings, arrays, maps and simple
/// values.
class _Cbor {
  _Cbor(this._bytes, [this._offset = 0]);

  final Uint8List _bytes;
  int _offset;

  Object? read() {
    final initial = _byte();
    final major = initial >> 5;
    final info = initial & 0x1f;
    if (major == 7) {
      return switch (info) {
        20 => false,
        21 => true,
        22 || 23 => null,
        _ => throw FormatException('Unsupported CBOR simple value $info'),
      };
    }
    final argument = _argument(info);
    return switch (major) {
      0 => argument,
      1 => -1 - argument,
      2 => _take(argument),
      3 => utf8.decode(_take(argument)),
      4 => [for (var i = 0; i < argument; i++) read()],
      5 => {for (var i = 0; i < argument; i++) read(): read()},
      _ => throw FormatException('Unsupported CBOR major type $major'),
    };
  }

  int _argument(int info) {
    if (info < 24) return info;
    final size = switch (info) {
      24 => 1,
      25 => 2,
      26 => 4,
      27 => 8,
      _ => throw const FormatException('Indefinite-length CBOR is not supported'),
    };
    var value = 0;
    for (final byte in _take(size)) {
      value = value << 8 | byte;
    }
    return value;
  }

  int _byte() => _take(1).first;

  Uint8List _take(int count) {
    if (_offset + count > _bytes.length) {
      throw const FormatException('Truncated CBOR');
    }
    return Uint8List.sublistView(_bytes, _offset, _offset += count);
  }
}
