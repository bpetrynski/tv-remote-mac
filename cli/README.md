# Philips TV command-line tools

Two Python scripts for Philips TVs over the JointSpace API v6 (HTTPS on port 1926, digest
auth), written while working out how the 65PUS8919 (Titan OS) pairs and which keys it takes.

- `philips.py` — a full CLI: discovery, pairing, keys, volume, power, Ambilight, raw API calls.
- `titan-os-reference.py` — a short, self-contained reference of the pairing and key flow.

```bash
pip install -r requirements.txt     # requests
```

## philips.py

```bash
./philips.py discover               # find the TV on the network and remember its address
./philips.py pair                   # one-time pairing, PIN from the TV screen (30 s window)
./philips.py power status           # On / Standby
./philips.py power on|off
./philips.py volume                 # read (0–60 on this model)
./philips.py volume 12
./philips.py mute
./philips.py key Home               # remote key, matched by fragment
./philips.py key CursorUp Confirm   # several at once
./philips.py keys                   # list of key codes
./philips.py ambilight              # current configuration
./philips.py ambilight styles
./philips.py ambilight off|on|FOLLOW_AUDIO
./philips.py get powerstate         # raw GET
./philips.py post input/key '{"key":"Mute"}'
```

Credentials are stored in `~/.config/philips-tv/config.json` (mode 600). The TV Remote app
reads and writes the same file, so a TV paired here shows up in the app and the other way
round. `PHILIPS_TV_HOST` overrides the address.

### Finding the TV

The address comes from `PHILIPS_TV_HOST`, then the saved address (if the TV answers there),
then a scan of the local subnets: a parallel connect to port 1926 followed by `GET /6/system`.
That endpoint needs no authentication, works before pairing and returns `deviceid_encrypted`,
which pairing stores as `deviceid`, so with several TVs on the network the paired one is hit.
A `/24` takes about 2 s. Networks wider than `/22` are cut down to the `/24` around the Mac's
own address. A found address is saved, so after a new DHCP lease only the first call is slower.

Bonjour does not help: Titan OS does not announce `_philipstv_s_rpc._tcp` or
`_philipstv_rpc._tcp` (checked by listening), hence the port scan.

## Findings for the 65PUS8919 (Titan OS)

**The pairing signature differs from Android TV.** This was behind a persistent `INVALID_PIN`
with the right PIN, in time:

| Platform | `auth_signature` |
|---|---|
| Android TV (reference descriptions, pylips) | base64(**hexdigest** of HMAC-SHA1) |
| **65PUS8919 / Titan OS** | base64(**raw digest** of HMAC-SHA1) |

The signed payload and the shared key are the same: `HMAC-SHA1(secret_key, str(timestamp) + pin)`.
`philips.py pair-debug` tries 8 signature variants within one 30-second pairing window.

**Android endpoints are missing** (HTTP 403): `applications`, `sources`. No list of installed
apps and no HDMI input switching through this API; apps are opened by navigating with keys.

Answering: `system`, `powerstate`, `audio/volume`, `input/key`, `input/textentry`,
`activities/current`, `activities/tv`, `ambilight/*`, `channeldb/tv`,
`menuitems/settings/structure`, `screenstate`, `context`.

**The TV answers `200 Ok` to any key name**, including made-up ones and an empty string.
Unknown keys are dropped silently, so the HTTP status never confirms that a key works; only
the screen does. `philips.py trykey` sends one key and asks whether anything happened.

Checked on screen:

| Works | Does not work |
|---|---|
| `Play`, `Pause`, `Confirm`, `Options` | `PlayPause`, `Stop` |

There is no play/pause toggle: `Play` and `Pause` are separate keys.

**Security.** The TV's certificate is self-signed, so verification is off. `auth_key` is a
real credential for controlling the TV; pairing again invalidates it.
