#!/usr/bin/env /usr/bin/python3
"""
One-off recovery for tracks a stale build of SpotifyMenuBar auto-deleted from a playlist.

Reads the pre-incident playlist snapshot that the app cached in history.json, diffs it
against the playlist as it exists on Spotify right now, and re-adds what's missing.

READ-ONLY unless you pass --apply. Run it bare first and read the output.

  ./scripts/recover-playlist.py                    # report only
  ./scripts/recover-playlist.py --apply            # re-add the missing tracks

Auth reuses the app's own Keychain token (service com.nathanlmeyers.SpotifyMenuBar.tokens,
account spotify-oauth) and refreshes it via the PKCE public-client refresh grant, exactly
as Sources/SpotifyMenuBar/Auth/SpotifyAuth.swift does. macOS will ask you to allow the
keychain read once.

Deliberately pinned to /usr/bin/python3: the python.org build on this Mac ships no CA
bundle and fails TLS verification against api.spotify.com. The system one uses the
macOS trust store. Stdlib only, no pip installs.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PLAYLIST_ID = "7c62lW8PpGmK3FKWFQGNL1"        # "new spots 13"
PLAYLIST_LABEL = "new spots 13"
KEYCHAIN_SERVICE = "com.nathanlmeyers.SpotifyMenuBar.tokens"
KEYCHAIN_ACCOUNT = "spotify-oauth"
SNAPSHOT = ".context/incident-2026-07-29/history.json"
API = "https://api.spotify.com/v1"
TOKEN_URL = "https://accounts.spotify.com/api/token"


# ---------------------------------------------------------------- auth

def client_id():
    """The app's PKCE Client ID, from $SPOTIFY_CLIENT_ID or Secrets.xcconfig.

    Not hardcoded: Secrets.xcconfig is gitignored specifically so the ID stays out of the
    repo, and this script lives in the repo.
    """
    if env := os.environ.get("SPOTIFY_CLIENT_ID"):
        return env.strip()
    try:
        for line in open("Secrets.xcconfig"):
            if line.strip().startswith("SPOTIFY_CLIENT_ID"):
                return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    sys.exit("No Client ID. Set $SPOTIFY_CLIENT_ID, or run from a checkout that has "
             "Secrets.xcconfig (copy Secrets.example.xcconfig and fill it in).")


def keychain_token_bundle():
    """The app's stored TokenBundle JSON: {accessToken, refreshToken, expiresAt}."""
    try:
        raw = subprocess.run(
            ["security", "find-generic-password",
             "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as e:
        sys.exit(f"Could not read the Keychain item: {e.stderr.strip() or e}\n"
                 f"Log in via the app once, then re-run.")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        sys.exit("Keychain item is not the expected TokenBundle JSON.")


def access_token():
    """A usable access token — refreshed if the stored one is at/near expiry."""
    bundle = keychain_token_bundle()
    refresh = bundle.get("refreshToken") or ""
    if not refresh:
        # No refresh token stored; the access token is all we have. It may be expired.
        return bundle.get("accessToken", "")

    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": client_id(),
    }).encode()
    req = urllib.request.Request(
        TOKEN_URL, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)["access_token"]
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        print(f"  ! token refresh failed ({e.code}): {detail}", file=sys.stderr)
        print("  ! falling back to the stored access token", file=sys.stderr)
        return bundle.get("accessToken", "")


# ---------------------------------------------------------------- http

def request(token, method, url, payload=None):
    """One authorized call, retrying on 429 (which this account sees a lot of)."""
    for attempt in range(6):
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Authorization": f"Bearer {token}"}
        if data:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = int(e.headers.get("Retry-After", "2")) + 1
                print(f"  … rate limited, waiting {wait}s", file=sys.stderr)
                time.sleep(wait)
                continue
            raise RuntimeError(
                f"{method} {url} -> HTTP {e.code}: "
                f"{e.read().decode('utf-8', 'replace')[:300]}"
            ) from None
    raise RuntimeError(f"{method} {url}: still rate limited after 6 attempts")


def playlist_items_endpoint(token):
    """This account's playlist-items path — /items (newer) or /tracks (older)."""
    for path in ("items", "tracks"):
        url = f"{API}/playlists/{PLAYLIST_ID}/{path}?limit=1"
        try:
            request(token, "GET", url)
            return path
        except RuntimeError as e:
            if "HTTP 404" in str(e):
                continue
            raise
    raise RuntimeError("Neither /items nor /tracks worked for this playlist.")


