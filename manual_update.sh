#!/bin/bash
# X-Autopilot manual update helper
# 
# WHY THIS EXISTS
# ───────────────
# v1.0.13 through v1.0.19 shipped with a broken in-app installer:
# clicking INSTALL NOW in the dashboard banner downloaded the new DMG
# but never completed the swap (a quit_flag bug killed the install
# thread mid-flight). v1.0.20+ has the fix, but you can't get there
# via the broken in-app updater. This script does the swap manually.
#
# WHAT IT DOES
# ────────────
# 1. Detects your Mac's architecture (Apple Silicon vs Intel)
# 2. Downloads the latest signed + notarized DMG
# 3. Quits any running X-Autopilot processes
# 4. Atomically swaps /Applications/X-Autopilot.app with the new bundle
# 5. Refreshes macOS Launch Services so the new bundle is recognized
# 6. Relaunches the app
#
# WHAT YOUR DATA DOES
# ───────────────────
# Nothing — your data stays exactly where it is.
# .env (API keys), config.yaml (settings), data/ (Twitter cookies,
# action history, voice profile) all live in
#   ~/Library/Application Support/X-Autopilot/
# This script only touches /Applications/X-Autopilot.app (the binary).
# When the new app launches, it picks up your existing data dir and
# resumes exactly where you left off — no re-onboarding, no lost stats.
#
# USAGE
#   curl -fsSL https://raw.githubusercontent.com/worklab-studio/x-autopilot-updates/main/manual_update.sh | bash
#
# Or save the script and run:
#   bash manual_update.sh

set -euo pipefail

REPO="worklab-studio/x-autopilot-updates"
APP_PATH="/Applications/X-Autopilot.app"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   X-Autopilot — Manual Update                    ║"
echo "║   Your data, login, settings stay safe.          ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── 1. Detect architecture ─────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
    arm64|aarch64)  DMG_NAME="X-Autopilot-mac-arm64.dmg" ;;
    x86_64|amd64)   DMG_NAME="X-Autopilot-mac-x86_64.dmg" ;;
    *)
        echo "❌ Unrecognized architecture: $ARCH"
        echo "   This script supports arm64 (Apple Silicon) and x86_64 (Intel)."
        exit 1 ;;
esac
echo "📐 Detected: $ARCH → will download $DMG_NAME"

# ── 2. Find latest release tag ─────────────────────────────────────
echo "🌐 Fetching latest release tag from GitHub..."
# Use python3 (always present on macOS 10.15+) to parse JSON safely.
# macOS grep/sed don't support \s — earlier regex approach broke parsing.
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | /usr/bin/python3 -c "import sys, json; print(json.load(sys.stdin).get('tag_name', ''))" \
    2>/dev/null || true)
if [ -z "$LATEST_TAG" ]; then
    echo "❌ Could not fetch latest release tag from GitHub."
    echo "   Check your internet connection or try again in a minute."
    exit 1
fi
echo "📦 Latest release: $LATEST_TAG"

# ── 3. Show currently installed version (if any) ───────────────────
if [ -f "$APP_PATH/Contents/Info.plist" ]; then
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "unknown")
    echo "📍 Currently installed: v$CURRENT_VERSION"
    if [ "v$CURRENT_VERSION" = "$LATEST_TAG" ]; then
        echo "✅ You're already on the latest version. Nothing to do."
        echo "   (Re-run this script anyway if you want to force a clean reinstall.)"
        # Continue anyway — user might be debugging
    fi
else
    echo "📍 No existing X-Autopilot.app found at $APP_PATH (fresh install)"
fi

# ── 4. Download DMG ────────────────────────────────────────────────
DMG_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$DMG_NAME"
DMG_TMP="/tmp/xa_manual_update_$$.dmg"
echo "⬇  Downloading $DMG_NAME (~60 MB)..."
curl -fsSL --progress-bar "$DMG_URL" -o "$DMG_TMP"
echo "✅ Downloaded → $DMG_TMP"

# ── 4b. Clear stale update_status.json ──────────────────────────────
# v1.0.22+ — without this, the dashboard banner keeps showing the
# announcement of whatever version was being advertised when the
# previous background checker last ran (every 24h). The buyer just
# updated to the latest, so the announcement is stale. Deleting forces
# the agent's background checker to refetch the appcast on next
# launch and update_status.json reflects "you are on latest".
STATUS_FILE="$HOME/Library/Application Support/X-Autopilot/data/update_status.json"
if [ -f "$STATUS_FILE" ]; then
    rm -f "$STATUS_FILE"
    echo "🧹 Cleared stale update banner state"
fi

# ── 5. Quit any running X-Autopilot ────────────────────────────────
if pgrep -f "X-Autopilot.app" >/dev/null 2>&1; then
    echo "🛑 Quitting running X-Autopilot processes..."
    pgrep -f "X-Autopilot.app" | xargs -I{} kill -TERM {} 2>/dev/null || true
    sleep 3
    pgrep -f "X-Autopilot.app" | xargs -I{} kill -KILL {} 2>/dev/null || true
    sleep 1
fi

# ── 6. Mount the DMG ───────────────────────────────────────────────
MOUNT_POINT="/tmp/xa_manual_update_mount_$$"
echo "💿 Mounting DMG..."
hdiutil attach "$DMG_TMP" -nobrowse -quiet -mountpoint "$MOUNT_POINT"

# ── 7. Swap the bundle ─────────────────────────────────────────────
echo "🔄 Swapping bundle at $APP_PATH..."
BACKUP_PATH="/Applications/.X-Autopilot.app.bak.$$"
if [ -d "$APP_PATH" ]; then
    mv "$APP_PATH" "$BACKUP_PATH"
fi
ditto "$MOUNT_POINT/X-Autopilot.app" "$APP_PATH"

# Verify the swap landed
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Swap failed — restoring backup."
    [ -d "$BACKUP_PATH" ] && mv "$BACKUP_PATH" "$APP_PATH"
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    rm -f "$DMG_TMP"
    exit 1
fi
NEW_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
echo "✅ Installed v$NEW_VERSION"

# ── 8. Cleanup mount + backup + tmp ────────────────────────────────
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
rm -rf "$BACKUP_PATH"
rm -f "$DMG_TMP"

# ── 9. Refresh Launch Services ─────────────────────────────────────
echo "🔁 Refreshing macOS Launch Services cache..."
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREG" ]; then
    "$LSREG" -f -R "$APP_PATH" >/dev/null 2>&1 || true
fi

# ── 10. Launch the new app ─────────────────────────────────────────
echo "🚀 Launching X-Autopilot..."
open -n "$APP_PATH"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅ Update complete — now on v$NEW_VERSION"
printf "║                                                  ║\n"
echo "║   Your dashboard, settings, voice profile,       ║"
echo "║   and Twitter login are unchanged.               ║"
echo "║                                                  ║"
echo "║   Future updates will install via the in-app     ║"
echo "║   INSTALL NOW button (the bug that required      ║"
echo "║   this script is fixed in v1.0.20+).             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
