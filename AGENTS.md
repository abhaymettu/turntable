# Turntable, for agents

Repo: https://github.com/abhaymettu/turntable

Turntable is an iOS app that plays Apple Music, plus a small stdlib-only Python server. You
(an agent with a shell) POST a "pick" to the server. The phone checks in every 15 seconds,
reads the current pick, and acts on it. You steer the human's music by writing to the
server. The phone is the only thing that touches Apple Music. You never touch Apple Music
directly and you have no Apple Music API credentials.

One server holds one human's pick and one human's devices. There is no account system and
no multi-tenancy. If you are steering more than one person, that is more than one server
process.

## If someone just handed you the setup prompt

They installed the app, tapped Copy, and pasted it to you. The whole job is: get the server
running, get it reachable, mint a pairing code, and reply with only the six characters. In
order:

1. Clone or open this repo.
2. Read the rest of this file.
3. Decide the address the phone should keep. If Tailscale is running on this machine, that
   is its `100.x` address; if it is not installed, install and start it and say, in one
   line, that they need to turn Tailscale on on their phone too. Without Tailscale the LAN
   address still works, but only while they are on that Wi-Fi.
4. Start the server with that address in `TURNTABLE_PUBLIC_URL` (see below). Leave it up.
5. Stay on the same Wi-Fi as the phone for the pairing step: the app finds the server over
   Bonjour and never asks anyone to type an address.
6. `python3 server.py --pair`, then reply with **only** the six character code. No address,
   no commentary. It lasts 15 minutes and works once.

## Start the server

```
cd server && ./run.sh
```

That runs `python3 server.py`. Python 3, stdlib only, nothing to `pip install`. It listens
on `0.0.0.0:8787` by default.

While it runs it also announces itself on the local network as `_turntable._tcp`, through
whichever of `dns-sd` (macOS) or `avahi-publish-service` (Linux) is present. That
announcement is how a freshly installed phone finds the server to redeem a pairing code
against; it is not how the phone remembers the server afterwards. If neither responder
exists the server runs exactly as before, and pairing then needs the address typed into the
app's Advanced screen.

Environment variables:

- `TURNTABLE_PORT` - listen port (default 8787)
- `TURNTABLE_LOG` - path to the append-only JSONL event log (default `server/turntable.jsonl`)
- `TURNTABLE_AUTH` - path to the auth file (default `server/auth.json`)
- `TURNTABLE_PUBLIC_URL` - the address to hand a freshly paired phone, when it differs from
  what the server sees (tunnels, reverse proxies)
- `TURNTABLE_APNS_KEY_PATH` - path to an APNs `.p8` key (default `server/apns_key.p8`);
  accepted but not used to send pushes yet

## Auth

Every endpoint except `GET /healthz` and `POST /pair` needs `Authorization: Bearer <token>`.
Without a valid token you get:

```
HTTP/1.0 401 Unauthorized
{"error": "unauthorized", "reason": "missing or unknown bearer token"}
```

On first start the server writes `server/auth.json` (mode 0600) with your token in
plaintext, plus hashed device tokens for paired phones. Read your token out of it:

```
TOKEN=$(python3 -c 'import json;print(json.load(open("server/auth.json"))["agent_token"])')
curl -H "Authorization: Bearer $TOKEN" http://localhost:8787/devices
```

Do not print or log `auth.json`'s contents anywhere the human did not ask for.

## Pair a phone

You cannot pair a phone yourself; you can only make a code and hand it over. Run:

```
python3 server.py --pair
```

This mints a six character code (alphabet `23456789ABCDEFGHJKMNPQRSTVWXYZ`, no ambiguous
characters), stores only its sha256 hash with a 15 minute expiry, and prints the code plus
a best-guess server address:

```
pairing code: DPGTX9
server address: http://192.168.1.192:8787
good for 15 minutes, one phone. Run this again for another code.
```

**Reply with only the code.** The printed address is for you, not for them: the app's first
run has no address field. It browses `_turntable._tcp`, finds this server, and POSTs the
code to it:

```
curl -s -X POST http://192.168.1.192:8787/pair \
  -H "Content-Type: application/json" \
  -d '{"code":"DPGTX9","device_id":"some-device-id"}'
```

