import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class AppConstants {
  static const _productionBackendUrl = 'https://tracker.legacy-group.tech';

  // Tracker backend. Release builds always talk to production. A debug build
  // can be pointed at a local server with
  // `flutter run --dart-define=BACKEND_URL=http://10.0.2.2:3000` (10.0.2.2 is
  // the host machine as seen from the Android emulator).
  static const backendBaseUrl = kReleaseMode
      ? _productionBackendUrl
      : String.fromEnvironment('BACKEND_URL', defaultValue: _productionBackendUrl);

  // Legacy Auth, the OpenID Provider the app signs in with. Like the tracker
  // backend, release builds always talk to production; a debug build can use a
  // local one with `--dart-define=AUTH_URL=http://10.0.2.2:4000`.
  static const _productionAuthUrl = 'https://auth.legacy-group.tech';
  static const authBaseUrl = kReleaseMode
      ? _productionAuthUrl
      : String.fromEnvironment('AUTH_URL', defaultValue: _productionAuthUrl);

  // This app's public client at Legacy Auth, and the custom-scheme URIs it is
  // registered with (docs/oidc-migration.md).
  static const oidcClientId = 'tracker-mobile';
  static const oidcCallbackScheme = 'com.legacy.legacytracker';
  static const oidcRedirectUri = '$oidcCallbackScheme:/oauth2redirect';
  static const oidcPostLogoutRedirectUri = '$oidcCallbackScheme:/logout';

  // Legacy Auth's own page for the account: password, passkeys, picture.
  static const accountSettingsUrl = '$authBaseUrl/settings';

  // Legacy Calendar, which takes a calendar token from the same sign-in. Like
  // the tracker backend, release builds always talk to production.
  static const _productionCalendarUrl = 'https://calendar.legacy-group.tech';
  static const calendarBaseUrl = kReleaseMode
      ? _productionCalendarUrl
      : String.fromEnvironment('CALENDAR_URL', defaultValue: _productionCalendarUrl);

  // The Legacy Calendar web app (not its API): where an event's "Open in
  // Legacy Calendar" link goes. Debug builds can override it with
  // `--dart-define=CALENDAR_WEB_URL=...`.
  static const _productionCalendarWebUrl = 'https://legacy-calendar.pages.dev';
  static const calendarWebUrl = kReleaseMode
      ? _productionCalendarWebUrl
      : String.fromEnvironment('CALENDAR_WEB_URL', defaultValue: _productionCalendarWebUrl);

  // Default map center (San Francisco)
  static const defaultMapCenter = LatLng(37.7749, -122.4194);
  static const defaultZoom = 13.0;

  // Map zoom limits. minZoom is intentionally permissive: the camera bounds
  // constraint (see worldBounds) is what actually stops zoom-out once the world
  // fills the viewport, so it adapts to the screen size instead of a fixed floor.
  static const minZoom = 1.0;
  static const maxZoom = 18.0;

  // Web Mercator's latitude limit: tiles don't exist beyond this, so showing it
  // would reveal a grey void at the poles.
  static const double maxMercatorLatitude = 85.05112878;
}
