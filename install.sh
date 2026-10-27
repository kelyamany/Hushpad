#!/bin/zsh
# Hushpad installer: builds the latest source and installs it, keeping exactly one copy of the app.
#
#   ./install.sh                 Mac: test, build, install to /Applications, launch
#   ./install.sh --iphone        also build & install on the connected iPhone (+ Apple Watch app)
#   ./install.sh --iphone-only   only the iPhone (+ Watch)
#   ./install.sh --clean         wipe build caches first (use when something behaves oddly)
#   ./install.sh --skip-tests    don't run the test suite
#   ./install.sh --team ABCDE12345   your Apple Development team ID (auto-detected if omitted)
#   ./install.sh --tidy          only remove stray copies of the app (Launchpad duplicates, old builds)
#   ./install.sh --uninstall     remove Hushpad from this Mac (asks before touching recordings)
#   ./install.sh --uninstall --iphone   …and from the connected iPhone (and its Watch)
#
# Installing never touches your recordings, settings or downloaded models.
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build.noindex"          # .noindex: Spotlight and Launchpad ignore build products
APP_NAME="Hushpad"
OLD_DEST="/Applications/LocalScribe.app"   # the app's name before 1.0; same app, same data
BUNDLE_ID="dev.localscribe.app"
DEST="/Applications/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/LocalScribe"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

do_mac=1 do_iphone=0 clean=0 tests=1 team="" mode=install
while (( $# )); do
  case "$1" in
    --iphone) do_iphone=1 ;;
    --iphone-only) do_iphone=1; do_mac=0 ;;
    --clean) clean=1 ;;
    --skip-tests) tests=0 ;;
    --team) team="${2:-}"; shift ;;
    --tidy) mode=tidy ;;
    --uninstall) mode=uninstall ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
  esac
  shift
done

bold=$'\e[1m' dim=$'\e[2m' green=$'\e[32m' yellow=$'\e[33m' red=$'\e[31m' reset=$'\e[0m'
step() { print -P "\n${bold}▸ $1${reset}"; }
ok()   { print "  ${green}✓${reset} $1"; }
warn() { print "  ${yellow}!${reset} $1"; }
info() { print "  ${dim}$1${reset}"; }
fail() { print "  ${red}✗ $1${reset}"; exit 1; }
# Yes/no question; the default is No unless the second argument is "y".
ask() {
  local answer prompt="[y/N]"
  [[ "${2:-n}" == y ]] && prompt="[Y/n]"
  print -n "  ${bold}?${reset} $1 $prompt "
  read -r answer </dev/tty || answer=""
  [[ -z "$answer" ]] && answer="${2:-n}"
  [[ "$answer" == [yY]* ]]
}

# Runs xcodebuild quietly, showing only errors; prints the log path on failure.
xcb() {
  local log="$BUILD/last-build.log"
  mkdir -p "$BUILD"
  if ! xcodebuild "$@" >"$log" 2>&1; then
    grep -E "error:|failed" "$log" | sort -u | head -20
    return 1
  fi
}

cd "$ROOT"

# ── Stray copies ─────────────────────────────────────────────────────────────
# Every Hushpad.app (or LocalScribe.app, its old name) macOS has ever seen (build folders, disk images, simulator builds) shows up in Launchpad.
# Keep only the one in /Applications: unregister the rest and delete old build products of this repo.
registered_copies() {
  "$LSREGISTER" -dump 2>/dev/null | sed -nE 's/^path:[[:space:]]+(.*\/('"$APP_NAME"'|LocalScribe)\.app)( \(0x[0-9a-f]+\))?$/\1/p' | sort -u
}

tidy() {
  local keep="${1:-$DEST}" removed=0
  while IFS= read -r copy; do
    [[ -z "$copy" || "$copy" == "$keep" ]] && continue
    "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true
    removed=$((removed + 1))
  done < <(registered_copies)
  # Build products from older versions of this script and from development builds.
  local stale=("$ROOT/build" "$ROOT/dist/dmg")
  for dir in "${stale[@]}"; do
    if [[ -e "$dir" ]]; then rm -rf "$dir"; fi
  done
  if [[ -d "$BUILD" ]]; then
    find "$BUILD" \( -name "$APP_NAME.app" -o -name "LocalScribe.app" \) -type d -prune 2>/dev/null | while IFS= read -r app; do
      "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    done || true
  fi
  "$LSREGISTER" -gc >/dev/null 2>&1 || true
  # Launchpad caches its grid; restarting the Dock makes it re-read the (now clean) list.
  if (( removed > 0 )); then killall Dock 2>/dev/null || true; fi
  if (( removed == 1 )); then ok "Removed 1 stray copy from Launchpad"; else ok "Removed $removed stray copies from Launchpad"; fi
}

