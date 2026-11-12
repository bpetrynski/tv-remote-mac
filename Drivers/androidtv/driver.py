"""Android TV / Google TV driver for TV Remote, built on androidtvremote2
(https://github.com/tronikos/androidtvremote2): the Android TV Remote protocol v2 used by
Google's own TV remote app and by Home Assistant's "Android TV Remote" integration.

Speaks the TV Remote driver protocol (DRIVERS.md): one JSON request per line on stdin,
one JSON reply per line on stdout. Logs go to stderr.

The client certificate this Mac pairs with lives in $TVREMOTE_DATA (set by the app).
"""

import asyncio
import html
import json
import logging
import os
import re
import socket
import sys
import time
import urllib.request

try:
    from androidtvremote2 import AndroidTVRemote, CannotConnect, ConnectionClosed, InvalidAuth
    from androidtvremote2.remotemessage_pb2 import RemoteMessage
    from zeroconf import ServiceStateChange
    from zeroconf.asyncio import AsyncServiceBrowser, AsyncServiceInfo, AsyncZeroconf
except ImportError:  # reported by `hello`
    AndroidTVRemote = None

log = logging.getLogger("androidtv")

SERVICE = "_androidtvremote2._tcp.local."
CLIENT_NAME = "TV Remote"
DATA = os.environ.get("TVREMOTE_DATA") or os.path.expanduser("~/Library/Application Support/TV Remote/androidtv")
CERT = os.path.join(DATA, "cert.pem")
KEY = os.path.join(DATA, "key.pem")

# Remote button -> Android key code (without the KEYCODE_ prefix).
KEYS = {
    "up": "DPAD_UP", "down": "DPAD_DOWN", "left": "DPAD_LEFT", "right": "DPAD_RIGHT",
    "ok": "DPAD_CENTER", "back": "BACK", "home": "HOME",
    "options": "SETTINGS", "info": "INFO", "source": "TV_INPUT",
    "playPause": "MEDIA_PLAY_PAUSE", "play": "MEDIA_PLAY", "pause": "MEDIA_PAUSE",
    "rewind": "MEDIA_REWIND", "forward": "MEDIA_FAST_FORWARD",
    "volumeUp": "VOLUME_UP", "volumeDown": "VOLUME_DOWN", "mute": "VOLUME_MUTE",
    "power": "POWER",
}

# The protocol cannot list installed apps; these are launched by package name
# (an app that is not installed opens its Play Store page instead).
APPS = [
    ("com.google.android.youtube.tv", "YouTube"),
    ("com.netflix.ninja", "Netflix"),
    ("com.amazon.amazonvideo.livingroom", "Prime Video"),
    ("com.disney.disneyplus", "Disney+"),
    ("com.wbd.stream", "Max"),
    ("com.apple.atve.androidtv.appletv", "Apple TV"),
    ("com.spotify.tv.android", "Spotify"),
    ("com.plexapp.android", "Plex"),
    ("org.xbmc.kodi", "Kodi"),
]


# Deep links the apps themselves answer to (as used by Home Assistant). Other apps start
# through android-app://<package>, then market://launch (needs the Play Store).
LINKS = {
    "com.google.android.youtube.tv": "https://www.youtube.com",
    "com.netflix.ninja": "https://www.netflix.com/title",
    "com.amazon.amazonvideo.livingroom": "https://app.primevideo.com",
    "com.disney.disneyplus": "https://www.disneyplus.com",
    "com.wbd.stream": "https://play.max.com",
    "com.spotify.tv.android": "spotify://",
    "com.plexapp.android": "plex://",
}


class DeviceErrors(logging.Handler):
    """androidtvremote2 only logs when the TV rejects a request; catch that for app links."""

    def __init__(self):
        super().__init__()
        self.rejected = []

    def emit(self, record):
        message = record.getMessage()
        if "error from the device" in message and "app_link" in message:
            self.rejected.append(message)


