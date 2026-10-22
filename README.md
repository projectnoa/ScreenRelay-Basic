# ScreenRelay

**Turn an old Mac into a second display for your new one.**

ScreenRelay extends your Mac's desktop onto another Mac — for example a 2017 5K iMac that
macOS no longer lets you use as a display (Target Display Mode is long gone). Connect the
two Macs with a Thunderbolt cable, run ScreenRelay on both, and the old Mac becomes a
real, native-resolution external display: drag windows onto it, arrange it in System
Settings › Displays, and use it like any monitor.

This is **ScreenRelay Basic**, the free and open-source edition, licensed under the
[GNU GPL v3](LICENSE). It exists so perfectly good hardware doesn't end up in a drawer.

<p>
  <a href="https://buymeacoffee.com/juanreyes">☕ Buy me a coffee</a> ·
  <a href="https://buildthestack.com">buildthestack.com</a>
</p>

---

## Features

- **A real extended display.** The host gets a virtual display that matches the other Mac's
  panel — including Retina ("looks like") modes and the usual More Space / Larger Text
  choices.
- **Native quality over Thunderbolt.** Frames are compressed to BC7, a texture format GPUs
  read directly, so the display Mac has nothing to decode and text stays sharp. Only the
  parts of the screen that change are sent: typing costs kilobytes, not a whole frame.
- **Works without Thunderbolt, too.** Over Wi‑Fi or Ethernet, ScreenRelay falls back to
  hardware HEVC/H.264 video.
- **A cursor that doesn't lag.** The pointer isn't part of the video: the display Mac moves
  its own cursor, so it responds at the panel's refresh rate.
- **The old Mac stays usable.** The stream runs full screen in its own Space. Move the old
  Mac's mouse and its cursor comes back; switch Spaces to reach its desktop; press Esc to
  leave full screen.
- **Sleeps with your Mac.** When the host sleeps, the display Mac turns its panel off; when
  the host wakes, it reconnects and the panel comes back.
- **Paired and authenticated.** Macs pair once with a 6-digit code. Every connection is
  verified in both directions, so your screen only ever goes to the Mac you paired with.
  By default the display only accepts connections over the cable.
- **Lives in the menu bar.** Starts at login if you like, and reconnects on its own.
- **Built-in diagnostics.** Live frame rate, encode/decode times and a link speed test.

## Requirements

| | Host (your main Mac) | Display (the old Mac) |
|---|---|---|
| macOS | 13 Ventura or later | 13 Ventura or later |
| Hardware | Apple silicon recommended | Any Mac with a Metal GPU; BC7 support for native quality |
| Permissions | Screen Recording, Local Network | Local Network |

- A **Thunderbolt cable** between the Macs gives the best results (a Thunderbolt Bridge
  carries ~10+ Gbps; native 5K at 60 fps needs about 7 Gbps). Wi‑Fi works for lighter use.
- Tested with an Apple silicon host and a 2017 27" 5K iMac (Radeon Pro 570, macOS 13.7).

## Build it yourself

You need **Xcode 27** or later (the project uses the macOS 27 SDK and deploys back to
macOS 13).

1. Clone the repository and open `ScreenRelay.xcodeproj`.
2. Select the **ScreenRelay** target › **Signing & Capabilities** and choose your own
   **Team**. A free personal team works. If Xcode complains about the bundle identifier,
   change `com.buildthestack.ScreenRelay` to something unique to you.
3. Choose **Product › Archive** (or build the Release configuration). Release builds are
   universal (Apple silicon + Intel), so the same app runs on both Macs.
4. Copy **ScreenRelay.app** to the **Applications** folder on *both* Macs.

To share builds with other people, sign them with a Developer ID certificate and notarize
them; otherwise Gatekeeper will block the app on their Macs.

## Setting up

1. **Connect the Macs** with a Thunderbolt cable and make sure *Thunderbolt Bridge* is
   active in System Settings › Network on both.
2. **On the old Mac**, open ScreenRelay and choose **Target** (it will be the display).
3. **On your main Mac**, open ScreenRelay and choose **Host**. Grant **Screen Recording**
   when asked, then connect to the old Mac from the menu bar or the settings window.
4. **Pair once.** The old Mac shows a 6-digit code; type it on the host.
5. The old Mac switches to a full-screen view of your new display. Arrange it in
   System Settings › Displays on the host.

ScreenRelay then lives in the menu bar. Turn on **Open at Login** on both Macs and leave
**Connect automatically** on, and the display reconnects whenever both Macs are awake.

### Tips

