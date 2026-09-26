#!/bin/bash
# End-to-end macOS release: build → Developer ID sign → notarize → staple →
# Gatekeeper verification → dist zip → Sparkle appcast → GitHub release.
#
# Usage: Scripts/release-macos.sh [all|build|notarize|verify|package|publish]...
#   default: all. Stages run in the listed order; each later stage assumes
#   the earlier ones already ran (e.g. `verify package publish` re-uses the
#   stapled app in .build/app).
#
# Required environment:
#   SIGN_IDENTITY   "Developer ID Application: … (TEAMID)"
# Optional:
#   ASC_PROFILE     asc auth profile holding the notary API key (default: Default)
#   GH_REPO         GitHub repo for the release (default: MikeChongCan/kumone)
#   ARCHES          e.g. "arm64 x86_64" for a universal build (see build-app.sh)
#
# Every artifact is verified the way a user's Mac will judge it (staple
# present, spctl accepts, syspolicy_check passes, a quarantined copy passes
# gktool) BEFORE anything is uploaded. A release that would show "Apple could
# not verify … is free of malware" cannot get past this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

APP_NAME="Kumone"
APP_BUNDLE="$ROOT/.build/app/$APP_NAME.app"
DIST="$ROOT/dist"
ASC_PROFILE="${ASC_PROFILE:-Default}"
GH_REPO="${GH_REPO:-MikeChongCan/kumone}"
FEED_URL="https://github.com/$GH_REPO/releases/latest/download/appcast.xml"
SPARKLE_BIN="$(find "$ROOT/.build/artifacts" -type d -path '*Sparkle/bin' 2>/dev/null | head -n1)"

VERSION="$(sed -n 's/^MARKETING_VERSION="\(.*\)"$/\1/p' "$SCRIPT_DIR/build-app.sh")"
[ -n "$VERSION" ] || { echo "error: cannot read MARKETING_VERSION from build-app.sh" >&2; exit 1; }
ZIP="$DIST/$APP_NAME-$VERSION.zip"
NOTARY_ZIP="$ROOT/.build/$APP_NAME-$VERSION-notarize.zip"
APPCAST="$DIST/appcast.xml"

log() { printf '\n==> %s\n' "$*"; }

stage_build() {
  [ -n "${SIGN_IDENTITY:-}" ] || { echo "error: SIGN_IDENTITY is required for a release build" >&2; exit 1; }
  log "Building $VERSION (release, signed)"
  SIGN_IDENTITY="$SIGN_IDENTITY" "$SCRIPT_DIR/build-app.sh" release
}

stage_notarize() {
  log "Notarizing $VERSION via asc profile '$ASC_PROFILE'"
  rm -f "$NOTARY_ZIP"
  make_zip "$APP_BUNDLE" "$NOTARY_ZIP"
  local result
  result="$(asc --profile "$ASC_PROFILE" notarization submit --file "$NOTARY_ZIP" --wait --timeout 1h)"
  local id status
  id="$(printf '%s' "$result" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("data",d).get("id",""))')"
  status="$(printf '%s' "$result" | python3 -c 'import sys,json; d=json.load(sys.stdin); d=d.get("data",d); print(d.get("attributes",d).get("status",""))')"
  echo "submission $id: $status"
  if [ "$status" != "Accepted" ]; then
    echo "error: notarization not accepted; developer log:" >&2
    asc --profile "$ASC_PROFILE" notarization log --id "$id" >&2 || true
    exit 1
  fi
  log "Stapling ticket"
  xcrun stapler staple "$APP_BUNDLE"
}

# make_zip <app> <zip> — a zip with no extended attributes / AppleDouble
# entries. ditto's default archives com.apple.provenance etc. as "._name"
# sidecars; extractors that cannot fold them back into xattrs leave them as
# files inside the bundle, which breaks the seal ("unsealed contents present
# in the root directory of an embedded framework" on 0.3.21).
make_zip() {
  rm -f "$2"
  ditto -c -k --keepParent --norsrc --noextattr --noqtn "$1" "$2"
  if unzip -l "$2" | grep -q '/\._'; then
    echo "error: $2 contains AppleDouble entries" >&2; exit 1
  fi
}

# verify_app <app> — fails unless a fresh Mac would open it without the
# "could not verify … malware" dialog.
verify_app() {
  local app="$1"
  codesign --verify --deep --strict --verbose=2 "$app"
  local sign_info
  sign_info="$(codesign -dvv "$app" 2>&1)"
  grep -q 'flags=0x10000(runtime)' <<<"$sign_info" || { echo "error: hardened runtime missing on $app" >&2; exit 1; }
  xcrun stapler validate "$app"
  local spctl_out
  spctl_out="$(spctl -a -vv --type execute "$app" 2>&1)"
  echo "$spctl_out"
  grep -q 'source=Notarized Developer ID' <<<"$spctl_out" || { echo "error: Gatekeeper does not see a notarized Developer ID app" >&2; exit 1; }
  syspolicy_check distribution "$app"
  # Simulate a browser download: copy with a quarantine flag and ask Gatekeeper.
  local q="$ROOT/.build/quarantine-check.app"
  rm -rf "$q"; cp -R "$app" "$q"
  xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;" "$q"
  local gk
  gk="$(gktool scan "$q" 2>&1 | tr '\r' '\n' | tail -n1)"
  rm -rf "$q"
  echo "$gk"
  grep -q 'would be allowed' <<<"$gk" || { echo "error: quarantined copy would be blocked by Gatekeeper" >&2; exit 1; }
}

