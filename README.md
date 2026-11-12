# Machinedrum for iPad (working title): engine bring-up

Goal: a native, standalone iPadOS Machinedrum emulator, plus an AUv3 for Mod-Lab/AUM, using the real
emulator from [joelanders/gearmulator-md-mm](https://github.com/joelanders/gearmulator-md-mm),
which is based on [Gearmulator](https://github.com/dsp56300/gearmulator) (GPL-3.0). This repository
contains **no Elektron firmware**. You import your own `elektron_sps1-1uw_os1.63.bin` through the Files app.

**Current stage:** an engine test app that runs the real MD engine on the iPad without JIT and measures
whether it can reach real time. See STATUS.md for measurements, what works and what's blocked.

## Build and install (Xcode only)
1. Download this branch as a ZIP from GitHub and unzip it.
2. Double-click `MDEngineTest.xcodeproj`. Signing is already set to your Personal Team.
3. Plug in the iPad, choose it at the top of the window, and press ▶. The first build takes several
   minutes (around 200 C++ files).
4. On the iPad, import the firmware in the app (Import… › browse to the .bin), optionally import the
   factory cache, then run the tests.

## Layout
- `Engine/source/…`: vendored emulator sources (GPL-3.0), with the iPad changes listed in STATUS.md
- `App/`: SwiftUI test app + Objective-C++ bridge (`App/Bridge/MDEngineTest.mm`)
- `tools/`: desktop benchmark harnesses used to produce the measurements in STATUS.md
