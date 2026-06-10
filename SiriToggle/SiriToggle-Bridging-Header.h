#ifndef SiriToggle_Bridging_Header_h
#define SiriToggle_Bridging_Header_h

#include <stdbool.h>
#include <stdint.h>

// ============================================================
//  minimuxer C API
//  Source: https://github.com/jkcoxson/minimuxer
//
//  After adding minimuxer.xcframework to the project:
//    1. Uncomment the correct variant below for your build.
//    2. In MinimuxerBridge.swift, uncomment the matching call.
// ============================================================

// Variant A — Path-based (older minimuxer builds)
// void start_minimuxer(const char* pairing_file_path);

// Variant B — Contents-based (preferred, newer minimuxer builds)
// void start_minimuxer_threads(const char* pairing_file_contents, uintptr_t length);

// Returns true if the local usbmuxd tunnel is ready at localhost:27015
// bool minimuxer_ready(void);

// ============================================================
//  To get minimuxer.xcframework:
//  1. Download from https://github.com/jkcoxson/minimuxer/releases
//  2. Place in SiriToggle/Frameworks/minimuxer.xcframework
//  3. In Xcode: Frameworks, Libraries, and Embedded Content → Add
//  4. Uncomment the declarations above
// ============================================================

#endif /* SiriToggle_Bridging_Header_h */
