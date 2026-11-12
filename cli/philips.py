#!/usr/bin/env python3
"""Control a Philips 65PUS8919 (JointSpace API v6, digest auth pairing).

Usage:
    ./philips.py discover          # find the TV on the network (and remember its address)
    ./philips.py pair              # one-time pairing (PIN shown on the TV screen)
    ./philips.py pair-request      # same, in two steps: step 1 (show PIN)
    ./philips.py pair-grant 1234   #                     step 2 (confirm PIN)
    ./philips.py info              # TV system info
    ./philips.py key HOME          # send a remote control key
    ./philips.py keys              # list remote control keys
    ./philips.py volume 12         # set volume / no argument = read it
    ./philips.py mute
    ./philips.py ambilight                    # current configuration
    ./philips.py ambilight styles             # available styles + algorithms
    ./philips.py ambilight off|on|FOLLOW_AUDIO
    ./philips.py power on|off|status
    ./philips.py get <path>        # raw GET, e.g. get powerstate
    ./philips.py post <path> '<json>'
"""

import base64
import hashlib
import hmac
import json
import os
import random
import socket
import stat
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests
from requests.auth import HTTPDigestAuth
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# The TV address is no longer hardcoded. Resolution order:
# PHILIPS_TV_HOST -> host saved in CONFIG (if it responds) -> network scan.
TV_HOST_ENV = os.environ.get("PHILIPS_TV_HOST")
API = 6
PORT = 1926
CONFIG = os.path.expanduser("~/.config/philips-tv/config.json")

# JointSpace v6 shared key – publicly known, embedded in the Philips app.
SECRET_KEY = base64.b64decode(
    "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA=="
)

DEVICE = {
    "app_id": "app.id",
    "app_name": "PhilipsCLI",
    "type": "native",
    "device_name": "mac",
    "device_os": "Android",
}


def base_url():
    return f"https://{resolve_host()}:{PORT}/{API}"


def load_config():
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except FileNotFoundError:
        sys.exit("Not paired. Run first: ./philips.py pair")


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG, stat.S_IRUSR | stat.S_IWUSR)


# MARK: - Finding the TV on the network ------------------------------------------

def _local_ipv4_networks():
    """Return a list of (ip, netmask) for local IPv4 interfaces, excluding loopback."""
    nets = []
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("inet ") or "127.0.0.1" in line:
                continue
            parts = line.split()
            ip = parts[1]
            mask = "255.255.255.0"
            if "netmask" in parts:
                raw = parts[parts.index("netmask") + 1]
                if raw.startswith("0x"):
                    v = int(raw, 16)
                    mask = ".".join(str((v >> sh) & 0xFF) for sh in (24, 16, 8, 0))
                else:
                    mask = raw
            nets.append((ip, mask))
    except (OSError, subprocess.SubprocessError):
        pass
    return nets


def _hosts_in(ip, mask):
    """Addresses to scan. Networks wider than /22 are trimmed to the /24 around us."""
    a = [int(x) for x in ip.split(".")]
    m = [int(x) for x in mask.split(".")]
    bits = sum(bin(x).count("1") for x in m)
    if bits < 22:
        bits, m = 24, [255, 255, 255, 0]
    base = [a[i] & m[i] for i in range(4)]
    count = 1 << (32 - bits)
    base_int = (base[0] << 24) | (base[1] << 16) | (base[2] << 8) | base[3]
    out = []
    for i in range(1, count - 1):
        v = base_int + i
        out.append(f"{(v >> 24) & 255}.{(v >> 16) & 255}.{(v >> 8) & 255}.{v & 255}")
    return out


def probe(host, timeout=1.5):
    """Is there a Philips TV at this address? Returns the /system dict or None.

    /6/system is unauthenticated, so this also works before pairing.
    """
    try:
        with socket.create_connection((host, PORT), timeout=0.7):
            pass
    except OSError:
        return None
    try:
        r = requests.get(
            f"https://{host}:{PORT}/{API}/system", verify=False, timeout=timeout
        )
        if r.status_code != 200:
            return None
        info = r.json()
    except (requests.RequestException, ValueError):
        return None
    return info if "name" in info and "api_version" in info else None


