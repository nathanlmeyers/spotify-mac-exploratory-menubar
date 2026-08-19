#!/usr/bin/env /usr/bin/python3
"""
Read-only probe for the "Artists to Follow" suggestion list.

February 2026 removed the endpoints this feature would normally be built on —
`GET /artists/{id}/top-tracks` is gone and `popularity` was stripped from both artist
and track objects — so the design leans on two things the docs do not actually promise:
that `/me/top/*` still carries artist images, and that Spotify's *desktop app* will
accept an artist URI in `play track` (which is how the play button avoids needing a
"most popular song" endpoint at all).

This script answers those before any app code is written.

  ./scripts/probe-artist-suggestions.py
  ./scripts/probe-artist-suggestions.py --play-test      # interrupts playback, restores it
  ./scripts/probe-artist-suggestions.py --follow-test ID # follows, then unfollows again

Questions:
  1. Are GET /me/top/artists and /me/top/tracks reachable, and do the artist objects
     still carry images[]? (needs `user-top-read`, which current tokens do NOT carry —
     a 403 here is the expected "log out and back in" state, not a broken endpoint.)
  2. Do top *tracks* expose artists[] with usable ids, and are those objects simplified
     (no images)? That difference decides whether GET /artists/{id} hydration is needed.
  3. Does GET /artists/{id} still return images[]? It's one request per artist since the
     batch endpoint was removed, so it's the cost driver.
  4. Does GET /me/library/contains work for artist URIs (the post-Feb-2026 replacement
     for /me/following/contains)?
  5. DECISIVE: does `tell application "Spotify" to play track "spotify:artist:X"` start
     playback? If it doesn't, the play button has to fall back to a concrete track URI.
  6. Optional: does PUT /me/library actually follow an artist? (needs `user-follow-modify`)

Writes are opt-in only: without --play-test nothing touches playback, and without
--follow-test nothing touches the account.

Auth reuses the app's own Keychain token exactly as scripts/probe-new-releases.py does.
Pinned to /usr/bin/python3 for the macOS trust store; stdlib only.
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

KEYCHAIN_SERVICE = "com.nathanlmeyers.SpotifyMenuBar.tokens"
KEYCHAIN_ACCOUNT = "spotify-oauth"
API = "https://api.spotify.com/v1"
TOKEN_URL = "https://accounts.spotify.com/api/token"

TIME_RANGES = ("short_term", "medium_term", "long_term")
TOP_LIMIT = 50          # documented maximum for /me/top/{type}
HYDRATION_SAMPLE = 3    # how many artists to spot-check GET /artists/{id} against


# ---------------------------------------------------------------- auth

def client_id():
    """The app's PKCE Client ID, from $SPOTIFY_CLIENT_ID or Secrets.xcconfig."""
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
    """A usable access token, plus the scopes the *stored* bundle recorded.

    The scope list is what lets the report tell "you never had this scope" apart from
    "the endpoint is gone" — the two produce an identical 403.
    """
    bundle = keychain_token_bundle()
    granted = bundle.get("grantedScopes", "")
    refresh = bundle.get("refreshToken") or ""
    if not refresh:
        return bundle.get("accessToken", ""), granted

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
            payload = json.load(r)
            return payload["access_token"], payload.get("scope", granted)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        print(f"  ! token refresh failed ({e.code}): {detail}", file=sys.stderr)
        print("  ! falling back to the stored access token", file=sys.stderr)
        return bundle.get("accessToken", ""), granted


# ---------------------------------------------------------------- http

class ApiError(RuntimeError):
    def __init__(self, code, body):
        super().__init__(f"HTTP {code}: {body[:200]}")
        self.code = code
        self.body = body


