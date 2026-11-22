# Handoff: VISCA Pilot / PTZ Tracker

**Date:** 2026-11-22 (America/Chicago)  
**Owner:** Timothy Ryan Hodges  
**Status:** First working slice built and pushed; **not yet verified on hardware** (Thunderbolt capture + Datavideo head). Next agent should clone locally, build in Xcode on the Mac that has the gear, and iterate.

---

## Goal

Native **macOS app** that:

1. Takes video from a **Thunderbolt / USB capture device**
2. Uses **Apple Vision** (human/face detect + object track) to find a subject
3. Sends **Datavideo DVIP / VISCA** pan-tilt hex over **TCP** to a PT head
4. Lets the operator watch video + tracking overlay and tune **reaction speed**, **buffer (dead zone)**, and **sensitivity**
5. Exposes a small **HTTP API** so **Bitfocus Companion** on another machine can turn tracking on/off

Default head endpoint: **`192.168.1.188:5002`**

---

## Where the code lives

| Item | Value |
| --- | --- |
| Origin / Cursor codebase | https://cursor.com/codebase/timothy-ryan-hodges/visca-pilot |
| Clone target (owner preference) | `/Users/calvarychurch/Documents/cursor/visca-pilot` |
| Visibility | Private (changeable in codebase settings) |
| Branch | `main` |
| Xcode project | `PTZTracker.xcodeproj` (repo root) |
| Prior cloud agent | https://cursor.com/agents/bc-c69dc3fa-35b0-4d92-89d6-ee67d3bbda42 |

### Get code onto the Mac

```bash
# Origin CLI (if needed)
curl -fsSL https://downloads.cursor.com/origin/install.sh | sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
origin auth login

mkdir -p /Users/calvarychurch/Documents/cursor
cd /Users/calvarychurch/Documents/cursor
origin repo clone timothy-ryan-hodges/visca-pilot
open /Users/calvarychurch/Documents/cursor/visca-pilot/PTZTracker.xcodeproj
```

Origin CLI docs: https://cursor.com/docs/origin/cli

**Note:** Cloud agents run on remote Linux VMs. They **cannot** open Xcode, access Thunderbolt devices, or write to `/Users/calvarychurch/...`. Local Mac work (build/run/hardware test) must happen on the church Mac or a Mac-hosted agent.

---

## Stack & how it was built

- **Language / UI:** Swift 5, SwiftUI, macOS **14+**
- **Capture:** AVFoundation (`AVCaptureSession`, prefers `.external` devices)
- **Tracking:** Vision — `VNDetectHumanRectanglesRequest` / `VNDetectFaceRectanglesRequest`, then `VNTrackObjectRequest` for lock
- **PT control:** Network.framework TCP client implementing **Datavideo DVIP** (same framing as Bitfocus `companion-module-datavideo-visca`)
- **Companion:** Tiny HTTP server via `NWListener` (default port **18787**)
- **Settings:** `UserDefaults` (IP, port, speeds, etc.)
- **Scaffold:** Hand-written Xcode project + sources (empty New Project repo; no existing conventions)

No web UI, no database, no auth. Sandbox is **off** in entitlements so camera + LAN client/server work easily for a local production tool.

---

## Architecture

```
Thunderbolt/USB camera
        │
        ▼
CameraCaptureService  ──frames──► TrackingController
                                        │
                     VisionTrackingService (bg queue)
                                        │
                     offset vs center + dead zone
                                        │
                                        ▼
                                  ViscaClient (TCP DVIP)
                                        │
                                        ▼
                           Datavideo PT head :5002

Companion (other machine) ──HTTP──► CompanionHTTPServer
                                        │
                                        ▼
                              trackingEnabled on/off
```

### Important files

| Path | Role |
| --- | --- |
| `PTZTracker/PTZTrackerApp.swift` | App entry, window, ⌘T command |
| `PTZTracker/AppModel.swift` | Owns settings / camera / controller |
| `PTZTracker/ContentView.swift` | Split view: preview + sidebar |
| `PTZTracker/Services/CameraCaptureService.swift` | Device list + capture session |
| `PTZTracker/Services/VisionTrackingService.swift` | Detect + track |
| `PTZTracker/Services/TrackingController.swift` | Glue: frames → motion → VISCA; Companion hooks |
| `PTZTracker/Services/ViscaClient.swift` | DVIP packet build + TCP send |
| `PTZTracker/Services/CompanionHTTPServer.swift` | HTTP API |
| `PTZTracker/Views/VideoPreviewView.swift` | Preview layer + tracking overlay |
| `PTZTracker/Views/ControlPanelView.swift` | Operator controls |
| `PTZTracker/Models/AppSettings.swift` | Persisted config |
| `PTZTracker/Info.plist` | Camera + local network usage strings |
| `PTZTracker/PTZTracker.entitlements` | Camera/network; sandbox false |
| `README.md` | User-facing run / Companion notes |