quit_mac_app() {
  mac_running() {
    pgrep -qf "^$DEST/Contents/MacOS/$APP_NAME" || pgrep -qf "$APP_NAME.app/Contents/MacOS/$APP_NAME$" ||
      pgrep -qf "^$OLD_DEST/Contents/MacOS/LocalScribe"
  }
  if mac_running; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do mac_running || break; sleep 0.5; done
    mac_running && fail "Hushpad is still open (recording, or a window waiting for you?). Quit it and rerun."
    ok "Closed the running app"
  fi
}

find_iphone() {
  mkdir -p "$BUILD"
  local devices_json="$BUILD/devices.json"
  xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1 || fail "Couldn't list devices (is Xcode set up?)."
  device=$(python3 -I - "$devices_json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for d in data.get("result", {}).get("devices", []):
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and hw.get("reality") != "simulated" and conn.get("pairingState") == "paired":
        print(d["identifier"], hw.get("udid", ""), d.get("deviceProperties", {}).get("name", "iPhone"), sep="\t")
        break
PY
)
  [[ -n "$device" ]] || fail "No paired iPhone found. Connect it with a cable, unlock it, tap Trust, and enable Settings › Privacy & Security › Developer Mode."
  IFS=$'\t' read -r device_id device_udid device_name <<<"$device"
  ok "Found $device_name"
}

# Bundle ids of every Hushpad (or LocalScribe) build on the iPhone (older versions may have used other ids).
iphone_copies() {
  local apps_json="$BUILD/iphone-apps.json"
  xcrun devicectl device info apps --device "$device_id" --json-output "$apps_json" >/dev/null 2>&1 || return 0
  python3 -I - "$apps_json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for app in data.get("result", {}).get("apps", []):
    bundle, name = app.get("bundleIdentifier", ""), app.get("name", "")
    if "localscribe" in bundle.lower() or name in ("Hushpad", "LocalScribe"):
        print(bundle)
PY
}

# ── Tidy only ────────────────────────────────────────────────────────────────
if [[ $mode == tidy ]]; then
  step "Removing stray copies of Hushpad"
  tidy
  print "\n${green}${bold}Done.${reset}"
  exit 0
fi

