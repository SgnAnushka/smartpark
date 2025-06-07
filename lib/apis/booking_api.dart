import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../model/parkingspot_model.dart';

class BookingAPI {
  static Future<void> restoreBookingState(BuildContext context, ParkingSpot spot) async {
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
    }
  }

  static Future<void> bookSpot(
      BuildContext context,
      ParkingSpot spot,
      int bookingDuration,
      TextEditingController controller,
      void Function(bool) setProcessing,
      ) async {
    setProcessing(true);

    final ref = FirebaseDatabase.instance.ref('parking_lots');
    final spotSnap = await ref.child(spot.key).get();
    int? cap = spotSnap.child('capacity').value is int ? spotSnap.child('capacity').value as int : null;
    if (cap == null || cap <= 0) {
      setProcessing(false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Spot not available.')),
      );
      return;
    }

    await ref.child('${spot.key}/capacity').set(cap - 1);

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final endTime = now.add(Duration(hours: bookingDuration)).millisecondsSinceEpoch;
    await prefs.setString('booked_spot_key', spot.key);
    await prefs.setString('booked_spot_name', spot.name);
    await prefs.setDouble('booked_spot_lat', spot.location.latitude);
    await prefs.setDouble('booked_spot_lng', spot.location.longitude);
    await prefs.setInt('booked_spot_capacity', spot.capacity);
    await prefs.setInt('booking_end_time', endTime);

    final user = FirebaseAuth.instance.currentUser!;
    final userId = user.uid;
    final userEmail = user.email ?? '';
    final historyRef = FirebaseDatabase.instance.ref('user_booking_history/$userId');
    final newBookingRef = historyRef.push();

    await newBookingRef.set({
      'userEmail': userEmail,
      'date': "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}",
      'startTime': now.millisecondsSinceEpoch,
      'endTime': endTime,
      'slotKey': spot.key,
      'slotName': spot.name,
      'slotLat': spot.location.latitude,
      'slotLng': spot.location.longitude,
      'durationHours': bookingDuration,
      'status': 'active',
    });
    await prefs.setString('last_booking_id', newBookingRef.key!);

    setProcessing(false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Slot booked!')),
    );
    await Future.delayed(const Duration(seconds: 1));
    Navigator.pop(context, true);
  }

  static Future<void> cancelBooking(
      BuildContext context,
      void Function(bool) setProcessing,
      ) async {
    setProcessing(true);

    final prefs = await SharedPreferences.getInstance();
    final spotKey = prefs.getString('booked_spot_key');
    final bookingId = prefs.getString('last_booking_id');
    if (spotKey == null) {
      setProcessing(false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No booking found.')),
      );
      return;
    }
    final ref = FirebaseDatabase.instance.ref('parking_lots');
    final capSnap = await ref.child('$spotKey/capacity').get();
    int? cap = capSnap.value is int ? capSnap.value as int : null;
    if (cap == null) cap = 0;
    await ref.child('$spotKey/capacity').set(cap + 1);

    if (bookingId != null) {
      final userId = FirebaseAuth.instance.currentUser!.uid;
      final bookingRef = FirebaseDatabase.instance
          .ref('user_booking_history/$userId/$bookingId');
      await bookingRef.update({
        'status': 'cancelled',
        'cancelledAt': DateTime.now().millisecondsSinceEpoch,
      });
      await prefs.remove('last_booking_id');
    }

    await prefs.remove('booked_spot_key');
    await prefs.remove('booked_spot_name');
    await prefs.remove('booked_spot_lat');
    await prefs.remove('booked_spot_lng');
    await prefs.remove('booked_spot_capacity');
    await prefs.remove('booking_end_time');

    setProcessing(false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Booking cancelled.')),
    );
    await Future.delayed(const Duration(seconds: 1));
    Navigator.pop(context, true);
  }
}
