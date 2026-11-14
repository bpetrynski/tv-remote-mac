"""Apple TV driver for TV Remote, built on pyatv (https://pyatv.dev) and its Companion
protocol: the same one the atvremote CLI and the iPhone's Control Center remote use.

Speaks the TV Remote driver protocol (DRIVERS.md): one JSON request per line on stdin,
one JSON reply per line on stdout. Logs go to stderr, which the app writes to
~/Library/Logs/TV Remote/appletv.log.

Credentials are kept by pyatv in ~/.pyatv.conf, so a device paired with
`atvremote --protocol companion pair` works here too, and the other way round.
"""

import asyncio
import json
import logging
import sys
import time

try:
    import pyatv
    from pyatv.const import (DeviceState, FeatureName, FeatureState, KeyboardFocusState,
                             OperatingSystem, PowerState, Protocol)
    from pyatv.interface import DeviceListener
    from pyatv.storage.file_storage import FileStorage
except ImportError:  # reported by `hello`, so the app can show what to install
    pyatv = None
    DeviceListener = object

log = logging.getLogger("appletv")


class DriverError(Exception):
    """An error with a code the app understands (see DRIVERS.md)."""

    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


# Remote button -> (feature that must be available, coroutine factory).
def _actions():
    return {
        "up": (FeatureName.Up, lambda a: a.remote_control.up()),
        "down": (FeatureName.Down, lambda a: a.remote_control.down()),
        "left": (FeatureName.Left, lambda a: a.remote_control.left()),
        "right": (FeatureName.Right, lambda a: a.remote_control.right()),
        "ok": (FeatureName.Select, lambda a: a.remote_control.select()),
        "back": (FeatureName.Menu, lambda a: a.remote_control.menu()),
        "home": (FeatureName.Home, lambda a: a.remote_control.home()),
        "volumeUp": (FeatureName.VolumeUp, lambda a: a.audio.volume_up()),
        "volumeDown": (FeatureName.VolumeDown, lambda a: a.audio.volume_down()),
        "rewind": (FeatureName.SkipBackward, lambda a: a.remote_control.skip_backward()),
        "forward": (FeatureName.SkipForward, lambda a: a.remote_control.skip_forward()),
    }


class _PlayerListener(DeviceListener):
    """Drops the AirPlay link when it dies, so the next status reconnects it."""

    def __init__(self, driver, player):
        self.driver = driver
        self.player = player

    def connection_lost(self, exception):
        self.connection_closed()

    def connection_closed(self):
        if self.driver.player is self.player:
            self.driver.player = None


