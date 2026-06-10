# SiriToggle

iOS 27 Siri AI Waitlist Bypass using BookRestore.

## Features

- Toggle Apple Intelligence / Siri AI waitlist on/off
- Uses BookRestore (same technique as Nugget/misaka26) to write modified `GenerativeModels.plist`
- **3 restore strategies** — choose the one that fits your environment
- Automatic fallback between strategies on failure

## Requirements

- iOS 27 Beta 1 or later
- iPhone 15 Pro or newer
- Developer Mode enabled
- `.mobiledevicepairing` file (generate with `jitterbugpair`)

## The 3 Restore Strategies

SiriToggle implements the mobilebackup2 restore protocol in **3 different ways**. You can select which one to use in the app's gear menu.

### 1. Pure Swift (Default)

**Native Swift implementation** of the DLMessage protocol. Connects directly to the minimuxer tunnel at `localhost:27015`.

| Pros | Cons |
|------|------|
| No external dependencies | Less battle-tested than libimobiledevice |
| Works on-device (iOS) | Protocol edge cases may need handling |
| No C library linking needed | |
| Best for App Store builds | |

**Best for:** iOS on-device builds, when you can't link C libraries.

```swift
// Already selected by default — no setup needed
```

### 2. libimobiledevice

**Uses the C library directly** via `@_silgen_name` declarations and a bridging header.

| Pros | Cons |
|------|------|
| Fastest and most reliable | Requires linking libimobiledevice |
| Battle-tested C code | Not suitable for on-device (iOS) |
| Direct C API access | macOS only |

**Best for:** macOS builds where you control the environment.

**Setup:**
```bash
# Install libimobiledevice
brew install libimobiledevice

# Link in Xcode:
# 1. Add to Bridging-Header.h:
#    #import <libimobiledevice/libimobiledevice.h>
#    #import <libimobiledevice/mobilebackup2.h>
#    #import <libimobiledevice/lockdown.h>
# 2. Add -limobiledevice to Other Linker Flags
# 3. Or use XCFramework: drag libimobiledevice.xcframework into Frameworks/
```

### 3. Python Bridge

**Shells out to pymobiledevice3** — the exact same library that Nugget uses.

| Pros | Cons |
|------|------|
| Easiest to set up | Requires Python 3 at runtime |
| Uses Nugget's own library | Not suitable for App Store distribution |
| Great for development | macOS only |

**Best for:** Development, quick testing, when other options aren't available.

**Setup:**
```bash
pip install pymobiledevice3
```

## Automatic Fallback

If your selected strategy fails, the engine automatically tries the others in order:

1. Your selected strategy
2. Remaining strategies (ordered by reliability)

Certain errors (missing library, missing Python) trigger fallback. Actual restore failures (connection errors, device rejections) are surfaced to the user.

## Project Structure

```
SiriToggle/
├── App/
│   ├── SiriToggleApp.swift          # App entry point
│   └── ContentView.swift            # Main UI with strategy picker
├── Core/
│   ├── RestoreStrategy.swift        # Strategy protocol & enum
│   ├── BookRestoreEngine.swift      # Main restore orchestrator
│   ├── PureSwiftRestoreStrategy.swift   # Option 1: Native Swift
│   ├── LibIMDRestoreStrategy.swift      # Option 2: C library wrapper
│   ├── PythonBridgeRestoreStrategy.swift # Option 3: Python subprocess
│   ├── BackupManifestBuilder.swift  # iTunes backup format generator
│   ├── PlistPayloadBuilder.swift    # GenerativeModels.plist builder
│   ├── MinimuxerBridge.swift        # minimuxer tunnel wrapper
│   └── PairingFileManager.swift     # Pairing file persistence
├── UI/
│   ├── ToggleCardView.swift         # Main toggle UI
│   ├── InfoSheetView.swift          # Help/info sheet
│   └── StrategyPickerView.swift     # Strategy selection UI
└── Python/
    └── restore_via_python.py        # Python bridge script
```

## How It Works

1. **Build plist**: Creates a modified `GenerativeModels.plist` with `EnhancedSiriWaitlist` set to enabled/disabled
2. **Build backup**: Wraps the plist in a valid iTunes backup format (Manifest.db, Info.plist, etc.)
3. **Restore**: Uses mobilebackup2 to push the backup to the device, which writes to `/System/Library/FeatureFlags/Domain/GenerativeModels.plist`
4. **Reboot**: Device must reboot for changes to take effect

## References

- [Nugget](https://github.com/leminlimez/Nugget) — Original Python implementation
- [minimuxer](https://github.com/jkcoxson/minimuxer) — USB tunnel for iOS
- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) — C library for iOS communication
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) — Python iOS communication library
