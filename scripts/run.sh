#!/usr/bin/env bash
#
# Spin up SpotifyMenuBar fast: scaffold secrets if needed, generate the Xcode
# project, build Debug, and launch the app. Run from anywhere — it resolves the
# repo root from its own location.
#
#   ./scripts/run.sh
#
set -euo pipefail

# Repo root = parent of this script's directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

# Scaffold the gitignored Secrets.xcconfig from the example template if missing.
if [ ! -f Secrets.xcconfig ]; then
  echo "Secrets.xcconfig not found — creating it from Secrets.example.xcconfig."
  cp Secrets.example.xcconfig Secrets.xcconfig
  echo "  → Add your Spotify Client ID to Secrets.xcconfig (see README 'One-time setup')."
fi

# Warn (but continue) if the Client ID is still the placeholder; the build will
# succeed, but login won't work until it's a real ID.
if grep -q "your_client_id_here" Secrets.xcconfig 2>/dev/null; then
  echo "warning: Secrets.xcconfig still has the placeholder Client ID — login will fail until you set it." >&2
fi

echo "Generating Xcode project…"
xcodegen generate

echo "Building (Debug)…"
xcodebuild -project SpotifyMenuBar.xcodeproj -scheme SpotifyMenuBar -configuration Debug build

echo "Launching…"
# Resolve THIS project's build product — a DerivedData glob would match (and launch)
# the builds of every other checkout/worktree of this app on the machine.
BUILT_DIR="$(xcodebuild -project SpotifyMenuBar.xcodeproj -scheme SpotifyMenuBar -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR =/ {print $2; exit}')"

# Quit any copy already running, from any checkout, before launching this one.
#
# The app enforces single-instance itself now (see InstanceGuard), but a build that predates
# that guard can't stand down on its own — and running this script from several workspaces is
# exactly what left four copies resident, four menu bar icons, and four of every Spotify poll.
# Matching on the full executable path can't catch Spotify.app itself, whose path has no
# "SpotifyMenuBar.app" component.
RUNNING='SpotifyMenuBar\.app/Contents/MacOS/SpotifyMenuBar'
if pgrep -f "$RUNNING" >/dev/null 2>&1; then
  # `pgrep -c` is a Linux extension; BSD/macOS pgrep has no count flag. The `|| true` keeps a
  # copy that exits between the test and the count from tripping `set -o pipefail`.
  echo "Quitting $( { pgrep -f "$RUNNING" || true; } | wc -l | tr -d ' ') running instance(s)…"
  pkill -f "$RUNNING" 2>/dev/null || true
  for _ in $(seq 1 15); do
    pgrep -f "$RUNNING" >/dev/null 2>&1 || break
    sleep 0.2
  done
  # A copy wedged on a stuck Apple event won't answer a polite quit, and that's precisely the
  # one that would otherwise stay in the menu bar forever.
  if pgrep -f "$RUNNING" >/dev/null 2>&1; then
    echo "  → one didn't quit on request; forcing."
    pkill -9 -f "$RUNNING" 2>/dev/null || true
  fi
fi

open "$BUILT_DIR/SpotifyMenuBar.app"

echo "Done. Look for the icon in your menu bar — there should be exactly one."
