#!/usr/bin/env bash
# Publishes the Android app as a GitHub release. Installed apps hear about it
# from the tracker server within minutes and install it in the background —
# see docs/app-updates.md.
#
#   scripts/release-android.sh [--notes "What changed"] [--apk PATH] [--ipa PATH] [--prerelease] [--allow-dirty] [--yes]
#
# The version comes from src/client/pubspec.yaml (`version: 1.2.0+12`). Bump
# the build number after the `+` for every release: phones only install a
# higher one.
#
#   --notes TEXT    release notes, shown in the app's update card
#   --apk PATH      APK to publish, already built by CI and signed here with
#                   the release key. Needs ANDROID_KEYSTORE plus
#                   ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and
#                   ANDROID_KEY_PASSWORD. Without it the APK is built from
#                   this checkout, signed by Gradle from android/key.properties.
#   --ipa PATH      unsigned iOS IPA to attach to the same release. Also
#                   publishes an AltStore/SideStore source feed next to it,
#                   both under fixed asset names so their URLs never move.
#   --prerelease    upload without rolling out (the server ignores
#                   prereleases); roll out later with
#                   gh release edit <tag> --prerelease=false
#   --allow-dirty   build even with uncommitted changes
#   --yes           don't ask for confirmation
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
client="$root/src/client"
repo="${ANDROID_RELEASES_REPO:-Legacy-xForce/legacytracker}"
# Every release must be signed with the same key, or phones refuse it.
cert_file="$client/android/release-signing-cert.sha256"

notes=""
apk=""
ipa=""
prerelease=()
allow_dirty=false
assume_yes=false
while (($#)); do
  case "$1" in
    --notes) notes="${2:?--notes needs a value}"; shift 2 ;;
    --apk) apk="${2:?--apk needs a value}"; shift 2 ;;
    --ipa) ipa="${2:?--ipa needs a value}"; shift 2 ;;
    --prerelease) prerelease=(--prerelease); shift ;;
    --allow-dirty) allow_dirty=true; shift ;;
    --yes) assume_yes=true; shift ;;
    -h | --help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

# ── Version ──────────────────────────────────────────────────────────────────
version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$client/pubspec.yaml")"
[[ "$version" =~ ^(.+)\+([0-9]+)$ ]] || die "pubspec.yaml version must look like 1.2.0+12 (found '$version')"
name="${BASH_REMATCH[1]}"
code="${BASH_REMATCH[2]}"
tag="android-v$name+$code"

latest="$(gh release list -R "$repo" --limit 100 --json tagName --jq '
  [.[].tagName | select(test("^android-v.+\\+[0-9]+$")) | split("+") | .[-1] | tonumber] | max // 0')"
((code > latest)) || die "build number $code must be higher than the latest release's ($latest); bump version in pubspec.yaml"

# ── Source ───────────────────────────────────────────────────────────────────
if [[ -n "$(git -C "$root" status --porcelain)" ]] && ! $allow_dirty; then
  die "uncommitted changes; commit them first (or pass --allow-dirty)"
fi
commit="$(git -C "$root" rev-parse HEAD)"
[[ -n "$(git -C "$root" branch -r --contains "$commit")" ]] ||
  die "commit ${commit:0:7} isn't pushed; push it first (the release tag points at it)"

# ── APK ──────────────────────────────────────────────────────────────────────
sdk="$(sed -n 's/^sdk\.dir=//p' "$client/android/local.properties" 2>/dev/null || true)"
sdk="${sdk:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}}"
find_build_tool() {
  local tool
  tool="$(find "$sdk/build-tools" -mindepth 2 -maxdepth 2 -name "$1" 2>/dev/null | sort -V | tail -1)"
  [[ -x "$tool" ]] || die "$1 not found under ${sdk:-<no Android SDK>}/build-tools"
  echo "$tool"
}
apksigner="$(find_build_tool apksigner)"
zipalign="$(find_build_tool zipalign)"

