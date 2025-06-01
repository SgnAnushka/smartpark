import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../model/parkingspot_model.dart';

class ParkingApi {
  // Firebase listeners and location permissions
  static StreamSubscription<DatabaseEvent>? listenToParkingSpots(
      void Function(List<ParkingSpot>) onUpdate) {
    final ref = FirebaseDatabase.instance.ref('parking_lots');
    return ref.onValue.listen((DatabaseEvent event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        onUpdate([]);
        return;
      }
      final spots = <ParkingSpot>[];
      data.forEach((key, value) {
        if (value is Map<dynamic, dynamic>) {
          spots.add(ParkingSpot.fromMap(value, key));
        }
      });
      onUpdate(spots);
    });
  }

  static Future<LatLng?> getCurrentLocation() async {
    await Permission.location.request();
    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    return LatLng(position.latitude, position.longitude);
  }

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

  static Future<void> checkAndHandleBookingExpiration() async {
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

  static Future<List<LatLng>> getRoute(LatLng start, LatLng end, String apiKey) async {
    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=${start.latitude},${start.longitude}&destination=${end.latitude},${end.longitude}&mode=driving&key=$apiKey';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['routes'] != null && data['routes'].isNotEmpty) {
        final route = data['routes'][0];
        final polyline = route['overview_polyline']['points'];
        return _decodePolyline(polyline);
      }
    }
    return [];
  }

  static List<LatLng> _decodePolyline(String polyline) {
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
}
