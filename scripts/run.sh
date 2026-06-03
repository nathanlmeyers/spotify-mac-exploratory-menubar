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
open ~/Library/Developer/Xcode/DerivedData/SpotifyMenuBar-*/Build/Products/Debug/SpotifyMenuBar.app

echo "Done. Look for the icon in your menu bar."
