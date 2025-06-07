import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import '../model/parkingspot_model.dart';
import '/screens/bookhis_screen.dart';
import 'booking_screen.dart';
import 'dart:math' as math;

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

  Set<Marker> markers = {};
  Set<Polyline> polylines = {};

  String? bookedSpotKey;
  Timer? _bookingExpiryTimer;

  @override
  void initState() {
    super.initState();
    _getPermissionAndLocation();
    _listenToParkingSpots();
    _startBookingExpiryTimer();
    _refreshBookingState();
    _restoreBookingStateFromFirebase();
  }

  @override
  void dispose() {
    positionStreamSubscription?.cancel();
    firebaseSub?.cancel();
    _bookingExpiryTimer?.cancel();
    super.dispose();
  }

  void _startBookingExpiryTimer() {
    _bookingExpiryTimer?.cancel();
    _bookingExpiryTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      await _refreshBookingState();
    });
  }

  Future<void> _refreshBookingState() async {
    await checkAndHandleBookingExpiration();
    await _checkBooking();
    setState(() {});
  }

  Future<void> _restoreBookingStateFromFirebase() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || prefs.getString('booked_spot_key') != null) return;

    final activeBooking = await FirebaseDatabase.instance
        .ref('user_booking_history/$userId')
        .orderByChild('status')
        .equalTo('active')
        .once();

    if (activeBooking.snapshot.value != null) {
      final bookingEntry = (activeBooking.snapshot.value as Map<dynamic, dynamic>).entries.first;
      final bookingData = bookingEntry.value as Map<dynamic, dynamic>;
      await prefs.setString('booked_spot_key', bookingData['slotKey']);
      await prefs.setString('last_booking_id', bookingEntry.key);
      await prefs.setString('booked_spot_name', bookingData['slotName']);
      await prefs.setDouble('booked_spot_lat', bookingData['slotLat']);
      await prefs.setDouble('booked_spot_lng', bookingData['slotLng']);
      await prefs.setInt('booked_spot_capacity', bookingData['capacity'] ?? 0);
      await prefs.setInt('booking_end_time', bookingData['endTime']);
    }
  }

  Future<void> checkAndHandleBookingExpiration() async {
    final prefs = await SharedPreferences.getInstance();
    final bookingEndTime = prefs.getInt('booking_end_time');
    final spotKey = prefs.getString('booked_spot_key');
    final bookingId = prefs.getString('last_booking_id');
    final userId = FirebaseAuth.instance.currentUser?.uid;

    if (bookingEndTime != null && spotKey != null && userId != null && bookingId != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now >= bookingEndTime) {
        // 1. Restore capacity
        final ref = FirebaseDatabase.instance.ref('parking_lots/$spotKey/capacity');
        final capSnap = await ref.get();
        int cap = capSnap.value is int ? capSnap.value as int : 0;
        await ref.set(cap + 1);

        // 2. Update booking history status to 'completed'
        final bookingRef = FirebaseDatabase.instance
            .ref('user_booking_history/$userId/$bookingId');
        await bookingRef.update({
          'status': 'completed',
          'completedAt': now,
        });

        // 3. Clear booking state
        await prefs.remove('booked_spot_key');
        await prefs.remove('booked_spot_name');
        await prefs.remove('booked_spot_lat');
        await prefs.remove('booked_spot_lng');
        await prefs.remove('booked_spot_capacity');
        await prefs.remove('booking_end_time');
        await prefs.remove('last_booking_id');
      }
    }
  }

  Future<void> _checkBooking() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('booked_spot_key');
    setState(() {
      bookedSpotKey = key;
      if (key != null) {
        selectedSpot = allParkingSpots.firstWhere(
              (spot) => spot.key == key,
          orElse: () {
            final name = prefs.getString('booked_spot_name') ?? '';
            final lat = prefs.getDouble('booked_spot_lat') ?? 0.0;
            final lng = prefs.getDouble('booked_spot_lng') ?? 0.0;
            final cap = prefs.getInt('booked_spot_capacity') ?? 0;
            return ParkingSpot(
              key: key,
              name: name,
              location: LatLng(lat, lng),
              capacity: cap,
            );
          },
        );
        if (selectedSpot != null && currentLocation != null) {
          _getRoute(currentLocation!, selectedSpot!.location);
        }
      }
    });
  }

  void _listenToParkingSpots() {
    final ref = FirebaseDatabase.instance.ref('parking_lots');
    firebaseSub = ref.onValue.listen((DatabaseEvent event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        setState(() {
          allParkingSpots = [];
        });
        _updateNearbyParkingSpots(forceNearest: true);
        return;
      }
      final spots = <ParkingSpot>[];
      data.forEach((key, value) {
        if (value is Map<dynamic, dynamic>) {
          spots.add(ParkingSpot.fromMap(value, key));
          }
          });
      setState(() {
        allParkingSpots = spots;
      });
      _updateNearbyParkingSpots(forceNearest: true);
      _checkBooking();
    });
  }

  Future<void> _getPermissionAndLocation() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });
    try {
      await Geolocator.requestPermission();
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        currentLocation = LatLng(position.latitude, position.longitude);
        isLoading = false;
      });
      _updateNearbyParkingSpots(forceNearest: true);
      positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen((Position newPosition) {
        setState(() {
          currentLocation = LatLng(newPosition.latitude, newPosition.longitude);
        });
        _updateNearbyParkingSpots();
        if (selectedSpot != null) {
          _getRoute(currentLocation!, selectedSpot!.location);
        }
        _updateInstructionIndex();
      });
    } catch (e) {
      setState(() {
        currentLocation = LatLng(24.953514, 84.011787);
        errorMessage = "Failed to get location. Using default location.";
        isLoading = false;
      });
      _updateNearbyParkingSpots(forceNearest: true);
    }
  }

  void _updateNearbyParkingSpots({bool forceNearest = false}) {
    if (currentLocation == null) return;
    setState(() {
      nearbyParkingSpots = allParkingSpots.where((spot) {
        return _calculateDistance(currentLocation!, spot.location) <= searchRadius && spot.isAvailable;
      }).toList();
    });
    if (bookedSpotKey == null) {
      if (forceNearest || selectedSpot == null || !nearbyParkingSpots.contains(selectedSpot)) {
        if (nearbyParkingSpots.isNotEmpty) {
          _selectNearestSpot();
        } else {
          setState(() {
            selectedSpot = null;
            routePoints = [];
            navigationInstructions = [];
            currentInstructionIndex = 0;
          });
        }
      }
    }
    _updateMarkers();
  }

  void _selectNearestSpot() {
    if (currentLocation == null || nearbyParkingSpots.isEmpty) return;
    ParkingSpot? closest;
    double minDist = double.infinity;
    for (var spot in nearbyParkingSpots) {
      double dist = _calculateDistance(currentLocation!, spot.location);
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
      });
      _getRoute(currentLocation!, selectedSpot!.location);
    }
  }

  void _onManualSpotSelect(ParkingSpot spot) {
    if (bookedSpotKey != null) return;
    setState(() {
      selectedSpot = spot;
      isRouting = true;
      routePoints = [];
      navigationInstructions = [];
      currentInstructionIndex = 0;
    });
    _getRoute(currentLocation!, spot.location);
  }

  double _calculateDistance(LatLng a, LatLng b) {
    const p = 0.017453292519943295;
    final c = (double x) => math.cos(x);
    final d = (double x) => math.sin(x);
    final lat1 = a.latitude * p;
    final lat2 = b.latitude * p;
    final a1 = d((lat2 - lat1) / 2);
    final a2 = d((b.longitude - a.longitude) * p / 2);
    final a3 = a1 * a1 + c(lat1) * c(lat2) * a2 * a2;
    return 12742 * math.asin(math.sqrt(a3)) * 1000; // in meters
  }

  Future<void> _getRoute(LatLng start, LatLng end) async {
    const apiKey = String.fromEnvironment('API_KEY');
    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=${start.latitude},${start.longitude}&destination=${end.latitude},${end.longitude}&mode=driving&key=$apiKey';
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final polyline = route['overview_polyline']['points'];
          final List<LatLng> points = _decodePolyline(polyline);
          setState(() {
            routePoints = points;
            isRouting = false;
          });
          _updatePolylines();
        } else {
          setState(() {
            routePoints = [];
            isRouting = false;
            errorMessage = "No route found.";
          });
        }
      } else {
        setState(() {
          routePoints = [];
          isRouting = false;
          errorMessage = "Failed to fetch route.";
        });
      }
    } catch (e) {
      setState(() {
        routePoints = [];
        isRouting = false;
        errorMessage = "Error fetching route.";
      });
    }
  }

  List<LatLng> _decodePolyline(String polyline) {
    List<LatLng> result = [];
    int index = 0, len = polyline.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, resultInt = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        resultInt |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((resultInt & 1) != 0 ? ~(resultInt >> 1) : (resultInt >> 1));
      lat += dlat;
      shift = 0;
      resultInt = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        resultInt |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((resultInt & 1) != 0 ? ~(resultInt >> 1) : (resultInt >> 1));
      lng += dlng;
      result.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return result;
  }

  void _updateMarkers() {
    Set<Marker> newMarkers = {};
    if (currentLocation != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('user'),
          position: currentLocation!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'You'),
        ),
      );
    }
    for (var spot in nearbyParkingSpots) {
      newMarkers.add(
        Marker(
          markerId: MarkerId(spot.name),
          position: spot.location,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            spot == selectedSpot ? BitmapDescriptor.hueOrange : BitmapDescriptor.hueGreen,
          ),
          infoWindow: InfoWindow(
            title: spot.name,
            snippet: 'Capacity: ${spot.capacity}',
            onTap: () {
              if (bookedSpotKey != null) _onManualSpotSelect(spot);
            },
          ),
        ),
      );
    }
    setState(() {
      markers = newMarkers;
    });
  }

  void _updatePolylines() {
    Set<Polyline> newPolys = {};
    if (routePoints.isNotEmpty) {
      newPolys.add(
        Polyline(
          polylineId: const PolylineId('route'),
          color: Colors.blue,
          width: 6,
          points: routePoints,
        ),
      );
    }
    setState(() {
      polylines = newPolys;
    });
  }

  void _updateInstructionIndex() {}

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
  }

  // ... (all your imports and class/state definitions above remain the same)

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
          //fontWeight: FontWeight.bold,
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
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            markers: markers,
            polylines: polylines,
            onMapCreated: (controller) => mapController = controller,
          ),
          // Bottom pop-up (always visible)
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
                  // Draggable handle (visual cue only)
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
                  // Only show radius slider and chips if not booked
                  if (bookedSpotKey == null)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Radius slider (only if not booked)
                        //if (selectedSpot == null)
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
                        // Spot selection chips (only if not booked)
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
                        // "Book" button (only if not booked and spot selected)
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
                  // When booked, only show spot info and "Cancel" button
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