# ── Uninstall ────────────────────────────────────────────────────────────────
if [[ $mode == uninstall ]]; then
  step "Uninstalling Hushpad"
  print "  This removes:"
  if (( do_mac )); then
    info "• the app ($DEST) and every other copy macOS knows about"
    info "• its settings, permissions and saved window state"
    info "• downloaded speech models ($(du -sh "$SUPPORT/Models" 2>/dev/null | cut -f1 || echo "none"))"
    info "• build files in this folder"
  fi
  if (( do_iphone )); then info "• the iPhone app, its Watch app and everything stored only on that iPhone"; fi
  print "  Your recordings are kept unless you say otherwise in a moment."
  ask "Continue?" || { print "  Nothing was changed."; exit 0; }

  if (( do_mac )); then
    quit_mac_app
    for app in "$DEST" "$OLD_DEST"; do
      if [[ -d "$app" ]]; then rm -rf "$app"; ok "Removed $app"; fi
    done
    tidy "/nonexistent"
    "$LSREGISTER" -u "$DEST" >/dev/null 2>&1 || true

    if tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1; then ok "Reset permissions (microphone, screen & system audio)"; fi
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    ok "Removed settings"
    rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
           "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
           "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" "$HOME/Library/WebKit/$BUNDLE_ID"
    # Keys saved by older versions (this Mac only). A key in iCloud Keychain is shared with your iPhone.
    # Only the API keys. The library key (account "library-key") stays: without it an encrypted library can't be opened again.
    for account in openrouter-api-key opencode-go-api-key; do
      while security delete-generic-password -s LocalScribe -a "$account" >/dev/null 2>&1; do :; done
    done
    ok "Removed the API keys stored on this Mac"
    info "Keys synced through iCloud Keychain stay for your other devices; delete “LocalScribe” in the Passwords app to remove them everywhere. Your library encryption key is kept on purpose."

    if [[ -d "$SUPPORT/Models" ]]; then rm -rf "$SUPPORT/Models"; ok "Removed speech models"; fi

    local_count=$(find "$SUPPORT/Recordings" -name recording.json -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
    staged=$(find "$SUPPORT/In Progress" -name recording.json -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
    total=$((local_count + staged))
    if (( total > 0 )); then
      if ask "Also delete the $total recording(s) stored on this Mac (in $SUPPORT)? They go to the Trash."; then
        trash_dir="$HOME/.Trash/Hushpad Recordings $(date +%Y-%m-%d\ %H%M%S)"
        mkdir -p "$trash_dir"
        if [[ -d "$SUPPORT/Recordings" ]]; then mv "$SUPPORT/Recordings" "$trash_dir/"; fi
        if [[ -d "$SUPPORT/In Progress" ]]; then mv "$SUPPORT/In Progress" "$trash_dir/"; fi
        rmdir "$SUPPORT" 2>/dev/null || true
        ok "Moved your recordings to the Trash"
      else
        ok "Kept your recordings in $SUPPORT"
      fi
    else
      rm -rf "$SUPPORT"
    fi
    info "A library folder you chose yourself (for example in iCloud Drive) is never touched."

    rm -rf "$BUILD" "$ROOT/build" "$ROOT/dist" "$ROOT/LocalScribeKit/.build"
    rm -rf ~/Library/Developer/Xcode/DerivedData/LocalScribe-*
    ok "Removed build files"
  fi

  if (( do_iphone )); then
    step "Uninstalling from iPhone"
    find_iphone
    warn "Recordings kept only on the iPhone (not in a synced folder) are deleted with the app."
    if ask "Remove Hushpad from $device_name?"; then
      for bundle in $(iphone_copies) "$BUNDLE_ID"; do
        xcrun devicectl device uninstall app --device "$device_id" "$bundle" >/dev/null 2>&1 && ok "Removed $bundle" || true
      done
      info "The Watch app is removed together with the iPhone app."
    fi
  fi
  print "\n${green}${bold}Hushpad is uninstalled.${reset}"
  exit 0
fi

# ── Prerequisites ────────────────────────────────────────────────────────────
step "Checking tools"
command -v xcodebuild >/dev/null || fail "Xcode is not installed. Install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
xcodebuild -version >/dev/null 2>&1 || fail "Xcode command line tools aren't set up. Run: sudo xcode-select -s /Applications/Xcode.app"
ok "$(xcodebuild -version | head -1)"
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || fail "XcodeGen is missing and Homebrew isn't installed. Install Homebrew (brew.sh), then rerun."
  warn "Installing XcodeGen with Homebrew…"
  brew install xcodegen >/dev/null
fi
ok "XcodeGen $(xcodegen --version | awk '{print $2}')"

# Signing with your Apple Development certificate gives the app a stable identity: macOS then keeps its
# permissions (microphone, screen & system audio) across updates, and the API key can sync via iCloud Keychain.
identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
if [[ -z "$team" && -n "$identity" ]]; then
  team=$(security find-certificate -c "$identity" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
         | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | head -1 || true)
fi
if [[ -n "$identity" ]]; then ok "Signing as $identity${team:+ (team $team)}"; else warn "No Apple Development certificate: the Mac app will be signed to run locally."; fi

# ── Clean ────────────────────────────────────────────────────────────────────
if (( clean )); then
  step "Cleaning build caches"
  rm -rf "$BUILD" "$ROOT/build" "$ROOT/dist" "$ROOT/LocalScribeKit/.build"
  rm -rf ~/Library/Developer/Xcode/DerivedData/LocalScribe-*
  ok "Clean"
fi
mkdir -p "$BUILD"

step "Generating the Xcode project"
xcodegen generate --quiet
ok "LocalScribe.xcodeproj is up to date"

# ── Tests ────────────────────────────────────────────────────────────────────
if (( tests )); then
  step "Running tests"
  if (cd LocalScribeKit && swift test >"$BUILD/tests.log" 2>&1); then
    ok "$(grep -E 'Test run with' "$BUILD/tests.log" | tail -1 | sed -E 's/.*(Test run with [0-9]+ tests).*/\1/') passed"
  else
    grep -E "✘|error:" "$BUILD/tests.log" | head -15
    fail "Tests failed (log: $BUILD/tests.log). Use --skip-tests to install anyway."
  fi
fi

# ── Mac ──────────────────────────────────────────────────────────────────────
if (( do_mac )); then
  step "Building for Mac (Release)"
  mac_build() {
    xcb -project LocalScribe.xcodeproj -scheme LocalScribe -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$BUILD" "$@" build
  }
  signed=none
  if [[ -n "$identity" && -n "$team" ]]; then
    team_sign=(CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates)
    if mac_build "${team_sign[@]}" LOCALSCRIBE_MAC_ENTITLEMENTS=App/LocalScribe-Keychain.entitlements; then
      signed=keychain
    elif mac_build "${team_sign[@]}"; then
      signed=team
      warn "Couldn't set up iCloud Keychain for the Mac app; your API key will stay on this Mac."
    fi
  fi
  if [[ $signed == none ]]; then
    mac_build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= || fail "Build failed. Full log: $BUILD/last-build.log"
    warn "Signed to run locally: macOS may ask for permissions again after each update, and the API key won't sync."
  fi
  built="$BUILD/Build/Products/Release/$APP_NAME.app"
  codesign --verify --deep --strict "$built" 2>/dev/null || fail "The built app's signature is invalid."
  ok "Built $(defaults read "$built/Contents/Info.plist" CFBundleShortVersionString)"

  step "Installing to /Applications"
  quit_mac_app
  rm -rf "$DEST.new"
  ditto "$built" "$DEST.new"
  xattr -cr "$DEST.new"
  rm -rf "$DEST" && mv "$DEST.new" "$DEST"
  # ditto keeps the build's old folder date; macOS caches icons by it, so bump it or a new icon never shows.
  touch "$DEST"
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  ok "Installed $DEST"
  if [[ -d "$OLD_DEST" ]]; then
    "$LSREGISTER" -u "$OLD_DEST" >/dev/null 2>&1 || true
    rm -rf "$OLD_DEST"
    ok "Removed the old LocalScribe.app (Hushpad replaces it; your meetings and settings stay)"
  fi
  tidy
  open "$DEST"
  ok "Launched"
fi

# ── iPhone (+ Watch) ─────────────────────────────────────────────────────────
if (( do_iphone )); then
  step "Installing on iPhone"
  [[ -n "$team" ]] || fail "No team found. In Xcode › Settings › Accounts, add your Apple ID (a free one works), click Manage Certificates › + › Apple Development, then rerun. Or pass --team YOURTEAMID."
  find_iphone

  step "Building for iPhone + Apple Watch"
  # Building for this iPhone (not generic iOS) lets Xcode add it to the provisioning profile.
  ios_destination="generic/platform=iOS"
  [[ -n "$device_udid" ]] && ios_destination="id=$device_udid"
  xcb -project LocalScribe.xcodeproj -scheme LocalScribe -configuration Release \
      -destination "$ios_destination" -derivedDataPath "$BUILD" \
      CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
      || fail "Build failed. Full log: $BUILD/last-build.log"
  ios_app="$BUILD/Build/Products/Release-iphoneos/$APP_NAME.app"
  [[ -d "$ios_app" ]] || fail "iPhone build not found."
  ok "Built"

  # Older builds under another bundle id would otherwise sit next to this one on the Home Screen.
  for bundle in $(iphone_copies); do
    [[ "$bundle" == "$BUNDLE_ID" || "$bundle" == "$BUNDLE_ID".* ]] && continue
    xcrun devicectl device uninstall app --device "$device_id" "$bundle" >/dev/null 2>&1 && ok "Removed an older copy ($bundle)" || true
  done

  xcrun devicectl device install app --device "$device_id" "$ios_app" >"$BUILD/install.log" 2>&1 \
    || { tail -5 "$BUILD/install.log"; fail "Install failed. Is the iPhone unlocked?"; }
  ok "Installed on $device_name"
  info "First time only: on the iPhone open Settings › General › VPN & Device Management and trust your developer profile."
  info "The Watch app installs from the iPhone automatically (Watch app › General › Automatic App Install), or tap Install under Available Apps."
  info "With a free Apple ID this install works for 7 days. Rerun ./install.sh --iphone-only to renew; your recordings stay."
fi

print "\n${green}${bold}Done.${reset}"
