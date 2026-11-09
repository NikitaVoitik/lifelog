# Lifelog for iPhone

A small SwiftUI app that covers the time away from the laptop. It records plain facts and uploads them straight to the
Worker, so the Mac doesn't need to be on.

- **Mic, always on** (the orange dot stays on): 5-minute AAC chunks at 16 kHz mono through the built-in mic, so music
  keeps playing and AirPods stay in high-quality mode. A per-minute loudness record notes whether another app is playing
  audio. Chunks with nothing above -50 dB aren't uploaded. Audio waits for Wi-Fi unless you allow cellular in the app.
- **Screen:** on/off, locked/unlocked (phone-use sessions and glances). It can't see which app you use.
- **Calls:** start, connect, end, with no numbers. **Motion** (walking, vehicle, still) and **steps** per 5 minutes.
- **Places:** arrivals, departures and ~500 m moves, named with Apple's reverse geocoder. No continuous GPS.
- **Battery**, **audio output** (speaker, AirPods) and recorder gaps.

On the Mac, `lifelog sync` pulls the events into `phone_events` and transcribes the non-silent audio like the Mac's
own (your voice is still "Me"); the timeline gets an **on phone** category.

## Build

Needs Xcode 26+, iOS 26+, a paired iPhone with Developer Mode on, and your Apple developer team id. Deploy the cloud
side first (`cloud/deploy.sh`), since the Worker URL and the phone's upload-only token are compiled in.

```bash
LIFELOG_TEAM=ABCDE12345 phone/build.sh   # generate the project, build, install and launch on the iPhone
phone/build.sh --sim                     # compile for the simulator only (no signing, no config needed)
```

| Setting | Env var | `config.json` key | Default |
|---|---|---|---|
| Team id | `LIFELOG_TEAM` | `phoneTeam` | required for a device build |
| Bundle id | `LIFELOG_BUNDLE_ID` | `phoneBundleId` | `lifelog.<team>.phone` |
| Worker URL | `LIFELOG_CLOUD_URL` | `cloudUrl` | from `cloud/deploy.sh` |
| Upload token | `LIFELOG_PHONE_TOKEN` | `phoneToken` | from `cloud/deploy.sh` |
| Device id in the cloud | | `phoneDeviceId` | `iphone` |
| Which iPhone | `LIFELOG_IPHONE` | | the first paired one |

`build.sh` writes `Sources/Secrets.swift` and runs `xcodegen` to make `LifelogPhone.xcodeproj` and `Sources/Info.plist`;
all three are gitignored. To build from Xcode by hand, copy `Secrets.example.swift` to `Sources/Secrets.swift`, fill it
in, and run `LIFELOG_TEAM=… LIFELOG_BUNDLE_ID=… xcodegen generate`.

Changing the bundle id installs a separate app (with its own permissions and unsent data).

## Limits

iOS can't start recording from the background. If the app is killed (force-quit, reboot, iOS reclaiming memory), a
location wake-up brings back everything except the mic and sends a "Lifelog stopped listening" notification; open the
app to resume.
