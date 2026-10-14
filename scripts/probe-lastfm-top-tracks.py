#!/usr/bin/env /usr/bin/python3
"""
Read-only probe for the Top Tracks (last.fm → Spotify) sync.

The feature turns last.fm "artist + title" rows into Spotify track ids by search, then scores
the ≤10 hits with the rules in `TopTracksLogic.swift`. This script runs the same rules against
the live API so the thresholds are chosen from data, not guesses. It never writes anything.

Two ways to get ground truth:

  # Real last.fm rows (needs a free key: https://www.last.fm/api/account/create)
  ./scripts/probe-lastfm-top-tracks.py --user <lastfm-user> --api-key <key> --period all

  # No last.fm key yet? Use one of your own playlists as the answer key: every row has an
  # artist, a title AND the true Spotify id, so the matcher can be graded exactly.
  ./scripts/probe-lastfm-top-tracks.py --self-test-playlist auto

Other checks:
  --check-filters       do `track:` / `artist:` tolerate ':' and '"'? is limit really 10?
                        is market=from_token accepted?
  --describe <id>       how Spotify entity-encodes a playlist description (the marker check)

Auth reuses the app's own Keychain token, exactly as scripts/probe-new-releases.py does.
Pinned to /usr/bin/python3 for the macOS trust store; stdlib only.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

KEYCHAIN_SERVICE = "com.nathanlmeyers.SpotifyMenuBar.tokens"
KEYCHAIN_ACCOUNT = "spotify-oauth"
API = "https://api.spotify.com/v1"
TOKEN_URL = "https://accounts.spotify.com/api/token"
LASTFM = "https://ws.audioscrobbler.com/2.0/"

ACCEPT = 0.85
ARTIST_FLOOR = 0.7
PACE = 0.5


# ---------------------------------------------------------------- auth (shared with the other probes)

def xcconfig_value(key):
    try:
        for line in open("Secrets.xcconfig"):
            if line.strip().startswith(key):
                return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    return None


def client_id():
    if env := os.environ.get("SPOTIFY_CLIENT_ID"):
        return env.strip()
    if v := xcconfig_value("SPOTIFY_CLIENT_ID"):
        return v
    sys.exit("No Client ID. Set $SPOTIFY_CLIENT_ID or run from a checkout with Secrets.xcconfig.")


def lastfm_key(arg):
    if arg:
        return arg
    if env := os.environ.get("LASTFM_API_KEY"):
        return env.strip()
    v = xcconfig_value("LASTFM_API_KEY")
    if v and v != "your_lastfm_api_key_here":
        return v
    return None


def keychain_token_bundle():
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
            capture_output=True, text=True, check=True).stdout.strip()
    except subprocess.CalledProcessError as e:
        sys.exit(f"Could not read the Keychain item: {e.stderr.strip() or e}\nLog in via the app once, then re-run.")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        sys.exit("Keychain item is not the expected TokenBundle JSON.")


def access_token():
    bundle = keychain_token_bundle()
    refresh = bundle.get("refreshToken") or ""
    if not refresh:
        return bundle.get("accessToken", "")
    body = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": refresh,
                                   "client_id": client_id()}).encode()
    req = urllib.request.Request(TOKEN_URL, data=body,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)["access_token"]
    except urllib.error.HTTPError as e:
        print(f"  ! token refresh failed ({e.code}): {e.read().decode('utf-8', 'replace')[:200]}", file=sys.stderr)
        return bundle.get("accessToken", "")


class ApiError(RuntimeError):
    def __init__(self, code, body):
        super().__init__(f"HTTP {code}: {body[:200]}")
        self.code = code
        self.body = body


THROTTLES = []


def get(token, url, *, retries=5):
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
                THROTTLES.append(wait)
                print(f"    … rate limited, waiting {wait}s", file=sys.stderr)
                time.sleep(wait)
                continue
            raise ApiError(e.code, body) from None
    raise ApiError(429, "still rate limited after retries")


# ---------------------------------------------------------------- the matcher, ported from TopTracksLogic.swift

def fold(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = re.sub("[’‘`´]", "'", s)
    s = re.sub("[“”]", '"', s)
    s = re.sub("[–—‐]", "-", s)
    return s


def words(s):
    return " ".join(t for t in re.split(r"[^a-z0-9]+", s.replace("'", "").replace("&", " and ")) if t)


BRACKETED_CREDIT = r"[\(\[]\s*(feat|ft|featuring|with)\b[^\)\]]*[\)\]]?"
TRAILING_CREDIT = r"\s+(feat|ft|featuring)\.?\s+.*$"
SAFE = (r"(\d{4}\s+)?(digital(ly)?\s+)?remaster(ed)?(\s+\d{4})?(\s+version)?"
        r"|radio\s+edit|single\s+version|album\s+version|(mono|stereo)(\s+(version|mix))?"
        r"|bonus\s+track|explicit(\s+version)?|deluxe(\s+(edition|version))?|original\s+mix"
        r"|official\s+(music\s+)?(video|audio|lyric\s+video|visuali[sz]er)"
        r"|from\s+[\"'].*[\"']|from\s+the\s+.*")
BRACKETED_SAFE = r"\s*[\(\[]\s*(" + SAFE + r")\s*[\)\]]"
DASHED_SAFE = r"\s+-\s+(" + SAFE + r")\s*$"
VARIANT = (r"\b(live|unplugged|remix(es|ed)?|rmx|acoustic|instrumental|demo|karaoke|cover|tribute"
           r"|sped up|slowed|reverb|nightcore|8 bit|lullaby|orchestral|piano version)\b")


def strip_credits(s):
    s = re.sub(BRACKETED_CREDIT, "", s, flags=re.I)
    return re.sub(TRAILING_CREDIT, "", s, flags=re.I)


def strip_safe(s):
    for _ in range(3):
        before = s
        s = re.sub(BRACKETED_SAFE, "", s, flags=re.I)
        s = re.sub(DASHED_SAFE, "", s, flags=re.I)
        if s == before:
            break
    return s


def normalized_title(s):
    return words(strip_safe(strip_credits(fold(s))))


def loose_title(s):
    t = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]?", "", fold(s))
    t = t.split(" - ", 1)[0]
    return words(t)


def normalized_artist(s):
    return words(fold(s))


def artist_candidates(s):
    full = normalized_artist(s)
    out = [full] if full else []
    primary = normalized_artist(re.sub(r"\s+(feat|ft|featuring|with)\.?\s+.*$", "", fold(s), flags=re.I))
    if primary and primary != full:
        out.append(primary)
    return out


def filter_value(s):
    return " ".join(re.sub(r'[:"]', " ", s).split())


def search_queries(name, artist):
    cands = artist_candidates(artist)
    primary = cands[-1] if cands else normalized_artist(artist)
    filtered = filter_value(strip_safe(strip_credits(fold(name))))
    out = []
    if filtered and primary:
        out.append(f"track:{filtered} artist:{primary}"[:200])
    plain = f"{loose_title(name)} {primary}"[:200]
    if plain.strip() and plain not in out:
        out.append(plain)
    return out


def variant_markers(norm):
    return {m.group(1) for m in re.finditer(VARIANT, norm)}


def token_similarity(a, b):
    ta, tb = set(a.split()), set(b.split())
    if not ta or not tb:
        return 0.0
    return 2 * len(ta & tb) / (len(ta) + len(tb))


def title_score(hit, scrobble):
    h, s = normalized_title(hit), normalized_title(scrobble)
    if h == s:
        return 1.0
    if loose_title(hit) == loose_title(scrobble):
        return 0.9
    return token_similarity(h, s)


def drop_the(s):
    return s[4:] if s.startswith("the ") else s


def artist_score(hit_artists, scrobble_artist):
    cands = artist_candidates(scrobble_artist)
    hits = [normalized_artist(a) for a in hit_artists if normalized_artist(a)]
    if not cands or not hits:
        return 0.0
    joined = [" ".join(hits), " and ".join(hits)]
    for c in cands:
        for h in hits:
            if h == c or drop_the(h) == drop_the(c):
                return 1.0
        if c in joined:
            return 1.0
    for c in cands:
        for h in hits:
            short, long_ = (h, c) if len(h) < len(c) else (c, h)
            if long_.startswith(short + " "):
                return 0.7
    return 0.0


def album_bonus(t):
    return {"album": 0.03, "single": 0.02}.get((t or "").lower(), 0.0)


def score(hit, index, name, artist):
    title = title_score(hit["name"], name)
    art = artist_score([a["name"] for a in hit["artists"]], artist)
    hm, sm = variant_markers(normalized_title(hit["name"])), variant_markers(normalized_title(name))
    penalty = (0.3 if hm - sm else 0.0) + (0.2 if sm - hm else 0.0)
    total = 0.6 * title + 0.4 * art - penalty + album_bonus(hit["album"]["album_type"]) - 0.01 * index
    return total, art


def best_match(hits, name, artist):
    scored = []
    for i, h in enumerate(hits):
        total, art = score(h, i, name, artist)
        scored.append((total, art, h))
    accepted = [x for x in scored if x[1] >= ARTIST_FLOOR and x[0] >= ACCEPT]
    best = max(accepted, key=lambda x: x[0]) if accepted else None
    return best, scored


# ---------------------------------------------------------------- data sources

def lastfm_rows(user, key, period, limit):
    q = urllib.parse.urlencode({"method": "user.gettoptracks", "user": user, "period": period,
                                "limit": limit, "api_key": key, "format": "json"})
    req = urllib.request.Request(f"{LASTFM}?{q}", headers={"User-Agent": "SpotifyMenuBar-probe/1"})
    try:
        with urllib.request.urlopen(req) as r:
            payload = json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        sys.exit(f"last.fm HTTP {e.code}: {body[:300]}")
    if "error" in payload:
        sys.exit(f"last.fm error {payload['error']}: {payload.get('message')}")
    rows = payload["toptracks"]["track"]
    print(f"   last.fm {period}: {len(rows)} rows (asked {limit}); "
          f"mbid filled on {sum(1 for r in rows if r.get('mbid'))}; "
          f"@attr.rank present on {sum(1 for r in rows if '@attr' in r)}; "
          f"playcount is str: {isinstance(rows[0].get('playcount'), str) if rows else '?'}")
    return [{"name": r["name"], "artist": r["artist"]["name"], "truth": None} for r in rows]


def playlist_rows(token, playlist_id, limit):
    candidates = [playlist_id]
    if playlist_id == "auto":
        # The 2026 playlist object no longer carries a track count, so try owned playlists in
        # order until one has enough rows to grade against.
        me = get(token, f"{API}/me")["id"]
        page = get(token, f"{API}/me/playlists?limit=50")
        candidates = [p["id"] for p in page["items"] if p["owner"]["id"] == me]
        names = {p["id"]: p["name"] for p in page["items"]}
    for pid in candidates:
        rows = read_playlist_rows(token, pid, limit)
        if len(rows) >= 20 or playlist_id != "auto":
            if playlist_id == "auto":
                print(f"   self-test playlist: \"{names.get(pid, pid)}\" ({len(rows)} rows used)")
            return rows[:limit]
        time.sleep(PACE)
    sys.exit("No owned playlist with 20+ tracks to self-test against; pass an id.")


def read_playlist_rows(token, playlist_id, limit):
    rows, url = [], f"{API}/playlists/{playlist_id}/items?limit=100"
    while url and len(rows) < limit:
        page = get(token, url)
        for entry in page["items"]:
            t = entry.get("item") or entry.get("track")
            if not t or not t.get("id"):
                continue
            artists = [a["name"] for a in t["artists"]]
            # last.fm would record "A feat. B"-style strings; use the primary artist like a
            # scrobbler usually does, but keep the full list for the grader.
            rows.append({"name": t["name"], "artist": artists[0], "truth": t["id"],
                         "truth_artists": artists})
        url = page.get("next")
    return rows


# ---------------------------------------------------------------- the experiment

def search(token, q, market):
    params = {"q": q, "type": "track", "limit": 10}
    if market:
        params["market"] = "from_token"
    data = get(token, f"{API}/search?{urllib.parse.urlencode(params)}")
    return data.get("tracks", {}).get("items", [])


def run(token, rows, market, dump):
    stats = {"rows": len(rows), "q1_hit": 0, "q2_hit": 0, "miss": 0, "searches": 0,
             "correct": 0, "wrong": 0, "unknown": 0, "artist_floor_rejections": 0,
             "near_ties": 0, "spotify_top1_agrees": 0}
    accepted_scores, rejected_best = [], []
    misses, wrongs = [], []
    timings = []
    details = []
    for i, row in enumerate(rows):
        name, artist = row["name"], row["artist"]
        queries = search_queries(name, artist)
        found, used, all_scored = None, None, []
        for qi, q in enumerate(queries):
            t0 = time.time()
            hits = search(token, q, market)
            timings.append(time.time() - t0)
            stats["searches"] += 1
            best, scored = best_match(hits, name, artist)
            all_scored = scored
            if best:
                found, used = best, qi
                break
            time.sleep(PACE)
        if all_scored:
            ordered = sorted(all_scored, key=lambda x: -x[0])
            if len(ordered) > 1 and ordered[0][0] - ordered[1][0] < 0.05 and found:
                stats["near_ties"] += 1
            if any(x[0] >= ACCEPT and x[1] < ARTIST_FLOOR for x in all_scored) and not found:
                stats["artist_floor_rejections"] += 1
            if found and all_scored[0][2]["id"] == found[2]["id"]:
                stats["spotify_top1_agrees"] += 1
        if found:
            stats["q1_hit" if used == 0 else "q2_hit"] += 1
            accepted_scores.append(found[0])
            hit = found[2]
            if row["truth"]:
                same_id = hit["id"] == row["truth"]
                same_song = (normalized_title(hit["name"]) == normalized_title(name)
                             and artist_score([a["name"] for a in hit["artists"]], artist) >= ARTIST_FLOOR)
                if same_id or same_song:
                    stats["correct"] += 1
                else:
                    stats["wrong"] += 1
                    wrongs.append((name, artist, hit["name"], ", ".join(a["name"] for a in hit["artists"]), found[0]))
            else:
                stats["unknown"] += 1
            details.append({"name": name, "artist": artist, "picked": hit["name"],
                            "picked_artists": [a["name"] for a in hit["artists"]], "score": round(found[0], 3),
                            "query": used, "truth": row["truth"], "picked_id": hit["id"]})
        else:
            stats["miss"] += 1
            if all_scored:
                rejected_best.append(max(x[0] for x in all_scored))
            misses.append((name, artist, [(round(x[0], 2), x[2]["name"], x[2]["artists"][0]["name"]) for x in
                           sorted(all_scored, key=lambda x: -x[0])[:2]]))
            details.append({"name": name, "artist": artist, "picked": None, "truth": row["truth"]})
        print(f"   [{i + 1:3}/{len(rows)}] {'Q' + str(used + 1) if found else '---'} "
              f"{name[:40]!r:44} {artist[:24]!r:28} "
              f"{('→ ' + found[2]['name'][:40] + '  (' + format(found[0], '.2f') + ')') if found else 'MISS'}")
        time.sleep(PACE)

    print()
    print("=" * 72)
    print("RESULTS")
    print("=" * 72)
    n = stats["rows"] or 1
    print(f"   rows {stats['rows']}; matched via Q1 {stats['q1_hit']} ({100 * stats['q1_hit'] / n:.0f}%), "
          f"via Q2 {stats['q2_hit']}, missed {stats['miss']} ({100 * stats['miss'] / n:.0f}%)")
    print(f"   searches {stats['searches']} ({stats['searches'] / n:.2f} per row); "
          f"mean request {1000 * sum(timings) / max(len(timings), 1):.0f} ms; 429s: {len(THROTTLES)}")
    if stats["correct"] + stats["wrong"]:
        print(f"   graded against the answer key: correct {stats['correct']}, WRONG {stats['wrong']}")
    print(f"   Spotify's own #1 agreed with the scorer on {stats['spotify_top1_agrees']} of the matched rows")
    print(f"   near-ties (runner-up within 0.05): {stats['near_ties']}; "
          f"rejected only by the artist floor: {stats['artist_floor_rejections']}")
    if accepted_scores:
        accepted_scores.sort()
        print(f"   accepted score: min {accepted_scores[0]:.2f}, median {accepted_scores[len(accepted_scores) // 2]:.2f}, "
              f"max {accepted_scores[-1]:.2f}")
    if rejected_best:
        rejected_best.sort()
        print(f"   best rejected score: max {rejected_best[-1]:.2f}, median {rejected_best[len(rejected_best) // 2]:.2f} "
              f"(how close the threshold is to letting misses through)")
    if wrongs:
        print("\n   WRONG matches (the failure that matters):")
        for name, artist, pn, pa, sc in wrongs:
            print(f"     {name!r} — {artist!r}  →  {pn!r} — {pa!r}  ({sc:.2f})")
    if misses:
        print("\n   misses, with the best two candidates:")
        for name, artist, cands in misses:
            print(f"     {name!r} — {artist!r}")
            for sc, cn, ca in cands:
                print(f"         {sc:.2f}  {cn!r} — {ca!r}")
    if dump:
        with open(dump, "w") as f:
            json.dump({"stats": stats, "rows": details}, f, indent=1)
        print(f"\n   wrote {dump}")


def check_filters(token):
    print("=" * 72)
    print("FILTER / LIMIT / MARKET CHECKS")
    print("=" * 72)
    for q in ['track:Yes: No artist:Test', 'track:"Hello" artist:Adele', "track:Hello artist:Adele"]:
        try:
            hits = search(token, q, False)
            print(f"   {q!r:50} → {len(hits)} hits; first: "
                  f"{(hits[0]['name'] + ' — ' + hits[0]['artists'][0]['name']) if hits else '-'}")
        except ApiError as e:
            print(f"   {q!r:50} → FAILED {e}")
        time.sleep(PACE)
    try:
        data = get(token, f"{API}/search?{urllib.parse.urlencode({'q': 'hello', 'type': 'track', 'limit': 50})}")
        print(f"   limit=50 actually returned {len(data.get('tracks', {}).get('items', []))}")
    except ApiError as e:
        print(f"   limit=50 is REJECTED outright, not capped: {e}  (so the app must never send >10)")
    time.sleep(PACE)
    try:
        hits = search(token, "track:Hello artist:Adele", True)
        print(f"   market=from_token accepted: {len(hits)} hits")
    except ApiError as e:
        print(f"   market=from_token REJECTED: {e}")


def describe(token, playlist_id):
    data = get(token, f"{API}/playlists/{playlist_id}?fields=name,description,owner(id)")
    print(json.dumps(data, indent=2, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--user", help="last.fm username")
    ap.add_argument("--api-key", help="last.fm API key (or $LASTFM_API_KEY / Secrets.xcconfig)")
    ap.add_argument("--period", default="1month", help="overall | 6month | 1month | all")
    ap.add_argument("--limit", type=int, default=50)
    ap.add_argument("--self-test-playlist", metavar="ID", help="grade the matcher against a playlist ('auto' picks one)")
    ap.add_argument("--market", action="store_true", help="add market=from_token to searches")
    ap.add_argument("--check-filters", action="store_true")
    ap.add_argument("--describe", metavar="PLAYLIST_ID")
    ap.add_argument("--dump", metavar="FILE", help="write per-row results as JSON")
    args = ap.parse_args()

    token = access_token()
    if args.check_filters:
        check_filters(token)
    if args.describe:
        describe(token, args.describe)
    if args.self_test_playlist:
        rows = playlist_rows(token, args.self_test_playlist, args.limit)
        print(f"   {len(rows)} answer-key rows")
        run(token, rows, args.market, args.dump)
    if args.user:
        key = lastfm_key(args.api_key)
        if not key:
            sys.exit("No last.fm API key: pass --api-key, set $LASTFM_API_KEY, or fill LASTFM_API_KEY in Secrets.xcconfig.")
        periods = ["overall", "6month", "1month"] if args.period == "all" else [args.period]
        seen_keys = {}
        for p in periods:
            rows = lastfm_rows(args.user, key, p, args.limit)
            keys = {normalized_artist(r["artist"]) + "|" + normalized_title(r["name"]) for r in rows}
            overlap = len(keys & set().union(*seen_keys.values())) if seen_keys else 0
            seen_keys[p] = keys
            print(f"   {p}: {overlap} of {len(keys)} rows already seen in an earlier period (cache hits on a real run)")
            run(token, rows, args.market, args.dump and f"{p}-{args.dump}")
    if not (args.check_filters or args.describe or args.self_test_playlist or args.user):
        ap.print_help()


if __name__ == "__main__":
    main()
