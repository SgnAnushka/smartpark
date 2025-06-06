import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';

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
}