asset="$client/build/legacytracker-$name-$code.apk"
mkdir -p "$(dirname "$asset")"
if [[ -n "$apk" ]]; then
  # CI's APK carries the runner's debug key; apksigner strips that and puts the
  # release key on the bytes CI validated.
  [[ -f "$apk" ]] || die "APK not found: $apk"
  for var in ANDROID_KEYSTORE ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
    [[ -n "${!var:-}" ]] || die "--apk needs $var to be set"
  done
  [[ -f "$ANDROID_KEYSTORE" ]] || die "keystore not found: $ANDROID_KEYSTORE"
  aligned="$client/build/.to-sign.apk"
  "$zipalign" -f -p 4 "$apk" "$aligned"
  # minSdk 24, so v2/v3 is what Android checks — the same schemes Gradle put
  # on past releases. Naming them keeps the output the same across build-tools.
  "$apksigner" sign --ks "$ANDROID_KEYSTORE" --ks-key-alias "$ANDROID_KEY_ALIAS" \
    --ks-pass env:ANDROID_KEYSTORE_PASSWORD --key-pass env:ANDROID_KEY_PASSWORD \
    --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
    --out "$asset" "$aligned"
  rm -f "$aligned"
else
  (cd "$client" && flutter build apk --release)
  cp "$client/build/app/outputs/flutter-apk/app-release.apk" "$asset"
fi

# ── Signing ──────────────────────────────────────────────────────────────────
set +e
certs="$("$apksigner" verify --print-certs "$asset" 2>&1)"
verify_status=$?
set -e
((verify_status == 0)) || die "apksigner could not verify the APK:\n$certs"
# apksigner repeats the same certificate under a label per signing scheme it
# finds ("Signer #1 certificate …", "V2 Signer: certificate …",
# "V3.0 Signer: certificate …"), and which of those appear depends on the
# build-tools on the runner, so match any of them.
signer='^(Signer #[0-9]+|V[0-9.]+ Signer):? certificate '
fingerprint="$(sed -n -E -e "s/${signer}SHA-256 digest: //p" <<<"$certs" | head -n 1)"
subject="$(sed -n -E -e "s/${signer}DN: //p" <<<"$certs" | head -n 1)"
[[ -n "$fingerprint" ]] || die "could not read the APK signing certificate from apksigner:\n$certs"
if [[ -f "$cert_file" ]]; then
  expected="$(tr -d '[:space:]' <"$cert_file")"
  [[ "$fingerprint" == "$expected" ]] ||
    die "the APK is signed with $fingerprint, but releases use $expected (${cert_file#"$root"/}); phones would refuse this update"
fi

sha="$(sha256sum "$asset" | cut -d' ' -f1)"

