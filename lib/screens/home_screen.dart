import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../model/parkingspot_model.dart';
import '../apis/parking_api.dart';
import '/screens/bookhis_screen.dart';
import 'booking_screen.dart';

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
  StreamSubscription? firebaseSub;

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
    await ParkingApi.checkAndHandleBookingExpiration();
    await _checkBooking();
    setState(() {});
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
    firebaseSub = ParkingApi.listenToParkingSpots((spots) {
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
      currentLocation = await ParkingApi.getCurrentLocation();
      setState(() {
        isLoading = false;
      });
      _updateNearbyParkingSpots(forceNearest: true);
      // Add location stream logic if needed
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
        return ParkingApi.calculateDistance(currentLocation!, spot.location) <= searchRadius && spot.isAvailable;
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

  Future<void> _getRoute(LatLng start, LatLng end) async {
    const apiKey = String.fromEnvironment('API_KEY');
    final points = await ParkingApi.getRoute(start, end, apiKey);
    setState(() {
      routePoints = points;
      // navigationInstructions logic can be added here if needed
      isRouting = false;
    });
    _updatePolylines();
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
              spot == selectedSpot ? BitmapDescriptor.hueOrange : BitmapDescriptor.hueGreen),
          infoWindow: InfoWindow(
            title: spot.name,
            snippet: 'Capacity: ${spot.capacity}',
            onTap: () {
              if (bookedSpotKey == null) _onManualSpotSelect(spot);
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

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Smart Parking"),
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
          )
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
          // Radius selector as horizontal scrollable chips (hidden when booked)
          if (bookedSpotKey == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 210,
              child: SizedBox(
                height: 50,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [200, 500, 1000, 2000, 3000].map((r) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: ChoiceChip(
                      label: Text('$r m'),
                      selected: searchRadius == r.toDouble(),
                      onSelected: (_) {
                        setState(() {
                          searchRadius = r.toDouble();
                        });
                        _updateNearbyParkingSpots(forceNearest: true);
                      },
                    ),
                  )).toList(),
                ),
              ),
            ),
          // Persistent bottom sheet for parking spots
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: EdgeInsets.only(
                  bottom: mq.padding.bottom > 0 ? mq.padding.bottom : 12, top: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
                boxShadow: [
                  const BoxShadow(
                    color: Colors.black12,
                    blurRadius: 14,
                    offset: Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.indigo[100],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  if (bookedSpotKey == null)
                    SizedBox(
                      height: 60,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: nearbyParkingSpots.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, idx) {
                          final spot = nearbyParkingSpots[idx];
                          final isSelected = spot == selectedSpot;
                          return ChoiceChip(
                            label: Text('${spot.name} (${spot.capacity})'),
                            selected: isSelected,
                            selectedColor: Colors.orange,
                            backgroundColor: Colors.indigo[50],
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.indigo[900],
                              fontWeight: FontWeight.bold,
                            ),
                            avatar: Icon(Icons.local_parking,
                                color: isSelected ? Colors.white : Colors.indigo),
                            onSelected: (_) {
                              if (bookedSpotKey == null) _onManualSpotSelect(spot);
                            },
                          );
                        },
                      ),
                    ),
                  if (selectedSpot != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10, left: 10, right: 10, bottom: 4),
                      child: Column(
                        children: [
                          Text(
                            "Navigating to: ${selectedSpot!.name} (Capacity: ${selectedSpot!.capacity})",
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.indigo,
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 140,
                                height: 48,
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.event_seat),
                                  label: const Text("Book"),
                                  onPressed: (bookedSpotKey != null)
                                      ? null
                                      : () async {
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
                              const SizedBox(width: 16),
                              SizedBox(
                                width: 140,
                                height: 48,
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.cancel),
                                  label: const Text("Cancel"),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.black),
                                  onPressed: (bookedSpotKey == null)
                                      ? null
                                      : () async {
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
            ),
          ),
          if (isRouting)
            Container(
              color: Colors.black38,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    CircularProgressIndicator(color: Colors.indigo),
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
