# SiriToggle

SwiftUI iOS app packaged by GitHub Actions as an unsigned IPA.

The workflow in `.github/workflows/build.yml` builds the `SiriToggle` scheme for a generic iOS device with code signing disabled, packages `Payload/SiriToggle.app`, and uploads `SiriToggle.ipa` as a workflow artifact.
