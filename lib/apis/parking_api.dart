import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;
import '../model/parkingspot_model.dart';
import '/screens/bookhis_screen.dart';
import '/screens/booking_screen.dart';

class ParkingApi {
  static double calculateDistance(LatLng a, LatLng b) {
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

  static Timer startBookingExpiryTimer(Future<void> Function() refreshBookingState) {
    return Timer.periodic(const Duration(seconds: 10), (timer) async {
      await refreshBookingState();
    });
  }

  // Setup compass listener for real-time direction
  static StreamSubscription<CompassEvent>? setupCompassListener(
      void Function(double heading) onHeadingChanged) {
    return FlutterCompass.events?.listen((CompassEvent event) {
      double? heading = event.heading;
      if (heading != null) {
        // Normalize heading to 0-360 range
        heading = heading < 0 ? (360 + heading) : heading;
        onHeadingChanged(heading);
      }
    });
  }

  // Convert heading to smooth turns for animation
  static double calculateSmoothTurns(double newHeading, double prevHeading, double currentTurns) {
    double diff = newHeading - prevHeading;

    // Handle 360° transition smoothly
    if (diff.abs() > 180) {
      if (prevHeading > newHeading) {
        diff = 360 - (newHeading - prevHeading).abs();
      } else {
        diff = 360 - (prevHeading - newHeading).abs();
        diff = diff * -1;
      }
    }

    return currentTurns + (diff / 360);
  }

  static Future<void> restoreBookingStateFromFirebase(BuildContext context) async {
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

  static Future<void> checkAndHandleBookingExpiration(
      SharedPreferences prefs,
      String? spotKey,
      int? bookingEndTime,
      String? bookingId,
      String? userId) async {
    if (bookingEndTime != null && spotKey != null && userId != null && bookingId != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now >= bookingEndTime) {
        final ref = FirebaseDatabase.instance.ref('parking_lots/$spotKey/capacity');
        final capSnap = await ref.get();
        int cap = capSnap.value is int ? capSnap.value as int : 0;
        await ref.set(cap + 1);

        final bookingRef = FirebaseDatabase.instance
            .ref('user_booking_history/$userId/$bookingId');
        await bookingRef.update({
          'status': 'completed',
          'completedAt': now,
        });
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

  static Future<void> checkBooking(
      SharedPreferences prefs,
      List<ParkingSpot> allParkingSpots,
      LatLng? currentLocation,
      void Function(String? bookedSpotKey, ParkingSpot? selectedSpot) setStateCallback,
      Future<void> Function(LatLng, LatLng) getRoute) async {
    final key = prefs.getString('booked_spot_key');
    ParkingSpot? selectedSpot;
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
        await getRoute(currentLocation, selectedSpot.location);
      }
    }
    setStateCallback(key, selectedSpot);
  }

  static void listenToParkingSpots(
      void Function(List<ParkingSpot> spots) setAllParkingSpots,
      void Function() updateNearbyParkingSpots,
      void Function() checkBooking) {
    final ref = FirebaseDatabase.instance.ref('parking_lots');
    ref.onValue.listen((DatabaseEvent event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        setAllParkingSpots([]);
        updateNearbyParkingSpots();
        return;
      }
      final spots = <ParkingSpot>[];
      data.forEach((key, value) {
        if (value is Map<dynamic, dynamic>) {
          spots.add(ParkingSpot.fromMap(value, key));
        }
      });
      setAllParkingSpots(spots);
      updateNearbyParkingSpots();
      checkBooking();
    });
  }

  static Future<void> getPermissionAndLocation(
      void Function(LatLng currentLocation) setCurrentLocation,
      void Function(bool isLoading, String? errorMessage) setLoading,
      void Function() updateNearbyParkingSpots,
      void Function(LatLng currentLocation) onPositionChange,
      void Function(StreamSubscription<Position> sub) setPositionStreamSubscription) async {
    setLoading(true, null);
    try {
      await Geolocator.requestPermission();
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final latLng = LatLng(position.latitude, position.longitude);
      setCurrentLocation(latLng);
      setLoading(false, null);
      updateNearbyParkingSpots();
      final sub = Geolocator.getPositionStream(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5, // Update every 5 meters for smoother animation
        ),
      ).listen((Position newPosition) {
        final newLatLng = LatLng(newPosition.latitude, newPosition.longitude);
        onPositionChange(newLatLng);
        updateNearbyParkingSpots();
      });
      setPositionStreamSubscription(sub);
    } catch (e) {
      setCurrentLocation(LatLng(24.953514, 84.011787));
      setLoading(false, "Failed to get location. Using default location.");
      updateNearbyParkingSpots();
    }
  }

