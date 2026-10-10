import 'dart:async' show unawaited;

import 'package:flutter/services.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import '../../data/models/passkey.dart';
import '../../data/network/auth_service.dart';
import '../../data/storage/token_storage.dart';

/// A passkey ceremony that didn't complete, with a [message] for the user.
/// [cancelled] means the user dismissed the system sheet on purpose, which
/// needs no message at all.
class PasskeyException implements Exception {
  const PasskeyException(this.message, {this.cancelled = false});

  const PasskeyException.cancelled() : this('', cancelled: true);

  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}

/// Runs passkey ceremonies: the auth server issues the WebAuthn options and
/// checks the result; the platform (Credential Manager on Android, the
/// AuthenticationServices framework on iOS) does the part in between — the
/// biometric / screen-lock prompt and the cryptography.
class PasskeyClient {
  PasskeyClient({required this.authService, PasskeyAuthenticator? authenticator})
    : _authenticator = authenticator ?? PasskeyAuthenticator();

  final AuthService authService;
  final PasskeyAuthenticator _authenticator;

  Future<AuthTokens> signIn() async {
    final options = await authService.passkeyLoginOptions();
    final request = AuthenticateRequestType.fromJson(
      options,
      // Fail straight away when the phone has no passkey for us, rather than
      // offering to scan a QR code with another device.
      preferImmediatelyAvailableCredentials: true,
    );
    final assertion = await _platform(() => _authenticator.authenticate(request));
    try {
      return await authService.passkeyLogin(assertion.toJson());
    } on AuthException catch (error) {
      if (error.statusCode != 404) rethrow;
      // Deleted from the account (maybe on another phone): have the
      // platform stop offering it.
      unawaited(
        _authenticator
            .signalUnknownCredential(
              SignalUnknownCredentialRequestType(
                relyingPartyId: request.relyingPartyId,
                credentialId: assertion.id,
              ),
            )
            .catchError((_) {}),
      );
      throw const PasskeyException(
        'That passkey was removed from your account. Sign in with your '
        'password instead.',
      );
    }
  }

  Future<Passkey> create(String accessToken) async {
    final options = await authService.passkeyRegistrationOptions(accessToken);
    final request = RegisterRequestType.fromJson(options);
    final attestation = await _platform(() => _authenticator.register(request));
    return authService.registerPasskey(accessToken, attestation.toJson());
  }

  Future<T> _platform<T>(Future<T> Function() ceremony) async {
    try {
      return await ceremony();
    } on AuthenticatorException catch (error) {
      throw _describe(error);
    } on PlatformException {
      // A platform error code the plugin doesn't classify.
      throw const PasskeyException('Something went wrong with the passkey. Try again.');
    }
  }

  static PasskeyException _describe(AuthenticatorException error) {
    return switch (error) {
      PasskeyAuthCancelledException() => const PasskeyException.cancelled(),
      NoCredentialsAvailableException() => const PasskeyException(
        'There\'s no passkey for Legacy Tracker on this phone yet. Sign in '
        'with your password, then add one from your profile.',
      ),
      ExcludeCredentialsCanNotBeRegisteredException() => const PasskeyException(
        'This phone already has a passkey for your account.',
      ),
      MissingGoogleSignInException() || SyncAccountNotAvailableException() =>
        const PasskeyException(
          'Passkeys need a Google account on this phone. Add one in '
          'Settings, then try again.',
        ),
      NoCreateOptionException() => const PasskeyException(
        'No passkey provider is turned on. Enable Google Password Manager '
        '(or another provider) in Settings, then try again.',
      ),
      DeviceNotSupportedException() ||
      PasskeyUnsupportedException() ||
      RestoreCredentialUnsupportedException() => const PasskeyException(
        'This phone doesn\'t support passkeys.',
      ),
      TimeoutException() => const PasskeyException(
        'The passkey prompt timed out. Try again.',
      ),
      DomainNotAssociatedException() => const PasskeyException(
        'This version of the app isn\'t set up for passkeys yet.',
      ),
      MalformedBase64Url() || UnhandledAuthenticatorException() =>
        const PasskeyException('Something went wrong with the passkey. Try again.'),
    };
  }
}
