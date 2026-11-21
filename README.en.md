# DualVibe Coding

[中文](README.md)

DualVibe Coding is a macOS-only DualSense workspace. It combines controller input, touchpad gestures, microphones, shortcuts, app launching, and per-app mappings in a native SwiftUI interface.

## Features

- Bluetooth or USB support for multiple DualSense controllers with battery and charging state.
- Touchpad mouse movement, left/right click, double click, drag, scrolling, and desktop gestures.
- Keyboard keys, mouse click/double-click/hold, recorded key combinations, and custom combo macros.
- Continuous stick output works alongside physical button presses for reliable drag-and-hold workflows.
- DualSense microphone support plus selection of another macOS microphone for speech input.
- A controller-friendly radial launcher for apps, combo macros, and mapped actions.
- Per-app mappings and full-window Finder drag-and-drop for `.app` files.
- Light, dark, and system appearance modes.
- Conflicts are marked directly on the affected mapping and the main window restores after reactivation.

## Requirements

- macOS 14 or newer
- DualSense controller
- Accessibility and Input Monitoring permissions for mouse, keyboard, touchpad, and shortcut output
- Microphone permission for voice input

## Install

Download `DualVibe-Coding-*.dmg` from GitHub Releases, open it, and drag the app to Applications. On first launch, open the Permissions page, enable the requested macOS permissions, then return to the app and choose Recheck.

## Build from source

```sh
brew install opus
./scripts/build-app.sh
./scripts/package-dmg.sh
```

Build outputs stay in local `.build/` and `dist/` directories, which are excluded from the public repository. The app keeps a stable bundle identifier and persistent signing identity so macOS permissions can survive updates.

## Screenshots

![Key mappings](docs/screenshots/mapping.png)

![Controller and voice](docs/screenshots/controller-voice.png)

![Permissions](docs/screenshots/permissions.png)

See [docs/DEMO.md](docs/DEMO.md) for the demo flow.

UI demo video: [dualvibe-demo.mp4](docs/video/dualvibe-demo.mp4)

## Sources

The project incorporates ideas from [Agent Remote](https://github.com/AbhisekBasu1/agent-remote), [remote-mic-app](https://github.com/HD838A/remote-mic-app), and [StarPie](https://github.com/Star-Pie/StarPie). Their licenses and notices are preserved under `ThirdParty/AgentRemote`.

## License

DualVibe Coding is released under the MIT License.

## Community

Join the DualVibe Coding group for discussion and feedback.

![DualVibe Coding community QR code](docs/community/dualvibe-coding-group.jpg)