def discover(want_deviceid=None, verbose=False):
    """Scan local subnets for the TV. Returns (host, info) or (None, None).

    If `deviceid_encrypted` is known from a previous pairing, pick exactly that
    unit; otherwise the first TV that answers on JointSpace.
    """
    targets = []
    for ip, mask in _local_ipv4_networks():
        for h in _hosts_in(ip, mask):
            if h != ip and h not in targets:
                targets.append(h)
    if verbose:
        print(f"Scanning {len(targets)} addresses on port {PORT}...", file=sys.stderr)

    hits = []
    with ThreadPoolExecutor(max_workers=128) as pool:
        for host, info in zip(targets, pool.map(probe, targets)):
            if info:
                hits.append((host, info))
                if verbose:
                    print(f"  found {host}: {info.get('name')}", file=sys.stderr)

    if not hits:
        return None, None
    if want_deviceid:
        for host, info in hits:
            if info.get("deviceid_encrypted") == want_deviceid:
                return host, info
    return hits[0]


_HOST = None


def resolve_host(quiet=True):
    """Resolve the TV address: environment variable -> saved host -> network scan."""
    global _HOST
    if _HOST:
        return _HOST
    if TV_HOST_ENV:
        _HOST = TV_HOST_ENV
        return _HOST

    cfg = {}
    try:
        with open(CONFIG) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        pass

    saved = cfg.get("host")
    if saved and probe(saved):
        _HOST = saved
        return _HOST

    if not quiet or saved:
        print(
            f"TV not responding at {saved or 'the saved address'} — searching the network...",
            file=sys.stderr,
        )
    host, info = discover(want_deviceid=cfg.get("deviceid"))
    if not host:
        sys.exit(
            "No TV found on the local network.\n"
            "Check that the TV is on and on the same network, or set it manually:\n"
            "  PHILIPS_TV_HOST=192.168.x.y ./philips.py ..."
        )
    print(f"Found {info.get('name')} at {host}", file=sys.stderr)
    if cfg:
        cfg["host"] = host
        cfg["deviceid"] = info.get("deviceid_encrypted")
        save_config(cfg)
    _HOST = host
    return _HOST


def auth(cfg=None):
    cfg = cfg or load_config()
    return HTTPDigestAuth(cfg["device_id"], cfg["auth_key"])


def _check(r, path):
    if r.status_code == 403:
        sys.exit(
            f"403 for /{path} – this endpoint is not exposed on Titan OS "
            "('applications' and 'sources', among others, are Android-only)."
        )
    if r.status_code == 401:
        sys.exit("401 – credentials rejected. Pair again: ./philips.py pair")
    r.raise_for_status()
    if not r.text.strip():
        return None
    try:
        return r.json()
    except ValueError:
        return r.text.strip()  # the TV answers POSTs with plain text, not JSON


def get(path, **kw):
    r = requests.get(f"{base_url()}/{path}", auth=auth(), verify=False, timeout=8, **kw)
    return _check(r, path)


def post(path, payload, **kw):
    r = requests.post(
        f"{base_url()}/{path}", json=payload, auth=auth(), verify=False, timeout=8, **kw
    )
    return _check(r, path)


PENDING = os.path.expanduser("~/.config/philips-tv/.pending.json")


def pair_request():
    """Step 1: ask the TV to pair – a PIN appears on screen."""
    device_id = "".join(random.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(16))
    device = dict(DEVICE, id=device_id)

    print(f"Requesting pairing with {resolve_host()} ...")
    r = requests.post(
        f"{base_url()}/pair/request",
        json={"scope": ["read", "write", "control"], "device": device},
        verify=False,
        timeout=10,
    )
    r.raise_for_status()
    resp = r.json()
    if resp.get("error_id") != "SUCCESS":
        sys.exit(f"TV rejected the request: {resp}")

    os.makedirs(os.path.dirname(PENDING), exist_ok=True)
    with open(PENDING, "w") as f:
        json.dump(
            {
                "device": device,
                "auth_key": resp["auth_key"],
                "timestamp": resp["timestamp"],
                "requested_at": time.time(),
            },
            f,
        )
    os.chmod(PENDING, stat.S_IRUSR | stat.S_IWUSR)
    print(f"PIN shown on the TV, valid for ~{resp.get('timeout', 60)} s.")
    print("Now run: ./philips.py pair-grant <PIN>")
    return resp


