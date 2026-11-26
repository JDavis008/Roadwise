# CarPlay

The native iPhone app has a CarPlay screen in `Roadwise/CarPlay/`. It's the twin of the Android Auto screens (`app/src/main/java/com/roadwise/app/car/`):

- **Map:** Roadwise draws its own map on the car screen, with your position, the route and the destination. Buttons: recenter, zoom in/out, pan.
- **Search:** type or dictate a place. Saved and recent places match first, so they still work with no signal.
- **Places:** Home, Work, favorites and recent places, plus nearby Gas, Food, Coffee, Parking, EV charging, Groceries, Hotels and Hospitals.
- **Route choices:** pick a route on the map and tap **Go**.
- **Turn-by-turn:** the guidance card shows the next two turns, the distance to the next turn, the ETA and the distance left. Spoken directions, reroutes and hazard warnings come from the same engine as the phone. **End** stops the trip.
- **Report:** one tap for police, crash, hazard, traffic, closure, speed trap, roadwork or weather.

The phone and the car share one `AppModel`, so a trip started on the phone shows in the car and the other way round.

## Offline

- A trip that's already running keeps guiding you with no signal: the route, voice and hazard warnings are all on the phone. Rerouting needs a connection.
- Search with no signal shows matching saved and recent places.
- When the connection drops or comes back, a banner on the car screen says so.
- Planning a new route, nearby search and map tiles you haven't viewed yet need a connection. The iPhone app has no downloadable offline maps or offline routing yet; the Android app does.

## Why it doesn't show up in the car yet

1. **Only the native app can appear in CarPlay.** The web app (Add to Home Screen) never can. CarPlay needs the app from `ios/`, installed through TestFlight or the App Store.
2. **Apple must grant the CarPlay navigation entitlement.** Without it, iOS hides the app from CarPlay even though the code is there.

## Steps to turn it on (needs the Apple Developer Program, $99/yr)

1. Join the Apple Developer Program.
2. Request the CarPlay entitlement: https://developer.apple.com/contact/carplay/
   Pick **Navigation** as the category. Describe it as: "Turn-by-turn driving directions with live hazard reports, speed limits and speed camera alerts."
   Apple usually replies in a few days to a few weeks.
3. When Apple approves it, open Certificates, Identifiers & Profiles → Identifiers → `com.roadwise.app` → Capabilities. Turn on **CarPlay Navigation**, then make a new provisioning profile. Signed builds fail until this is done, because `Roadwise/Roadwise.entitlements` asks for `com.apple.developer.carplay-maps`.
4. Build the signed TestFlight workflow in `../codemagic.yaml` and install it from TestFlight.
5. Connect the iPhone to the car. **Roadwise** appears on the CarPlay home screen. If it doesn't, check iPhone Settings → General → CarPlay → your car → Customize.

## Testing without a car

On a Mac in Xcode, run the app on a simulator, then choose **I/O → External Displays → CarPlay** in the Simulator. Use **Features → Location → Freeway Drive** to move the car. You can also use Apple's CarPlay Simulator app (Additional Tools for Xcode) with a real iPhone.

The cloud build (Codemagic) can't open the CarPlay window. It runs `RoadwiseTests/CarPlayTests.swift`, which builds the trips, turn cards, list rows and report grid with the real CarPlay framework and checks that the car scene is registered.