def request(token, url, *, method="GET", payload=None, retries=5):
    """One authorized request, honoring Retry-After on 429."""
    data = json.dumps(payload).encode() if payload is not None else None
    for _ in range(retries):
        headers = {"Authorization": f"Bearer {token}"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            if e.code == 429:
                wait = int(e.headers.get("Retry-After", "2")) + 1
                print(f"    … rate limited, waiting {wait}s", file=sys.stderr)
                time.sleep(wait)
                continue
            raise ApiError(e.code, body) from None
    raise ApiError(429, "still rate limited after retries")


def get(token, url, **kw):
    return request(token, url, **kw)


def scope_note(granted, scope):
    has = scope in granted.split()
    return f"stored token grants {scope}: {has}", has


# ---------------------------------------------------------------- probes

def probe_top_artists(token, granted):
    """Q1 — top artists, and whether they still carry images."""
    print("=" * 72)
    print("1. GET /me/top/artists  (scope: user-top-read)")
    print("=" * 72)
    note, has_scope = scope_note(granted, "user-top-read")
    print(f"   {note}")

    seeds = {}          # id -> {name, image, genres, hits:[(range, rank)]}
    for rng in TIME_RANGES:
        q = urllib.parse.urlencode({"time_range": rng, "limit": TOP_LIMIT})
        try:
            page = get(token, f"{API}/me/top/artists?{q}")
        except ApiError as e:
            print(f"   {rng}: FAILED ({e})")
            if not has_scope:
                print("   -> Expected: the scope was never granted. Add user-top-read to")
                print("      SpotifyAuth.allScopes, log out and back in once, then re-run.")
            else:
                print("   -> UNEXPECTED: scope granted but the call failed. Do not build on")
                print("      this endpoint until you know why.")
            return None
        items = page.get("items", [])
        with_images = sum(1 for a in items if a.get("images"))
        with_genres = sum(1 for a in items if a.get("genres"))
        has_popularity = any("popularity" in a for a in items)
        print(f"   {rng:<12} {len(items):>3} artists of {page.get('total')}, "
              f"{with_images} with images[], {with_genres} with genres[]")
        if has_popularity:
            print("      note: popularity is present after all — re-check the Feb 2026 notes")
        for rank, a in enumerate(items):
            if not a.get("id"):
                continue
            entry = seeds.setdefault(a["id"], {
                "name": a.get("name", "(unknown)"),
                "image": (a.get("images") or [{}])[0].get("url"),
                "genres": a.get("genres") or [],
                "hits": [],
            })
            entry["hits"].append((rng, rank))

    print(f"   -> OK. {len(seeds)} distinct artists across {len(TIME_RANGES)} ranges "
          f"({len(TIME_RANGES)} requests)")
    missing_image = [v["name"] for v in seeds.values() if not v["image"]]
    if missing_image:
        print(f"      {len(missing_image)} without an image, e.g. {missing_image[:3]}")
    else:
        print("      every top artist carried an image — no hydration needed for these")
    return seeds


def probe_top_tracks(token, granted):
    """Q2 — top tracks, and the shape of their artist credits."""
    print()
    print("=" * 72)
    print("2. GET /me/top/tracks  (scope: user-top-read)")
    print("=" * 72)

    credits = {}        # artist id -> {name, tracks:set, primary:int, image_seen:bool}
    for rng in TIME_RANGES:
        q = urllib.parse.urlencode({"time_range": rng, "limit": TOP_LIMIT})
        try:
            page = get(token, f"{API}/me/top/tracks?{q}")
        except ApiError as e:
            print(f"   {rng}: FAILED ({e})")
            return None
        items = page.get("items", [])
        artist_objs = [a for t in items for a in (t.get("artists") or [])]
        with_images = sum(1 for a in artist_objs if a.get("images"))
        print(f"   {rng:<12} {len(items):>3} tracks, {len(artist_objs)} artist credits, "
              f"{with_images} of those carry images[]")
        for t in items:
            for i, a in enumerate(t.get("artists") or []):
                if not a.get("id"):
                    continue
                e = credits.setdefault(a["id"], {
                    "name": a.get("name", "(unknown)"),
                    "tracks": set(), "primary": 0, "image_seen": bool(a.get("images")),
                })
                e["tracks"].add(t.get("name") or t.get("id"))
                if i == 0:
                    e["primary"] += 1

    print(f"   -> OK. {len(credits)} distinct credited artists ({len(TIME_RANGES)} requests)")
    print("      => artist objects on tracks are SIMPLIFIED (no images) if the counts "
          "above are 0,")
    print("         which is what makes GET /artists/{id} hydration necessary.")
    return credits


def probe_artist_detail(token, artist_ids):
    """Q3 — the hydration call, one request per artist since the batch endpoint is gone."""
    print()
    print("=" * 72)
    print("3. GET /artists/{id}  (hydration for artists seen only via tracks)")
    print("=" * 72)
    if not artist_ids:
        print("   skipped — no candidate ids available")
        return
    for artist_id in artist_ids[:HYDRATION_SAMPLE]:
        try:
            a = get(token, f"{API}/artists/{artist_id}")
        except ApiError as e:
            print(f"   {artist_id}: FAILED ({e})")
            continue
        images = a.get("images") or []
        sizes = ", ".join(f"{i.get('width')}x{i.get('height')}" for i in images) or "none"
        print(f"   {a.get('name', artist_id):<28} images: {sizes}")
        print(f"   {'':<28} genres: {a.get('genres') or []}")
        for gone in ("popularity", "followers"):
            if gone in a:
                print(f"   {'':<28} note: {gone} still present — re-check the Feb 2026 notes")

    # The batch form is what we'd rather use; confirm it really is gone so the
    # one-request-per-artist cost is justified rather than assumed.
    try:
        get(token, f"{API}/artists?ids={','.join(artist_ids[:2])}")
        print("   -> batch GET /artists?ids= WORKS — hydration could be batched after all")
    except ApiError as e:
        print(f"   -> batch GET /artists?ids= is unavailable ({e.code}), as expected; "
              f"hydration costs 1 request per artist")


def probe_library_contains(token, granted, artist_ids):
    """Q4 — the post-Feb-2026 follow check."""
    print()
    print("=" * 72)
    print("4. GET /me/library/contains  (replaces /me/following/contains)")
    print("=" * 72)
    note, _ = scope_note(granted, "user-follow-read")
    print(f"   {note}")
    if not artist_ids:
        print("   skipped — no candidate ids available")
        return
    uris = ",".join(f"spotify:artist:{i}" for i in artist_ids[:3])
    try:
        body = get(token, f"{API}/me/library/contains?uris={urllib.parse.quote(uris)}")
        print(f"   -> OK. {body}")
    except ApiError as e:
        print(f"   -> FAILED ({e})")
        print("      Not fatal: GET /me/following?type=artist already gives the full")
        print("      followed set, which is what the exclusion filter actually uses.")


# ---------------------------------------------------------------- AppleScript

def osa(script):
    """Run one AppleScript line against Spotify, returning (ok, output)."""
    try:
        out = subprocess.run(["osascript", "-e", script],
                             capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        return False, "timed out"
    if out.returncode != 0:
        return False, (out.stderr or "").strip()
    return True, (out.stdout or "").strip()


def spotify_state():
    ok, state = osa('tell application "Spotify" to player state as string')
    if not ok:
        return None
    _, track = osa('tell application "Spotify" to id of current track as string')
    _, pos = osa('tell application "Spotify" to player position as string')
    return {"state": state, "track": track, "position": pos}


def probe_play_artist_uri(artist_id, artist_name):
    """Q5 — the question the play button rests on.

    `play track` is documented for tracks. Whether the desktop app accepts an *artist*
    URI decides whether the play button can exist without a "most popular song"
    endpoint, so it is tested against the real app rather than reasoned about.
    """
    print()
    print("=" * 72)
    print("5. AppleScript: play track \"spotify:artist:…\"  (the play button)")
    print("=" * 72)

    before = spotify_state()
    if before is None:
        print("   -> Spotify isn't running or isn't scriptable. Start it and re-run.")
        return
    print(f"   before: state={before['state']} track={before['track']} "
          f"position={before['position']}")

    ok, err = osa(f'tell application "Spotify" to play track "spotify:artist:{artist_id}"')
    if not ok:
        print(f"   -> REJECTED: {err}")
        print("   => The play button must play a concrete track URI instead. Use the")
        print("      highest-ranked top track crediting the artist (already fetched, so")
        print("      no extra request) and label the button with that track's name.")
        return

    time.sleep(2.5)     # give the client time to start the artist and report the track
    after = spotify_state() or {}
    print(f"   after:  state={after.get('state')} track={after.get('track')}")
    _, now_name = osa('tell application "Spotify" to name of current track as string')
    _, now_artist = osa('tell application "Spotify" to artist of current track as string')
    print(f"   now playing: {now_name!r} by {now_artist!r}")

    if after.get("state") == "playing" and after.get("track") != before["track"]:
        print(f"   -> ACCEPTED. Playing an artist URI works; Spotify picked a song for "
              f"{artist_name!r}.")
        print("   => The play button can send spotify:artist:<id> and let Spotify choose.")
    else:
        print("   -> Command succeeded but playback didn't visibly change. Treat as a")
        print("      failure and use the concrete-track fallback.")

    # Put the user's music back where it was.
    if before["track"].startswith("spotify:"):
        osa(f'tell application "Spotify" to play track "{before["track"]}"')
        if before["position"]:
            osa(f'tell application "Spotify" to set player position to {before["position"]}')
    if before["state"] != "playing":
        osa('tell application "Spotify" to pause')
    print("   restored previous playback state")


# ---------------------------------------------------------------- follow write

def probe_follow(token, granted, artist_id):
    """Q6 — the one write the feature performs. Opt-in, and it undoes itself."""
    print()
    print("=" * 72)
    print("6. PUT /me/library  (follow an artist; scope: user-follow-modify)")
    print("=" * 72)
    note, has_scope = scope_note(granted, "user-follow-modify")
    print(f"   {note}")
    uri = f"spotify:artist:{artist_id}"

    try:
        was = get(token, f"{API}/me/library/contains?uris={urllib.parse.quote(uri)}")
        print(f"   already following: {was}")
    except ApiError as e:
        was = None
        print(f"   could not read follow state ({e})")

    try:
        request(token, f"{API}/me/library", method="PUT", payload={"uris": [uri]})
        print("   -> PUT OK")
    except ApiError as e:
        print(f"   -> PUT FAILED ({e})")
        if not has_scope:
            print("      Expected: user-follow-modify was never granted.")
        return

    try:
        now = get(token, f"{API}/me/library/contains?uris={urllib.parse.quote(uri)}")
        print(f"   follow state after PUT: {now}")
    except ApiError as e:
        print(f"   could not confirm ({e})")

    # Restore: this is a research script, so it leaves the account as it found it.
    if was and was[0] is False:
        try:
            request(token, f"{API}/me/library?uris={urllib.parse.quote(uri)}",
                    method="DELETE")
            print("   -> unfollowed again, account restored")
        except ApiError as e:
            print(f"   ! could not unfollow again ({e}) — unfollow {artist_id} by hand")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--play-test", action="store_true",
                    help="test playing an artist URI (interrupts playback, then restores it)")
    ap.add_argument("--follow-test", metavar="ARTIST_ID",
                    help="follow this artist via PUT /me/library, then unfollow again")
    args = ap.parse_args()

    token, granted = access_token()
    if not token:
        sys.exit("No access token. Log in via the app once, then re-run.")
    print(f"scopes on the stored token: {granted or '(none recorded)'}\n")

    seeds = probe_top_artists(token, granted) or {}
    credits = probe_top_tracks(token, granted) or {}

    # Prefer ids seen only via tracks — those are exactly the ones needing hydration.
    track_only = [i for i in credits if i not in seeds]
    probe_artist_detail(token, track_only or list(credits) or list(seeds))
    probe_library_contains(token, granted, list(seeds) or list(credits))

    if args.play_test:
        pick = next(iter(seeds.items()), None) or next(iter(credits.items()), None)
        if pick:
            probe_play_artist_uri(pick[0], pick[1]["name"])
        else:
            print("\n5. skipped — no artist id available to test with")
    else:
        print("\n5. AppleScript play test skipped (pass --play-test; it briefly takes over "
              "playback)")

    if args.follow_test:
        probe_follow(token, granted, args.follow_test)
    else:
        print("6. follow write test skipped (pass --follow-test ARTIST_ID)")


if __name__ == "__main__":
    main()