def pair_grant(pin):
    """Step 2: confirm with the PIN and save credentials."""
    try:
        with open(PENDING) as f:
            pending = json.load(f)
    except FileNotFoundError:
        sys.exit("No pairing in progress. Run first: ./philips.py pair-request")

    device = pending["device"]
    device_id = device["id"]
    auth_key = pending["auth_key"]
    timestamp = pending["timestamp"]
    pin = pin.strip()

    elapsed = time.time() - pending.get("requested_at", time.time())
    print(f"[diag] {elapsed:.1f} s since pair-request, PIN={pin!r} ({len(pin)} chars)")

    # Note: the 65PUS8919 (Titan OS) signs with the RAW SHA-1 digest → base64.
    # Android TV uses base64 of the hexdigest – that variant returns INVALID_PIN here.
    signature = base64.b64encode(
        hmac.new(SECRET_KEY, (str(timestamp) + pin).encode(), hashlib.sha1).digest()
    ).decode()

    grant = {
        "auth": {
            "auth_AppId": "1",
            "pin": pin,
            "auth_timestamp": timestamp,
            "auth_signature": signature,
        },
        "device": device,
    }
    r = requests.post(
        f"{base_url()}/pair/grant",
        json=grant,
        auth=HTTPDigestAuth(device_id, auth_key),
        verify=False,
        timeout=10,
    )
    if r.status_code != 200:
        sys.exit(f"Pairing failed ({r.status_code}): {r.text}")
    resp = r.json()
    if resp.get("error_id") != "SUCCESS":
        sys.exit(f"Pairing failed: {resp}")

    save_config({
        "host": resolve_host(),
        "deviceid": (probe(resolve_host()) or {}).get("deviceid_encrypted"),
        "device_id": device_id,
        "auth_key": auth_key,
    })
    os.remove(PENDING)
    print(f"OK. Credentials saved to {CONFIG} (chmod 600).")


def pair():
    """Interactive variant: request + PIN typed on the keyboard."""
    pair_request()
    pair_grant(input("Enter the PIN from the TV screen: "))


def _sig_variants(timestamp, pin):
    """auth_signature candidates – different platforms compute it differently."""
    ts = str(timestamp)
    key_raw = SECRET_KEY
    key_b64 = (
        "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA=="
    ).encode()

    def h(key, msg, alg):
        return hmac.new(key, msg, alg)

    msg = (ts + pin).encode()
    msg_rev = (pin + ts).encode()

    return [
        ("sha1/hex→b64 (reference)", base64.b64encode(h(key_raw, msg, hashlib.sha1).hexdigest().encode()).decode()),
        ("sha1/digest→b64", base64.b64encode(h(key_raw, msg, hashlib.sha1).digest()).decode()),
        ("sha1/hex", h(key_raw, msg, hashlib.sha1).hexdigest()),
        ("sha256/hex→b64", base64.b64encode(h(key_raw, msg, hashlib.sha256).hexdigest().encode()).decode()),
        ("sha256/digest→b64", base64.b64encode(h(key_raw, msg, hashlib.sha256).digest()).decode()),
        ("sha1/hex→b64, key as b64 text", base64.b64encode(h(key_b64, msg, hashlib.sha1).hexdigest().encode()).decode()),
        ("sha1/hex→b64, order pin+ts", base64.b64encode(h(key_raw, msg_rev, hashlib.sha1).hexdigest().encode()).decode()),
        ("PIN only, no signature", ""),
    ]


def pair_debug():
    """One pairing window, many signature variants – finds the right algorithm."""
    resp = pair_request()
    print("\n[diag] raw pair/request response:")
    print(json.dumps(resp, indent=2))

    pin = input("\nEnter the PIN from the TV screen: ").strip()

    with open(PENDING) as f:
        pending = json.load(f)
    device, auth_key, timestamp = pending["device"], pending["auth_key"], pending["timestamp"]
    session = requests.Session()
    session.auth = HTTPDigestAuth(device["id"], auth_key)
    session.verify = False

    for label, signature in _sig_variants(timestamp, pin):
        payload = {
            "auth": {
                "auth_AppId": "1",
                "pin": pin,
                "auth_timestamp": timestamp,
                "auth_signature": signature,
            },
            "device": device,
        }
        try:
            r = session.post(f"{base_url()}/pair/grant", json=payload, timeout=6)
            body = r.json() if r.text.strip() else {}
        except Exception as e:  # noqa: BLE001 – diagnostics, we want every error
            print(f"  ✗ {label:<38} exception: {e}")
            continue

        status = body.get("error_id", r.status_code)
        if status == "SUCCESS":
            save_config({
                "host": resolve_host(),
                "deviceid": (probe(resolve_host()) or {}).get("deviceid_encrypted"),
                "device_id": device["id"],
                "auth_key": auth_key,
            })
            os.remove(PENDING)
            print(f"\n  ✓ WORKED: {label}")
            print(f"Credentials saved to {CONFIG}")
            return
        print(f"  ✗ {label:<38} {status}")

    print("\nNo variant succeeded – the results above show where to look next.")