class Driver(DeviceListener):
    def __init__(self, loop):
        self.loop = loop
        self.storage = None
        self.atv = None
        self.available = set()
        self.apps = []
        self.apps_task = None
        self.pairing = None
        self.pairing_protocol = None
        self.pair_conf = None
        self.already_paired = False
        # Second, read-only link over AirPlay for the play state (Companion has none).
        self.player = None
        self.player_task = None
        self.player_tried = 0.0
        self.tv = None  # {"id", "host"} of the connected Apple TV
        self.play_state = False  # option "play_state" (Settings): off unless turned on

    # -- helpers ---------------------------------------------------------------

    async def _storage(self):
        if self.storage is None:
            self.storage = FileStorage.default_storage(self.loop)
            await self.storage.load()
        return self.storage

    async def _scan(self, identifier=None, hosts=None, timeout=3):
        """Unicast queries to the given addresses. Without addresses pyatv falls back to
        multicast, which listens on a port (only used when running the driver by hand)."""
        storage = await self._storage()
        kwargs = {"storage": storage, "timeout": timeout}
        if identifier:
            kwargs["identifier"] = identifier
        if hosts:
            kwargs["hosts"] = hosts
        return await pyatv.scan(self.loop, **kwargs)

    @staticmethod
    def _is_apple_tv(conf):
        info = conf.device_info
        return (conf.get_service(Protocol.Companion) is not None
                and info.operating_system == OperatingSystem.TvOS
                and "HomePod" not in info.model_str)

    def _need_atv(self):
        if self.atv is None:
            raise DriverError("not connected", "not_connected")
        return self.atv

    def _has(self, feature):
        return self.atv.features.in_state(FeatureState.Available, feature)

    # DeviceListener: the Apple TV restarted or the network dropped.
    def connection_lost(self, exception):
        log.warning("connection lost: %s", exception)
        self.atv = None

    def connection_closed(self):
        self.atv = None

    # -- play state ----------------------------------------------------------------

    def _start_player(self, tv):
        """Opens the AirPlay link in the background, at most every 30 s. It needs AirPlay
        credentials (`atvremote --protocol airplay pair`); without them the play state stays
        unknown and the app treats the TV as playing."""
        if not self.play_state or tv is None or self.player or (self.player_task and not self.player_task.done()):
            return
        if time.monotonic() - self.player_tried < 30:
            return
        self.player_tried = time.monotonic()
        self.player_task = self.loop.create_task(self._connect_player(tv, self.atv))

    async def _connect_player(self, tv, owner):
        try:
            confs = await self._scan(identifier=tv["id"], hosts=[tv["host"]], timeout=2)
            airplay = confs[0].get_service(Protocol.AirPlay) if confs else None
            if airplay is None or not airplay.credentials:
                log.info("no AirPlay credentials: play state unknown")
                return
            for service in confs[0].services:
                if service.protocol not in (Protocol.AirPlay, Protocol.MRP):
                    service.enabled = False
            player = await pyatv.connect(confs[0], self.loop, storage=await self._storage())
        except Exception as e:  # the remote works without it
            log.info("play state not available: %s", e)
            return
        if owner is not self.atv or owner is None:  # disconnected or switched TVs meanwhile
            log.info("play state link dropped: the TV changed meanwhile")
            player.close()
            return
        log.info("play state link up")
        player.listener = _PlayerListener(self, player)
        self.player = player

    def _close_player(self):
        if self.player_task and not self.player_task.done():
            self.player_task.cancel()
        self.player_task = None
        if self.player is not None:
            player, self.player = self.player, None
            player.close()

    async def _playing(self):
        """True/False from the AirPlay link, None if unknown."""
        if self.player is None:
            return None
        try:
            playing = await asyncio.wait_for(self.player.metadata.playing(), 1)
        except Exception as e:
            log.info("play state read failed: %s", e)
            self._close_player()
            return None
        return playing.device_state in (DeviceState.Playing, DeviceState.Loading, DeviceState.Seeking)

    # -- operations --------------------------------------------------------------

    async def op_hello(self, req):
        if pyatv is None:
            return {"ready": False, "error": "pyatv is not installed. Install it with: pipx install pyatv"}
        return {"ready": True}

    async def op_discover(self, req):
        hosts = req.get("hosts") or ([req["host"]] if req.get("host") else None)
        confs = await self._scan(hosts=hosts, timeout=2 if hosts else 3)
        return [
            {"id": c.identifier, "name": c.name, "host": str(c.address), "model": c.device_info.model_str}
            for c in confs
            if self._is_apple_tv(c)
        ]

    # Pairing takes up to two PINs: Companion for the remote, then AirPlay for the play
    # state (only with the "play_state" option on). Either is skipped when ~/.pyatv.conf
    # already has its credentials.

    async def op_pair_begin(self, req):
        tv = req["tv"]
        await self._close_pairing()
        self.play_state = bool((req.get("options") or {}).get("play_state"))
        confs = await self._scan(identifier=tv["id"], hosts=[tv["host"]])
        if not confs:
            raise DriverError("The Apple TV is not answering. Make sure it is awake.")
        self.pair_conf = confs[0]
        companion = confs[0].get_service(Protocol.Companion)
        if companion is not None and companion.credentials:
            # The remote is paired (here or with atvremote); maybe the play state is not.
            prompt = await self._begin_airplay()
            if prompt:
                return {"prompt": prompt}
            self.already_paired = True
            return {"paired": True}
        await self._begin(Protocol.Companion)
        return {"prompt": f"Enter the PIN shown on {confs[0].name}."}

    async def _begin(self, protocol):
        self.pairing = await pyatv.pair(self.pair_conf, protocol, self.loop,
                                        storage=await self._storage(), name="TV Remote")
        self.pairing_protocol = protocol
        await self.pairing.begin()

    async def _begin_airplay(self):
        """Starts AirPlay pairing if it is missing. Returns the prompt, or None when there is
        nothing to pair or the Apple TV refuses (the remote then works without play state)."""
        airplay = self.pair_conf.get_service(Protocol.AirPlay)
        if not self.play_state or airplay is None or airplay.credentials:
            return None
        try:
            await self._begin(Protocol.AirPlay)
        except Exception as e:
            log.warning("AirPlay pairing not started: %s", e)
            await self._close_pairing()
            return None
        return (f"One more PIN from {self.pair_conf.name}: it lets the Mac see whether "
                "something is playing.")

    async def op_pair_finish(self, req):
        if self.already_paired:
            self.already_paired = False
            return {"data": {}}
        if self.pairing is None:
            raise DriverError("Start pairing first.")
        pin = str(req.get("pin", "")).strip()
        if not pin.isdigit():
            raise DriverError("The PIN is made of digits.")
        self.pairing.pin(int(pin))
        protocol = self.pairing_protocol
        try:
            await self.pairing.finish()
            paired = self.pairing.has_paired
        except Exception as e:
            log.warning("%s pairing failed: %s", protocol, e)
            paired = False
        finally:
            await self._close_pairing()
        if not paired:
            raise DriverError("Wrong PIN. Start again to get a new one.")
        await (await self._storage()).save()
        if protocol == Protocol.Companion:
            prompt = await self._begin_airplay()
            if prompt:
                return {"prompt": prompt}  # the app asks for the next PIN
        return {"data": {}}

    async def op_pair_cancel(self, req):
        await self._close_pairing()
        return None

    async def _close_pairing(self):
        self.already_paired = False
        if self.pairing is not None:
            pairing, self.pairing = self.pairing, None
            await pairing.close()

    async def op_connect(self, req):
        tv = req["tv"]
        await self.op_disconnect(req)
        self.player_tried = 0.0
        self.play_state = bool((req.get("options") or {}).get("play_state"))
        # Only the saved address: if the device moved, the app finds it (Bonjour) and retries.
        confs = await self._scan(identifier=tv["id"], hosts=[tv["host"]], timeout=2)
        if not confs:
            raise DriverError("The Apple TV is not answering at its last address.")
        conf = confs[0]
        if not any(s.credentials for s in conf.services if s.protocol == Protocol.Companion):
            raise DriverError("This Apple TV is not paired. Add it again.", "unauthorized")
        # Companion alone covers the remote; skipping AirPlay and RAOP makes connecting faster.
        for service in conf.services:
            if service.protocol != Protocol.Companion:
                service.enabled = False
        self.atv = await pyatv.connect(conf, self.loop, storage=await self._storage())
        self.atv.listener = self

        actions = {name for name, (feature, _) in _actions().items() if self._has(feature)}
        if self._has(FeatureName.PlayPause):
            actions.add("playPause")
        if self._has(FeatureName.PlayPause) or self._has(FeatureName.Play):
            actions.add("play")
        if self._has(FeatureName.PlayPause) or self._has(FeatureName.Pause):
            actions.add("pause")
        if self._has(FeatureName.TurnOn):
            actions.add("power")
        if self._has(FeatureName.TextSet):
            actions.add("keyboard")

        # The app list can take seconds (or fail) while the Apple TV sleeps: load it later.
        self.apps = []
        self._load_apps()
        self.tv = {"id": tv["id"], "host": str(conf.address)}
        self._start_player(self.tv)
        return {"host": str(conf.address), "actions": sorted(actions)}

    def _load_apps(self):
        if self.apps or (self.apps_task and not self.apps_task.done()) or not self._has(FeatureName.AppList):
            return

        async def load(atv):
            try:
                apps = await atv.apps.app_list()
            except Exception as e:  # the remote works without the app list
                log.info("app list not available yet: %s", e)
                return
            if atv is self.atv:
                self.apps = sorted(({"id": a.identifier, "title": a.name} for a in apps),
                                   key=lambda a: a["title"].lower())

        self.apps_task = self.loop.create_task(load(self.atv))

    async def op_disconnect(self, req):
        self._close_player()
        if self.atv is not None:
            atv, self.atv = self.atv, None
            atv.close()
        return None

    async def op_action(self, req):
        atv = self._need_atv()
        action = req.get("action")
        if action == "power":
            if atv.power.power_state == PowerState.On:
                await atv.power.turn_off()
            else:
                await atv.power.turn_on()
        elif action == "playPause":
            await atv.remote_control.play_pause()
        elif action in ("play", "pause"):
            # Separate keys where the Apple TV has them, the toggle otherwise.
            feature = FeatureName.Play if action == "play" else FeatureName.Pause
            if self._has(feature):
                await (atv.remote_control.play() if action == "play" else atv.remote_control.pause())
            else:
                await atv.remote_control.play_pause()
        elif action in _actions():
            await _actions()[action][1](atv)
        else:
            raise DriverError(f"Apple TV has no “{action}” button.")
        return None

    async def op_status(self, req):
        atv = self._need_atv()
        state = atv.power.power_state
        result = {"power": {PowerState.On: "On", PowerState.Off: "Standby"}.get(state, "connected")}
        self._load_apps()  # retried until the Apple TV is awake enough to answer
        self._start_player(self.tv)  # retried if it failed or dropped
        playing = await self._playing()
        if playing is not None:
            result["playing"] = playing
        if self.apps:
            result["picker"] = {"id": "apps", "label": "App", "symbol": "square.grid.2x2",
                                "options": self.apps, "current": None}
        return result

    async def op_pick(self, req):
        atv = self._need_atv()
        if req.get("picker") != "apps":
            raise DriverError("Unknown picker.")
        await atv.apps.launch_app(req["option"])
        return None

    async def op_volume(self, req):
        raise DriverError("Apple TV takes volume steps, not a volume level.")

    async def op_text_get(self, req):
        atv = self._need_atv()
        if atv.keyboard.text_focus_state != KeyboardFocusState.Focused:
            return {"text": None}
        return {"text": await atv.keyboard.text_get()}

    async def op_text(self, req):
        # The whole field is replaced, so `previous` is not needed. tvOS has no Return key
        # over Companion; search fields update as you type, so `submit` sends nothing.
        atv = self._need_atv()
        if atv.keyboard.text_focus_state == KeyboardFocusState.Unfocused:
            raise DriverError("Select a text field on the Apple TV first.")
        await atv.keyboard.text_set(req.get("text", ""))
        return None

    # -- loop --------------------------------------------------------------------

    async def handle(self, req):
        rid = req.get("id")
        op = req.get("op", "")
        method = getattr(self, f"op_{op}", None)
        if method is None:
            return {"id": rid, "ok": False, "error": f"Unknown operation “{op}”."}
        if pyatv is None and op != "hello":
            return {"id": rid, "ok": False, "code": "unavailable",
                    "error": "pyatv is not installed. Install it with: pipx install pyatv"}
        try:
            return {"id": rid, "ok": True, "result": await method(req)}
        except DriverError as e:
            return {"id": rid, "ok": False, "error": str(e), "code": e.code}
        except Exception as e:
            log.exception("%s failed", op)
            if op in ("action", "status", "pick", "text"):
                # Most likely the link died under us: let the app reconnect.
                self.atv = None
                return {"id": rid, "ok": False, "error": "not connected", "code": "not_connected"}
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
    # stdin closed: the app quit.
    await driver.op_disconnect({})
    await driver._close_pairing()


if __name__ == "__main__":
    asyncio.run(main())