DEVICE_ERRORS = DeviceErrors()
logging.getLogger("androidtvremote2").addHandler(DEVICE_ERRORS)

# Packages that are the TV itself rather than an app someone opened.
NOT_APPS = ("launcher", "settings", "systemui", "tvrecommendations", "android.tv.home", "packageinstaller")
RECENT_TILES = 4


class AppCatalog:
    """Recently used apps per TV, with names and icons from the app's Google Play page.

    Android TV Remote cannot list installed apps, but reports the app in the foreground.
    That feeds the "recent" list; names and icons are fetched once and cached in DATA.
    """

    def __init__(self, loop):
        self.loop = loop
        self.folder = os.path.join(DATA, "apps")
        self.icons = os.path.join(self.folder, "icons")
        os.makedirs(self.icons, exist_ok=True)
        self.meta = self._read("catalog.json", {})
        for pkg, title in APPS:
            self.meta.setdefault(pkg, {})["title"] = title
        self.fetching = set()

    def _read(self, name, default):
        try:
            with open(os.path.join(self.folder, name)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return default

    def _write(self, name, value):
        path = os.path.join(self.folder, name)
        with open(path + ".tmp", "w") as f:
            json.dump(value, f, indent=1)
        os.replace(path + ".tmp", path)

    @staticmethod
    def is_app(pkg):
        return bool(pkg) and not any(word in pkg for word in NOT_APPS)

    def recent(self, tv_id):
        return self._read(f"recent-{tv_id.replace(':', '')}.json", [])

    def used(self, tv_id, pkg):
        """Moves an app to the front of the TV's recent list."""
        if not self.is_app(pkg):
            return
        recent = [p for p in self.recent(tv_id) if p != pkg]
        recent.insert(0, pkg)
        self._write(f"recent-{tv_id.replace(':', '')}.json", recent[:20])
        self.ensure([pkg])

    def remember_link(self, pkg, link):
        """The link format this TV accepted for the app; tried first next time."""
        entry = self.meta.setdefault(pkg, {})
        if entry.get("link") != link:
            entry["link"] = link
            self._write("catalog.json", self.meta)

    def option(self, pkg):
        info = self.meta.get(pkg, {})
        icon = info.get("icon")
        option = {"id": pkg, "title": info.get("title") or pkg.split(".")[-1].capitalize()}
        if icon and os.path.exists(icon):
            option["icon"] = icon
        return option

    def ensure(self, packages):
        """Fetches missing names and icons in the background (once per app)."""
        for pkg in packages:
            if pkg in self.fetching or self.meta.get(pkg, {}).get("checked"):
                continue
            self.fetching.add(pkg)
            self.loop.create_task(self._fetch(pkg))

    async def _fetch(self, pkg):
        try:
            title, icon = await asyncio.to_thread(self._download, pkg)
            entry = self.meta.setdefault(pkg, {})
            entry["checked"] = int(time.time())
            if title and pkg not in dict(APPS):
                entry["title"] = title
            if icon:
                entry["icon"] = icon
            self._write("catalog.json", self.meta)
        except Exception as e:  # no network or no Play page (sideloaded app): keep the name only
            log.info("no store info for %s: %s", pkg, e)
            self.meta.setdefault(pkg, {})["checked"] = int(time.time())
            self._write("catalog.json", self.meta)
        finally:
            self.fetching.discard(pkg)

    def _download(self, pkg):
        url = f"https://play.google.com/store/apps/details?id={pkg}&hl=en"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as r:
            page = r.read().decode("utf-8", "replace")

        def meta(prop):
            m = re.search(rf'<meta property="og:{prop}" content="([^"]*)"', page)
            return html.unescape(m.group(1)) if m else None

        title = meta("title")
        if title:
            title = re.sub(r"\s*-\s*Apps on Google Play$", "", title)
            title = re.sub(r"\s*(for Android TV|\(Android TV\)|- Android TV)$", "", title, flags=re.I)
        icon = None
        image = meta("image")
        if image:
            image = re.sub(r"=[^=/]*$", "", image) + "=s128"
            req = urllib.request.Request(image, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=10) as r:
                kind = r.headers.get("Content-Type", "")
                ext = "webp" if "webp" in kind else "jpg" if "jpeg" in kind else "png"
                icon = os.path.join(self.icons, f"{pkg}.{ext}")
                with open(icon, "wb") as f:
                    f.write(r.read())
        return title, icon


class DriverError(Exception):
    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


class Driver:
    def __init__(self, loop):
        self.loop = loop
        self.remote = None
        self.pairing = None
        self.tv_id = None
        self.tv = None
        self.ime = False
        self.field = None  # text of the focused field on the TV, when it has told us
        self.catalog = AppCatalog(loop) if AndroidTVRemote else None

    def _client(self, host, ime=False):
        # Without the IME channel the TV keeps its own on-screen keyboard. With it, a focused
        # text field shows "use the keyboard on your mobile device" instead: so it is only
        # switched on once the user starts typing from the Mac.
        os.makedirs(DATA, exist_ok=True)
        return AndroidTVRemote(CLIENT_NAME, CERT, KEY, host, loop=self.loop, enable_ime=ime)

    @staticmethod
    async def _ensure_cert(client):
        """The private key pairs this Mac with every TV: keep it readable by the user only."""
        await client.async_generate_cert_if_missing()
        os.chmod(KEY, 0o600)

    async def _identify(self, host):
        """Name and MAC from the TV's certificate; works before pairing."""
        client = self._client(host)
        await self._ensure_cert(client)
        try:
            name, mac = await asyncio.wait_for(client.async_get_name_and_mac(), 3)
        finally:
            client.disconnect()
        return {"id": mac.lower(), "name": name, "host": host}

    async def _browse(self, seconds=3.0):
        """Addresses of Android TV Remote services announced over mDNS."""
        hosts = set()
        aiozc = AsyncZeroconf()

        def on_change(zeroconf, service_type, name, state_change):
            if state_change is ServiceStateChange.Added:
                found.append(name)

        found = []
        browser = AsyncServiceBrowser(aiozc.zeroconf, [SERVICE], handlers=[on_change])
        try:
            await asyncio.sleep(seconds)
            for name in found:
                info = AsyncServiceInfo(SERVICE, name)
                if await info.async_request(aiozc.zeroconf, 1500):
                    for addr in info.addresses:
                        if len(addr) == 4:
                            hosts.add(socket.inet_ntoa(addr))
        finally:
            await browser.async_cancel()
            await aiozc.async_close()
        return sorted(hosts)

    async def _find_all(self, hosts=None):
        """Identify the given addresses. Without addresses the driver browses mDNS itself,
        which listens on a port (only used when running the driver by hand)."""
        hosts = hosts or await self._browse()
        results = await asyncio.gather(*(self._identify(h) for h in hosts), return_exceptions=True)
        return [r for r in results if isinstance(r, dict)]

    def _need_remote(self):
        if self.remote is None:
            raise DriverError("not connected", "not_connected")
        return self.remote

    # -- operations --------------------------------------------------------------

    async def op_hello(self, req):
        if AndroidTVRemote is None:
            return {"ready": False, "error": "androidtvremote2 is not installed."}
        return {"ready": True}

    async def op_discover(self, req):
        return await self._find_all(req.get("hosts") or ([req["host"]] if req.get("host") else None))

    async def op_pair_begin(self, req):
        tv = req["tv"]
        await self.op_pair_cancel(req)
        self.pairing = self._client(tv["host"])
        await self._ensure_cert(self.pairing)
        try:
            await self.pairing.async_start_pairing()
        except CannotConnect:
            raise DriverError("The TV is not answering. Make sure it is on.")
        return {"prompt": "Enter the code shown on the TV (6 characters)."}

    async def op_pair_finish(self, req):
        if self.pairing is None:
            raise DriverError("Start pairing first.")
        code = str(req.get("pin", "")).strip().upper()
        try:
            await self.pairing.async_finish_pairing(code)
        except InvalidAuth:
            raise DriverError("Wrong code. Try again.")
        except ConnectionClosed:
            self.pairing = None
            raise DriverError("The TV closed the pairing. Start again.")
        self.pairing = None
        return {"data": {}}

    async def op_pair_cancel(self, req):
        if self.pairing is not None:
            pairing, self.pairing = self.pairing, None
            pairing.disconnect()
        return None

    async def op_connect(self, req):
        return await self._connect(req["tv"], ime=False)

    async def _connect(self, tv, ime):
        await self.op_disconnect({})
        host = tv.get("host")
        remote = self._client(host, ime)
        try:
            await asyncio.wait_for(remote.async_connect(), 5)
        except InvalidAuth:
            remote.disconnect()
            raise DriverError("The TV no longer accepts this Mac. Add it again.", "unauthorized")
        except (CannotConnect, ConnectionClosed, asyncio.TimeoutError):
            # If the TV moved, the app finds it (Bonjour) and retries with the new address.
            remote.disconnect()
            raise DriverError("The TV is not answering at its last address.")
        remote.keep_reconnecting()
        self.remote = remote
        self.tv = tv
        self.ime = ime
        self.field = None
        if ime:
            self._watch_field(remote)
        self.tv_id = tv["id"].lower()
        # Every app opened on the TV, also with its own remote, joins the recent list.
        tv_id = self.tv_id
        remote.add_current_app_updated_callback(lambda pkg: self.catalog.used(tv_id, pkg))
        if remote.current_app:
            self.catalog.used(tv_id, remote.current_app)
        self.catalog.ensure([pkg for pkg, _ in APPS] + self.catalog.recent(tv_id))
        return {"host": host, "actions": sorted(KEYS) + ["keyboard"]}

    async def op_disconnect(self, req):
        if self.remote is not None:
            remote, self.remote = self.remote, None
            remote.disconnect()
        return None

    async def op_action(self, req):
        remote = self._need_remote()
        key = KEYS.get(req.get("action"))
        if key is None:
            raise DriverError(f"Android TV has no “{req.get('action')}” button.")
        try:
            remote.send_key_command(key)
        except ConnectionClosed:
            raise DriverError("not connected", "not_connected")
        return None

    async def op_status(self, req):
        remote = self._need_remote()
        on = remote.is_on
        result = {"power": "connected" if on is None else ("On" if on else "Standby")}
        volume = remote.volume_info
        if volume:
            result.update(volume=volume["level"], volume_max=volume["max"] or 100, muted=volume["muted"])
        # Recent apps first; popular ones fill the tiles until there is enough history.
        recent = self.catalog.recent(self.tv_id)
        tiles = (recent + [p for p, _ in APPS if p not in recent])[:RECENT_TILES]
        known = list(dict.fromkeys(recent + [p for p, _ in APPS]))
        options = sorted((self.catalog.option(p) for p in known), key=lambda o: o["title"].lower())
        result["picker"] = {
            "id": "apps", "label": "App", "symbol": "square.grid.2x2", "current": None,
            "options": options, "recent": tiles, "active": remote.current_app,
        }
        return result

    async def op_pick(self, req):
        remote = self._need_remote()
        if req.get("picker") != "apps":
            raise DriverError("Unknown picker.")
        option = req["option"]
        if "://" in option:
            links = [option]
        else:
            known = self.catalog.meta.get(option, {}).get("link")
            links = list(dict.fromkeys(
                [known, LINKS.get(option), f"android-app://{option}", f"market://launch?id={option}"]))
            links = [link for link in links if link]
        for link in links:
            seen = len(DEVICE_ERRORS.rejected)
            try:
                remote.send_launch_app_command(link)
            except ConnectionClosed:
                raise DriverError("not connected", "not_connected")
            # A rejected link comes back as an error within a few hundred ms.
            await asyncio.sleep(0.7)
            if not any(link in m for m in DEVICE_ERRORS.rejected[seen:]):
                break
        else:
            raise DriverError("The TV could not open this app.")
        if "://" not in option:
            self.catalog.remember_link(option, link)
            self.catalog.used(self.tv_id, option)
        return None

    async def op_volume(self, req):
        raise DriverError("Android TV takes volume steps, not a volume level.")

    def _watch_field(self, remote):
        """The TV reports the focused text field (with its text) over the IME channel, but
        androidtvremote2 keeps only the counters. Read the same messages alongside it.
        Private API: if it changes, typing still works, only the old text is not shown."""
        proto = getattr(remote, "_remote_message_protocol", None)
        original = getattr(proto, "_handle_message", None)
        if original is None:
            return

        def handle(raw):
            original(raw)
            try:
                msg = RemoteMessage()
                msg.ParseFromString(raw)
                if msg.HasField("remote_ime_key_inject"):
                    self.field = msg.remote_ime_key_inject.text_field_status.value
                elif msg.HasField("remote_ime_show_request") and \
                        msg.remote_ime_show_request.HasField("remote_text_field_status"):
                    self.field = msg.remote_ime_show_request.remote_text_field_status.value
            except Exception:
                log.debug("could not read the text field", exc_info=True)

        proto._handle_message = handle

    async def op_text_get(self, req):
        """The text already in the focused field, or null when the TV does not say."""
        self._need_remote()
        if not self.ime:
            await self._connect(self.tv, ime=True)
        for _ in range(10):
            if self.field is not None:
                break
            await asyncio.sleep(0.1)
        return {"text": self.field}

    async def op_text(self, req):
        """Makes the focused text field read `text`. The TV's cursor sits after `previous`
        (what the app sent before), so the changed tail is deleted and typed again."""
        text, previous = req.get("text", ""), req.get("previous", "")
        self._need_remote()
        if not self.ime:
            await self._connect(self.tv, ime=True)
            await asyncio.sleep(0.5)  # the TV reports the focused field right after connecting
        remote = self._need_remote()
        same = 0
        while same < min(len(text), len(previous)) and text[same] == previous[same]:
            same += 1
        try:
            for _ in range(len(previous) - same):
                remote.send_key_command("DEL")
            if text[same:]:
                remote.send_text(text[same:])
            if req.get("submit"):
                remote.send_key_command("ENTER")
        except ConnectionClosed:
            raise DriverError("not connected", "not_connected")
        return None

    # -- loop --------------------------------------------------------------------

    async def handle(self, req):
        rid = req.get("id")
        op = req.get("op", "")
        method = getattr(self, f"op_{op}", None)
        if method is None:
            return {"id": rid, "ok": False, "error": f"Unknown operation “{op}”."}
        if AndroidTVRemote is None and op != "hello":
            return {"id": rid, "ok": False, "code": "unavailable",
                    "error": "androidtvremote2 is not installed. Install the driver in Settings."}
        try:
            return {"id": rid, "ok": True, "result": await method(req)}
        except DriverError as e:
            return {"id": rid, "ok": False, "error": str(e), "code": e.code}
        except Exception as e:
            log.exception("%s failed", op)
            return {"id": rid, "ok": False, "error": str(e) or type(e).__name__}


async def main():
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    driver = Driver(loop)
    # Requests run one at a time, in order: key presses must not overtake each other.
    while line := await reader.readline():
        try:
            req = json.loads(line)
        except ValueError:
            continue
        reply = await driver.handle(req)
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()
    await driver.op_disconnect({})
    await driver.op_pair_cancel({})


if __name__ == "__main__":
    asyncio.run(main())
