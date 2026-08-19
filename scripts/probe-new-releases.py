#!/usr/bin/env /usr/bin/python3
"""
Read-only probe for the "New From Followed" release radar.

The design of the daily scan rests on assumptions the Spotify docs do not actually
guarantee. This script answers them against the live API before any app code is written.
It never writes anything — there is no --apply.

  ./scripts/probe-new-releases.py
  ./scripts/probe-new-releases.py --artists "Metro Boomin,Future"   # override the sample

Questions:
  1. Is GET /me/following?type=artist reachable? (needs the user-follow-read scope, which
     current tokens do NOT carry — a 403 here is the expected "log out and back in" state.)
  2. ORDERING: does GET /artists/{id}/albums come back newest-first? The docs specify no
     sort order and `limit` maxes at 10, so a page-1-only incremental scan is only safe if
     the order is descending. This is the question that decides the paging strategy.
  3. What page size does GET /albums/{id}/tracks actually return, and does the simplified
     track object still carry artists[]? The primary-artist filter depends on it.
  4. Roughly how fast can we call the API before the dev-mode quota pushes back?

Auth reuses the app's own Keychain token exactly as scripts/recover-playlist.py does.
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

# Used only when /me/following is unreachable. Deliberately prolific artists with deep
# `appears_on` catalogues — the hardest case for the ordering question.
FALLBACK_ARTISTS = ["Metro Boomin", "Future", "Ty Dolla $ign", "Mark Ronson", "Bon Iver"]

ALBUM_PAGE = 10        # documented maximum for GET /artists/{id}/albums
ORDER_PAGES = 3        # how deep to look when judging sort order


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
    """A usable access token, refreshed via the public-client refresh grant.

    Also returns the scopes the *stored* bundle recorded, so the report can tell
    "you never had this scope" apart from "the endpoint is gone".
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


def get(token, url, *, retries=5):
    """One authorized GET, honoring Retry-After on 429."""
    for _ in range(retries):
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
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


# ---------------------------------------------------------------- probes

def probe_following(token, granted):
    """Q1 — is the followed-artists endpoint reachable?"""
    print("=" * 72)
    print("1. GET /me/following?type=artist  (scope: user-follow-read)")
    print("=" * 72)
    has_scope = "user-follow-read" in granted.split()
    print(f"   stored token grants user-follow-read: {has_scope}")
    try:
        page = get(token, f"{API}/me/following?type=artist&limit=50")
    except ApiError as e:
        print(f"   -> FAILED ({e})")
        if not has_scope:
            print("   -> Expected: the scope was never granted. Add it to SpotifyAuth.scopes,")
            print("      then log out and back in once, and re-run this probe.")
        else:
            print("   -> UNEXPECTED: scope is granted but the call failed. The endpoint may")
            print("      have moved under /me/library. Investigate before building on it.")
        return None

    block = page.get("artists", {})
    items = block.get("items", [])
    total = block.get("total")
    print(f"   -> OK. returned {len(items)} of {total} followed artists")
    print(f"      cursor pagination present: {'cursors' in block}, next: {bool(block.get('next'))}")

    # Walk the rest so the cost model is based on the real number, not a guess.
    count, pages, url = len(items), 1, block.get("next")
    names = [a["name"] for a in items]
    ids = [a["id"] for a in items]
    while url:
        block = get(token, url).get("artists", {})
        batch = block.get("items", [])
        count += len(batch)
        names += [a["name"] for a in batch]
        ids += [a["id"] for a in batch]
        pages += 1
        url = block.get("next")
    print(f"   -> full walk: {count} artists over {pages} requests")
    print(f"      => an incremental scan costs ~{pages + count * 2} requests "
          f"({pages} follow pages + 2 album queries per artist)")
    return list(zip(ids, names))


