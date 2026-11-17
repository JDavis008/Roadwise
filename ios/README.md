# Roadwise for iPhone (native app)

A SwiftUI version of Roadwise for iOS 17 and later. It uses Apple Maps for the map and the same free services as the Android app:

- Valhalla for routing, alternative routes, avoid options and speed limits
- Photon for search and nearby places
- the optional Roadwise server for shared reports and live location

**Features:** speed-camera alerts, a gray trail for the part of the route already driven, place search and nearby categories, Home/Work/Favorites and recent places, routes for car, bike and walking with up to 3 alternatives, voice turn-by-turn that keeps going with the screen locked, automatic rerouting, speed limit and a speeding chime, Waze-style reports with spoken alerts and routing around closures, live location sharing, satellite view, and a Preview drive.

> **Just want it on your iPhone today?** Use the web version: open **https://jdavis008.github.io/Roadwise/** in Safari, tap Share, then **Add to Home Screen**. The native app below needs a Mac to build.

## Build it (needs a Mac with Xcode 15 or newer)

```bash
brew install xcodegen
cd ios
xcodegen generate
open Roadwise.xcodeproj
```

In Xcode, select the **Roadwise** target › Signing & Capabilities, pick your Team, then press Run with your iPhone plugged in. A free Apple ID can install it on your own phone, but that install expires after 7 days. Putting it on other people's phones (TestFlight or the App Store) needs an Apple Developer account, which costs $99 a year.

## Build in the cloud (no Mac)

`codemagic.yaml` at the repo root has an **iOS build (unsigned simulator)** workflow. It builds the app on a cloud Mac, runs a smoke test that searches for a place, and saves screenshots. To use it, connect this GitHub repo at [codemagic.io](https://codemagic.io). The commented-out TestFlight workflow needs an Apple Developer account.

## Status

The app builds on Xcode (cloud Mac via Codemagic) and passes the UI smoke test on the iPhone simulator (latest: build #3, 2026-11-17). The test launches the app, allows location, searches "Ohio Stadium", opens the place card, plans routes, runs a preview drive and ends it. It has not been tried on a real iPhone yet. CarPlay is not included: Apple has to approve the CarPlay navigation entitlement for each developer account.
