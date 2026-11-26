# Roadwise for iPhone (native app)

A SwiftUI version of Roadwise for iOS 17 and later, with CarPlay. It uses the same free map data and services as the Android app:

- MapLibre with OpenFreeMap tiles for the map (light, dark and satellite)
- Valhalla for routing, alternative routes, avoid options and speed limits: the public server online, and the same engine on the phone ([valhalla-mobile](https://github.com/Rallista/valhalla-mobile)) offline
- Photon for search and nearby places online, and a downloaded search index offline
- the optional Roadwise server for shared reports and live location

**Offline:** Settings › Offline maps downloads a whole state: street maps (light and dark), an offline search index, and routing tiles. Maps, search, route planning, rerouting and speed limits then work with no signal, on the phone and in CarPlay. The routing and search packs are built by [`tools/ios-offline`](../tools/ios-offline/README.md).

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

The app builds on Xcode (cloud Mac via Codemagic) and passes the UI smoke test and the CarPlay unit tests on the iPhone simulator (latest: build #5, 2026-11-25). The test launches the app, allows location, searches "Ohio Stadium", opens the place card, plans routes, runs a preview drive and ends it. It has not been tried on a real iPhone yet. CarPlay is built in (see [CARPLAY.md](CARPLAY.md)), but it only shows up in a car once Apple grants the CarPlay navigation entitlement to the developer account.