ipa_asset=""
ipa_sha=""
feed_asset=""
if [[ -n "$ipa" ]]; then
  [[ -f "$ipa" ]] || die "IPA not found: $ipa"
  command -v jq >/dev/null || die "jq is required to generate the iOS source feed"
  # Fixed asset names: `releases/latest/download/<name>` is the URL the iOS
  # feed hands out, and it only stays stable if the name never changes.
  ipa_asset="$client/build/LegacyTracker.ipa"
  feed_asset="$client/build/altstore-source.json"
  cp "$ipa" "$ipa_asset"
  ipa_sha="$(sha256sum "$ipa_asset" | cut -d' ' -f1)"
  ipa_size="$(wc -c <"$ipa_asset" | tr -d '[:space:]')"

  # Read the identity out of the Xcode project so the feed can never claim a
  # bundle id or minimum iOS the built IPA does not have.
  ios_project="$client/ios/Runner.xcodeproj/project.pbxproj"
  bundle_id="$(sed -n -E 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);.*/\1/p' "$ios_project" |
    grep -v '\.RunnerTests$' | sort -u | head -1)"
  [[ -n "$bundle_id" ]] || die "could not read the iOS bundle id from ${ios_project#"$root"/}"
  min_ios="$(sed -n -E 's/^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);.*/\1/p' "$ios_project" |
    sort -V | head -1)"

  # `latest` skips prereleases, so a prerelease feed names its own tag.
  if ((${#prerelease[@]})); then
    asset_base="https://github.com/$repo/releases/download/${tag//+/%2B}"
  else
    asset_base="https://github.com/$repo/releases/latest/download"
  fi
  icon_url="https://raw.githubusercontent.com/$repo/HEAD/src/client/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"
  about="Real-time location sharing for the Legacy group: a live map, history and replay, checkpoints and calendar events."

  # AltStore/SideStore source feed. SideStore decodes app-level
  # localizedDescription as a plain string and verifies sha256 when present,
  # and it picks versions[0] as the current release — order matters, not dates.
  jq -n \
    --arg bundleId "$bundle_id" \
    --arg version "$name" \
    --arg build "$code" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg downloadURL "$asset_base/LegacyTracker.ipa" \
    --arg sourceURL "$asset_base/altstore-source.json" \
    --argjson size "$ipa_size" \
    --arg sha256 "$ipa_sha" \
    --arg minOSVersion "$min_ios" \
    --arg iconURL "$icon_url" \
    --arg website "https://github.com/$repo" \
    --arg about "$about" \
    --arg notes "${notes:-Legacy Tracker for iOS. The build is unsigned; SideStore signs it with your own Apple ID.}" \
    '{
      name: "Legacy Tracker",
      identifier: ($bundleId + ".source"),
      website: $website,
      sourceURL: $sourceURL,
      iconURL: $iconURL,
      subtitle: $about,
      description: ("Apps in this source are built from " + $website + " and re-signed by your own Apple ID, so Apple push notifications are not available. Your phone still streams live positions while it is awake and tracking."),
      apps: [
        {
          name: "Legacy Tracker",
          bundleIdentifier: $bundleId,
          developerName: "Legacy xForce",
          subtitle: $about,
          localizedDescription: $about,
          iconURL: $iconURL,
          category: "social",
          versions: [
            {
              version: $version,
              buildVersion: $build,
              date: $date,
              localizedDescription: $notes,
              downloadURL: $downloadURL,
              size: $size,
              sha256: $sha256
            }
            + (if $minOSVersion == "" then {} else {minOSVersion: $minOSVersion} end)
          ]
        }
      ]
    }' >"$feed_asset"
fi

echo
echo "Release    $tag${prerelease[*]:+ (prerelease)} → $repo"
echo "Commit     ${commit:0:12}$($allow_dirty && echo ' + uncommitted changes' || true)"
echo "APK        ${asset#"$root"/} ($(du -h "$asset" | cut -f1)), sha256 $sha"
if [[ -n "$ipa_asset" ]]; then
  echo "IPA        ${ipa_asset#"$root"/} ($(du -h "$ipa_asset" | cut -f1)), sha256 $ipa_sha"
  echo "Feed       ${feed_asset#"$root"/}"
fi
echo "Signed by  $subject"
echo "           $fingerprint"
if [[ "$subject" == *"CN=Android Debug"* ]]; then
  echo
  echo "warning: signed with this machine's debug key. Every future release must be"
  echo "         signed with this same key; see docs/app-updates.md, \"Signing key\"."
fi
echo
if ! $assume_yes; then
  read -r -p "Publish? [y/N] " answer
  [[ "$answer" == [yY]* ]] || exit 1
fi

# ── Publish ──────────────────────────────────────────────────────────────────
assets=("$asset")
title="Android $name ($code)"
if [[ -n "$ipa_asset" ]]; then
  assets+=("$ipa_asset" "$feed_asset")
  title="Android + iOS $name ($code)"
fi
gh release create "$tag" "${assets[@]}" -R "$repo" --target "$commit" \
  --title "$title" --notes "$notes" ${prerelease[@]+"${prerelease[@]}"}

digest="$(gh api "repos/$repo/releases/tags/${tag//+/%2B}" \
  --jq '.assets[] | select(.name | endswith(".apk")) | .digest')"
[[ "$digest" == "sha256:$sha" ]] || die "GitHub reports '$digest' for the uploaded APK, expected sha256:$sha"
if [[ -n "$ipa_asset" ]]; then
  ipa_digest="$(gh api "repos/$repo/releases/tags/${tag//+/%2B}" \
    --jq '.assets[] | select(.name | endswith(".ipa")) | .digest')"
  [[ "$ipa_digest" == "sha256:$ipa_sha" ]] || die "GitHub reports '$ipa_digest' for the uploaded IPA, expected sha256:$ipa_sha"
  echo "iOS feed   $asset_base/altstore-source.json"
  echo "           one-tap: https://altdirect.app/?url=$asset_base/altstore-source.json&r=sidestore"
fi

if [[ ! -f "$cert_file" ]]; then
  echo "$fingerprint" >"$cert_file"
  echo "Pinned the signing certificate in ${cert_file#"$root"/}; commit it."
fi
if ((${#prerelease[@]})); then
  echo "Uploaded as a prerelease. Roll it out with: gh release edit '$tag' -R $repo --prerelease=false"
else
  echo "Published. Phones are told within ~5 minutes and install it once the app is in the background."
fi
