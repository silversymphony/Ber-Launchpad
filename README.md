# Ber Launchpad

A native macOS Launchpad replacement replicating macOS Sequoia's fullscreen Launchpad interface and behavior for **macOS 26 (Tahoe) / macOS 27+**, built with Swift, AppKit, SwiftUI, CoreAnimation, and Carbon Global HotKeys.

## Features

- **Fullscreen Frosted Glass UI**: Borderless `NSPanel` overlay using `NSVisualEffectView` (`.fullScreenUI`) across spaces and active display.
- **Global Shortcut & Hardware `F4` Replacement**:
  - Opens/closes with **`⌥ + Space`** (`Option + Space`) or hardware **`F4` (Launchpad)** key.
  - Option to automatically disable the default macOS 26 Applications window (`CGSSetSymbolicHotKeyEnabled` IDs `160`, `161`, `173`, `174`) so only Ber Launchpad appears.
- **Recent app Row**:
  - Dedicated top row titled **`Recent app`** showing recently launched/activated applications at the exact same icon size as the grid, separated by a horizontal divider line.
- **Smart Category Folders & Dynamic Sizing**:
  - Automatically groups installed apps into Category Folders on first launch (*Internet & Social*, *Productivity & Office*, *Graphics & Media*, *Developer Tools*, *Utilities & System*, *Games*, *Other*).
  - Opened category/folder windows match the exact Settings icon size and dynamically resize up to nearly full screen based on item count.
- **Full Drag & Drop, Search & Jiggle Mode**:
  - Instant type-to-search from anywhere (searches top-level and inside folders).
  - Trackpad 2-finger horizontal swipe paging, arrow key navigation, and `Esc` layered dismissal.
  - Drag apps to reorder, merge into folders, rename folders inline, or drag out of folders.
  - Long-press or hold `Option` to enter **Jiggle Mode** and move third-party apps to Trash.
- **Customizable Settings (`⌘ + ,` or gear icon)**:
  - Grid columns (`5–10`) & rows (`4–8`), icon size (`56–110 pt`), backdrop dim, custom hotkey recorder, **Launch at Login** (`LaunchAgent`), Recent Apps toggle, and layout presets (*Category Folders*, *macOS Sequoia Default*, *Alphabetical A–Z*).

## Installation

### Prebuilt App
1. Download `Ber-Launchpad-macOS.zip` from [Releases](https://github.com/silversymphony/Ber-Launchpad/releases).
2. Unzip and move `Ber Launchpad.app` into `/Applications`.
3. Launch `Ber Launchpad.app`, then press **`⌥ + Space`** or **`F4`** anytime.

### Build from Source
Requires macOS 14+ and Swift 6+ Command Line Tools (`arm64` / universal):

```zsh
./build_app.sh
```

This compiles the release binary, generates `AppIcon.icns`, assembles and signs `Ber Launchpad.app`, and installs a copy to `/Applications/Ber Launchpad.app`.