  // Create custom animated user marker instead of default blue marker
  static void updateMarkers(
      LatLng? currentLocation,
      List<ParkingSpot> nearbyParkingSpots,
      ParkingSpot? selectedSpot,
      String? bookedSpotKey,
      double userHeading,
      double userTurns,
      void Function(Set<Marker> markers) setMarkers) async {
    Set<Marker> newMarkers = {};

    // Custom animated user location marker
    if (currentLocation != null) {
      // Create custom marker icon
      final BitmapDescriptor customIcon = await BitmapDescriptor.fromBytes(
        await _createCustomMarkerIcon(userHeading),
      );

      newMarkers.add(
        Marker(
          markerId: const MarkerId('user'),
          position: currentLocation,
          icon: customIcon,
          anchor: const Offset(0.5, 0.5), // Center the marker
          infoWindow: const InfoWindow(title: 'Your Location'),
          flat: true, // Keep marker flat on the map
          rotation: userHeading, // Apply rotation directly to marker
        ),
      );
    }

    // Parking spot markers remain the same
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
          ),
        ),
      );
    }
    setMarkers(newMarkers);
  }

  // UPDATED: Create even larger custom marker icon (doubled again)
  static Future<Uint8List> _createCustomMarkerIcon(double heading) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    const double size = 240.0; // INCREASED from 120.0 to 240.0 (doubled again)

    // Draw outer circle (radar effect) - much larger
    final Paint outerPaint = Paint()
      ..color = Colors.blue.withOpacity(0.3)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, outerPaint);

    // Draw inner circle - much larger
    final Paint innerPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(size / 2, size / 2), 40, innerPaint); // INCREASED from 20 to 40

    // Draw white border - much larger
    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6; // INCREASED from 3 to 6
    canvas.drawCircle(const Offset(size / 2, size / 2), 40, borderPaint); // INCREASED from 20 to 40

    // Draw navigation arrow (pointing up, rotation is handled by marker) - much larger
    final Paint arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final Path arrowPath = Path();
    const double arrowSize = 28.0; // INCREASED from 14.0 to 28.0
    const double centerX = size / 2;
    const double centerY = size / 2;

    arrowPath.moveTo(centerX, centerY - arrowSize / 2); // Top point
    arrowPath.lineTo(centerX - arrowSize / 3, centerY + arrowSize / 2); // Bottom left
    arrowPath.lineTo(centerX + arrowSize / 3, centerY + arrowSize / 2); // Bottom right
    arrowPath.close();

    canvas.drawPath(arrowPath, arrowPaint);

    // Convert to image
    final ui.Picture picture = pictureRecorder.endRecording();
    final ui.Image image = await picture.toImage(size.toInt(), size.toInt());
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    return byteData!.buffer.asUint8List();
  }

  static Future<void> getRoute(
      LatLng start,
      LatLng end,
      void Function(List<LatLng> routePoints, bool isRouting) setStateCallback,
      void Function() updatePolylines,
      void Function(String errorMessage) setErrorMessage) async {
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
          final List<LatLng> points = decodePolyline(polyline);
          setStateCallback(points, false);
          updatePolylines();
        } else {
          setStateCallback([], false);
          setErrorMessage("No route found.");
        }
      } else {
        setStateCallback([], false);
        setErrorMessage("Failed to fetch route.");
      }
    } catch (e) {
      setStateCallback([], false);
      setErrorMessage("Error fetching route.");
    }
  }

  static List<LatLng> decodePolyline(String polyline) {
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

  static void updatePolylines(
      List<LatLng> routePoints,
      void Function(Set<Polyline> polylines) setPolylines) {
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
    setPolylines(newPolys);
  }

  static Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
  }
}
