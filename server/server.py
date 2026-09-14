#!/usr/bin/env python3
"""
Turntable server: a stdlib-only HTTP API that an agent steers and a phone follows.

One server holds one user's pick and one user's devices. There is no multi-tenancy and
no account system on purpose; run your own.

Run it:
    python3 server.py
    TURNTABLE_PORT=9000 TURNTABLE_LOG=/tmp/tt.jsonl python3 server.py

Pair a phone (prints a 6 character code, good for 15 minutes):
    python3 server.py --pair

Every endpoint except GET /healthz and POST /pair needs a bearer token. The agent's own
token is generated on first start and written to server/auth.json; read it from there:
    TOKEN=$(python3 -c 'import json;print(json.load(open("auth.json"))["agent_token"])')
    curl -H "Authorization: Bearer $TOKEN" http://localhost:8787/devices
"""

import hashlib
import json
import os
import secrets
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_LOCK = threading.Lock()
CURRENT_PICK = {"action": "none"}
NEXT_PICK_ID = 1
DEVICES = {}

HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.environ.get("TURNTABLE_LOG", os.path.join(HERE, "turntable.jsonl"))
AUTH_PATH = os.environ.get("TURNTABLE_AUTH", os.path.join(HERE, "auth.json"))

# Set this when the phone reaches the server at a different address than the one the
# server sees, which is every tunnel (cloudflared, ngrok) and every reverse proxy.
# It is what a freshly paired phone is told to use. Unset, the phone is told the host
# it used for the pairing request itself, which is right for LAN and tailnet setups.
PUBLIC_URL = os.environ.get("TURNTABLE_PUBLIC_URL", "").rstrip("/")

# The APNs Auth Key (.p8) is a developer-portal artifact this server cannot generate.
# The path is accepted now so it is wired up; sending a push with it is a later step.
APNS_KEY_PATH = os.environ.get("TURNTABLE_APNS_KEY_PATH", os.path.join(HERE, "apns_key.p8"))

# Crockford base32 without the ambiguous glyphs, and without 0 and 1 as well, so a code
# read out loud or typed on a phone has no pairs that look alike.
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"
CODE_LENGTH = 6
CODE_TTL_S = 15 * 60
CODE_MAX_TRIES = 10

AUTH_LOCK = threading.Lock()


# --- auth file -------------------------------------------------------------------

def _read_auth():
    try:
        with open(AUTH_PATH) as f:
            auth = json.load(f)
    except (OSError, ValueError):
        auth = {}
    auth.setdefault("agent_token", "")
    auth.setdefault("pending", [])
    auth.setdefault("devices", {})
    return auth


def _write_auth(auth):
    tmp = AUTH_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(auth, f, indent=2)
    os.replace(tmp, AUTH_PATH)


