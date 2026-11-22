# PTZ Tracker

macOS app that watches a Thunderbolt / USB video input, uses Apple Vision to track a person or face, and drives a Datavideo VISCA PT head over DVIP (TCP, default `192.168.1.188:5002`). Tracking can also be toggled from Bitfocus Companion on another machine.

Requires **macOS 14+** and **Xcode 15+**.

## Run locally

1. Open `PTZTracker.xcodeproj` in Xcode on this Mac.
2. Select the **PTZTracker** scheme → **My Mac**.
3. If prompted, pick your Apple Development team (Signing & Capabilities). Leave the bundle id as `com.local.PTZTracker` or change it.
4. Press **Run** (⌘R). Grant camera access when asked.
5. In the sidebar:
   - Choose your Thunderbolt capture device and click **Start Camera**.
   - Confirm VISCA IP / port (defaults: `192.168.1.188` / `5002`).
   - Tune **Reaction speed**, **Buffer (dead zone)**, and **Sensitivity**.
   - Flip **Tracking On** when you want the head to move.

Shortcut: **⌘T** toggles tracking.

## What you see

- Live video from the selected input
- Amber box + confidence on the tracked subject (when tracking is on)
- Dashed dead-zone around frame center (the buffer)
- Current pan/tilt motion chip and last DVIP hex packet

## Datavideo protocol

Uses the same DVIP framing as Bitfocus’s `companion-module-datavideo-visca`:

- TCP to the head
- 2-byte big-endian length (including the length field) + VISCA frame
- Camera address byte `0x80 + id` (default id `1` → `0x81`)
- Pan/tilt drive: `81 01 06 01 VV WW RR SS FF`

## Bitfocus Companion

The app listens for Generic HTTP requests (default port **18787**). The sidebar shows the LAN base URL, e.g. `http://192.168.1.50:18787`.

| Action | URL |
| --- | --- |
| Status | `GET /status` |
| Tracking on | `GET /tracking/on` |
| Tracking off | `GET /tracking/off` |
| Toggle | `GET /tracking/toggle` |

### Companion setup

1. On the Companion machine, add connection **Generic HTTP**.
2. Base URL: `http://<this-mac-lan-ip>:18787/`
3. Button press action → **GET** with URI `tracking/on`, `tracking/off`, or `tracking/toggle`.
4. Optional: poll `status` every few seconds and store the JSON into a custom variable for button feedback (`tracking` is `true`/`false`).

Allow incoming connections if macOS Firewall prompts for **PTZ Tracker**.

## Tuning tips

- **Buffer**: raise it if the head hunts while the subject is roughly centered.
- **Reaction speed**: lower it for smoother, slower corrections.
- **Sensitivity**: raise it to ignore weak / false detections; lower it if the box drops out.
- Use **Invert pan / tilt** if the head moves the wrong way relative to the picture.

## Project layout

```
PTZTracker.xcodeproj
PTZTracker/
  PTZTrackerApp.swift
  Services/   # capture, Vision, VISCA, Companion HTTP
  Views/      # preview + controls
  Models/
```