It gets back `{"server_url": "...", "token": "..."}`. **`server_url` is the address the
phone keeps**, and it is `TURNTABLE_PUBLIC_URL` when you set one, or the host the phone
reached you on when you did not. Set `TURNTABLE_PUBLIC_URL` to the tailnet or tunnel
address before pairing and the phone keeps working after it leaves that Wi-Fi; leave it
unset and the phone keeps a LAN address that stops resolving the moment they go out.

A code works once. Redeeming an already-used or unknown code returns
`{"error": "bad code", "reason": "bad code"}` at HTTP 403. A code past its 15 minute window
returns `{"error": "expired", "reason": "expired"}`. Ten wrong guesses burn every code
currently pending, so do not brute force this.

If Bonjour cannot cross the network between you and the phone, the app's Advanced screen
takes an address directly; that is the fallback, not the path.

## Endpoint reference

Base examples below assume the server is local on port 8787 and `$TOKEN` is your agent
token from `auth.json`.

### `GET /healthz` - no auth

```
curl -s http://localhost:8787/healthz
{"ok": true, "ts": 1789365842.93}
```

### `POST /pair` - no auth

Covered above.

### `GET /now-playing` - the current pick

```
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8787/now-playing
{"action": "none"}
```

Once you have set a pick it looks like this instead:

```
{"action": "play", "source": "apple_music", "catalog_id": "1440806041",
 "title": "Bohemian Rhapsody", "artist": "Queen", "pick_id": 1, "set_at": 1789365865.69}
```

### `POST /now-playing` - set the pick

Body shape depends on `action`:

- `"play"` - needs `source: "apple_music"` and `catalog_id` (string). `title` and `artist`
  are optional and cosmetic (not looked up, just echoed back).
- `"pause"` - just `{"action": "pause"}`.
- `"none"` - just `{"action": "none"}`. Posting this pauses playback, the same as
  `"pause"`: it comes back with a `pick_id`, and the phone acts on anything that has one.
  The idle `{"action": "none"}` you read from `GET /now-playing` before any pick has been
  set is a different thing, and is ignored, because it has no `pick_id`.
- `"add_to_playlist"` - needs `playlist_name` (string). `catalog_id`, `title`, `artist` are
  optional.

The response echoes your pick back with a new integer `pick_id` and a `set_at` timestamp:

```
curl -s -X POST http://localhost:8787/now-playing \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"action":"play","source":"apple_music","catalog_id":"1440806041","title":"Bohemian Rhapsody","artist":"Queen"}'

{"action": "play", "source": "apple_music", "catalog_id": "1440806041",
 "title": "Bohemian Rhapsody", "artist": "Queen", "pick_id": 1, "set_at": 1789365865.69}
```

Bad input is a 400 with a plain-English `error`, for example:

```
{"error": "action must be 'play', 'none', 'pause', or 'add_to_playlist'"}
{"error": "catalog_id must be a non-empty string"}
```

### `POST /checkin` - what the phone sends

This is the phone's message, not yours. You do not normally call it; read the same data
back through `GET /devices` instead. It requires `device_id`; every other field
(`app_version`, `playing`, `track`, `position_s`, `ts`, `app_state`, `applied_pick_id`,
`last_steer_error`) is optional and passed through as given. It responds with
`{"ok": true, "pick": <current pick>}`.

### `GET /devices` - every device the server has heard from

```
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8787/devices
{"devices": {"test-iphone-1": {
  "device_id": "test-iphone-1", "app_version": "1.0", "playing": false, "track": null,
  "position_s": 0, "ts": 1234567890, "app_state": "foreground", "applied_pick_id": null,
  "last_steer_error": null, "last_seen": 1789365865.68
}}}
```

Keyed by `device_id`. `last_seen` is a unix timestamp the server stamped on receipt, in
seconds. The rest of the fields are exactly what that phone last reported in its check-in:
`app_version`, `playing`, `track`, `position_s`, `app_state` (`"foreground"`,
`"background"`, or `"inactive"`), `applied_pick_id`, `last_steer_error`.

### `POST /apns-token` - push registration only

Records a device's push token. No push is actually sent by this server yet. Needs
`device_id` and `token`; `app_version` is optional. Responds `{"ok": true}`.

### Other status codes

- `400` - malformed or missing JSON body, or a body that fails validation, with `error`
  explaining why.
