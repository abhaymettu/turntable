# Turntable

An iPhone app your coding agent can DJ.

You text your agent. The music changes.

Turntable is two pieces: an iOS app that plays Apple Music, and a small Python server your
agent writes to. The agent never touches Apple Music. It sets a pick on the server, the
phone checks in every 15 seconds, reads the pick, and plays it.

```
  you  ->  your agent  ->  server  <-  phone  ->  Apple Music
         "play something     the pick    checks in every 15s
          quieter"                       and follows it
```

That is the whole idea. The agent already knows what you are doing, what you asked for
last time, and what time it is. This gives it a speaker.

## Quickstart

You need: an iPhone with an Apple Music subscription, a Mac with Xcode to install the app,
and a machine your agent can run commands on.

**1. Start the server.** Python 3, standard library only, nothing to install.

```
cd server && ./run.sh
```

**2. Mint a pairing code.** In another shell, on the same machine:

```
cd server && python3 server.py --pair
```

It prints a six character code and the address to reach the server at. The code lasts 15
minutes and works once.

**3. Build and install the app**, then type that address and code into the pairing screen.
See "Building the app" below. The app ships pointing at nothing; pairing is how it learns
where your server is and gets the token it sends with every later request.

**4. Let the agent steer.** Point your agent at [AGENTS.md](AGENTS.md) and ask for a song.

## For agents

[AGENTS.md](AGENTS.md) is the file to hand a coding agent. It covers the one command
server setup, minting a pairing code, every endpoint with a curl example, how to tell
whether the phone is actually listening, and the etiquette of steering someone's music.

## What is in the app

- **DJ.** Search the Apple Music catalog, tap to queue, drag to reorder, swipe to remove.
  A Now Playing bar with a record that turns while music plays. A status line that says
  whether the agent link is up, and when it is not, why.
- **Video.** Paste a YouTube link and it plays in an embedded player. No API key.
- **Podcasts.** Paste an RSS feed and it parses and plays episodes. No API key.
- **Audio route.** The current output (AirPods, speaker, car) is read and shown.

Every gate has a real screen rather than a spinner: no permission yet, permission denied,
no subscription, empty queue, search failed, no results, agent offline with the reason.

## Connectivity

The phone has to be able to reach the server. Three ways, with their costs:

- **Tailscale.** Both on the tailnet, use the server's `100.x` address. Nothing is exposed
  publicly. Needs the Tailscale app running on the phone.
- **A tunnel** (cloudflared, ngrok). Gives a laptop behind NAT a public https URL. Set
  `TURNTABLE_PUBLIC_URL` to the tunnel URL so a pairing phone is told the right address.
  Free tunnel URLs change on restart, and the phone then has a stale address.
- **A public host.** Stable, works on cell data, and the server is on the open internet
  with only a bearer token in front of it. Put it behind TLS before doing this.

## Design decisions

- **One user per server.** No accounts, no multi-tenancy. One person's picks and devices
  per server process. Run your own.
- **The token is the whole security model.** Every endpoint except `GET /healthz` and
  `POST /pair` needs `Authorization: Bearer <token>`. The phone's token comes from
  pairing; the agent's own token is generated on first start and written to
  `server/auth.json` (mode 0600, gitignored). Pairing codes are stored hashed with a 15
  minute expiry and burn after ten wrong guesses.
- **The app says why.** A failed steer comes back to the server in the next check-in as
  `last_steer_error`, so the agent can report the real reason instead of guessing.
- **Colour never carries meaning alone.** Every status dot sits next to a word.

## Building the app

Needs Xcode 26 with an iOS 26 simulator or a registered device. The project file is
committed, so a clean checkout builds without xcodegen.

```
xcodebuild -scheme Turntable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

To run it on your own phone, change `PRODUCT_BUNDLE_IDENTIFIER` and `bundleIdPrefix` in
`project.yml` to your own reverse domain, run `xcodegen generate`
(`brew install xcodegen`), and set your team in Xcode. Apple Music playback needs a real
device and a signed-in account with a subscription; the simulator will get you as far as
the subscription gate.

The app icon is generated, not drawn by hand:

```
python3 tools/make_icon.py
```

## Screenshots

TODO: DJ tab with a queue.

TODO: pairing screen.

TODO: agent status line showing an offline reason.

TODO: podcasts tab.

## What is not built

- Nothing sends a push. The app registers for APNs and posts its token, but sending a
  notification needs an APNs Auth Key from Apple, which this repo cannot generate.
- No auto-pause or auto-resume on an audio route change. Route changes are read and shown,
  not acted on.
- The check-in loop is 15 seconds and polls. A steer lands within that window, and when
  iOS suspends the app because nothing is playing, it lands when the app wakes. The
  server's `last_seen` is the honest signal for "the phone is not listening".

## Player choice

The queue and transport use `ApplicationMusicPlayer`, not `SystemMusicPlayer`. The system
player was the first pick, because the lock screen and the Music app follow it. But its
queue is write-only in the MusicKit API: no `entries`, so no visible queue, no reorder, no
remove. The reasoning is in the header of `Turntable/PlayerModel.swift`.

## Credits

Authorization, subscription check and debounced search follow the patterns in
[wesmatlock/MusicKitDemo](https://github.com/wesmatlock/MusicKitDemo) (MIT).

## License

MIT. See [LICENSE](LICENSE).
