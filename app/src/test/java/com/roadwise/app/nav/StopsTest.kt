package com.roadwise.app.nav

import android.location.Location
import android.os.Looper
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import com.roadwise.app.RoadwiseApp
import com.roadwise.app.core.LatLon
import com.roadwise.app.core.Place
import com.roadwise.app.routing.Maneuver
import com.roadwise.app.routing.Route
import com.roadwise.app.routing.Turn
import com.roadwise.app.routing.Waypoint
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Stops on the way: marking them on a route, calling them out, and moving past them. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = RoadwiseApp::class)
class StopsTest {
    private val app get() = ApplicationProvider.getApplicationContext<RoadwiseApp>()
    private val dest = Place("Ohio Stadium", "411 Woody Hayes Dr, Columbus", 40.0000, -83.0000, "stadium", "test")
    private val gas = Waypoint(LatLon(39.9750, -82.9998), "Speedway")   // beside point 15, about 17 m east

    /** Straight north, 40 points about 111 m apart, with a right turn at point 20. */
    private fun route(): Route {
        val pts = (0..40).map { LatLon(39.9600 + it * 0.001, -83.0000) }
        return Route(
            points = pts,
            maneuvers = listOf(
                Maneuver(Turn.DEPART, "Head north on High Street", "Head north on High Street", "High Street", 0),
                Maneuver(Turn.RIGHT, "Turn right onto Rich Street", "Turn right onto Rich Street", "Rich Street", 20),
                Maneuver(Turn.ARRIVE, "Arrive at Ohio Stadium", "Arrive at Ohio Stadium", null, 40),
            ),
            durationS = 320.0, cumTime = DoubleArray(pts.size) { it * 8.0 }, speedLimits = IntArray(pts.size),
            source = "online", label = "via High Street",
        )
    }

    private fun fix(lat: Double, lon: Double = -83.0000) = Location("test").apply {
        latitude = lat; longitude = lon; speed = 13f; bearing = 0f; accuracy = 5f
        time = System.currentTimeMillis(); elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @After fun tearDown() { app.c.nav.stop(); idle() }

    @Test
    fun stopsAreMarkedInOrderWithAnArrivalInstruction() {
        val second = Waypoint(LatLon(39.9900, -83.0001), "Tim Hortons")
        val r = route().withStops(listOf(gas, second))
        assertEquals(listOf(15, 30), r.stopIndex.toList())
        assertEquals(listOf("Head north on High Street", "Arrive at Speedway", "Turn right onto Rich Street", "Arrive at Tim Hortons", "Arrive at Ohio Stadium"),
            r.maneuvers.map { it.text })
        assertEquals(listOf(0, 15, 20, 30, 40), r.maneuvers.map { it.pointIndex })
        // Same points, time and destination as before.
        assertEquals(route().distanceM, r.distanceM, 0.01)
        assertEquals(dest.latLon.lat, r.destination.lat, 1e-9)
        // No stops: the route is unchanged.
        val plain = route()
        assertTrue(plain.withStops(emptyList()) === plain)
    }

    @Test
    fun drivingPastAStopCountsItAndMovesOn() {
        val nav = app.c.nav
        nav.start(route().withStops(listOf(gas)), dest)
        idle()
        assertEquals(listOf("Speedway"), nav.state.value.stops.map { it.name })

        nav.onLocation(fix(39.9700))   // point 10: the stop is next, about 555 m ahead
        idle()
        var s = nav.state.value
        assertEquals("Arrive at Speedway", s.next?.text)
        assertEquals(555.0, s.stopDistM, 15.0)
        assertEquals(40.0, s.stopTimeS, 1.0)
        assertEquals(1, s.stops.size)

        nav.onLocation(fix(39.9762))   // just past it
        idle()
        s = nav.state.value
        assertTrue(s.stops.isEmpty())
        assertTrue(s.message!!.startsWith("Reached Speedway"))
        assertEquals("Turn right onto Rich Street", s.next?.text)
        assertFalse(s.arrived)

        nav.onLocation(fix(39.9999))   // the end
        idle()
        assertTrue(nav.state.value.arrived)
    }

    @Test
    fun pullingIntoTheStopReachesItWithoutGoingOffRoute() {
        val nav = app.c.nav
        nav.start(route().withStops(listOf(gas)), dest)
        idle()
        // In the gas station lot, 60 m off the road: reached, and not "off route".
        repeat(5) { nav.onLocation(fix(39.9751, -82.9993)); idle() }
        val s = nav.state.value
        assertTrue(s.stops.isEmpty())
        assertFalse(s.offRoute)
        assertFalse(s.rerouting)
        // Back on the road the next instruction is the turn, not the stop again.
        nav.onLocation(fix(39.9765)); idle()
        assertEquals("Turn right onto Rich Street", nav.state.value.next?.text)
    }
}
