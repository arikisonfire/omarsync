#!/usr/bin/env python3
"""Pick a file or folder through the desktop portal and print its path.

usage: pick-path.py folder|file [TITLE] [START_DIR]
Exit 0 with the path on stdout, 1 when cancelled, 2 on errors.
"""
import os
import sys
from urllib.parse import unquote, urlparse

try:
    import gi

    gi.require_version("Gio", "2.0")
    gi.require_version("GLib", "2.0")
    from gi.repository import Gio, GLib  # noqa: E402
except (ImportError, ValueError) as err:
    # python-gobject missing: an error (2), not "cancelled" (1)
    print("pick-path: %s" % err, file=sys.stderr)
    sys.exit(2)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "folder"
    title = sys.argv[2] if len(sys.argv) > 2 else ("Choose folder" if mode == "folder" else "Choose file")
    start = sys.argv[3] if len(sys.argv) > 3 else ""

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    sender = bus.get_unique_name()[1:].replace(".", "_")
    token = "omarchy_rsync_%d" % os.getpid()
    handle = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender, token)

    loop = GLib.MainLoop()
    result = {"code": 2, "path": ""}

    def on_response(_conn, _sender, _path, _iface, _signal, params, *_):
        response, results = params.unpack()
        uris = results.get("uris") or []
        if response == 0 and uris:
            parsed = urlparse(uris[0])
            if parsed.scheme == "file":
                result["path"] = unquote(parsed.path)
                result["code"] = 0
        elif response == 1:
            result["code"] = 1
        loop.quit()

    bus.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
                         handle, None, Gio.DBusSignalFlags.NO_MATCH_RULE, on_response)

    options = {
        "handle_token": GLib.Variant("s", token),
        "modal": GLib.Variant("b", True),
        "directory": GLib.Variant("b", mode == "folder"),
    }
    if start and os.path.isdir(start):
        options["current_folder"] = GLib.Variant("ay", os.fsencode(start) + b"\0")

    try:
        bus.call_sync("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                      "org.freedesktop.portal.FileChooser", "OpenFile",
                      GLib.Variant("(ssa{sv})", ("", title, options)),
                      GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, -1, None)
    except GLib.Error as err:
        print(err.message, file=sys.stderr)
        return 2

    def give_up():
        result["code"] = 1
        loop.quit()
        return False

    # A dialog that never answers must not block the Browse buttons forever.
    GLib.timeout_add_seconds(15 * 60, give_up)
    loop.run()
    if result["code"] == 0:
        print(result["path"])
    return result["code"]


if __name__ == "__main__":
    sys.exit(main())
