# PadLink — use your iPhone as a PC controller

The iPhone app is a touchscreen Xbox-style gamepad. It sends input over Wi-Fi
(UDP) to a small Python server on your PC, which shows up in Windows as a real
**Xbox 360 controller**. Steam, Game Pass and anything that supports XInput will
see it. Up to 4 phones can connect at once (each one becomes its own controller).

```
iPhone app  ──UDP :28910──►  padlink_server.py  ──►  ViGEmBus virtual Xbox 360 pad  ──►  games
```

## Controls

| Control | How |
|---|---|
| Left / right stick | Put your thumb anywhere in the dashed circle. The stick centres where you touch, and follows your thumb if you drag past the edge |
| L3 / R3 (stick click) | **Double-tap a stick and keep holding.** The knob turns orange while it's clicked |
| A B X Y, D-pad, LB/RB, LT/RT, Back/Guide/Start | Tap. You can slide between buttons, or rest your thumb between A and B to press both |
| Settings | Tap the status pill or the gear at the top |

Buttons give a light haptic tap. If the phone goes quiet for 0.5 s (app closed,
Wi-Fi drop), the server releases every input so nothing gets stuck.

---

## 1. Build the .ipa (no Mac needed)

You need a Mac to compile iOS apps, so this project uses a free GitHub-hosted Mac
to do it:

1. Create a GitHub repo (public repos get unlimited free build minutes; private
   ones get about 200 Mac minutes a month, and one build takes about 3–5).
2. Upload **everything in this folder**, including the hidden `.github` folder.
   - The easy way: install [GitHub Desktop](https://desktop.github.com/), add this
     folder as a repo, and publish it.
   - In the browser: use *Add file → Upload files* to upload the rest, then
     *Add file → Create new file*, name it `.github/workflows/build-ipa.yml` and
     paste in the contents of that file.
3. Open the repo's **Actions** tab, then **Build IPA**. It runs on every push, or
   you can start it with *Run workflow*.
4. When it goes green, download the **PadLink-ipa** artifact and unzip it to get
   `PadLink.ipa`.

(If you do have a Mac: `brew install xcodegen`, `cd ios`, `xcodegen generate`,
open `PadLink.xcodeproj`, pick your team, and run it on your phone.)

## 2. Sideload onto the iPhone

Use **Sideloadly** (Windows) or **AltStore**:

1. Plug the iPhone into the PC and open Sideloadly. Drop in `PadLink.ipa`, enter
   your Apple ID and click Start.
2. On the iPhone (iOS 16+): **Settings → Privacy & Security → Developer Mode → On**
   (the phone restarts).
3. **Settings → General → VPN & Device Management**, then trust your Apple ID.

With a free Apple ID, sideloaded apps expire after 7 days. Re-sign with
Sideloadly (or let AltStore refresh it) when that happens.

## 3. Run the server on the PC

Double-click **`server\start-server.bat`**.

- On the first run it installs `vgamepad`, which pops up the **ViGEmBus driver
  installer**. Accept it (this is what creates the virtual Xbox controller).
- When Windows Firewall asks, allow Python on **Private networks**.
- The window shows the IP address to type into the app, e.g. `192.168.1.20 port 28910`.

To run it by hand: `python -m pip install vgamepad`, then
`python server\padlink_server.py [--port 28910]`.

## 4. Connect

Open PadLink, enter the PC's IP, and allow the **Local Network** prompt. The
status pill turns green and shows your PC's name. Windows should play the
"device connected" sound, and the controller appears in `joy.cpl`.

It also works over the iPhone's **Personal Hotspot**: connect the PC to the
hotspot and use the IP the server prints (usually `172.20.10.x`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Red "No response" | Make sure the server is running and you typed the IP it printed. Allow Python through Windows Firewall, and check that the Wi-Fi network is set to **Private** in Windows (Settings → Network → your Wi-Fi → Network profile type) |
| Still no response | Guest and hotel networks often block devices from talking to each other ("AP isolation"). Try your home network or Personal Hotspot |
| Never got the Local Network prompt / denied it | iPhone Settings → PadLink → turn on **Local Network** |
| "Could not create virtual controller" | The ViGEmBus driver isn't installed. Run `python -m pip install --force-reinstall vgamepad` and accept the installer, then reboot |
| App won't open after a week | The free-account signature expired. Re-sideload it |

## Project layout

```
ios/project.yml               XcodeGen spec (the Xcode project is generated from it)
ios/PadLink/GamepadView.swift  multitouch gamepad: layout, touch handling, drawing
ios/PadLink/PadConnection.swift  UDP sender + connection status
ios/PadLink/PadViewController.swift  screen, settings dialog
server/padlink_server.py      UDP → virtual Xbox 360 controller
.github/workflows/build-ipa.yml  cloud build of the unsigned .ipa
```

### Protocol

JSON over UDP, port 28910 by default.

- Phone → PC, about once a second: `{"t":"hello"}`. The PC replies with
  `{"t":"ok","name":"<pc name>","slot":1}`.
- Phone → PC, on every change and every 50 ms:
  `{"t":"s","sid":<session>,"q":<seq>,"b":<XUSB button bits>,"lx":..,"ly":..,"rx":..,"ry":..,"lt":..,"rt":..}`.
  Sticks run from -1 to 1 (up is +1) and triggers from 0 to 1. The PC drops any
  packet that arrives out of order.