KEYS = """Standby Back Find RedColour GreenColour YellowColour BlueColour Home VolumeUp
VolumeDown Mute Options Dot Digit0 Digit1 Digit2 Digit3 Digit4 Digit5 Digit6 Digit7 Digit8
Digit9 Info CursorUp CursorDown CursorLeft CursorRight Confirm Next Previous Adjust WatchTV
Viewmode Teletext Subtitle ChannelStepUp ChannelStepDown Source AmbilightOnOff PlayPause Pause
FastForward Stop Rewind Record Online""".split()


def resolve_key(name):
    for k in KEYS:
        if k.lower() == name.lower():
            return k
    matches = [k for k in KEYS if name.lower() in k.lower()]
    if len(matches) == 1:
        return matches[0]
    sys.exit(f"Unknown key {name!r}. Candidates: {matches or 'none'}")


def cmd_apps():
    return get("applications")["applications"]


def main(argv):
    if not argv:
        print(__doc__)
        return

    cmd, args = argv[0], argv[1:]

    if cmd == "discover":
        host, info = discover(verbose=True)
        if not host:
            sys.exit("No TV found on the local network.")
        print(f"{info.get('name')}  ->  {host}")
        try:
            with open(CONFIG) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            cfg = None
        if cfg:
            cfg["host"] = host
            cfg["deviceid"] = info.get("deviceid_encrypted")
            save_config(cfg)
            print(f"Saved address to {CONFIG}")

    elif cmd == "pair":
        pair()

    elif cmd == "pair-request":
        pair_request()

    elif cmd == "pair-grant":
        pair_grant(args[0])

    elif cmd == "pair-debug":
        pair_debug()

    elif cmd == "info":
        print(json.dumps(get("system"), indent=2, ensure_ascii=False))

    elif cmd == "keys":
        print("\n".join(KEYS))

    elif cmd == "trykey":
        # The TV returns 200 for ANY string, even non-existent keys – the only reliable
        # test is to watch the screen. By default it tries the playback keys.
        candidates = args or ["PlayPause", "Pause", "Play", "Confirm", "Stop", "Options"]
        print("Play something on the TV, then watch the screen after each key.\n")
        working = []
        for k in candidates:
            input(f"  Enter = send {k!r} ... ")
            post("input/key", {"key": k})
            if input(f"    did it work? [y/N] ").strip().lower() in ("t", "y"):
                working.append(k)
        print("\nWorking keys:", ", ".join(working) if working else "none")

    elif cmd == "key":
        for name in args:
            post("input/key", {"key": resolve_key(name)})
            time.sleep(0.15)
        print("sent:", " ".join(args))

    elif cmd == "apps":
        for a in cmd_apps():
            print(f"{a['label']:<30} {a['intent']['component']['packageName']}")

    elif cmd == "launch":
        needle = " ".join(args).lower()
        hits = [a for a in cmd_apps() if needle in a["label"].lower()]
        if not hits:
            sys.exit(f"No app found matching {needle!r}")
        app = hits[0]
        post("activities/launch", {"intent": app["intent"]})
        print("launched:", app["label"])

    elif cmd == "volume":
        if args:
            post("audio/volume", {"muted": False, "current": int(args[0])})
            print("volume:", args[0])
        else:
            print(json.dumps(get("audio/volume"), indent=2))

    elif cmd == "mute":
        post("input/key", {"key": "Mute"})
        print("mute")

    elif cmd == "power":
        if not args or args[0] == "status":
            print(get("powerstate")["powerstate"])
        else:
            state = "On" if args[0] == "on" else "Standby"
            post("powerstate", {"powerstate": state})
            print("powerstate ->", state)

    elif cmd == "ambilight":
        if not args:
            print(json.dumps(get("ambilight/currentconfiguration"), indent=2))
        elif args[0] == "styles":
            for s in get("ambilight/supportedstyles")["supportedStyles"]:
                algos = ", ".join(s.get("algorithms", []))
                print(f"{s['styleName']:<16} {algos}")
        elif args[0] == "off":
            post("ambilight/power", {"power": "Off"})
            print("ambilight off")
        elif args[0] == "on":
            post("ambilight/power", {"power": "On"})
            print("ambilight on")
        else:
            post("ambilight/currentconfiguration", {"styleName": args[0], "isExpert": False})
            print("ambilight ->", args[0])

    elif cmd == "get":
        print(json.dumps(get(args[0]), indent=2, ensure_ascii=False))

    elif cmd == "post":
        print(json.dumps(post(args[0], json.loads(args[1])), indent=2, ensure_ascii=False))

    else:
        sys.exit(f"Unknown command: {cmd}\n{__doc__}")


if __name__ == "__main__":
    main(sys.argv[1:])
