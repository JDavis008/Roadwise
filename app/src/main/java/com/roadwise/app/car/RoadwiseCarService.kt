package com.roadwise.app.car

import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.util.Log
import androidx.car.app.CarAppService
import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.navigation.NavigationManager
import androidx.car.app.navigation.NavigationManagerCallback
import androidx.car.app.navigation.model.Destination
import androidx.car.app.navigation.model.Trip
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.coroutineScope
import com.roadwise.app.Container
import com.roadwise.app.RoadwiseApp
import com.roadwise.app.core.LatLon
import com.roadwise.app.core.Place
import kotlinx.coroutines.launch

/** Entry point Android Auto binds to. */
class RoadwiseCarService : CarAppService() {
    // Sideloaded personal app: accept any Android Auto host (Play builds would use an allowlist).
    override fun createHostValidator(): HostValidator = HostValidator.ALLOW_ALL_HOSTS_VALIDATOR

    override fun onCreateSession(): Session = RoadwiseSession()
}

class RoadwiseSession : Session(), DefaultLifecycleObserver {
    lateinit var c: Container
    lateinit var renderer: CarMapRenderer
    private var navManager: NavigationManager? = null
    private var navStartedOnCar = false
    private var lastTripAt = 0L

    override fun onCreateScreen(intent: Intent): Screen {
        c = (carContext.applicationContext as RoadwiseApp).c
        renderer = CarMapRenderer(carContext, c, lifecycle)
        lifecycle.addObserver(this)
        val root = CarMapScreen(carContext, this)
        handleNavigateIntent(intent, root)
        return root
    }

    override fun onCreate(owner: LifecycleOwner) {
        ensureLocationPermission()
        watchConnectivity()
        val nm = carContext.getCarService(NavigationManager::class.java)
        navManager = nm
        nm.setNavigationManagerCallback(object : NavigationManagerCallback {
            override fun onStopNavigation() { c.endNavigation() }
            override fun onAutoDriveEnabled() {
                // Desktop Head Unit / testing: drive the active route with simulated GPS.
                c.nav.state.value.route?.let { c.simulator.start(it) }
            }
        })
        // Tell the car (and its instrument cluster) about trips, whoever started them.
        lifecycle.coroutineScope.launch {
            c.nav.state.collect { s ->
                if (s.active && !navStartedOnCar) {
                    runCatching { nm.navigationStarted() }.onFailure { Log.w(TAG, "navigationStarted", it) }
                    navStartedOnCar = true
                } else if (!s.active && navStartedOnCar) {
                    runCatching { nm.navigationEnded() }
                    navStartedOnCar = false
                }
                val now = System.currentTimeMillis()
                if (s.active && !s.arrived && now - lastTripAt > 1000) {
                    lastTripAt = now
                    runCatching { nm.updateTrip(buildTrip(s)) }
                }
            }
        }
    }

    /**
     * Android Auto can't show the system permission dialog on the car screen, so ask on the phone
     * (the host shows "continue on your phone"). Without it the car map has no position.
     */
    private fun ensureLocationPermission() {
        if (c.location.hasPermission) return
        val perms = listOf(android.Manifest.permission.ACCESS_FINE_LOCATION, android.Manifest.permission.ACCESS_COARSE_LOCATION)
        runCatching {
            carContext.requestPermissions(perms) { granted, _ ->
                if (android.Manifest.permission.ACCESS_FINE_LOCATION in granted) c.location.apply()
                else CarToast.makeText(carContext, "Roadwise needs location. Allow it on your phone.", CarToast.LENGTH_LONG).show()
            }
        }.onFailure {
            Log.w(TAG, "requestPermissions", it)
            CarToast.makeText(carContext, "Open Roadwise on your phone to allow location", CarToast.LENGTH_LONG).show()
        }
    }

    /** When the connection drops, tell the driver whether downloaded maps cover where they are. */
    private fun watchConnectivity() {
        lifecycle.coroutineScope.launch {
            var first = true
            c.net.online.collect { online ->
                val wasFirst = first; first = false
                if (online) {
                    if (!wasFirst) CarToast.makeText(carContext, "Back online", CarToast.LENGTH_SHORT).show()
                    return@collect
                }
                val here = c.location.last ?: LatLon(c.prefs.lastLat, c.prefs.lastLon)
                val covered = runCatching { c.db.areas().any { it.status == "ready" && it.bbox.contains(here) } }.getOrDefault(false)
                CarToast.makeText(carContext,
                    if (covered) "Offline - using downloaded maps, search and routing"
                    else "Offline - this area isn't downloaded. Download it in Roadwise on your phone.",
                    CarToast.LENGTH_LONG).show()
            }
        }
    }

    override fun onDestroy(owner: LifecycleOwner) {
        if (navStartedOnCar) runCatching { navManager?.navigationEnded() }
        navManager?.clearNavigationManagerCallback()
    }

    private fun buildTrip(s: com.roadwise.app.nav.NavState): Trip {
        val b = Trip.Builder()
        val est = CarFormat.estimate(s.remainingM, s.remainingS, s.etaMillis, c.prefs.current.imperial)
        s.next?.let { m -> b.addStep(CarFormat.step(m, c.prefs.current.imperial), CarFormat.estimate(s.distToNextM, 0.0, s.etaMillis, c.prefs.current.imperial)) }
        b.addDestination(Destination.Builder().setName(s.destination?.name ?: "Destination").setAddress(s.destination?.address ?: "").build(), est)
        s.currentStreet?.let { b.setCurrentRoad(it) }
        b.setLoading(s.rerouting)
        return b.build()
    }

    override fun onNewIntent(intent: Intent) {
        val top = carContext.getCarService(androidx.car.app.ScreenManager::class.java).top
        handleNavigateIntent(intent, top)
    }

    override fun onCarConfigurationChanged(newConfiguration: Configuration) {
        renderer.setDark(carContext.isDarkMode)
    }

    /** "Hey Google, navigate to …" arrives as ACTION_NAVIGATE with a geo: URI. */
    private fun handleNavigateIntent(intent: Intent, from: Screen) {
        if (intent.action != CarContext.ACTION_NAVIGATE) return
        val uri: Uri = intent.data ?: return
        val ssp = uri.schemeSpecificPart ?: return
        val coords = ssp.substringBefore('?').split(',')
        val lat = coords.getOrNull(0)?.toDoubleOrNull(); val lon = coords.getOrNull(1)?.toDoubleOrNull()
        // geo: URIs are opaque (no getQueryParameter), so read q= by hand.
        val q = ssp.substringAfter("q=", "").substringBefore('&').takeIf { it.isNotBlank() }
            ?.let { Uri.decode(it.replace('+', ' ')) }
        val sm = carContext.getCarService(androidx.car.app.ScreenManager::class.java)
        if (lat != null && lon != null && (lat != 0.0 || lon != 0.0)) {
            sm.push(CarRoutePreviewScreen(carContext, this, Place(q ?: "Destination", "", lat, lon)))
        } else if (!q.isNullOrBlank()) {
            lifecycle.coroutineScope.launch {
                val here = c.location.last ?: LatLon(c.prefs.lastLat, c.prefs.lastLon)
                val hit = runCatching { c.search.search(q, here) }.getOrDefault(emptyList()).firstOrNull()
                if (hit != null) sm.push(CarRoutePreviewScreen(carContext, this@RoadwiseSession, hit))
                else sm.push(CarSearchScreen(carContext, this@RoadwiseSession, q))
            }
        }
    }

    companion object { const val TAG = "RoadwiseSession" }
}