stage_verify() {
  log "Verifying stapled app"
  verify_app "$APP_BUNDLE"
}

stage_package() {
  log "Packaging $ZIP"
  mkdir -p "$DIST"
  rm -f "$ZIP"
  make_zip "$APP_BUNDLE" "$ZIP"
  # Verify what users will actually download, extracted with plain unzip:
  # unlike Archive Utility it keeps nothing from extended attributes, so it
  # is the strictest extractor a user is likely to hit.
  local unpack="$ROOT/.build/zip-check"
  rm -rf "$unpack"; mkdir -p "$unpack"
  unzip -q "$ZIP" -d "$unpack"
  verify_app "$unpack/$APP_NAME.app"
  rm -rf "$unpack"

  log "Signing update and writing appcast"
  [ -n "$SPARKLE_BIN" ] || { echo "error: Sparkle bin tools not found under .build/artifacts" >&2; exit 1; }
  local sig_attrs
  sig_attrs="$("$SPARKLE_BIN/sign_update" "$ZIP")"   # sparkle:edSignature="…" length="…"
  local notes_html
  notes_html="$("$SCRIPT_DIR/release-notes.sh" "$VERSION" --html)"
  local build_number pub_date
  build_number="$(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleVersion)"
  pub_date="$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"
  local item_file="$ROOT/.build/appcast-item.xml"
  cat > "$item_file" <<ITEM
        <item>
            <title>$VERSION</title>
            <pubDate>$pub_date</pubDate>
            <sparkle:version>$build_number</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <description><![CDATA[$notes_html]]></description>
            <enclosure url="https://github.com/$GH_REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.zip" type="application/octet-stream" $sig_attrs/>
        </item>
ITEM
  # Keep the previously published items so older installs still get an update path.
  local previous="$ROOT/.build/appcast-previous.xml"
  if ! curl -fsSL "$FEED_URL" -o "$previous"; then
    printf '<?xml version="1.0" standalone="yes"?>\n<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n    <channel>\n        <title>%s</title>\n    </channel>\n</rss>\n' "$APP_NAME" > "$previous"
  fi
  VERSION="$VERSION" ITEM_FILE="$item_file" PREVIOUS="$previous" OUT="$APPCAST" python3 - <<'PY'
import os, re
prev = open(os.environ["PREVIOUS"], encoding="utf-8").read()
item = open(os.environ["ITEM_FILE"], encoding="utf-8").read()
ver = os.environ["VERSION"]
# Drop any earlier item for this same version (re-release), then insert the new one first.
prev = re.sub(r"\s*<item>(?:(?!</item>).)*?<title>%s</title>.*?</item>" % re.escape(ver), "", prev, flags=re.S)
head, sep, tail = prev.partition("<channel>")
if not sep:
    raise SystemExit("appcast: no <channel> element")
title_end = tail.find("</title>")
if title_end == -1:
    raise SystemExit("appcast: channel has no <title>")
insert_at = title_end + len("</title>")
tail = tail[:insert_at] + "\n" + item.rstrip("\n") + tail[insert_at:]
open(os.environ["OUT"], "w", encoding="utf-8").write(head + sep + tail)
PY
  xmllint --noout "$APPCAST"
  grep -q "releases/download/v$VERSION/$APP_NAME-$VERSION.zip" "$APPCAST"
  echo "appcast: $APPCAST"
}

stage_publish() {
  log "Publishing v$VERSION to $GH_REPO"
  [ -f "$ZIP" ] && [ -f "$APPCAST" ] || { echo "error: run the package stage first" >&2; exit 1; }
  local notes="$ROOT/.build/release-notes-$VERSION.md"
  "$SCRIPT_DIR/release-notes.sh" "$VERSION" > "$notes"
  # Only ASCII asset names: GitHub strips non-ASCII characters from asset
  # filenames, which turned 网易云小乐-x.zip into a confusing "-x.zip" duplicate.
  if gh release view "v$VERSION" --repo "$GH_REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" "$APPCAST" --repo "$GH_REPO" --clobber
  else
    gh release create "v$VERSION" "$ZIP" "$APPCAST" --repo "$GH_REPO" \
      --title "v$VERSION" --notes-file "$notes" --latest
  fi
  log "Checking the live feed"
  # GitHub's releases/latest redirect can lag a new release by a minute.
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if curl -fsSL "$FEED_URL" | grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"; then
      echo "live appcast lists $VERSION"; break
    fi
    [ "$attempt" -lt 6 ] || { echo "error: live appcast does not list $VERSION after 3 minutes" >&2; exit 1; }
    sleep 30
  done
  echo "https://github.com/$GH_REPO/releases/tag/v$VERSION"
}

STAGES=("$@")
[ "${#STAGES[@]}" -eq 0 ] && STAGES=(all)
for stage in "${STAGES[@]}"; do
  case "$stage" in
    all) stage_build; stage_notarize; stage_verify; stage_package; stage_publish ;;
    build|notarize|verify|package|publish) "stage_$stage" ;;
    *) echo "usage: $0 [all|build|notarize|verify|package|publish]..." >&2; exit 2 ;;
  esac
done
