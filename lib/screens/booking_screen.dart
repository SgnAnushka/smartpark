import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../model/parkingspot_model.dart';
import '/apis/booking_api.dart';

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
  void initState() {
    super.initState();
    _restoreBookingState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _restoreBookingState() async {
    await BookingAPI.restoreBookingState(context, widget.spot);
  }

  Future<void> _bookSpot() async {
    await BookingAPI.bookSpot(
      context,
      widget.spot,
      bookingDuration,
      _controller,
          (val) => setState(() { isProcessing = val; }),
    );
  }

  Future<void> _cancelBooking() async {
    await BookingAPI.cancelBooking(
      context,
          (val) => setState(() { isProcessing = val; }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900]?.withOpacity(0.97),
      appBar: AppBar(
        backgroundColor: Colors.grey[900]?.withOpacity(0.97),
        title: Text(
          widget.isCancel ? "Cancel Booking" : "Book Parking Spot",
          style: const TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.spot.name,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            if (!widget.isCancel) ...[
              TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: "Booking Duration (hours)",
                  labelStyle: const TextStyle(color: Colors.white70),
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.teal),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.teal),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.teal),
                  ),
                ),
                style: const TextStyle(color: Colors.white),
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
                    backgroundColor: Colors.teal,
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
                    backgroundColor: Colors.grey,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  child: isProcessing
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Cancel Booking"),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
