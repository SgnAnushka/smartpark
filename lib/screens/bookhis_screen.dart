import 'package:flutter/material.dart';
import '/apis/bookhis_api.dart';

class BookingHistoryScreen extends StatefulWidget {
  const BookingHistoryScreen({Key? key}) : super(key: key);

  @override
  State<BookingHistoryScreen> createState() => _BookingHistoryScreenState();
}

class _BookingHistoryScreenState extends State<BookingHistoryScreen> {
  List<Map<String, dynamic>> bookingHistory = [];
  bool isLoading = true;
  late BookingHistoryApi api;

  @override
  void initState() {
    super.initState();
    api = BookingHistoryApi();
    api.loadBookingHistory((history) {
      setState(() {
        bookingHistory = history;
        isLoading = false;
      });
    });
  }

  String _formatTimestamp(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Booking History')),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : bookingHistory.isEmpty
          ? const Center(child: Text('No booking history found.'))
          : ListView.builder(
        itemCount: bookingHistory.length,
        itemBuilder: (context, index) {
          final booking = bookingHistory[index];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTile(
              leading: Icon(
                booking['status'] == 'active'
                    ? Icons.event_available
                    : booking['status'] == 'cancelled'
                    ? Icons.cancel
                    : Icons.check_circle,
                color: booking['status'] == 'active'
                    ? Colors.green
                    : booking['status'] == 'cancelled'
                    ? Colors.red
                    : Colors.blue,
              ),
              title: Text(
                booking['slotName'],
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Date: ${booking['date']}'),
                  Text('Start: ${_formatTimestamp(booking['startTime'])}'),
                  Text('End:   ${_formatTimestamp(booking['endTime'])}'),
                  Text('Duration: ${booking['durationHours']} hour(s)'),
                  Text('Status: ${booking['status']}'),
                ],
              ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }
}
