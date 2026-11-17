# Roadwise

A GPS navigation app for Android and iPhone that mixes Google Maps–style search and routing with Waze-style community alerts. The Android app works fully offline.

**At a glance**
- 🗺️ Day, night and satellite maps, place search, and routes for car, bike and walking
- 🔊 Turn-by-turn voice navigation with rerouting, speed limits and over-speed chimes
- 🚨 Waze-style reports (police, crashes, hazards, closures, speed traps), with routes that avoid closed roads
- 📍 Live location sharing: friends watch you on a web map, no app needed
- 🚗 Android Auto support
- 📶 Works with no signal: download a whole state's maps, routing and search in one tap
- 🆓 No account, no ads, no API keys; it uses only free, open map services

## Download

### Android

**[⬇️ Download Roadwise.apk](https://github.com/JDavis008/Roadwise/releases/latest/download/Roadwise.apk)** (Android 8.0 or newer)

1. Open the link on your Android phone and download the APK.
2. Open the downloaded file. If Android asks, allow your browser or Files app to **Install unknown apps**.
3. Open Roadwise and allow location access. Allow notifications too, so voice guidance keeps running in the background.

The APK is sideloaded (not from Google Play) and signed with a development key. Every version is listed on the [Releases](https://github.com/JDavis008/Roadwise/releases) page.

### iPhone

**Option 1: web app (works today)**: **[📱 Open Roadwise for iPhone](https://jdavis008.github.io/Roadwise/)**

1. Open the link in **Safari** on your iPhone.
2. Tap the Share button, then **Add to Home Screen**. Roadwise now opens full-screen like a regular app.
3. Open it from your home screen and allow location access.

It has the map (day, night and satellite), search and nearby places, routes for car, bike and walking, voice turn-by-turn with rerouting and speed limits, reports and live sharing (using the same server as Android), Home/Work/Favorites, and a Preview drive. iPhone sets some limits on web apps: guidance only runs while Roadwise is on screen (it keeps the screen awake for you), there's no CarPlay, and offline use is limited to map areas you've already viewed or saved.

**Option 2: native iPhone app (needs a Mac to build)**: the SwiftUI source is in [`ios/`](ios/). It has the same features and keeps navigating with the screen locked. The build steps are in [ios/README.md](ios/README.md). Apple only lets you install apps built in Xcode (on your own phone with a free Apple ID), or through TestFlight and the App Store with a $99/year developer account, so there's no direct download for it.

## What it does

**Maps and search (like Google Maps)**
- Vector map with automatic day/night styles (switches at local sunset), a **Satellite** view (Esri World Imagery aerial photos with street labels, from the Layers button), 3D driving view and a compass
- Search for places, addresses and coordinates, with voice search and "nearby" categories (gas, food, coffee, parking, EV charging, groceries, hotels, hospitals)
- Saved places (Home, Work, Favorites), recent searches, sharing a place, and opening `geo:` links from other apps
- Routes for driving, biking and walking, up to 3 alternatives, and options to avoid tolls, highways or ferries

**Navigation and alerts (like Waze)**
- Turn-by-turn voice guidance (text-to-speech on the phone, so it works offline), automatic rerouting, ETA and arrival time
- Speed-limit sign and speedometer, with a chime when you're over the limit (you set the tolerance)
- Community reports: police, crash, hazard, traffic, closure, speed trap, roadwork and weather. Each can be confirmed or dismissed ("still there" / "not there"), and you get spoken alerts when one is on your route
- Road-closure reports are routed around automatically
- Speed-camera alerts from OpenStreetMap
- "Preview" button that drives a route with simulated GPS, for demos and testing

**Share location**
- Send your current location as a map link that works in any messaging app
- While navigating, share your trip and ETA
- Live location for 15 minutes, 1 hour, 8 hours or until you arrive. People with the link watch you move on a web map in their browser; they don't need the app

**Android Auto**
- The car screen shows the same live map, with turn-by-turn cards (including on the instrument cluster in cars that support it).
- You can search with Home, Work, recents and nearby gas, food, coffee and EV charging, pick a route and tap Go.
- Hazard reports are one tap, "Hey Google, navigate to …" works, and you can pan and zoom the map.
- Because Roadwise is sideloaded (not from the Play Store), Android Auto only lists it after you turn on **Unknown sources**: Android Auto settings → tap Version 10 times to unlock developer settings → ⋮ → Developer settings → Unknown sources.

**Offline**
- One tap downloads your whole state. You can also pick several states from a list, or draw an area on the map
- Each download includes:
  - the map (day and night styles)
  - routing data for on-phone turn-by-turn directions (BRouter)
  - a search index of places and streets
  - speed cameras
- If the phone has no data connection, the app switches to offline routing and search automatically

## Layout
- `app/`: Android app (Kotlin, Jetpack Compose, MapLibre)
- `web/`: iPhone and browser web app (MapLibre GL JS, no build step), deployed to GitHub Pages by `.github/workflows/pages.yml`
- `ios/`: native iPhone app (SwiftUI and MapKit, generated with XcodeGen); `codemagic.yaml` builds it on a cloud Mac
- `brouter/`: the BRouter offline routing engine, bundled (MIT licence, see `LICENSE-BRouter.txt`)
- `server/`: reports and live-location server (Node, no dependencies). Optional: without it the app still does maps, search, navigation and offline use; reports and live sharing need a server URL in Settings

## Build
```
export JAVA_HOME="D:\Android SDK\jbr"
./gradlew :app:assembleRelease   # -> app/build/outputs/apk/release/app-release.apk
```
The release build is signed with the debug key, which is fine for sideloading. Google Play would need a real keystore.

## Server
- Runs hidden and starts automatically at Windows sign-in (`server/install-autostart.ps1`). Stop it with `server/stop.ps1`.
- Listens on `127.0.0.1:48120`. Tailnet-only HTTPS: `https://<your-machine>.<tailnet>.ts.net:9443`
- In the app, go to Settings → Live reports → Report server URL, then tap Save & test
- Tests: `node server/test/server-test.js`

## Data sources
Map data © OpenStreetMap contributors.

| What | Source |
|---|---|
| Map tiles | OpenFreeMap |
| Satellite imagery | Esri World Imagery (needs internet) |
| Online routing | Valhalla (FOSSGIS) |
| Search | Photon (Komoot) |
| Places and cameras | Overpass API |
| Offline routing data | brouter.de |

## Known limits
- There are no live traffic speeds, because no free source exists. Traffic comes from community "Traffic" reports.
- Offline street names come from the downloaded map, so a few small or unnamed roads may show just "Turn left".
