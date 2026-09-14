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

## What you need to do any of this

Everything below works from a plain shell. It does not care what kind of agent you are.

**Required, whichever kind of agent you are:**

- A shell somewhere. Python 3.8 or newer, standard library only. Nothing to `pip install`,
  no virtualenv, no root, no account, no API key.
- A way to fetch a URL: `git clone`, or `curl`, or `wget`. One file is enough.
- The ability to leave a process running after a command returns, or a second shell.
  `nohup python3 server.py > turntable.log 2>&1 &` is enough and needs neither systemd nor
  a process manager.
- A way to send the human one string of text.

**Then one of these two, and this is the only real decision in the whole setup:**

- **A, the LAN path.** Your shell is on a computer on the phone's own Wi-Fi, and that
  computer has a local-network responder: `dns-sd` on macOS (always present) or
  `avahi-publish-service` on Linux (`avahi-utils`, with `avahi-daemon` running). The
  server announces itself, the phone finds it, and the code is six characters.
- **B, the remote path.** Your shell is anywhere else — a cloud machine, a hosted runner,
  a VPS — and you already have an address the phone can reach it at. Then set
  `TURNTABLE_PUBLIC_URL` and `--pair` mints a longer code that carries that address, so
  nothing has to be discovered. No responder is needed and neither is the human's Wi-Fi.

Path B needs an address that *already exists*: a public hostname this machine already
answers on, a tunnel already installed and running, or a tailnet address **the phone is
also on**. Tailscale on your side alone is not reachability; if the phone is not in that
tailnet, a `100.x` address is a dead end. Do not install a tunnel, sign the human up for
anything, or assume you can reach a computer in their house. If you have no such address,
say so in one line and let them run the server themselves. That answer is cheap; a code
that cannot be redeemed is not.

**Not required, ever:** a particular agent, editor, IDE or model; a plugin, extension or
tool protocol; a specific language runtime beyond Python 3; Docker; Homebrew; Tailscale;
an Apple Developer account; any edit to any file in this repo. If something below seems to
ask for one of those, it is optional and is labelled so.

## If someone just handed you the setup prompt

They installed the app, tapped Copy, and pasted it to you. The whole job is four commands
and one code. The only thing you have to decide is where the server runs, and the answer
follows from where your shell is.

### The decision tree

```
Is your shell on a computer that is on the phone's Wi-Fi right now?
├── yes ──> path A. Start the server plain. --pair prints six characters.
│                   Reply with those six characters and nothing else.
└── no  ──> Do you ALREADY have an address the phone can reach this machine at?
            (public hostname it already answers on, a tunnel already running,
             or a tailnet address the PHONE is also on)
            ├── yes ──> path B. Start the server with TURNTABLE_PUBLIC_URL set to it.
            │                   --pair prints one long TT1- code carrying that address.
            │                   Reply with that one code and nothing else.
            └── no  ──> Stop. Tell them in one line that their phone cannot reach you,
                        and that they should run these commands on their own computer.
                        Do not install a tunnel. Do not sign them up for anything.
```

### Path A, the LAN path

```
curl -fsSL https://raw.githubusercontent.com/abhaymettu/turntable/main/server/server.py -o server.py
nohup python3 server.py > turntable.log 2>&1 &
curl -s http://localhost:8787/healthz
python3 server.py --pair
```

1. Get `server/server.py`. `git clone` the repo if you prefer; the single file is the whole
   server and runs standalone from any directory.
2. Start it in the background, so you keep your shell. Then confirm with `/healthz`, which
   answers `{"ok": true, ...}` and needs no token.
3. Mint the code. The same shell is fine; `--pair` is a separate short-lived invocation
   that writes a code into the auth file and exits, not a second server.
4. **Reply with only the six characters.** No address, no commentary, nothing else. The
   app finds the server itself over the local network.

Two things to watch on this path:

- **Stay on the phone's Wi-Fi until they have typed the code.** That is the only step that
  needs it. Afterwards the phone uses the address the server named in its reply.
- **If `--pair` warns about `dns-sd` or `avahi-publish-service`, do not hand over that
  code.** Without a responder the phone cannot find the server on the Wi-Fi. Either fix
  the responder or switch to path B, which needs neither.

### Path B, the remote path