def resolve_by_search(token, names):
    """Fallback artist list when /me/following is unreachable.

    Takes several hits and prefers an exact name match: search relevance got noticeably
    worse when `limit` was capped at 10, and limit=1 was returning the wrong artist
    outright (a query for "Metro Boomin" came back as Future).
    """
    out = []
    for name in names:
        q = urllib.parse.urlencode({"q": name, "type": "artist", "limit": 10})
        try:
            hits = get(token, f"{API}/search?{q}").get("artists", {}).get("items", [])
        except ApiError as e:
            print(f"   ! search for {name!r} failed ({e})", file=sys.stderr)
            continue
        exact = [h for h in hits if h.get("name", "").casefold() == name.casefold()]
        pick = (exact or hits or [None])[0]
        if pick:
            out.append((pick["id"], pick["name"]))
        else:
            print(f"   ! no artist found for {name!r}", file=sys.stderr)
    return out


# Each is probed on its own. The combined query `album,single` looked unordered, but the
# raw dates showed a descending run restarting partway through — the response is a
# concatenation of per-group blocks. Probing one group at a time tests that directly.
GROUPS = ("album", "single", "compilation", "appears_on")


def probe_ordering(token, artists):
    """Q2 — the question the whole incremental strategy rests on."""
    print()
    print("=" * 72)
    print("2. ORDERING of GET /artists/{id}/albums, one include_group at a time")
    print("=" * 72)
    verdicts = {}
    for group in GROUPS:
        print(f"\n   include_groups={group}")
        results = []
        for artist_id, name in artists:
            dates, total = [], None
            for page in range(ORDER_PAGES):
                q = urllib.parse.urlencode({
                    "include_groups": group,
                    "limit": ALBUM_PAGE,
                    "offset": page * ALBUM_PAGE,
                })
                try:
                    body = get(token, f"{API}/artists/{artist_id}/albums?{q}")
                except ApiError as e:
                    print(f"     {name}: FAILED ({e})")
                    break
                total = body.get("total", total)
                items = body.get("items", [])
                if not items:
                    break
                dates += [(i.get("release_date", "?"), i.get("release_date_precision", "?"))
                          for i in items]

            if not dates:
                print(f"     {name}: (none in this group)")
                continue

            plain = [d for d, _ in dates]
            descending = all(plain[i] >= plain[i + 1] for i in range(len(plain) - 1))
            results.append(descending)
            mark = "descending" if descending else "NOT DESCENDING"
            pages_to_crawl = "?" if total is None else -(-total // ALBUM_PAGE)
            print(f"     {name}: total={total} (full crawl = {pages_to_crawl} requests) -> {mark}")
            print(f"       {' '.join(plain[:12])}{' …' if len(plain) > 12 else ''}")
            precisions = sorted({p for _, p in dates})
            print(f"       precision values: {', '.join(precisions)}")
        verdicts[group] = bool(results) and all(results)

    print("\n   VERDICT (per group, queried alone)")
    for group, ok in verdicts.items():
        print(f"     {group:<12} {'newest-first' if ok else 'ARBITRARY ORDER'}")
    cheap = [g for g, ok in verdicts.items() if ok]
    costly = [g for g, ok in verdicts.items() if not ok]
    if cheap:
        print(f"     => stop-early paging is safe for: {', '.join(cheap)}")
    if costly:
        print(f"     => needs a full crawl, amortized across days: {', '.join(costly)}")
    return verdicts


def probe_album_tracks(token, artists):
    """Q3 — page size and whether artists[] survives on the simplified track object."""
    print()
    print("=" * 72)
    print("3. GET /albums/{id}/tracks  (no limit param sent — what is the default?)")
    print("=" * 72)
    for artist_id, name in artists[:2]:
        q = urllib.parse.urlencode({"include_groups": "album", "limit": 1})
        try:
            albums = get(token, f"{API}/artists/{artist_id}/albums?{q}").get("items", [])
        except ApiError as e:
            print(f"   {name}: could not list albums ({e})")
            continue
        if not albums:
            continue
        album = albums[0]
        try:
            page = get(token, f"{API}/albums/{album['id']}/tracks")
        except ApiError as e:
            print(f"   {name}: /albums/{album['id']}/tracks FAILED ({e})")
            continue
        items = page.get("items", [])
        print(f"   {name} — “{album.get('name')}” ({album.get('total_tracks')} tracks)")
        print(f"     default page size: limit={page.get('limit')}, "
              f"returned={len(items)}, next={bool(page.get('next'))}")
        if items:
            first = items[0]
            has_artists = "artists" in first and bool(first["artists"])
            print(f"     simplified track carries artists[]: {has_artists}")
            if has_artists:
                credited = ", ".join(a.get("name", "?") for a in first["artists"])
                print(f"     e.g. “{first.get('name')}” -> {credited}")
                print(f"     primary-artist filter is viable: "
                      f"{'yes' if first['artists'][0].get('id') else 'no (no id field)'}")
            print(f"     fields available: {', '.join(sorted(first.keys()))}")

        # The album object is what the date/compilation filters read — show what's left of it.
        print(f"     album object fields: {', '.join(sorted(album.keys()))}")
        print(f"       album_type={album.get('album_type')!r} "
              f"album_group={album.get('album_group', '(removed)')!r}")


def probe_pace(token, artists):
    """Q4 — how fast can we go before the dev-mode quota complains?"""
    print()
    print("=" * 72)
    print("4. PACING — 60 sequential requests, no delay")
    print("=" * 72)
    if not artists:
        print("   (no artists to probe with)")
        return
    artist_id = artists[0][0]
    started = time.monotonic()
    throttled_at = None
    for i in range(60):
        q = urllib.parse.urlencode({"include_groups": "album", "limit": ALBUM_PAGE,
                                    "offset": (i % 5) * ALBUM_PAGE})
        req = urllib.request.Request(f"{API}/artists/{artist_id}/albums?{q}",
                                     headers={"Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req) as r:
                r.read()
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            throttled_at = (i + 1, e.code, e.headers.get("Retry-After"), body[:200])
            break
    elapsed = time.monotonic() - started
    done = throttled_at[0] - 1 if throttled_at else 60
    rate = done / elapsed if elapsed else 0
    print(f"   completed {done} requests in {elapsed:.1f}s ({rate:.1f} req/s)")
    if throttled_at:
        n, code, retry_after, body = throttled_at
        print(f"   -> THROTTLED on request #{n}: HTTP {code}, Retry-After={retry_after}")
        print(f"      body: {body}")
        print(f"      => pace the scan well under {rate:.1f} req/s.")
    else:
        print(f"   -> no throttling at {rate:.1f} req/s over 60 requests.")
        print(f"      => 3 req/s is a safe default for the scanner's pacer.")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--artists", help="comma-separated artist names to sample instead of "
                                      "your followed artists")
    ap.add_argument("--sample", type=int, default=5,
                    help="how many followed artists to sample for the ordering probe")
    args = ap.parse_args()

    token, granted = access_token()
    print(f"granted scopes: {granted or '(none recorded)'}\n")

    followed = probe_following(token, granted)

    if args.artists:
        sample = resolve_by_search(token, [n.strip() for n in args.artists.split(",")])
    elif followed:
        # Spread the sample across the follow list rather than taking the first N, which
        # are all one alphabetical/recency cluster.
        step = max(1, len(followed) // args.sample)
        sample = followed[::step][:args.sample]
    else:
        print("\n   (falling back to a fixed sample so the rest of the probe can run)")
        sample = resolve_by_search(token, FALLBACK_ARTISTS)

    if not sample:
        sys.exit("\nNo artists to probe with — cannot answer the ordering question.")
    print(f"\nsampling: {', '.join(n for _, n in sample)}")

    probe_ordering(token, sample)
    probe_album_tracks(token, sample)
    probe_pace(token, sample)

    print("\nDone. Nothing was written.")


if __name__ == "__main__":
    main()
