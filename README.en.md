# DualVibe Coding

[中文](README.md)

<p align="center">
  <a href="https://github.com/ruaomol/DualVibe-Coding/releases"><img src="https://img.shields.io/badge/macOS-14%2B-111827" alt="macOS 14 or later"></a>
  <a href="https://github.com/ruaomol/DualVibe-Coding"><img src="https://img.shields.io/github/last-commit/ruaomol/DualVibe-Coding?label=updated" alt="Last commit"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/ruaomol/DualVibe-Coding" alt="MIT License"></a>
  <a href="https://github.com/ruaomol/DualVibe-Coding/stargazers"><img src="https://img.shields.io/github/stars/ruaomol/DualVibe-Coding?style=social" alt="GitHub Stars"></a>
</p>

<p align="center">
  <a href="https://github.com/ruaomol/DualVibe-Coding/releases">Download DMG</a> ·
  <a href="https://github.com/ruaomol/DualVibe-Coding/issues">Report an issue</a>
</p>

<h2 align="center">DualVibe Coding: a Mac buddy, a coding helper, and smoother to use.</h2>

<p align="center">
  <img src="docs/assets/overview/dualvibe-mac-mini-hero.png" alt="DualVibe Coding makes your Mac easier to use" width="960">
</p>

**Control at hand, act as you please. Your next coding device doesn't have to be a keyboard and mouse.**

DualVibe Coding is a macOS app that turns a DualSense into a mouse, keyboard, microphone, and launcher. It starts by making controller input immediately usable, then connects touchpad gestures, button mappings, a radial launcher, and per-app setups.

DualVibe Coding is built natively with SwiftUI. It can connect more than one DualSense over Bluetooth or USB, and shows battery and charging status at a glance.

<p align="center">
  <img src="docs/assets/overview/dualvibe-controller-workflow.png" alt="A DualSense workflow for controlling a Mac" width="960">
</p>

## DualVibe Coding, a Mac buddy

### One controller, one complete workflow

Connect the controller, choose a mapping, open the wheel, and send the action to the current app. DualVibe Coding keeps buttons, sticks, touchpad gestures, microphone input, and app launching in one workflow.

<p align="center">
  <img src="docs/assets/overview/dualvibe-overview.png" alt="DualVibe Coding feature overview" width="960">
</p>

### Touchpad as a mouse

Move the pointer, click, double-click, right-click, drag, scroll, and switch desktops. Stick output can stay continuous while you hold buttons, which makes dragging and holding more reliable.

<p align="center">
  <img src="docs/assets/screenshots/touchpad-mouse.png" alt="Touchpad, pointer, and scrolling settings" width="760">
</p>

### Buttons you can remap

Map buttons to keys, mouse clicks, holds, or shortcut combinations. Each app can have its own mappings, and conflicts show up right on the slot they affect.

<p align="center">
  <img src="docs/assets/screenshots/mapping.png" alt="DualSense button mapping" width="760">
</p>

### A wheel that opens apps

The radial launcher can open apps, run combos, or fire mapped actions. Steer it with the D-pad or a stick. Drag a `.app` from Finder straight into the app library.

It also supports light, dark, or system appearance, and the window comes back as it was after you reactivate it.

<p align="center">
  <img src="docs/assets/screenshots/radial-launcher.png" alt="Radial launcher workflow" width="960">
</p>

### App library

Drag the `.app` files you use into the app library. Each app can use an independent mapping or keep the global mapping. Search, add, and edit apps from one place.

<p align="center">
  <img src="docs/assets/screenshots/app-library.png" alt="DualVibe Coding app library" width="960">
</p>

## What you need

- macOS 14 or later
- A DualSense controller
- Accessibility and Input Monitoring permissions if you want mouse, keyboard, touchpad, or shortcut output
- Microphone permission if you want voice input

## Download and install

[DualVibe Coding v0.1.0](https://github.com/ruaomol/DualVibe-Coding/releases/tag/v0.1.0) includes `DualVibe-Coding-0.1.0.dmg`. Open the disk image, drag DualVibe Coding.app to Applications, then open the **Permissions** page on first launch. Grant what macOS asks for and hit **Recheck**.

<details>
<summary><strong>Show first-launch and permission steps</strong></summary>

1. Open the app's **Permissions** page and review Accessibility, Input Monitoring, and Microphone status.
2. Click the button beside each missing permission and follow the macOS System Settings prompt.
3. Return to DualVibe Coding, click **Recheck**, and confirm that the status is granted.
4. Accessibility and Input Monitoring are enough for button mappings. Enable Microphone when you want voice input.

</details>

<p align="center">
  <img src="docs/assets/screenshots/permissions.png" alt="DualVibe Coding permission status" width="760">
</p>

## Build from source

```sh
brew install opus
./scripts/build-app.sh
./scripts/package-dmg.sh
```

Build outputs stay in local `.build/` and `dist/` folders. `scripts/package-dmg.sh` creates `DualVibe-Coding-VERSION.dmg` in `dist/`, ready to upload to GitHub Releases. The app keeps a stable bundle identifier and a persistent signing identity, so your macOS permission grants can survive updates.

## Privacy and sources

This repository contains source code, build scripts, required third-party notices, and public documentation. Personal mappings, app paths, signing keys, build caches, screenshots, and test records stay out of the public repo.

The project draws on [Agent Remote](https://github.com/AbhisekBasu1/agent-remote) for DualSense input and touchpad ideas, [remote-mic-app](https://github.com/HD838A/remote-mic-app) for the microphone approach, and [StarPie](https://github.com/Star-Pie/StarPie) for the controller wheel.

## License

DualVibe Coding is released under the [MIT License](LICENSE). Third-party licenses and notices are bundled with the app and kept in `ThirdParty/AgentRemote`.

## Community

Questions, or just want to talk about how you use it? Join the DualVibe Coding group.

<p align="center">
  <img src="docs/assets/community/dualvibe-coding-group.jpg" alt="DualVibe Coding community QR code" width="360">
</p>
