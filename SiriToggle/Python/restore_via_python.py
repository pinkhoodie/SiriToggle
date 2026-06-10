#!/usr/bin/env python3
"""
MobileBackup2 restore bridge for SiriToggle.

This script is called by PythonBridgeRestoreStrategy via subprocess.
It uses pymobiledevice3 (the same library Nugget uses) to perform the restore.

Requirements:
    pip install pymobiledevice3

Usage:
    python3 restore_via_python.py <backup_dir_path> [--udid <device_udid>]

Exit codes:
    0 - Success
    1 - Python error / exception
    2 - pymobiledevice3 not installed
    3 - Device not found / not connected
    4 - Find My enabled
    5 - Restore failed
"""

import sys
import os
import argparse
import json
import traceback
import time

# Check pymobiledevice3 availability
try:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.mobilebackup2 import Mobilebackup2Service
    from pymobiledevice3.exceptions import PyMobileDevice3Exception, ConnectionTerminatedError
except ImportError:
    print("ERROR: pymobiledevice3 not installed. Run: pip install pymobiledevice3", file=sys.stderr)
    sys.exit(2)


def progress_callback(percentage):
    """Emit progress as JSON lines for the Swift caller to parse."""
    msg = {
        "type": "progress",
        "value": float(percentage) / 100.0  # 0.0 - 1.0
    }
    print(json.dumps(msg), flush=True)


def emit_status(message):
    """Emit a status message."""
    msg = {
        "type": "status",
        "message": str(message)
    }
    print(json.dumps(msg), flush=True)


def emit_error(message):
    """Emit an error message."""
    msg = {
        "type": "error",
        "message": str(message)
    }
    print(json.dumps(msg), flush=True)
    sys.stderr.write(f"ERROR: {message}\n")


def main():
    parser = argparse.ArgumentParser(description="MobileBackup2 restore bridge")
    parser.add_argument("backup_dir", help="Path to the backup directory")
    parser.add_argument("--udid", help="Device UDID (optional)", default=None)
    args = parser.parse_args()

    backup_dir = os.path.abspath(args.backup_dir)

    if not os.path.isdir(backup_dir):
        emit_error(f"Backup directory not found: {backup_dir}")
        sys.exit(5)

    emit_status("Connecting to device...")

    try:
        # Create lockdown client (USB via usbmuxd)
        if args.udid:
            lockdown = create_using_usbmux(serial=args.udid)
        else:
            lockdown = create_using_usbmux()

        emit_status(f"Connected to {lockdown.identifier}")
        time.sleep(0.5)

        # Perform restore
        emit_status("Starting mobilebackup2 restore...")

        with Mobilebackup2Service(lockdown) as mb:
            mb.restore(
                backup_dir,
                system=True,        # Restore system files (enables RootDomain writes)
                reboot=False,       # Don't auto-reboot
                copy=False,         # Don't copy backup (use in-place)
                source=".",
                progress_callback=progress_callback,
                skip_apps=True      # Skip app restoration (faster, we only need files)
            )

        emit_status("Restore completed successfully")
        print(json.dumps({"type": "complete", "success": True}), flush=True)
        sys.exit(0)

    except PyMobileDevice3Exception as e:
        error_str = str(e)
        if "Find My" in error_str:
            emit_error("Find My must be disabled. Go to Settings -> [Your Name] -> Find My -> turn off.")
            sys.exit(4)
        elif "lockdown" in error_str.lower() or "pair" in error_str.lower():
            emit_error(f"Device pairing failed. Trust this computer on the device and try again. Details: {error_str}")
            sys.exit(3)
        else:
            emit_error(f"pymobiledevice3 error: {error_str}")
            sys.exit(5)

    except ConnectionTerminatedError:
        # This usually means the device rebooted during restore — expected behavior
        emit_status("Device disconnected during restore (expected if rebooting)")
        print(json.dumps({"type": "complete", "success": True}), flush=True)
        sys.exit(0)

    except Exception as e:
        emit_error(f"Unexpected error: {str(e)}")
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
