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
   - Tune **Reaction speed**, **Dead zone width**, **Dead zone height**, and **Sensitivity**.
   - Flip **Tracking On** when you want the head to move.

Shortcut: **⌘T** toggles tracking.

## Blackmagic UltraStudio HD Mini

PTZ Tracker uses DeckLink for the UltraStudio HD Mini with a **1080i60 SDI** feed (60.00 fields per second). Select SDI in Blackmagic Desktop Video Setup and close other apps using the input before starting capture. The Video Input section shows the capture mode and whether frames are arriving. PTZ Tracker deinterlaces this feed before sending it to Vision and the preview, using one field per frame and interpolating the missing lines.

Install Blackmagic Desktop Video on the Mac that runs the app. To build with DeckLink support, extract Blackmagic DeckLink SDK 16.0 to `~/Downloads/Blackmagic DeckLink SDK 16.0` or point the Xcode build setting `DECKLINK_SDK_INCLUDE` to the SDK’s `Mac/include` folder. The project also builds without the SDK for AVFoundation inputs.

## What you see

- Live video from the selected input
- Amber box + confidence on the tracked subject (when tracking is on)
- Movable crosshair and dashed dead zone for composing the shot
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

## Save and recall head positions

Use the existing **Generic HTTP Requests** connection in Companion. With tracking off, move the head manually and wait for it to stop. Add a **POST** action with the appropriate URI and leave the request body empty.

| Slot | Save the current position | Recall the saved position |
| --- | --- | --- |
| 1–4 | `presets/1/save` through `presets/4/save` | `presets/1/recall` through `presets/4/recall` |
| 5 (Center) | `presets/5/save` | `presets/5/recall` |

To use one button per slot in Companion, add a duration group of 1500 ms set to run on release. Put the recall action under **Short release**, put the save action in the duration group, and leave **Press actions** empty.

The app’s **Position Memory** section also recalls slots 1–4 and Center. Blue indicates that PTZ Tracker sent a save command for that slot and head. The slots use the head’s native preset memory. Saving replaces the position in that slot. Leave tracking off while recalling a position. An HTTP 202 response confirms the app sent the command over TCP.

## Ignore zones

Open **Ignore Zones** and drag rectangles on the live video. A face or person is eligible for tracking only when its center is outside all zones. Zones remain active after leaving the tab and are saved across app restarts. Use **Remove** next to a zone to delete it.

The **Memory** tab contains position recall and reset. The **Connection** tab contains video input, Datavideo, and Companion settings.

## Select a primary target

1. Choose **Face** or **Person**, then enable **Select Target**.
2. In the live preview, click the outline of the subject you want to follow.
3. Turn **Tracking On** when you want the head to move.

The head holds if Vision loses the selected target. If Return to Center is enabled, the head recalls Center after the configured wait. Click another outlined target, use **Choose Another Target** to replace a current selection, or turn **Select Target** off to resume automatic selection. The framing sliders remain available while choosing a target.

## Tuning tips

- **Framing** lets you click or drag in the live preview to place the crosshair where the tracked face or person should stay. You can also use the horizontal and vertical sliders. The app saves the position. **Reset to Center** restores the default.
- **Dead zone width** and **Dead zone height** resize the dashed box independently. Each percentage is measured against the corresponding video dimension. The head starts correcting as a moving subject approaches or crosses the box edge, then settles near the crosshair. Narrow the width to start horizontal corrections sooner.
- **Reaction speed** scales how fast the head moves during a correction. The head speeds up as the subject moves farther from the crosshair or drifts outward faster, then eases down as the subject returns toward or crosses the crosshair.
- **Return to Center** waits 1–120 seconds after losing a tracked face or person, then recalls the head’s saved Center position (slot 5) once. Reacquiring a target during the wait cancels the return. Tracking stays enabled. The setting defaults to Off.
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
