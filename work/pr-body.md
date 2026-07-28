## What changed

- Replace the original mascot presentation with cute OpenPets cow/bear frame animations and selectable pet skins.
- Scale the compact pet continuously with portfolio return: 0% keeps the base size, +10% reaches 2×, and -10% reaches 0.5×.
- Resize the transparent draggable window together with the pet so enlarged artwork is not clipped.
- Add live market snapshots, refreshed position trends, stock-related news notifications, updated interactions, and sharing/debug UI.
- Add the new cow app icon and third-party artwork notice.
- Update development/build scripts and README for v0.3.2.

## Why

The desktop pet should stay small and unobtrusive while making portfolio performance immediately visible through its character, expression, and size.

## Impact

The app remains a native SwiftUI macOS development build. Existing dragging, hover positions, notifications, speech, and expanded portfolio UI remain available.

## Validation

- Compiled `native/StockPet.swift` for arm64 macOS 15.
- Validated `run-dev.sh` and `build-native.sh` syntax.
- Validated `native/Info.plist` with `plutil`.
- Visually checked the +10% 2× and -10% 0.5× window states without clipping.

## Asset notice

See `THIRD_PARTY_NOTICES.md` for OpenPets artwork provenance and redistribution notes.