Identical except for step 2 and what you reply with:

```
curl -fsSL https://raw.githubusercontent.com/abhaymettu/turntable/main/server/server.py -o server.py
TURNTABLE_PUBLIC_URL=https://your-existing-address nohup python3 server.py > turntable.log 2>&1 &
curl -s http://localhost:8787/healthz
python3 server.py --pair
```

`TURNTABLE_PUBLIC_URL` has to be **https** unless it is a private or tailnet address; see
*Which addresses are allowed* below. `--pair` then prints one long code beginning `TT1-`
that carries that address inside it. **Reply with that one code, whole, and nothing else.**
Do not send the address separately, do not wrap the code in quotes or backticks, and do not
break it across lines: it goes into the same single box in the app that a six character
code goes into.

If `--pair` refuses and tells you the address is unusable, it means exactly what it says.
Fix the address or fall back to telling the human you cannot be reached.

Everything else in this file is either the API you steer with afterwards, or optional.

## Start the server

```
python3 server.py
```

Or `cd server && ./run.sh`, which is the same thing from a checkout. Python 3, stdlib only,
nothing to `pip install`. It listens on `0.0.0.0:8787` by default, and `server.py` is
self-contained: copy that one file anywhere and it works, writing its auth and log files
beside itself.

If your shell blocks on a foreground process, background it and keep working in the same
shell:

```
nohup python3 server.py > turntable.log 2>&1 &
```

While it runs it also announces itself on the local network as `_turntable._tcp`, through
whichever of `dns-sd` (macOS) or `avahi-publish-service` (Linux, from `avahi-utils`, with
`avahi-daemon` running) is present. That announcement is how a freshly installed phone
finds the server to redeem a pairing code against; it is not how the phone remembers the
server afterwards.

**With no responder, the LAN path cannot pair at all.** The server still starts and still
serves every endpoint, but a phone that has never paired has no way to find it, and the app
has no address field before pairing. The server says so at startup and again at `--pair`
time. Install `avahi-utils`, or run the server on a machine that has a responder, or use
the remote path: with `TURNTABLE_PUBLIC_URL` set, the code carries the address and no
announcement is involved.

Environment variables:

- `TURNTABLE_PORT` - listen port (default 8787)
- `TURNTABLE_LOG` - path to the append-only JSONL event log (default `server/turntable.jsonl`)
- `TURNTABLE_AUTH` - path to the auth file (default `server/auth.json`)
- `TURNTABLE_PUBLIC_URL` - the address the phone should use. Two effects: it is what a
  freshly paired phone is handed, and it makes `--pair` mint the long code that carries it
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

What it prints depends on `TURNTABLE_PUBLIC_URL`, and on nothing else. You do not pick the
shape and neither does the human.

### Unset: the six character LAN code

```
pairing code: DPGTX9
server address: http://192.168.1.192:8787
good for 15 minutes, one phone. Run this again for another code.
this server is announced on the local network, so the phone finds it itself: send the six
characters and nothing else.
```

Alphabet `23456789ABCDEFGHJKMNPQRSTVWXYZ`, no ambiguous characters, stored only as a sha256
with a 15 minute expiry. **Reply with only the code.** The printed address is for you: the
app browses `_turntable._tcp`, finds this server, and POSTs the code to it.

### Set: the long `TT1-` code

```
pairing code: TT1-aHR0cHM6Ly90dW5uZWwuZXhhbXBsZS5jb20KVkJSSDNZSk5LOVdLNUhRTg
carries this address: https://tunnel.example.com
good for 15 minutes, one phone. Send that one code string whole, and nothing else.
```

The payload is `TT1-` and then base64url, unpadded, of `<url>\n<secret>` in UTF-8. The
secret is 16 characters of the same alphabet, about 78 bits, against the 6 characters
(about 29 bits) the LAN path uses, because a remote server can be reached from anywhere.
Base64url, not the address in plain text, so nothing in the code looks like a link that a
messaging app will turn into a tappable one and mangle.

**The code carries no bearer token.** It carries a single-use secret that dies in 15
minutes and lives on this server only as a hash. A code somebody else reads buys them one
race against the clock, not an account.

The app decodes it, checks the address field by field, and POSTs the secret straight there.
Nothing is discovered, so the phone's own Wi-Fi is irrelevant on this path.

