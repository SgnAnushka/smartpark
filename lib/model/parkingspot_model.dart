import 'package:google_maps_flutter/google_maps_flutter.dart';

class ParkingSpot {
  final String key;
  final String name;
  final LatLng location;
  final int capacity;

  ParkingSpot({
    required this.key,
    required this.name,
    required this.location,
    required this.capacity,
  });

  factory ParkingSpot.fromMap(Map<dynamic, dynamic> map, String key) {
    return ParkingSpot(
      key: key,
      name: map['name'] ?? '',
      location: LatLng(
        (map['latitude'] as num).toDouble(),
        (map['longitude'] as num).toDouble(),
      ),
      capacity: map['capacity'] is int
          ? map['capacity']
          : (map['capacity'] is double
          ? (map['capacity'] as double).toInt()
          : int.tryParse('${map['capacity']}') ?? 0),
    );
  }

  bool get isAvailable => capacity > 0;
}
