import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../model/parkingspot_model.dart';

class BookingScreen extends StatefulWidget {
  final ParkingSpot spot;
  final bool isCancel;
  const BookingScreen({Key? key, required this.spot, this.isCancel = false}) : super(key: key);

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  bool isProcessing = false;
  int bookingDuration = 0; // in hours
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _bookSpot() async {
    setState(() { isProcessing = true; });

    final ref = FirebaseDatabase.instance.ref('parking_lots');
    final spotSnap = await ref.child(widget.spot.key).get();
    int? cap = spotSnap.child('capacity').value is int ? spotSnap.child('capacity').value as int : null;
    if (cap == null || cap <= 0) {
      setState(() { isProcessing = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Spot not available.')),
      );
      return;
    }

    // Reduce capacity by 1
    await ref.child('${widget.spot.key}/capacity').set(cap - 1);

    // Save booking info locally (store all relevant fields)
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final endTime = now.add(Duration(hours: bookingDuration)).millisecondsSinceEpoch;
    await prefs.setString('booked_spot_key', widget.spot.key);
    await prefs.setString('booked_spot_name', widget.spot.name);
    await prefs.setDouble('booked_spot_lat', widget.spot.location.latitude);
    await prefs.setDouble('booked_spot_lng', widget.spot.location.longitude);
    await prefs.setInt('booked_spot_capacity', widget.spot.capacity);
    await prefs.setInt('booking_end_time', endTime);

    // Save booking history in Firebase
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
      'slotKey': widget.spot.key,
      'slotName': widget.spot.name,
      'slotLat': widget.spot.location.latitude,
      'slotLng': widget.spot.location.longitude,
      'durationHours': bookingDuration,
      'status': 'active',
    });
    // Store bookingId for later cancellation/completion
    await prefs.setString('last_booking_id', newBookingRef.key!);

    setState(() { isProcessing = false; });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Slot booked!')),
    );
    await Future.delayed(const Duration(seconds: 1));
    Navigator.pop(context, true);
  }

  Future<void> _cancelBooking() async {
    setState(() { isProcessing = true; });

    final prefs = await SharedPreferences.getInstance();
    final spotKey = prefs.getString('booked_spot_key');
    final bookingId = prefs.getString('last_booking_id');
    if (spotKey == null) {
      setState(() { isProcessing = false; });
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

    // Update booking history status in Firebase
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

    setState(() { isProcessing = false; });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Booking cancelled.')),
    );
    await Future.delayed(const Duration(seconds: 1));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isCancel ? "Cancel Booking" : "Book Parking Spot"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.spot.name,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.indigo),
            ),
            const SizedBox(height: 24),
            if (!widget.isCancel) ...[
              TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: "Booking Duration (hours)",
                  border: OutlineInputBorder(),
                ),
                onChanged: (val) {
                  final parsed = int.tryParse(val);
                  setState(() {
                    bookingDuration = (parsed != null && parsed > 0) ? parsed : 0;
                  });
                },
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: (isProcessing || bookingDuration <= 0) ? null : _bookSpot,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  child: isProcessing
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Book"),
                ),
              ),
            ],
            if (widget.isCancel) ...[
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: isProcessing ? null : _cancelBooking,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  child: isProcessing
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Cancel Booking"),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}
