import 'package:flutter_test/flutter_test.dart';

import 'package:legacytracker/src/features/auth/attestation.dart';

import 'passkey_fixtures.dart';

void main() {
  test('reads a P-256 key and names a known provider', () {
    final credential = AttestedCredential.parse(p256Attestation);
    expect(credential.publicKey, p256PublicKey);
    expect(credential.aaguid, 'ea9b8d66-4d01-1d21-3ce4-b6b48cb575d4');
    expect(credential.providerName, 'Google Password Manager');
  });

  test('reads an RSA key from an unnamed provider', () {
    final credential = AttestedCredential.parse(rsaAttestation);
    expect(credential.publicKey, rsaPublicKey);
    expect(credential.providerName, isNull);
  });

  test('rejects what is not an attestation object', () {
    expect(() => AttestedCredential.parse('YXR0'), throwsFormatException);
    // {"fmt": "none"}: no authData.
    expect(() => AttestedCredential.parse('oWNmbXRkbm9uZQ'), throwsFormatException);
  });
}
