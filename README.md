# Orbit

A home network dashboard for Starlink. It shows how your connection is doing, which devices are online, and who's using the internet. It keeps a history Starlink itself doesn't keep: the dish only remembers the last 15 minutes.

Orbit runs on a computer at home and you open it in a browser. It reads from your dish and router over their local connection, so it keeps working when the internet is down.

`Orbit Home Network.html` is the original design prototype, which runs on simulated data. The real app is in `orbit/` (the server) and `web/` (the page).

## What you need

- A Starlink dish and the Starlink router. Tested with the Standard kit and Router Gen 3.
- A computer on your Starlink Wi-Fi with Python 3.10 or newer. A Mac that sleeps works, but history has gaps while it's asleep. A Raspberry Pi or other always-on computer is better.

If your Starlink router is in bypass mode, Orbit still sees the dish but can't see your devices.

## Set up and run

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m orbit
```

Then open http://localhost:8787. Press Ctrl+C to stop; history is saved as it goes.

Options:

| Option | What it does |
|---|---|
| `--lan` | Lets phones and laptops on your Wi-Fi open the dashboard. Each one signs in once with an access code, which Orbit prints when it starts. This computer never needs the code. |
| `--new-code` | Makes a new access code and signs every other device out. |
| `--port 8787` | Uses a different port. |
| `--db data/orbit.db` | Keeps history somewhere else. |
| `--dish 192.168.100.1:9200`, `--router 192.168.1.1:9000` | Uses different dish or router addresses. |

### Keep it running in the background (Mac)

History is only as complete as the time Orbit spends running. To run it as a background service:

```bash
scripts/service.sh install
```

The service:
- starts when you log in;
- restarts within seconds if it crashes;
- keeps the Mac awake while it's plugged in. On battery the Mac sleeps as usual, and closing the lid always makes it sleep, so leave it plugged in with the lid open.

Add `--lan` to the install command to let phones open it. The access code then appears in `scripts/service.sh status`.

| Command | What it does |
|---|---|
| `scripts/service.sh status` | Shows whether it's running and recording. |
| `scripts/service.sh logs` | Shows its log. |
| `scripts/service.sh restart` | Restarts it. Do this after changing Orbit's code. |
| `scripts/service.sh stop` / `start` | Stops it until you start it again or next log in, and starts it again. |
| `scripts/service.sh uninstall` | Removes the service. Your history stays. |

Only one copy of Orbit can use a history at a time, because two would count every device's usage twice. If the service is running, `python -m orbit` in a terminal says so and quits.

After the Mac sleeps:
- **Whole-home usage:** Orbit fills in the last 15 minutes from the dish's own history.
- **Per-device usage:** it carries across the gap for devices that stayed connected, because the router's counters kept running.

To check what your own dish and router report, run the read-only probe. It writes a redacted report to `scripts/probe_report.json`.

```bash
.venv/bin/python scripts/probe_starlink.py
```

## Mac app

`mac/` holds a native Mac app, built in SwiftUI. It has a window with the same pages as the web version, and a menu bar icon that shows Starlink's latency. Click the icon for a quick look and a speed test button.

The app shows what the Orbit server on this Mac records, so the server needs to be running (`scripts/service.sh status`). The web version keeps working alongside it.

Build it and install it in Applications:

```bash
mac/build.sh --install
```

Run this again after changing the app's code. If Orbit is open, it quits and reopens on the new version.

To try a change without installing it, run `mac/build.sh` on its own. It builds `mac/build/Orbit.app`.

In the app's settings (⌘,) you can make it open when you log in.

## What it shows

- **Overview:** a health headline, latency, current use, data used today, dropouts, and a live map of devices by signal strength. It also makes suggestions, such as weak signals, unnamed devices, restarts and big downloads.
- **Devices:** every device the router has seen, with live speed, data used today, band and signal. You can rename a device, set its type and choose its owner.
- **People:** devices grouped by who uses them.
- **Usage:** data used per hour or day, average use and latency over time, and breakdowns by person and by device, over 24 hours, 7 days or 30 days.
- **Starlink:** the dish's own obstruction map, dropouts with their cause, dish and router details, and speed tests.
- **Speed test:** the router measures download, then upload, for about 30 seconds. It uses a few hundred MB of data. Results are kept, and "In use now" is measured against the last one.
- **Activity:** new devices, devices connecting and disconnecting, dropouts, software updates, and the changes you made.

## How it measures

- **Whole home:** the dish reports download and upload speed every second. Orbit saves each reading and adds them up for daily totals.
- **Per device:** the router reports a running byte count for each device. Orbit reads it every 2 seconds and records the difference.
  - The counter restarts when a device reconnects, and Orbit accounts for that.
  - The counter includes traffic that stays inside your home, such as casting to a TV. So per-device totals can add up to more than the whole-home total.
- **Live speed per device:** worked out from those counters over the last 6 seconds.
- **Dropouts:** come from the dish, with its own reason for each one.

## What Orbit can and can't change

Orbit can send only the requests listed in `orbit/starlink.py`. Most are reads (`READ_ONLY`). The only action (`ACTIONS`) is `start_speedtest`, which asks the router to run its own speed test.

When tested on a Starlink Router Gen 3 (October 2026), the router allowed every read and the speed test, but refused settings changes with `PERMISSION_DENIED`. Those need Starlink's signing keys, so only the Starlink app can make them. That rules out, from Orbit:
- pausing a device
- block schedules, such as bedtime
- speed limits
- renaming devices on the router itself

Orbit does show what you set in the app. A device that's paused or inside a schedule shows as **Blocked**, and its details say whether it has a schedule.

Orbit never restarts, stows or reconfigures the dish or router.

## Privacy and security

- **What's stored:** history lives in `data/orbit.db` on this computer. Orbit never stores or shows your Wi-Fi password.
- **Which addresses work:** the server answers only on this computer's own addresses. That blocks other websites from reading it through DNS rebinding. Changes must come from the dashboard page itself.
- **Signing in:** with `--lan`, other devices sign in with the access code. A signed-in device keeps a session cookie for a year, which page scripts can't read. Orbit stores only a hash of each session. After 5 wrong codes from one address, that address waits 10 minutes.
- **MAC addresses:** the router hides the second half of every device's MAC address, so Orbit identifies devices by the router's client ID.
- **How long things are kept:**
  - Per-second readings: 2 days.
  - Per-minute summaries: 400 days.
  - Per-device minutes: 35 days.
  - Per-device daily totals: forever.

## Layout

```
orbit/            the server (Python, standard library plus the Starlink gRPC library)
  starlink.py     access to the dish and router (reads, plus the speed test)
  collector.py    polls them, works out usage, runs speed tests, keeps the live picture
  store.py        SQLite history
  server.py       the web server, JSON API and live stream
  auth.py         sign-in for other devices when running with --lan
web/              the dashboard (React and htm, no build step; libraries in web/vendor)
mac/              the native Mac app (SwiftUI and Swift Charts), built with mac/build.sh
scripts/          the probe, and service.sh for running Orbit in the background on a Mac
```
