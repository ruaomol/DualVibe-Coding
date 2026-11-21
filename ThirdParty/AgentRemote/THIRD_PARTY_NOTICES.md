# Third-party notices

Agent Remote is MIT-licensed, but it includes or adapts work under additional
permissive terms. The corresponding license texts are shipped in every app
bundle.

## Distributed components

### Agent Remote

The Swift Bluetooth HID transport, Opus wrapper, microphone PCM path,
speech processing, and driver installer are adapted from Agent Remote (MIT).
The original copyright and permission notice are in `LICENSE` and in the
application bundle as `AgentRemote-LICENSE.txt`.

Upstream: <https://github.com/abhisekbasu1/agent-remote>

### Apple NullAudio sample

`Driver/DualSenseBridgeMic.c` began from Apple's NullAudio Core Audio sample
and contains substantial Agent Remote modifications. Apple's original 2013
sample-code terms are retained in `Driver/LICENSE-APPLE.txt` and packaged as
`AudioDriver-APPLE-LICENSE.txt`.

### Opus

Bluetooth voice decoding dynamically loads `libopus.0.dylib`. Packaging copies
the library from a matching local Opus installation. The redistributable license is retained in
`Licenses/Opus.txt` and packaged as `Opus-LICENSE.txt`.

Upstream: <https://opus-codec.org/>

### Sonic

The vendored `CSonic/sonic.c` and `CSonic/include/sonic.h` are
Bill Cox's Sonic library, copyright 2010, licensed under Apache-2.0. The license
is retained in `Licenses/Sonic.txt` and packaged as
`Sonic-APACHE-LICENSE.txt`.

Upstream: <https://github.com/waywardgeek/sonic>

### yabai Dock gesture technique

The app’s native Space switch adapts `Sources/DualSenseBridge/MacOSWorkspaceSwitcher.swift`
from Agent Remote revision `ca76e8cab84b264bf8b86657bce3e426c0f31cdb`.
That file credits the MIT-licensed Dock gesture technique from yabai.

Upstream reference: <https://github.com/asmvik/yabai/blob/master/src/space_manager.c>

```text
The MIT License (MIT)

Copyright (c) 2019 Åsmund Vikane

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## Protocol research references

The Bluetooth HID report layout and microphone arming work were informed by
open-source controller implementations and documentation. These projects are
not bundled dependencies; they are cited so the origin of the protocol
research remains auditable:

- awalol/DS5Dongle: <https://github.com/awalol/DS5Dongle> (MIT)
- MarcelineVPQ/DS5Dongle-OLED-Edition:
  <https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition> (MIT)
- Linux `hid-playstation`:
  <https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c>
- hbashton/VIIPER: <https://github.com/hbashton/VIIPER>

When updating a vendored component or adapting additional implementation code,
record the upstream revision, preserve its copyright notice, and update both
this document and the packaged licenses.
