# SiriToggle

iOS 27 Siri AI Waitlist Bypass using BookRestore with 3 mobilebackup2 strategies.

## Quick Start

1. Generate a pairing file: `./jitterbugpair`
2. Import the `.mobiledevicepairing` file into the app
3. Choose your restore strategy (gear icon)
4. Toggle Siri AI on/off
5. Reboot when prompted

## The 3 Restore Strategies

| Strategy | Dependencies | Best For |
|----------|-------------|----------|
| **Pure Swift** | None | iOS on-device, App Store |
| **libimobiledevice** | `brew install libimobiledevice` | macOS, max reliability |
| **Python Bridge** | `pip install pymobiledevice3` | Development, quick testing |

The app automatically falls back to other strategies if the selected one fails.

See [SiriToggle/README.md](SiriToggle/README.md) for full documentation.
