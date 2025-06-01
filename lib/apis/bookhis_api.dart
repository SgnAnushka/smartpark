import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class BookingHistoryApi {
  final userId = FirebaseAuth.instance.currentUser!.uid;
  late DatabaseReference historyRef;

  BookingHistoryApi() {
    historyRef = FirebaseDatabase.instance.ref('user_booking_history/$userId');
  }

  void loadBookingHistory(Function(List<Map<String, dynamic>>) onLoaded) {
    historyRef.onValue.listen((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) {
        onLoaded([]);
        return;
      }
      final List<Map<String, dynamic>> bookings = [];
      data.forEach((key, value) {
        if (value is Map) {
          bookings.add({
            'id': key,
            'slotName': value['slotName'] ?? '',
            'date': value['date'] ?? '',
            'startTime': value['startTime'] ?? 0,
            'endTime': value['endTime'] ?? 0,
            'durationHours': value['durationHours'] ?? 0,
            'status': value['status'] ?? 'unknown',
          });
        }
      });
      bookings.sort((a, b) => b['startTime'].compareTo(a['startTime']));
      onLoaded(bookings);
    });
  }
}