### Which addresses are allowed

`--pair` refuses to mint a code for an address the app would reject, so you find out here
rather than the human finding out with a code that cannot work. An address must:

- start with `http://` or `https://`, and be at most 200 characters;
- have a host of at most 128 characters, and a port in 1-65535 if it names one;
- carry no username, password, query or fragment;
- be **https**, unless the host is one the traffic cannot leave a shared network on:
  `localhost`, a `.local`, `.ts.net` or `.internal` name, `10.x`, `127.x`, `192.168.x`,
  `172.16-31.x`, `169.254.x`, `100.64-127.x` (where tailnet addresses live), `::1`, or an
  IPv6 ULA or link-local address.

Plain http to a public host is refused because the pairing secret goes out in that request
and the device token comes back in the reply, both readable by anything on the path.

### Redemption

```
curl -s -X POST http://192.168.1.192:8787/pair \
  -H "Content-Type: application/json" \
  -d '{"code":"DPGTX9","device_id":"some-device-id"}'
```

`code` is the six characters, or the 16 character secret out of a `TT1-` code. The server
does not care which; it hashes what it is given. It answers
`{"server_url": "...", "token": "..."}`.

**`server_url` is the address the phone keeps**, and it stays authoritative: it is
`TURNTABLE_PUBLIC_URL` when you set one, or the host the phone reached you on when you did
not. It is not the address out of the code. Set `TURNTABLE_PUBLIC_URL` to the tailnet or
tunnel address before pairing and the phone keeps working after it leaves that Wi-Fi; leave
it unset and the phone keeps a LAN address that stops resolving the moment they go out.

A code works once. Redeeming an already-used or unknown code returns
`{"error": "bad code", "reason": "bad code"}` at HTTP 403. A code past its 15 minute window
returns `{"error": "expired", "reason": "expired"}`. Ten wrong guesses burn every code
currently pending, so do not brute force this.

There is no third path and no address field on first run. The app's Advanced screen does
take an address directly, but it is inside the app behind pairing: it repoints an **already
paired** phone at a server that moved, on the token it already holds. If you are not on the
human's Wi-Fi and have no address their phone can reach, neither path is open to you, and
the honest thing to tell them is that the server has to run somewhere they can reach.

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

## Connectivity options, all optional

None of this is needed to pair or to steer. Skip the whole section unless the human has
asked for music that keeps working when they leave the house, and never install software
on their machine to satisfy it without asking first.

Whichever you pick, set `TURNTABLE_PUBLIC_URL` **before** the phone pairs. It is what the
pairing reply hands back, it is the address the phone keeps, and it is what puts the
address inside the code. Setting it afterwards does nothing to a phone that already paired;
that phone needs a fresh code, or the address typed into the app's Advanced screen.

- **Tailscale.** Phone and server both join the same tailnet; the phone is paired against
  the server's `100.x` tailnet address. Nothing is exposed to the public internet. Tradeoff:
  both sides need the Tailscale app/daemon running and connected, and if the phone's
  Tailscale connection drops, steering stops working even though the app itself is fine.
  **The phone has to be in that tailnet.** A `100.x` address is reachable from your machine
  and from nowhere else; if the human has not joined their phone, this is not an option and
  saying it is wastes their time.

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

1. Start the server: `nohup python3 server.py > turntable.log 2>&1 &`, with `TURNTABLE_PUBLIC_URL=<address the phone can reach>` in front of it if you are not on the phone's Wi-Fi
2. Read your token: `TOKEN=$(python3 -c 'import json;print(json.load(open("auth.json"))["agent_token"])')` (run from beside `server.py`, or point at wherever `TURNTABLE_AUTH` put it)
3. Mint a pairing code: `python3 server.py --pair`
4. Reply with only the code it printed, whole: six characters on the LAN path, one long `TT1-` string on the remote path
5. Confirm the device shows up: `curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8787/devices`
6. Set a first pick, for example:
   ```
   curl -s -X POST http://localhost:8787/now-playing \
     -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"action":"play","source":"apple_music","catalog_id":"<id from a music.apple.com URL>"}'
   ```
   Then wait 15 seconds and check `/devices` again for `applied_pick_id` and `last_steer_error`.
