# Contributing to ScreenRelay

Thanks for helping keep old Macs useful! Bug reports, fixes and improvements are all welcome.

## Before you start

- **Contributor License Agreement.** Contributions are accepted under the
  [ScreenRelay Contributor License Agreement](CLA.md). In short: you keep the copyright to
  your work, your contribution is published here under the GPL v3, and you also allow the
  maintainer to use it in other editions of ScreenRelay, including commercial ones. Pull
  requests can only be merged once you've agreed to it (there's a checkbox in the pull request
  template).
- For anything bigger than a small fix, please **open an issue first** so we can agree on the
  approach before you spend time on it.

## Reporting bugs

Please include:

- The ScreenRelay version on **each** Mac (shown in the menu bar panel and the settings
  window, e.g. *ScreenRelay Basic 1.0 (1)*).
- Both Macs' models and macOS versions, and how they're connected (Thunderbolt, Ethernet,
  Wi‑Fi).
- What the host's status shows (Network, Stream and Live rows), and the steps to reproduce.

## Making changes

1. Fork the repository and create a branch for your change.
2. Build with Xcode 27 or later, signing with your own team (see the README).
3. Test with two Macs if your change touches streaming, pairing or the display.
4. Keep the style of the surrounding code: Swift, 4-space indentation, comments that explain
   *why*, no force unwraps.
5. If you change the wire protocol, bump `RelayProtocol.version` and **never reuse a message
   number** — gaps in `MessageType` are intentional.
6. Open a pull request describing what changed and why, and tick the CLA box.

## License

ScreenRelay Basic is licensed under the [GNU General Public License v3](LICENSE).
