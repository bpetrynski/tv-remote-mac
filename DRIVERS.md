# Writing a TV Remote driver

A driver teaches TV Remote to talk to one kind of TV. It is a folder with two files:

```
MyTV/
  driver.json   what the driver is and how to start it
  driver.py     the program (any language: Python, Node, Go, a shell script…)
```

Put the folder into `~/Library/Application Support/TV Remote/Drivers/` (Settings →
Supported TVs → Open Drivers Folder) and restart the app. Your TVs show up in
"Add TV…" next to the built-in ones. The bundled drivers (`appletv`, `androidtv`) are
complete examples; copy one and change it.

## driver.json

```json
{
  "id": "mytv",
  "name": "My TV brand",
  "run": [["{python}", "-I", "driver.py"]],
  "requirements": ["some-python-library"],
  "bonjour": ["_mytv-remote._tcp"],
  "install_hint": "Install it in Settings → Supported TVs.",
  "works": ["Which models work, and what you tested on."],
  "does_not_work": ["Which models or features do not."],
  "notes": ["Anything a user should know: pairing, power-on from standby…"]
}
```

| key | meaning |
|---|---|
| `id` | Unique, lowercase. Stored with each paired TV; do not change it later. |
| `run` | Candidate command lines, tried in order; the first whose program exists is used. Runs in the driver's folder. `~/` is expanded, bare names are looked up in `PATH` and Homebrew folders. |
| `requirements` | Optional Python packages. `{python}` in `run` is then a private virtual environment that the app creates and fills on "Install" (with `uv` if available, else `python3 -m venv` + pip). |
| `bonjour` | Optional Bonjour service types. The app browses for them (through macOS, so the driver never listens on a port and the firewall stays quiet) and passes the addresses to `discover` as `hosts`. Without it, `discover` gets no `hosts` and must search by itself. |
| `works`, `does_not_work`, `notes` | Shown in Settings → Supported TVs. Be honest: say what you tested. |

The environment variable `TVREMOTE_DATA` points to a folder the driver may use for its own
files (certificates, keys). Write logs to **stderr**: the app keeps them in
`~/Library/Logs/TV Remote/<id>.log`. Stdout is reserved for replies.

## Protocol

The app starts the program once and keeps it running. It writes one JSON request per line
to stdin and expects exactly one JSON reply per line on stdout, in the same order:

```
→ {"id": 7, "op": "action", "action": "up"}
← {"id": 7, "ok": true, "result": null}
← {"id": 8, "ok": false, "error": "The TV is not answering.", "code": null}
```

Handle requests one at a time, in order (key presses must not overtake each other). When
stdin closes, the app has quit: disconnect and exit.

`code` in an error reply is optional:

| code | the app… |
|---|---|
| `not_connected` | reconnects (`connect`) and repeats the request once |
| `unauthorized` | shows "pair again" and does not search the network |
| `unavailable` | shows the error as a setup problem (missing library) |

### Operations

| op | request | result |
|---|---|---|
| `hello` | – | `{"ready": true}` or `{"ready": false, "error": "what is missing"}` |
| `discover` | `hosts` (optional list: check only these addresses; also used for an address typed by hand) | list of `{"id", "name", "host", "model"?}`. `id` must be stable per physical device (MAC, serial). |
| `pair_begin` | `tv`: `{"id", "host"}` | `{"prompt": "Enter the PIN shown on the TV."}` — make the TV show its PIN |
| `pair_finish` | `pin` | `{"data": {...}, "name"?, "host"?}` — `data` (strings only) is stored and passed back on `connect` |
| `pair_cancel` | – | `null` |
| `connect` | `tv`: `{"id", "host", "name", "data"}` | `{"host": "current address", "actions": [...]}`. Try only the given address and fail fast: if the TV moved, the app runs `discover`, matches the `id` and calls `connect` again. |
| `disconnect` | – | `null` |
| `action` | `action` (one of the action names below) | `null` |
| `status` | – | see below |
| `pick` | `picker`, `option` | `null` |
| `volume` | `value` (absolute level) | `null` (only if you support it; otherwise return an error) |
| `text_get` | – | `{"text": "what the focused field holds"}`, or `{"text": null}` if unknown. The typing field opens with it, so old text can be edited. Optional. |
| `text` | `text`, `previous`, `submit` | `null` — make the focused text field read `text`. `previous` is what the app sent before (the TV's cursor is after it), so you can either replace the whole field or delete the changed tail and type the rest. `submit: true` presses Enter afterwards. Only sent if `connect` listed `keyboard`. |

**Actions**: `up down left right ok back home options info source playPause play pause rewind
forward volumeUp volumeDown mute power keyboard`. `keyboard` is not a button: it says the driver
handles `text`, and the remote then offers a field for typing (K). `playPause` is the native toggle (Space); without it
the app toggles by sending `play` and `pause` in turn. Report in `connect` only those the TV really has; the
remote hides the other buttons. `power` toggles: decide on or standby yourself.

**Status**:

```json
{
  "power": "On",
  "volume": 12, "volume_max": 100, "muted": false,
  "picker": {
    "id": "apps", "label": "App", "symbol": "square.grid.2x2",
    "current": null,
    "options": [{"id": "com.example.app", "title": "Example"}]
  }
}
```

`power` is a short word shown in the header (`On` and `Standby` get colours). Omit
`volume` if the TV does not report it. The optional `picker` adds one control under the
remote: with `current` set it is a selection (like Ambilight styles), with `current: null`
a menu of one-off actions (like opening apps). `symbol` is an SF Symbols name.

## Testing without the app

Pipe requests in and read the replies:

```bash
printf '%s\n' '{"id":1,"op":"hello"}' '{"id":2,"op":"discover"}' | python3 driver.py
```

Keep test runs read-only (`hello`, `discover`, `connect`, `status`) unless someone is
watching the TV: `action` and `pick` change what is on screen.
