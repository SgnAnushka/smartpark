import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../model/parkingspot_model.dart';
import '/screens/bookhis_screen.dart';
import 'booking_screen.dart';
import 'dart:math' as math;
import '../apis/parking_api.dart';

class HomeScreen extends StatefulWidget {
  final User user;
  const HomeScreen({Key? key, required this.user}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  GoogleMapController? mapController;
  LatLng? currentLocation;
  bool isLoading = true;
  String? errorMessage;
  List<LatLng> routePoints = [];
  bool isRouting = false;
  ParkingSpot? selectedSpot;
  double searchRadius = 1000;
  List<String> navigationInstructions = [];
  int currentInstructionIndex = 0;
  MapType mapType = MapType.normal;

  List<ParkingSpot> allParkingSpots = [];
  List<ParkingSpot> nearbyParkingSpots = [];
  StreamSubscription<Position>? positionStreamSubscription;
  StreamSubscription<DatabaseEvent>? firebaseSub;
  StreamSubscription<CompassEvent>? compassStreamSubscription;

  Set<Marker> markers = {};
  Set<Polyline> polylines = {};

  String? bookedSpotKey;
  Timer? _bookingExpiryTimer;
  bool userSelectedSpot = false;

  // Compass and animation variables
  double userHeading = 0.0;
  double userTurns = 0.0;
  double prevHeading = 0.0;

  // FIXED: Cache custom marker to prevent flickering
  BitmapDescriptor? _cachedUserMarker;
  Timer? _markerUpdateTimer;

  @override
  void initState() {
    super.initState();

    ParkingApi.getPermissionAndLocation(
          (loc) => setState(() => currentLocation = loc),
          (loading, error) => setState(() {
        isLoading = loading;
        errorMessage = error;
      }),
          () => _updateNearbyParkingSpots(forceNearest: true),
          (newLoc) {
        setState(() => currentLocation = newLoc);
        // FIXED: Throttle location-based updates
        _throttledUpdateNearbySpots();
      },
          (sub) => positionStreamSubscription = sub,
    );

    ParkingApi.listenToParkingSpots(
          (spots) => setState(() => allParkingSpots = spots),
          () => _updateNearbyParkingSpots(forceNearest: true),
          () => _checkBooking(),
    );

    _bookingExpiryTimer = ParkingApi.startBookingExpiryTimer(() async {
      await _refreshBookingState();
    });

    _restoreBookingStateFromFirebase();
    _setupCompass();
  }

  // FIXED: Throttled updates to prevent constant refreshing
  void _throttledUpdateNearbySpots() {
    _markerUpdateTimer?.cancel();
    _markerUpdateTimer = Timer(const Duration(milliseconds: 500), () {
      if (!userSelectedSpot) {
        _updateNearbyParkingSpots();
      } else {
        // Just update markers without changing selection
        _updateMarkersOnly();
      }
    });
  }

  void _setupCompass() {
    compassStreamSubscription = ParkingApi.setupCompassListener((newHeading) {
      setState(() {
        userTurns = ParkingApi.calculateSmoothTurns(newHeading, prevHeading, userTurns);
        prevHeading = userHeading;
        userHeading = newHeading;
      });
      // FIXED: Only update user marker rotation, not all markers
      _updateUserMarkerRotation();
    });
  }

  // FIXED: Update only user marker rotation without recreating everything
  void _updateUserMarkerRotation() {
    if (currentLocation != null && markers.isNotEmpty) {
      final existingMarkers = Set<Marker>.from(markers);

      // FIXED: Use firstWhere instead of indexWhere for Set
      try {
        final userMarker = existingMarkers.firstWhere(
              (m) => m.markerId.value == 'user',
        );

        // Remove the old marker
        existingMarkers.remove(userMarker);

        // Add updated marker with new rotation
        existingMarkers.add(userMarker.copyWith(
          rotationParam: userHeading,
        ));

        setState(() {
          markers = existingMarkers;
        });
      } catch (e) {
        // User marker not found, do nothing
      }
    }
  }


  @override
  void dispose() {
    positionStreamSubscription?.cancel();
    firebaseSub?.cancel();
    _bookingExpiryTimer?.cancel();
    compassStreamSubscription?.cancel();
    _markerUpdateTimer?.cancel();
    super.dispose();
  }

  // FIXED: Better logic for preserving manual selection
  void _updateNearbyParkingSpots({bool forceNearest = false}) {
    if (currentLocation == null) return;

    final previousNearbySpots = List<ParkingSpot>.from(nearbyParkingSpots);

    setState(() {
      nearbyParkingSpots = allParkingSpots.where((spot) {
        return ParkingApi.calculateDistance(currentLocation!, spot.location) <= searchRadius && spot.isAvailable;
      }).toList();
    });

    if (bookedSpotKey == null) {
      // FIXED: Better preservation of manual selection
      if (userSelectedSpot && selectedSpot != null) {
        // If user manually selected a spot, only change if it's no longer available
        if (!nearbyParkingSpots.contains(selectedSpot)) {
          // Selected spot is no longer nearby, reset
          setState(() {
            selectedSpot = null;
            userSelectedSpot = false;
            routePoints = [];
            navigationInstructions = [];
            currentInstructionIndex = 0;
          });
          if (nearbyParkingSpots.isNotEmpty) {
            _selectNearestSpot();
          }
        }
      } else {
        // No manual selection or forced update
        if (forceNearest || selectedSpot == null || !nearbyParkingSpots.contains(selectedSpot)) {
          if (nearbyParkingSpots.isNotEmpty) {
            _selectNearestSpot();
          } else {
            setState(() {
              selectedSpot = null;
              routePoints = [];
              navigationInstructions = [];
              currentInstructionIndex = 0;
              userSelectedSpot = false;
            });
          }
        }
      }
    }
    _updateMarkersOnly();
  }

  void _selectNearestSpot() {
    if (currentLocation == null || nearbyParkingSpots.isEmpty) {
      setState(() {
        selectedSpot = null;
        userSelectedSpot = false;
      });
      return;
    }
    ParkingSpot? closest;
    double minDist = double.infinity;
    for (var spot in nearbyParkingSpots) {
      double dist = ParkingApi.calculateDistance(currentLocation!, spot.location);
      if (dist < minDist) {
        minDist = dist;
        closest = spot;
      }
    }
    if (closest != null) {
      setState(() {
        selectedSpot = closest;
        isRouting = true;
        routePoints = [];
        navigationInstructions = [];
        currentInstructionIndex = 0;
        // Keep userSelectedSpot as false for auto-selection
      });
      _getRoute(currentLocation!, selectedSpot!.location);
    }
  }

  // FIXED: Ensure manual selection is preserved
  void _onManualSpotSelect(ParkingSpot spot) {
    if (bookedSpotKey != null) return;
    setState(() {
      selectedSpot = spot;
      isRouting = true;
      routePoints = [];
      navigationInstructions = [];
      currentInstructionIndex = 0;
      userSelectedSpot = true; // IMPORTANT: Mark as manually selected
    });
    if (currentLocation != null) {
      _getRoute(currentLocation!, spot.location);
    }
  }

  // FIXED: Separate method for updating markers without selection logic
  void _updateMarkersOnly() {
    ParkingApi.updateMarkers(
      currentLocation,
      nearbyParkingSpots,
      selectedSpot,
      bookedSpotKey,
      userHeading,
      userTurns,
          (m) => setState(() => markers = m),
    );
  }

  Future<void> _getRoute(LatLng start, LatLng end) async {
    await ParkingApi.getRoute(
      start,
      end,
          (points, routing) => setState(() {
        routePoints = points;
        isRouting = routing;
      }),
          () => ParkingApi.updatePolylines(
        routePoints,
            (p) => setState(() => polylines = p),
      ),
          (err) => setState(() => errorMessage = err),
    );
  }

  Future<void> _refreshBookingState() async {
    final prefs = await SharedPreferences.getInstance();
    await ParkingApi.checkAndHandleBookingExpiration(
      prefs,
      prefs.getString('booked_spot_key'),
      prefs.getInt('booking_end_time'),
      prefs.getString('last_booking_id'),
      FirebaseAuth.instance.currentUser?.uid,
    );
    await _checkBooking();
    setState(() {});
  }

  Future<void> _restoreBookingStateFromFirebase() async {
    await ParkingApi.restoreBookingStateFromFirebase(context);
  }

  Future<void> _checkBooking() async {
    final prefs = await SharedPreferences.getInstance();
    await ParkingApi.checkBooking(
      prefs,
      allParkingSpots,
      currentLocation,
          (key, spot) => setState(() {
        bookedSpotKey = key;
        selectedSpot = spot;
        userSelectedSpot = false;
      }),
          (start, end) => _getRoute(start, end),
    );
  }

  void _updateInstructionIndex() {}

  Future<void> _logout() async {
    await ParkingApi.logout();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.grey[900]?.withOpacity(0.97),
        title: const Text("Smart Parking"),
        iconTheme: const IconThemeData(color: Colors.teal),
        titleTextStyle: const TextStyle(
          color: Colors.teal,
          fontSize: 20,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Booking History',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const BookingHistoryScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshBookingState,
            tooltip: "Refresh parking spots",
          ),
        ],
      ),
      body: isLoading || currentLocation == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: currentLocation!,
              zoom: 16,
            ),
            mapType: mapType,
            myLocationEnabled: false,
            myLocationButtonEnabled: true,
            markers: markers,
            polylines: polylines,
            onMapCreated: (controller) => mapController = controller,
            onTap: (latLng) {
              if (bookedSpotKey == null) {
                ParkingSpot? tappedSpot = nearbyParkingSpots.firstWhere(
                      (spot) =>
                  ParkingApi.calculateDistance(latLng, spot.location) < 30,
                  orElse: () => ParkingSpot(
                    key: '',
                    name: '',
                    location: latLng,
                    capacity: 0,
                  ),
                );
                if (tappedSpot.key.isNotEmpty) {
                  _onManualSpotSelect(tappedSpot);
                }
              }
            },
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[900]?.withOpacity(0.97),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 6,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              padding: const EdgeInsets.only(bottom: 12, top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selectedSpot == null || bookedSpotKey == null)
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: Colors.teal[400],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  if (bookedSpotKey == null)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              const Text(
                                'Radius:',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 4,
                                    trackShape: const RoundedRectSliderTrackShape(),
                                    activeTrackColor: Colors.teal[400],
                                    inactiveTrackColor: Colors.grey[700],
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                                    thumbColor: Colors.white,
                                    overlayColor: Colors.teal.withOpacity(0.2),
                                  ),
                                  child: Slider(
                                    min: 0,
                                    max: 4000,
                                    value: searchRadius,
                                    divisions: 40,
                                    onChanged: (value) {
                                      setState(() {
                                        searchRadius = value;
                                        userSelectedSpot = false; // Reset manual selection on radius change
                                      });
                                      _updateNearbyParkingSpots(forceNearest: true);
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${searchRadius.toInt()} m',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 50,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            itemCount: nearbyParkingSpots.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 6),
                            itemBuilder: (context, idx) {
                              final spot = nearbyParkingSpots[idx];
                              final isSelected = spot == selectedSpot;
                              return ChoiceChip(
                                label: Text(
                                  spot.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                selected: isSelected,
                                selectedColor: Colors.teal[400],
                                backgroundColor: Colors.grey[700],
                                avatar: Icon(
                                  Icons.local_parking,
                                  color: isSelected ? Colors.white : Colors.white,
                                  size: 16,
                                ),
                                onSelected: (_) {
                                  if (bookedSpotKey == null) _onManualSpotSelect(spot);
                                },
                              );
                            },
                          ),
                        ),
                        // FIXED: Show book button when spot is selected and not booked
                        if (selectedSpot != null && bookedSpotKey == null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  "${selectedSpot!.name} (${selectedSpot!.capacity})",
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 140,
                                      height: 44,
                                      child: ElevatedButton.icon(
                                        icon: const Icon(Icons.event_seat, size: 18),
                                        label: const Text("Book", style: TextStyle(fontSize: 16)),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.teal[400],
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(14),
                                          ),
                                        ),
                                        onPressed: () async {
                                          if (selectedSpot != null && currentLocation != null) {
                                            final result = await Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) => BookingScreen(
                                                  spot: selectedSpot!,
                                                ),
                                              ),
                                            );
                                            if (result == true) {
                                              await _refreshBookingState();
                                            }
                                          }
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    SizedBox(
                                      width: 140,
                                      height: 44,
                                      child: ElevatedButton.icon(
                                        icon: const Icon(Icons.cancel, size: 18),
                                        label: const Text("Cancel", style: TextStyle(fontSize: 16)),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.grey[700],
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(14),
                                          ),
                                        ),
                                        onPressed: () async {
                                          final result = await Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) => BookingScreen(
                                                spot: selectedSpot!,
                                                isCancel: true,
                                              ),
                                            ),
                                          );
                                          if (result == true) {
                                            await _refreshBookingState();
                                          }
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  if (bookedSpotKey != null && selectedSpot != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "Navigating to: ${selectedSpot!.name}",
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: 140,
                            height: 44,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.cancel, size: 18),
                              label: const Text("Cancel", style: TextStyle(fontSize: 16)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey[700],
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: () async {
                                final result = await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => BookingScreen(
                                      spot: selectedSpot!,
                                      isCancel: true,
                                    ),
                                  ),
                                );
                                if (result == true) {
                                  await _refreshBookingState();
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (isRouting)
            Container(
              color: Colors.black38,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    CircularProgressIndicator(color: Colors.teal),
                    SizedBox(height: 12),
                    Text("Routing...", style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
