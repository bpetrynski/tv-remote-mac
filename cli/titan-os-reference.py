#!/usr/bin/env python3
"""Working pairing + remote-key reference for Philips Titan OS (65PUS8919/12).

Everything in this file was verified against the actual TV. Where something is not
verified, it is marked as such. Nothing here is guessed.

    python3 titan-os-reference.py <tv-ip> pair
    python3 titan-os-reference.py <tv-ip> key Home CursorRight Confirm
    python3 titan-os-reference.py <tv-ip> volume 12
    python3 titan-os-reference.py <tv-ip> check

Credentials from `pair` are stored next to this script in titan-os-credentials.json
and reused by the other commands.

Environment: JointSpace API v6.1, HTTPS on port 1926, HTTP Digest auth, self-signed
certificate (verification must be disabled). Reported by the TV as
`digest_auth_pairing`, `secured_transport: true`, `os_type: Linux`.
"""

import base64
import hashlib
import hmac
import json
import os
import random
import sys
import time

import requests
from requests.auth import HTTPDigestAuth
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# JointSpace v6 shared secret - publicly known, same value as on Android TV.
SECRET_KEY = base64.b64decode(
    "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA=="
)

CREDENTIALS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "titan-os-credentials.json")


# ---------------------------------------------------------------------------
# 1. PAIRING
# ---------------------------------------------------------------------------

def pair(host):
    device = {
        "app_id": "app.id",
        "app_name": "ReferenceClient",
        "type": "native",
        "device_name": "laptop",
        "device_os": "Android",
        "id": "".join(random.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(16)),
    }
    base = f"https://{host}:1926/6"

    # --- Step 1: request. The TV now shows a 4-DIGIT PIN (not 6 characters). ---
    r = requests.post(
        f"{base}/pair/request",
        json={"scope": ["read", "write", "control"], "device": device},
        verify=False,
        timeout=10,
    )
    r.raise_for_status()
    resp = r.json()
    if resp.get("error_id") != "SUCCESS":
        sys.exit(f"pair/request rejected: {resp}")

    auth_key = resp["auth_key"]
    timestamp = resp["timestamp"]
    print(f"PIN is on the TV screen, valid for {resp.get('timeout', 30)} s.")
    pin = input("PIN (4 digits): ").strip()

    # --- Step 2: grant. THIS IS THE BUG MOST CLIENTS HIT. ---
    #
    # auth_signature = base64( RAW digest of HMAC-SHA1(SECRET_KEY, str(timestamp) + pin) )
    #
    # Public Philips implementations (pylips and every guide derived from it) base64
    # the HEXDIGEST instead. On Titan OS that variant returns INVALID_PIN even with a
    # correct PIN inside the 30 s window. Both variants were tested against the same
    # pairing session on this TV: hexdigest -> INVALID_PIN, raw digest -> SUCCESS.
    #
    # The ha-philipsjs library used by Home Assistant already uses the raw-digest
    # variant, which is why pairing from Home Assistant succeeds on this model.
    signature = base64.b64encode(
        hmac.new(SECRET_KEY, (str(timestamp) + pin).encode(), hashlib.sha1).digest()
    ).decode()

    r = requests.post(
        f"{base}/pair/grant",
        json={
            "auth": {
                "auth_AppId": "1",
                "pin": pin,
                "auth_timestamp": timestamp,
                "auth_signature": signature,
            },
            "device": device,
        },
        auth=HTTPDigestAuth(device["id"], auth_key),
        verify=False,
        timeout=10,
    )
    if r.status_code != 200 or r.json().get("error_id") != "SUCCESS":
        sys.exit(f"pair/grant failed ({r.status_code}): {r.text}")

    creds = {"host": host, "device_id": device["id"], "auth_key": auth_key}
    with open(CREDENTIALS, "w") as f:
        json.dump(creds, f, indent=2)
    os.chmod(CREDENTIALS, 0o600)
    print(f"Paired. Credentials stored in {CREDENTIALS}")
    return creds


def digest():
    try:
        with open(CREDENTIALS) as f:
            creds = json.load(f)
    except FileNotFoundError:
        sys.exit("Not paired yet. Run: pair")
    return HTTPDigestAuth(creds["device_id"], creds["auth_key"])


# ---------------------------------------------------------------------------
# 2. REMOTE KEYS
# ---------------------------------------------------------------------------
#
# POST /6/input/key with {"key": "<code>"}.
#
# TRAP: the TV answers "200 Ok" to ANY string, including codes that do not exist
# ("CompletelyFakeKey999") and an empty one. Unknown keys are silently dropped, so the
# HTTP status never tells you whether a key did anything. The only reliable test is
# looking at the screen. Every list below comes from that kind of on-screen testing.

