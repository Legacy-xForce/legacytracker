#!/usr/bin/env bash
# Publishes the Android app as a GitHub release. Installed apps hear about it
# from the tracker server within minutes and install it in the background —
# see docs/app-updates.md.
#
#   scripts/release-android.sh [--notes "What changed"] [--ipa PATH] [--prerelease] [--allow-dirty] [--yes]
#
# The version comes from src/client/pubspec.yaml (`version: 1.2.0+12`). Bump
# the build number after the `+` for every release: phones only install a
# higher one.
#
#   --notes TEXT    release notes, shown in the app's update card
#   --ipa PATH      unsigned iOS IPA to attach to the same release
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
ipa=""
prerelease=()
allow_dirty=false
assume_yes=false
while (($#)); do
  case "$1" in
    --notes) notes="${2:?--notes needs a value}"; shift 2 ;;
    --ipa) ipa="${2:?--ipa needs a value}"; shift 2 ;;
    --prerelease) prerelease=(--prerelease); shift ;;
    --allow-dirty) allow_dirty=true; shift ;;
    --yes) assume_yes=true; shift ;;
    -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# ── Build ────────────────────────────────────────────────────────────────────
(cd "$client" && flutter build apk --release)
asset="$client/build/legacytracker-$name-$code.apk"
cp "$client/build/app/outputs/flutter-apk/app-release.apk" "$asset"

# ── Signing ──────────────────────────────────────────────────────────────────
sdk="$(sed -n 's/^sdk\.dir=//p' "$client/android/local.properties" 2>/dev/null || true)"
sdk="${sdk:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}}"
apksigner="$(find "$sdk/build-tools" -mindepth 2 -maxdepth 2 -name apksigner 2>/dev/null | sort -V | tail -1)"
[[ -x "$apksigner" ]] || die "apksigner not found under ${sdk:-<no Android SDK>}/build-tools"
set +e
certs="$("$apksigner" verify --print-certs "$asset" 2>&1)"
verify_status=$?
set -e
((verify_status == 0)) || die "apksigner could not verify the APK:\n$certs"
fingerprint="$(sed -n \
  -e 's/^Signer #1 certificate SHA-256 digest: //p' \
  -e 's/^V2 Signer: certificate SHA-256 digest: //p' \
  <<<"$certs" | head -n 1)"
subject="$(sed -n \
  -e 's/^Signer #1 certificate DN: //p' \
  -e 's/^V2 Signer: certificate DN: //p' \
  <<<"$certs" | head -n 1)"
[[ -n "$fingerprint" ]] || die "could not read the APK signing certificate from apksigner:\n$certs"
if [[ -f "$cert_file" ]]; then
  expected="$(tr -d '[:space:]' <"$cert_file")"
  [[ "$fingerprint" == "$expected" ]] ||
    die "the APK is signed with $fingerprint, but releases use $expected (${cert_file#"$root"/}); phones would refuse this update"
fi

sha="$(sha256sum "$asset" | cut -d' ' -f1)"

ipa_asset=""
ipa_sha=""
if [[ -n "$ipa" ]]; then
  [[ -f "$ipa" ]] || die "IPA not found: $ipa"
  ipa_asset="$client/build/legacytracker-$name-$code.ipa"
  cp "$ipa" "$ipa_asset"
  ipa_sha="$(sha256sum "$ipa_asset" | cut -d' ' -f1)"
fi

echo
echo "Release    $tag${prerelease[*]:+ (prerelease)} → $repo"
echo "Commit     ${commit:0:12}$($allow_dirty && echo ' + uncommitted changes' || true)"
echo "APK        ${asset#"$root"/} ($(du -h "$asset" | cut -f1)), sha256 $sha"
if [[ -n "$ipa_asset" ]]; then
  echo "IPA        ${ipa_asset#"$root"/} ($(du -h "$ipa_asset" | cut -f1)), sha256 $ipa_sha"
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
  assets+=("$ipa_asset")
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
