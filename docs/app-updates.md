# Android app updates

The Android app is distributed outside the Play Store and updates itself.
Publishing a release is one command; phones install it in the background.

## How it works

```
scripts/release-android.sh
   └─ GitHub release  android-v1.2.0+12  (one .apk; GitHub records its SHA-256)
        │
tracker server  — reads the releases every 5 min (services/app-releases.ts)
   ├─ GET /api/v1/app/android/latest   → version, APK URL, SHA-256, size, notes
   └─ new version seen → FCM data push  lt_cmd=update  to every device
        │
app (android/.../updates/AppUpdater.kt)
   ├─ checks: on the push, every 6 h (WorkManager), and at app start (≤ 1/h)
   ├─ downloads a newer APK, verifies size + SHA-256
   └─ installs it with PackageInstaller once the app has been off screen for
      3 minutes and no trip is being recorded
```

None of this needs a signed-in user. The login screen also checks every
time it opens and shows a small banner with an *Install* button when a newer
version exists. So if a release breaks signing in, a fixed release still
reaches users without a reinstall.

The app closes while it installs. Tracking resumes by itself
(`BootReceiver` handles `MY_PACKAGE_REPLACED`), so a parked phone carries on
sharing without anyone opening the app.

**Silent installs.** On Android 12+ the app installs its own updates with no
prompt, provided the user has allowed it to install apps (Settings → Apps →
Legacy Tracker → *Install unknown apps*). The profile tab's *App updates* card
links there. Without that permission, or on Android 8–11, the app posts an
"Update ready — tap to install" notification instead, and Android asks for one
confirmation tap. Android itself requires the confirmation in those cases.

**Security.** Android only installs an update signed with the same key as the
installed app. A compromised server, GitHub account or download can therefore
withhold updates, but it can't replace the app with someone else's build. The
SHA-256 check catches corrupted downloads.

**Debug builds** (`flutter run`) never update themselves in the background.
The card's *Check* / *Install* buttons still work, for testing.

## Publishing a release

1. Bump the build number in `src/client/pubspec.yaml` (`version: 1.2.0+12`:
   the number after `+` must go up with every release).
2. Commit and push.
3. Run:

   ```bash
   scripts/release-android.sh --notes "Faster trip detection"
   ```

   It builds the release APK, checks the signing key, shows a summary, asks
   for confirmation, creates the GitHub release and checks the digest GitHub
   recorded.

The `Release Android and iOS` workflow does the same and also attaches an
unsigned iOS IPA plus its SideStore source feed to the release (see below). It
reuses the IPA that CI already built for the commit being tagged, and builds
one on a macOS runner when there is nothing to reuse. To attach an existing
IPA from a local release, pass `--ipa PATH`.

To try a build on a few phones first, pass `--prerelease`. The server ignores
prereleases, so you can install the APK from the release page by hand. Roll it
out with `gh release edit <tag> --prerelease=false`.

**Pulling a bad release:** delete it, or mark it as a prerelease. Phones that
already installed it keep it, because Android doesn't downgrade. Fix forward
with a higher build number.

## Signing key

Every release must be signed with the same key, forever. An APK signed with a
different key can't update existing installs. The app marks that version as
failed and waits for the next one, and users would have to uninstall and
reinstall.

`src/client/android/app/build.gradle.kts` signs release builds with the key described in
`src/client/android/key.properties` (git-ignored):

```properties
storeFile=/absolute/path/to/legacytracker-release.jks
storePassword=…
keyAlias=legacytracker
keyPassword=…
```

Without that file, releases are signed with the building machine's debug key
(`~/.config/.android/debug.keystore` on the current dev machine), as before.
That works, but:

- releases can only be built on that one machine;
- the keystore's password is the well-known `android`;
- losing that file ends updates for every installed phone.