# Confirmed on screen on 65PUS8919/12.
KEYS_WORKING = [
    "CursorUp", "CursorDown", "CursorLeft", "CursorRight", "Confirm",
    "Home", "Back", "Options",
    "Play", "Pause",
    "Mute",
]

# Confirmed to do nothing on this model, despite returning 200 Ok.
KEYS_BROKEN = ["PlayPause", "Stop"]

# In the standard JointSpace key list, but NOT tested on screen here. Do not assume
# these work on Titan OS - the 200 Ok response is not evidence.
KEYS_UNVERIFIED = [
    "Standby", "Info", "Source", "Find", "Adjust", "WatchTV", "Viewmode",
    "VolumeUp", "VolumeDown", "ChannelStepUp", "ChannelStepDown",
    "Rewind", "FastForward", "Next", "Previous", "Record", "Online",
    "Teletext", "Subtitle", "AmbilightOnOff", "Dot",
    "RedColour", "GreenColour", "YellowColour", "BlueColour",
    *[f"Digit{n}" for n in range(10)],
]

# Two things worth building into a remote UI for this model:
#
# 1. There is no play/pause toggle. "PlayPause" is dead here, so the client must track
#    playback state itself and send either "Play" or "Pause". This is what Home
#    Assistant does, and it is the reason its remote works on this TV.
# 2. "Play" is not part of the documented JointSpace key list, but it works on Titan OS.
#    A client that validates key names against the published list will reject it.


def send_keys(host, keys):
    for name in keys:
        if name in KEYS_BROKEN:
            print(f"{name}: known to do nothing on this model, sending anyway")
        r = requests.post(
            f"https://{host}:1926/6/input/key",
            json={"key": name},
            auth=digest(),
            verify=False,
            timeout=8,
        )
        # Reminder: 200 here means "request accepted", not "key executed".
        print(f"POST /6/input/key {name} -> {r.status_code} {r.text.strip()[:40]}")
        time.sleep(0.2)


# ---------------------------------------------------------------------------
# 3. VOLUME
# ---------------------------------------------------------------------------

def volume(host, level=None):
    """Scale is 0-60 on this model; GET /6/audio/volume also reports min/max and mute."""
    url = f"https://{host}:1926/6/audio/volume"
    if level is None:
        r = requests.get(url, auth=digest(), verify=False, timeout=8)
        print(r.text)
        return

    requests.post(url, json={"current": int(level), "muted": False},
                  auth=digest(), verify=False, timeout=8)

    # Read-after-write returns a stale value: set 15, read immediately, get 14.
    # Measured correct from ~300 ms. A UI that refreshes instantly shows the wrong number.
    time.sleep(0.4)
    r = requests.get(url, auth=digest(), verify=False, timeout=8)
    print(r.text)


# ---------------------------------------------------------------------------
# 4. ENDPOINT SUPPORT ON TITAN OS
# ---------------------------------------------------------------------------

def check(host):
    base = f"https://{host}:1926/6"

    # Confirmed working.
    for path in ("system", "powerstate", "audio/volume", "activities/current",
                 "activities/tv", "ambilight/currentconfiguration", "screenstate", "context"):
        r = requests.get(f"{base}/{path}", auth=digest(), verify=False, timeout=8)
        print(f"GET /6/{path} -> {r.status_code} {r.text.strip()[:100]}")

    # Confirmed NOT available on Titan OS: both return 403. There is no installed-app
    # list and no HDMI input switching through this API on this model. A client that
    # depends on them should hide those features here rather than fail silently.
    # Apps have to be launched by navigating with Home + cursor keys + Confirm.
    for path in ("applications", "sources"):
        r = requests.get(f"{base}/{path}", auth=digest(), verify=False, timeout=8)
        print(f"GET /6/{path} -> {r.status_code} (403 expected on Titan OS)")

    # Also confirmed: channeldb/tv returns {} - no tuned channels, epgsource "no_epg".


# A diagnostic note that may save time: `curl --digest` gets HTTP 503 on POSTs to this
# TV, while Python requests and Swift URLSession on the same payloads work fine. If you
# debug with curl, you can wrongly conclude the TV is broken.


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    tv, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    if cmd == "pair":
        pair(tv)
    elif cmd == "key":
        send_keys(tv, args or ["Home"])
    elif cmd == "keys":
        print("working:   ", " ".join(KEYS_WORKING))
        print("broken:    ", " ".join(KEYS_BROKEN))
        print("unverified:", " ".join(KEYS_UNVERIFIED))
    elif cmd == "volume":
        volume(tv, args[0] if args else None)
    elif cmd == "check":
        check(tv)
    else:
        sys.exit(__doc__)