def live_playlist_uris(token, path):
    """Every track URI currently in the playlist, following pagination."""
    uris, url = [], f"{API}/playlists/{PLAYLIST_ID}/{path}?limit=100"
    while url:
        page = request(token, "GET", url)
        for entry in page.get("items", []):
            inner = entry.get("item") or entry.get("track") or {}
            uri = inner.get("uri")
            if uri:
                uris.append(uri)
        url = page.get("next")
    return uris


def track_names(token, uris):
    """{uri: 'Artist — Title'}, best effort. Names are for your review only, so a
    lookup failure degrades to a clickable link rather than aborting the recovery.

    This app's registration is refused (403) on the batch /tracks?ids= endpoint but
    allowed on single /tracks/{id}, so fetch one at a time and fall back quietly."""
    names = {}
    for uri in uris:
        try:
            t = request(token, "GET", f"{API}/tracks/{uri.split(':')[-1]}")
            artists = ", ".join(a["name"] for a in t.get("artists", []))
            names[uri] = f"{artists} — {t['name']}"
        except RuntimeError as e:
            print(f"  ! name lookup failed for {uri}: {e}", file=sys.stderr)
    return names


def link(uri):
    return f"https://open.spotify.com/track/{uri.split(':')[-1]}"


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true",
                    help="actually re-add the missing tracks (default: report only)")
    ap.add_argument("--snapshot", default=SNAPSHOT,
                    help=f"path to the backed-up history.json (default: {SNAPSHOT})")
    args = ap.parse_args()

    try:
        history = json.load(open(args.snapshot))
    except FileNotFoundError:
        sys.exit(f"No snapshot at {args.snapshot} — see Phase 0 of the plan.")

    before = set(history["targetMembership"][PLAYLIST_ID])
    auto_judged = set(history["seenBySource"].get(PLAYLIST_ID, []))
    print(f"Snapshot: {len(before)} tracks were in “{PLAYLIST_LABEL}” before the incident")
    print(f"Auto-judged by the stale build (deletion candidates): {len(auto_judged)}")

    token = access_token()
    path = playlist_items_endpoint(token)
    live_list = live_playlist_uris(token, path)
    live = set(live_list)
    print(f"Live now: {len(live_list)} tracks ({len(live)} unique)\n")

    missing = before - live
    if not missing:
        print("Nothing missing — the playlist already matches the snapshot. No action needed.")
        return

    # Ordered by the snapshot's own ordering where we can, for a stable, reviewable list.
    snapshot_order = [u for u in history["targetMembership"][PLAYLIST_ID] if u in missing]
    overlap = missing & auto_judged
    print(f"MISSING: {len(missing)} tracks")
    print(f"  of which {len(overlap)} are in the auto-judged set "
          f"(high confidence: deleted by the bug)")
    print(f"  and {len(missing - auto_judged)} are not "
          f"(may predate the incident or have been removed by you)\n")

    names = track_names(token, snapshot_order)
    for i, uri in enumerate(snapshot_order, 1):
        mark = "*" if uri in overlap else " "
        print(f"{i:3d}. {mark} {names.get(uri, '(name unavailable)'):<52} {link(uri)}")
    print("\n  * = confirmed in the auto-judged set")

    print("\nCaveats:")
    print("  - Original playlist order is not recoverable; re-added tracks land at the end.")
    print("  - Tracks you added after the snapshot are still live and won't appear above.")
    print("  - Spotify's account 'Recover playlists' page only restores deleted playlists,")
    print("    not removed tracks, so this snapshot is the only source.")

    if not args.apply:
        print(f"\nRead-only run. Re-run with --apply to re-add these "
              f"{len(snapshot_order)} tracks.")
        return

    print(f"\nRe-adding {len(snapshot_order)} tracks to “{PLAYLIST_LABEL}”…")
    for i in range(0, len(snapshot_order), 100):
        batch = snapshot_order[i:i + 100]
        request(token, "POST", f"{API}/playlists/{PLAYLIST_ID}/{path}", {"uris": batch})
        print(f"  added {len(batch)} (through #{i + len(batch)})")
    print("Done. Re-run without --apply to verify MISSING is empty.")


if __name__ == "__main__":
    main()