- `404` - unknown path, `{"error": "not found"}`.
- `405` - `PUT`, `DELETE`, `PATCH` on any path, `{"error": "method not allowed"}`.

## How the phone acts on a pick

Read `Turntable/AgentLink.swift` if you want the full logic; the short version:

- The phone only acts on a pick that has a `pick_id`, and only if that `pick_id` differs
  from the last one it applied. A pick with no `pick_id` (the idle `{"action": "none"}`
  state before you have ever set one) is ignored, not treated as "pause."
- Re-POSTing the exact same pick body still gets you a new `pick_id`, because the server
  assigns one on every `POST /now-playing`. The phone will treat that as a new instruction
  and apply it again, restarting the song if it is a `"play"` pick. Do not loop the same
  POST expecting it to be a no-op.
- On `"play"`, the phone looks `catalog_id` up in Apple Music and plays it. If the catalog
  id is already the currently playing track, it marks the pick applied without restarting
  playback.
- Failures are reported back on the phone's next check-in as `last_steer_error`, string in
  `/devices` under that device. The pick it did successfully apply shows up as
  `applied_pick_id`.

## Where to get a catalog_id

It is the numeric id in an Apple Music song URL: the `NNNNNNNN` in
`music.apple.com/.../i=NNNNNNNN` or `music.apple.com/.../song/.../NNNNNNNN`. There is no
search API available to you here; get the id from a URL the human gives you, or ask them
for one. Do not invent or guess a catalog_id.

## Connectivity options

- **Tailscale.** Phone and server both join the same tailnet; the phone is paired against
  the server's `100.x` tailnet address. Nothing is exposed to the public internet. Tradeoff:
  both sides need the Tailscale app/daemon running and connected, and if the phone's
  Tailscale connection drops, steering stops working even though the app itself is fine.

- **cloudflared or ngrok tunnel.** Gives a laptop behind NAT a public https URL. Set
  `TURNTABLE_PUBLIC_URL` to the tunnel URL so a pairing phone is told the right address
  instead of a LAN IP. Tradeoff: free tunnel URLs change on restart, which silently
  un-pairs the phone's stored server address until it is paired again.

- **Public host (a small VPS).** Stable address, reachable from cell data, no tunnel to
  babysit. Tradeoff: the server is then reachable by anyone on the internet, and the only
  thing standing in front of it is the bearer token. Put a TLS-terminating reverse proxy in
  front of it before doing this. The app itself accepts a plain `http://` server address
  without complaint, so it will work without TLS, and a token sent over plain http on a
  public network is readable by anyone on the path.

## Etiquette

- Check `GET /devices` and compare `last_seen` to the current time before steering. More
  than about 60 seconds stale means the phone is not listening right now; say that instead
  of steering into the void.
- `app_state: "background"` together with `playing: false` means iOS has likely parked the
  app. A steer may sit unapplied until the human opens it again.
- After steering, wait one check-in cycle (15 seconds) and read `/devices` again. Confirm
  `applied_pick_id` matches the `pick_id` you just set, and read `last_steer_error`.
- Report the exact failure reason to the human, verbatim from `last_steer_error`. Do not
  summarize it as "it didn't work."
- Do not re-POST the same pick in a loop. Every `POST /now-playing` mints a new `pick_id`
  and the phone will restart the song on each one.
- Steering someone's music is interruptive. Do it when asked, and tell them what you did.

## First five minutes in this repo

1. Start the server: `cd server && ./run.sh` (add `TURNTABLE_PUBLIC_URL` first if the phone should keep a tailnet or tunnel address)
2. Read your token: `TOKEN=$(python3 -c 'import json;print(json.load(open("auth.json"))["agent_token"])')` (run from inside `server/`, or point at wherever `TURNTABLE_AUTH` put it)
3. Mint a pairing code: `python3 server.py --pair`
4. Reply with only the six character code. The app finds the server itself
5. Confirm the device shows up: `curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8787/devices`
6. Set a first pick, for example:
   ```
   curl -s -X POST http://localhost:8787/now-playing \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"action":"play","source":"apple_music","catalog_id":"<id from a music.apple.com URL>"}'
   ```
   Then wait 15 seconds and check `/devices` again for `applied_pick_id` and `last_steer_error`.