- Run the **same build on both Macs.** The app shows its edition and version (for example
  *ScreenRelay Basic 1.0 (1)*) in the menu bar panel and the settings window, and while
  connected the host shows the display's version too, with a warning if they differ.
- Set **Picture** to *Automatic* and **Stream resolution** to *100%* for native quality over
  Thunderbolt.
- Use **Link speed › Test** to check what your cable actually carries.
- On the old Mac, Esc leaves full screen, ⌘M minimizes, and closing the window disconnects.

## How it works

```
 Host Mac                                              Display Mac
 ┌─────────────────────────────────┐                   ┌─────────────────────────────────┐
 │ Virtual display (CoreGraphics)  │                   │ Full-screen Metal view          │
 │   ↓ ScreenCaptureKit            │    Thunderbolt    │   ↑ BC7 texture (no decode)     │
 │ BC7 encoder on the GPU          │ ────── TCP ─────▶ │ Changed tiles copied in         │
 │   (only changed 64×64 tiles)    │                   │                                 │
 │ Pointer position and shape      │ ────── UDP ─────▶ │ Moves its own hardware cursor   │
 └─────────────────────────────────┘                   └─────────────────────────────────┘
```

- **Virtual display:** created with CoreGraphics' `CGVirtualDisplay` (a private API, also
  used by tools like DeskPad and BetterDisplay), so macOS treats it as a real monitor.
- **Capture:** ScreenCaptureKit captures only that display.
- **Transport:** each frame is BC7-encoded on the GPU (~4 ms for 5K on Apple silicon). The
  encoder is deterministic, so comparing blocks with the previous frame finds exactly what
  changed; only those tiles are sent. At most two frames are ever in flight, so latency
  can't build up.
- **Fallback:** on slower links, hardware HEVC/H.264 with frame acknowledgements, so the
  host never sends faster than the display Mac can decode.
- **Discovery:** Bonjour (`_screenrelay._tcp`). Ports: TCP 52100 (stream), UDP 52101 (pointer).

### Project layout

| Folder | What's inside |
|---|---|
| `ScreenRelay/App` | Menu bar app, settings window, launch at login |
| `ScreenRelay/Host` | Virtual display, capture, BC7/HEVC encoders, pointer relay |
| `ScreenRelay/Target` | Connection handling, BC7/HEVC renderers, full-screen window, cursor |
| `ScreenRelay/Shared` | Wire protocol, framing, pairing and authentication |

## Troubleshooting

**"Network is down" when connecting.** macOS is blocking ScreenRelay's access to the local
network. Open System Settings › Privacy & Security › Local Network and turn ScreenRelay
off and back on.

**The display isn't found, or connects over Wi‑Fi.** Check that Thunderbolt Bridge has a
169.254.x.x address on both Macs. With *wired only* on, ScreenRelay binds its connection to
the bridge directly. You can also type the display's address (shown in its window).

**The picture is soft or laggy.** Make sure the stream says *BC7, native quality* (Picture:
Automatic, over Thunderbolt) and that Stream resolution is 100%.

**I can't find the app.** It lives in the menu bar (look for the relay icon on the host, the
monitor icon on the display). On a crowded menu bar, macOS may hide it behind the notch —
open ScreenRelay again from Finder or Spotlight to show its window.

## Privacy & security

- Your screen is only sent to a Mac you paired with, and only after both Macs have proven
  they hold the pairing key (HMAC-SHA256 over fresh nonces). Keys live in each Mac's
  Keychain; you can forget a paired Mac at any time.
- The display only accepts connections over a wired link unless you allow Wi‑Fi.
- The video stream itself is not encrypted — on a direct cable between your own Macs this
  keeps latency and CPU use low. Avoid allowing Wi‑Fi connections on untrusted networks.
- ScreenRelay is not sandboxed, because the virtual display API requires it, and it uses a
  private macOS API that a future macOS release could change.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Contributions
are accepted under the [Contributor License Agreement](CLA.md): you keep the copyright to your
work, and you also allow the maintainer to use it in other editions of ScreenRelay, including
commercial ones.

## License

ScreenRelay Basic is free software: you can redistribute it and/or modify it under the terms
of the **GNU General Public License, version 3** as published by the Free Software
Foundation. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See [LICENSE](LICENSE) for the full text.

If you distribute a modified version, it must also be under the GPL v3, with its source code
available.

Contributions to this repository are made under the [Contributor License Agreement](CLA.md),
which is separate from, and in addition to, the GPL v3.

## Support

ScreenRelay is a free project. If it saved an old Mac from the drawer, you can
[buy me a coffee](https://buymeacoffee.com/juanreyes) — thank you!

More of my work: [buildthestack.com](https://buildthestack.com)