To move to a dedicated key, create one (`keytool -genkeypair -v -keystore
legacytracker-release.jks -alias legacytracker -keyalg RSA -keysize 4096
-validity 36500`), back it up somewhere safe, and add `key.properties`. Phones
running a debug-signed build then have to uninstall and reinstall once. Do
this before the first self-updating build goes out, since that build has to be
installed by hand anyway. Also update `PASSKEY_ANDROID_APPS` on legacy-auth
with the new certificate's SHA-256, or passkey sign-in stops working.

The first published release pins its certificate fingerprint in
`src/client/android/release-signing-cert.sha256` (commit it). The release
script refuses to publish an APK signed with any other key.

## Server configuration

| Variable | Default | |
|---|---|---|
| `ANDROID_RELEASES_REPO` | `Legacy-xForce/legacytracker` | Repository the releases are read from. Empty disables update checks: the endpoint returns 204. |
| `GITHUB_TOKEN` | — | Optional. Unauthenticated GitHub API calls are limited to 60 an hour per IP; the server needs about 12. |

Update pushes need `FIREBASE_SERVICE_ACCOUNT_JSON`, like live mode. Without
it, phones still find releases on their 6-hourly check.

## Limits

- **First install is manual.** Download the APK from the release page.
  Every update after that installs itself.
- **Play Store.** Play's policy forbids apps that update themselves outside
  Play, and `REQUEST_INSTALL_PACKAGES` is a restricted permission there. A
  Play build would need the updater removed.
- **Google's developer verification.** Since September 2026, certified
  Android devices in Brazil, Indonesia, Singapore and Thailand only install
  apps from developers verified with Google, sideloaded ones included. Other
  countries follow from 2027. Before it reaches your users, register the
  package name and signing key in the Android Developer Console. A free
  limited-distribution account covers up to 20 devices; beyond that you need
  a verified account. That is one more reason to settle on the final signing
  key now.
- **iOS** can't install its own updates outside the App Store. The options
  there are TestFlight, an Apple Developer Enterprise / custom-app
  distribution, a sideloaded source such as SideStore (see below), or
  patching Dart code over the air with a service such as Shorebird.

## iOS installs (SideStore / AltStore)

An iOS release is a signed-by-the-user install: CI builds it with
`--no-codesign`, and SideStore re-signs the IPA on the phone with whoever's
Apple ID they use. The release page is not the delivery mechanism — a source
feed is, so the same `scripts/release-android.sh` run publishes both under
fixed asset names:

```
https://github.com/Legacy-xForce/legacytracker/releases/latest/download/altstore-source.json
https://github.com/Legacy-xForce/legacytracker/releases/latest/download/LegacyTracker.ipa
```

`releases/latest/` ignores prereleases and always resolves to the newest
stable release, which is why the names carry no version. The feed is
generated, never hand-edited: it reads the bundle id and minimum iOS out of
`ios/Runner.xcodeproj/project.pbxproj`, the size and SHA-256 from the IPA it
just packaged, and `versions[0]` is what AltStore clients compare against the
installed app, so a new release shows up as an update in the app's own list.

To install: add the feed URL in SideStore (Browse → Sources → add), or use a
one-tap redirect from [altdirect](https://altdirect.app), which only turns a
feed URL into an `sidestore://source?url=` deep link:

```
https://altdirect.app/?url=https://github.com/Legacy-xForce/legacytracker/releases/latest/download/altstore-source.json&r=sidestore
```

What a sideloaded install does not get:

- **No push.** The app is signed with the user's team, not ours, so our
  APNs key cannot address it and FCM data messages (`lt_cmd`) never arrive.
  Live mode still works while the engine is awake — `live_ttl_s` comes back
  with every upload (`TrackingEngine.applyLiveTtl`) — but a stationary,
  backgrounded phone is not woken by someone opening a map. Notifications
  need TestFlight or App Store, where we sign the binary.
- **Free Apple ID limits.** Three sideloaded apps at a time, re-signed every
  7 days; SideStore refreshes it when the phone is on the same Wi-Fi as a
  helper or when the app is opened. A paid developer account raises this to
  one year, on the *user's* account, not ours.
- **Manual first install**, like Android: the source has to be added once.
