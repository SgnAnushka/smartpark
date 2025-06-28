# smartpark

A smart, real-time parking management app built with Flutter.

## Project Overview

**smartpark** is a Flutter-based mobile application designed to simplify the parking experience. It enables users to discover, book, and manage parking spots in real time, leveraging modern mobile and cloud technologies for seamless operation.

## Purpose

- Simplify parking by providing real-time discovery, booking, and management of parking spots.
- Utilize location services, booking management, and live updates to enhance user convenience.

## Key Features

- **User Authentication:**  
  Secure Google Sign-In via Firebase Authentication for safe and easy access.

- **Real-Time Parking Discovery:**  
  View available parking spots on an interactive map, using Google Maps and live location tracking.

- **Smart Booking System:**  
  Book parking spots with automatic management of capacity and booking duration.  
  Prevents double-booking and tracks booking statuses (active, cancelled, etc.).

- **Booking History:**  
  Access detailed records of past bookings, including slot name, date, start/end time, duration, and status.

- **Live Updates:**  
  Real-time updates for parking spot availability and booking status using Firebase Realtime Database.

- **Navigation & Directions:**  
  Get navigation instructions to your booked spot, with compass-based direction and route plotting.

- **Persistent State:**  
  Booked spot details are saved using SharedPreferences to ensure continuity even after app restarts.

## Technical Stack

| Layer            | Technology/Package                    |
|------------------|--------------------------------------|
| Frontend         | Flutter (Dart)                       |
| Backend/Data     | Firebase Authentication, Realtime DB |
| Maps & Location  | Google Maps Flutter, Geolocator, Flutter Compass |
| State Management | setState, stateful widgets           |

## Project Structure

- `lib/main.dart`  
  App entry point, sets up authentication and main navigation.

- `lib/screens/home_screen.dart`  
  Main screen displaying the map and parking functionalities.

- `lib/apis/parking_api.dart`  
  Handles parking spot logic, location, booking state, and marker updates.

- `lib/apis/auth_api.dart`  
  Manages user authentication with Google and Firebase.

- `lib/apis/booking_api.dart` & `lib/apis/bookhis_api.dart`  
  Manage booking logic and user booking history.

## Getting Started

1. **Clone the repository** and install dependencies:
    ```
    git clone https://github.com/yourusername/smartpark.git
    cd smartpark
    flutter pub get
    ```
2. **Set up Firebase**  
   - Create a Firebase project.
   - Enable Google Sign-In and Realtime Database.
   - Download the `google-services.json` (Android) and/or `GoogleService-Info.plist` (iOS) and place them in the appropriate directories.

3. **Add your Google Maps API key**  
   - Follow the [Google Maps Flutter setup guide](https://pub.dev/packages/google_maps_flutter).

4. **Run the app**  
    ```
    flutter run
    ```

## Useful Resources

- [Flutter: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter Cookbook: Useful samples](https://docs.flutter.dev/cookbook)
- [Flutter Documentation](https://docs.flutter.dev/)

## Summary

**smartpark** is a full-featured, real-time smart parking mobile app that lets users find, book, and manage parking spots efficiently. It focuses on ease of use and seamless integration with Google and Firebase services.

---