def _hash(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def ensure_agent_token():
    """The token the agent uses for its own curl calls. Created once, kept in auth.json."""
    with AUTH_LOCK:
        auth = _read_auth()
        if not auth["agent_token"]:
            auth["agent_token"] = secrets.token_urlsafe(32)
            _write_auth(auth)


def token_is_valid(token):
    if not token:
        return False
    with AUTH_LOCK:
        auth = _read_auth()
    if auth["agent_token"] and secrets.compare_digest(token, auth["agent_token"]):
        return True
    return _hash(token) in auth["devices"]


def mint_code():
    """Mint one pairing code, store only its hash with a 15 minute expiry, return it."""
    code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
    now = time.time()
    with AUTH_LOCK:
        auth = _read_auth()
        # Drop anything that expired more than an hour ago. Recently expired codes are
        # kept so a late redeem can be told "expired" instead of "no such code".
        auth["pending"] = [p for p in auth["pending"] if p["expires"] > now - 3600]
        auth["pending"].append({"hash": _hash(code), "expires": now + CODE_TTL_S, "tries": 0})
        _write_auth(auth)
    return code


def normalize_code(raw):
    return "".join(c for c in raw.upper() if c.isalnum())


def redeem_code(raw, device_id):
    """Trade a pairing code for a device token. Returns (token, None) or (None, reason)."""
    code = normalize_code(raw)
    if len(code) != CODE_LENGTH:
        return None, "bad code"
    digest = _hash(code)
    now = time.time()
    with AUTH_LOCK:
        auth = _read_auth()
        match = next((p for p in auth["pending"] if p["hash"] == digest), None)
        if match is None:
            # Charge a failed attempt against every live code, so guessing burns the
            # window rather than getting unlimited tries at it.
            for pending in auth["pending"]:
                pending["tries"] = pending.get("tries", 0) + 1
            auth["pending"] = [p for p in auth["pending"] if p["tries"] < CODE_MAX_TRIES]
            _write_auth(auth)
            return None, "bad code"
        auth["pending"].remove(match)
        if match["expires"] < now:
            _write_auth(auth)
            return None, "expired"
        token = secrets.token_urlsafe(32)
        auth["devices"][_hash(token)] = {"device_id": device_id, "paired_at": now}
        _write_auth(auth)
    return token, None


def lan_address(port):
    """Best guess at an address the phone can reach, for the printed pairing message."""
    if PUBLIC_URL:
        return PUBLIC_URL
    ip = "127.0.0.1"
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packet leaves the machine; this only asks the routing table which local
        # address would be used to reach the internet.
        probe.connect(("8.8.8.8", 80))
        ip = probe.getsockname()[0]
    except OSError:
        pass
    finally:
        probe.close()
    return "http://%s:%d" % (ip, port)


# --- state -----------------------------------------------------------------------

def append_log(kind, data):
    entry = {"ts": time.time(), "kind": kind, "data": data}
    with open(LOG_PATH, "a") as f:
        f.write(json.dumps(entry) + "\n")


def replay_log():
    global CURRENT_PICK, NEXT_PICK_ID, DEVICES
    if not os.path.exists(LOG_PATH):
        return
    with open(LOG_PATH, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            kind = entry.get("kind")
            data = entry.get("data")
            if kind == "pick" and isinstance(data, dict):
                CURRENT_PICK = data
                pick_id = data.get("pick_id")
                if isinstance(pick_id, int) and pick_id >= NEXT_PICK_ID:
                    NEXT_PICK_ID = pick_id + 1
            elif kind == "checkin" and isinstance(data, dict):
                device_id = data.get("device_id")
                if device_id:
                    DEVICES[device_id] = data


def validate_pick(body):
    if not isinstance(body, dict):
        return None, "body must be a JSON object"
    action = body.get("action")
    if action not in ("play", "none", "pause", "add_to_playlist"):
        return None, "action must be 'play', 'none', 'pause', or 'add_to_playlist'"
    pick = {"action": action}
    if action == "add_to_playlist":
        playlist_name = body.get("playlist_name")
        if not isinstance(playlist_name, str) or not playlist_name:
            return None, "playlist_name must be a non-empty string"
        pick["playlist_name"] = playlist_name
        catalog_id = body.get("catalog_id")
        if isinstance(catalog_id, str) and catalog_id:
            pick["catalog_id"] = catalog_id
        for key in ("title", "artist"):
            value = body.get(key, "")
            pick[key] = value if isinstance(value, str) else ""
    if action == "play":
        source = body.get("source")
        if source != "apple_music":
            return None, "source must be 'apple_music'"
        catalog_id = body.get("catalog_id")
        if not isinstance(catalog_id, str) or not catalog_id:
            return None, "catalog_id must be a non-empty string"
        pick["source"] = source
        pick["catalog_id"] = catalog_id
        for key in ("title", "artist"):
            value = body.get(key, "")
            pick[key] = value if isinstance(value, str) else ""
    return pick, None


def validate_apns_token(body):
    if not isinstance(body, dict):
        return None, "body must be a JSON object"
    device_id = body.get("device_id")
    token = body.get("token")
    if not isinstance(device_id, str) or not device_id:
        return None, "device_id must be a non-empty string"
    if not isinstance(token, str) or not token:
        return None, "token must be a non-empty string"
    return {
        "device_id": device_id,
        "token": token,
        "app_version": body.get("app_version"),
    }, None


def validate_checkin(body):
    if not isinstance(body, dict):
        return None, "body must be a JSON object"
    device_id = body.get("device_id")
    if not isinstance(device_id, str) or not device_id:
        return None, "device_id must be a non-empty string"
    data = {
        "device_id": device_id,
        "app_version": body.get("app_version"),
        "playing": body.get("playing"),
        "track": body.get("track"),
        "position_s": body.get("position_s"),
        "ts": body.get("ts"),
        "app_state": body.get("app_state"),
        "applied_pick_id": body.get("applied_pick_id"),
        "last_steer_error": body.get("last_steer_error"),
    }
    return data, None


# --- http ------------------------------------------------------------------------

OPEN_PATHS = {("GET", "/healthz"), ("POST", "/pair")}


class Handler(BaseHTTPRequestHandler):
    server_version = "TurntableHTTP/1.0"

    def send_json(self, status, obj):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def authorized(self, method):
        """Everything but /healthz and /pair needs a bearer token from a pairing."""
        if (method, self.path) in OPEN_PATHS:
            return True
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme.lower() == "bearer" and token_is_valid(token.strip()):
            return True
        self.send_json(401, {"error": "unauthorized", "reason": "missing or unknown bearer token"})
        return False

    def read_json_body(self):
        length = self.headers.get("Content-Length")
        try:
            length = int(length) if length is not None else 0
        except ValueError:
            length = 0
        if length <= 0:
            return None, "request body is required"
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8")), None
        except ValueError:
            return None, "body must be valid JSON"

    def public_url(self):
        """The address to hand a freshly paired phone."""
        if PUBLIC_URL:
            return PUBLIC_URL
        scheme = self.headers.get("X-Forwarded-Proto", "http").split(",")[0].strip()
        host = self.headers.get("Host") or self.server.server_address[0]
        return "%s://%s" % (scheme, host)

    def do_GET(self):
        if not self.authorized("GET"):
            return
        if self.path == "/healthz":
            self.send_json(200, {"ok": True, "ts": time.time()})
        elif self.path == "/now-playing":
            with STATE_LOCK:
                pick = CURRENT_PICK
            self.send_json(200, pick)
        elif self.path == "/devices":
            with STATE_LOCK:
                devices = dict(DEVICES)
            self.send_json(200, {"devices": devices})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        global NEXT_PICK_ID, CURRENT_PICK
        if not self.authorized("POST"):
            return
        if self.path == "/pair":
            body, err = self.read_json_body()
            if err:
                self.send_json(400, {"error": err, "reason": "bad request"})
                return
            if not isinstance(body, dict):
                self.send_json(400, {"error": "body must be a JSON object", "reason": "bad request"})
                return
            code = body.get("code")
            device_id = body.get("device_id")
            if not isinstance(code, str) or not isinstance(device_id, str) or not device_id:
                self.send_json(400, {"error": "code and device_id are required", "reason": "bad request"})
                return
            token, reason = redeem_code(code, device_id)
            if reason:
                self.send_json(403, {"error": reason, "reason": reason})
                return
            self.send_json(200, {"server_url": self.public_url(), "token": token})
        elif self.path == "/now-playing":
            body, err = self.read_json_body()
            if err:
                self.send_json(400, {"error": err})
                return
            pick, err = validate_pick(body)
            if err:
                self.send_json(400, {"error": err})
                return
            with STATE_LOCK:
                pick["pick_id"] = NEXT_PICK_ID
                NEXT_PICK_ID += 1
                pick["set_at"] = time.time()
                CURRENT_PICK = pick
            append_log("pick", pick)
            self.send_json(200, pick)
        elif self.path == "/checkin":
            body, err = self.read_json_body()
            if err:
                self.send_json(400, {"error": err})
                return
            data, err = validate_checkin(body)
            if err:
                self.send_json(400, {"error": err})
                return
            with STATE_LOCK:
                data["last_seen"] = time.time()
                DEVICES[data["device_id"]] = data
                pick = CURRENT_PICK
            append_log("checkin", data)
            self.send_json(200, {"ok": True, "pick": pick})
        elif self.path == "/apns-token":
            body, err = self.read_json_body()
            if err:
                self.send_json(400, {"error": err})
                return
            data, err = validate_apns_token(body)
            if err:
                self.send_json(400, {"error": err})
                return
            append_log("apns_token", data)
            self.send_json(200, {"ok": True})
        else:
            self.send_json(404, {"error": "not found"})

    def do_PUT(self):
        self.send_json(405, {"error": "method not allowed"})

    do_DELETE = do_PATCH = do_PUT


def main():
    port = int(os.environ.get("TURNTABLE_PORT", "8787"))
    ensure_agent_token()
    if "--pair" in sys.argv[1:]:
        code = mint_code()
        print("pairing code: %s" % code)
        print("server address: %s" % lan_address(port))
        print("good for 15 minutes, one phone. Run this again for another code.")
        return
    replay_log()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    key_state = "present" if os.path.exists(APNS_KEY_PATH) else "missing, placeholder path only"
    print("turntable server listening on 0.0.0.0:%d, log at %s" % (port, LOG_PATH), file=sys.stderr)
    print("auth at %s (agent token is in there)" % AUTH_PATH, file=sys.stderr)
    print("pair a phone with: python3 server.py --pair", file=sys.stderr)
    print("APNs key path: %s (%s)" % (APNS_KEY_PATH, key_state), file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
