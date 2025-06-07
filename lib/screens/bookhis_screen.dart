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
      backgroundColor: Colors.grey[900]?.withOpacity(0.97),
      appBar: AppBar(
        backgroundColor: Colors.grey[900]?.withOpacity(0.97),
        title: const Text(
          'Booking History',
          style: TextStyle(color: Colors.teal),
        ),
        iconTheme: const IconThemeData(color: Colors.teal),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.teal))
          : bookingHistory.isEmpty
          ? const Center(
        child: Text(
          'No booking history found.',
          style: TextStyle(color: Colors.white),
        ),
      )
          : ListView.builder(
        itemCount: bookingHistory.length,
        itemBuilder: (context, index) {
          final booking = bookingHistory[index];
          return Card(
            color: Colors.grey[800],
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTile(
              leading: Icon(
                booking['status'] == 'active'
                    ? Icons.event_available
                    : booking['status'] == 'cancelled'
                    ? Icons.cancel
                    : Icons.check_circle,
                color: booking['status'] == 'active'
                    ? Colors.teal[400]
                    : booking['status'] == 'cancelled'
                    ? Colors.red[400]
                    : Colors.blueGrey,
              ),
              title: Text(
                booking['slotName'],
                style: const TextStyle(
                    //fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Date: ${booking['date']}',
                      style: const TextStyle(color: Colors.white70)),
                  Text('Start: ${_formatTimestamp(booking['startTime'])}',
                      style: const TextStyle(color: Colors.white70)),
                  Text('End:   ${_formatTimestamp(booking['endTime'])}',
                      style: const TextStyle(color: Colors.white70)),
                  Text('Duration: ${booking['durationHours']} hour(s)',
                      style: const TextStyle(color: Colors.white70)),
                  Text('Status: ${booking['status']}',
                      style: TextStyle(
                          color: booking['status'] == 'active'
                              ? Colors.teal[400]
                              : booking['status'] == 'cancelled'
                              ? Colors.red[400]
                              : Colors.blueGrey,
                          //fontWeight: FontWeight.bold
                         )
                  ),
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