---

## Protocol details (do not “simplify” away)

Matches Bitfocus Datavideo VISCA module behavior:

1. VISCA body example (pan/tilt drive): `01 06 01 VV WW RR SS FF`
2. Prepend device address: `0x80 + cameraId` (default id 1 → `0x81`)
3. Prepend **2-byte big-endian length including the length field itself**
4. Example stop-ish packet shape: `00 0B 81 01 06 01 … FF`
5. Transport: **TCP** to configured host/port (default `192.168.1.188:5002`)
6. Client dedupes identical motion keys so it doesn’t flood the head

Directions: left `01`, right `02`, up `01`, down `02`, stop axis `03`.

---

## Companion API

Base URL shown in UI, e.g. `http://<mac-lan-ip>:18787`

| Method | Path | Effect |
| --- | --- | --- |
| GET | `/status` or `/tracking/status` | JSON status |
| GET | `/tracking/on` | Enable tracking |
| GET | `/tracking/off` | Disable + stop head |
| GET | `/tracking/toggle` | Toggle |

JSON roughly: `{"tracking":bool,"viscaConnected":bool,"hasTarget":bool,"camera":"ip:port"}`

Companion: **Generic HTTP** connection → GET those paths.

---

## Tuning semantics

| Control | Meaning |
| --- | --- |
| Reaction speed (0.1–1.0) | Scales VISCA pan/tilt speed from offset magnitude |
| Buffer / dead zone | Fraction of half-frame ignored around center |
| Sensitivity | Min Vision confidence to accept / keep target |
| Invert pan/tilt | Flip if picture vs head direction is wrong |
| Detect mode | Person vs Face |

Overlay shows dashed dead zone, box + confidence, TRACKING / ARMED OFF chip, motion chip, last hex.

---

## What is done

- [x] Full SwiftUI macOS app scaffold + shared Xcode scheme
- [x] Capture device picker (prefers external)
- [x] Vision person/face + object tracking
- [x] DVIP VISCA pan/tilt client with reconnect
- [x] Sidebar config for IP/port/camera id/tuning/Companion port
- [x] Companion HTTP on/off/toggle/status
- [x] README + this handoff
- [x] Code on Origin as `timothy-ryan-hodges/visca-pilot`

## What is NOT done / next agent priorities

1. **Clone to** `/Users/calvarychurch/Documents/cursor/visca-pilot` and open in Xcode  
2. Set **Signing Team**, build & run on **My Mac**  
3. **Hardware bring-up** with real Thunderbolt input + head at `192.168.1.188:5002`  
4. Fix direction/speed/hunting (invert, buffer, reaction) based on real motion  
5. Confirm Companion from another machine (firewall allow if prompted)  
6. Optional polish: App icon, smoother tracking, zoom, multi-subject pick, better reconnect UX, hardened HTTP  
7. If DVIP framing fails on this specific head, compare packet captures vs Companion’s Datavideo VISCA module before changing protocol

---

## How to run (local Mac)

1. Open `PTZTracker.xcodeproj`  
2. Scheme **PTZTracker** → **My Mac**  
3. Signing team as needed (`com.local.PTZTracker`)  
4. Run ⌘R → allow camera  
5. Pick capture device → Start Camera → set VISCA IP/port → Tracking On (or ⌘T)

Requires **macOS 14+**, **Xcode 15+**.

---

## Working agreements for the next agent

- Prefer **local Cursor / Mac environment** for build, run, and AV/Vision testing.  
- Keep changes focused on this PTZ product; don’t add auth/DB/web unless asked.  
- Preserve DVIP length-prefix behavior unless proven wrong on-device.  
- User’s preferred project folder: `/Users/calvarychurch/Documents/cursor`.  
- Commit/push to Origin `visca-pilot` when finishing slices.  
- Do not invent a second monorepo or rewrite in Electron/Python unless the owner requests it — requirement was **built-in macOS object tracking**.

---

## Quick context for prompts

> Continue the macOS SwiftUI app in `timothy-ryan-hodges/visca-pilot` (`PTZTracker.xcodeproj`). It auto-tracks a person/face from Thunderbolt video via Vision and drives a Datavideo VISCA PT head over DVIP TCP (`192.168.1.188:5002`), with Companion HTTP on port 18787. Read `HANDOFF.md` and `README.md`. Clone to `/Users/calvarychurch/Documents/cursor/visca-pilot`, build in Xcode on the Mac with the capture device and head, then harden tracking and verify Companion.
