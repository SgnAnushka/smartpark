import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '/auth/auth_api.dart';

class HomeScreen extends StatelessWidget {
  final User user;
  final AuthApi _authApi = AuthApi();

  HomeScreen({super.key, required this.user});

  Future<void> _logout() async {
    await _authApi.signOutFromGoogle();
    // No need to navigate manually; AuthGate will rebuild on auth change!
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              backgroundImage: user.photoURL != null
                  ? NetworkImage(user.photoURL!)
                  : null,
              radius: 32,
              child: user.photoURL == null
                  ? const Icon(Icons.person, size: 32)
                  : null,
            ),
            const SizedBox(height: 8),
            Text('Welcome, ${user.displayName ?? user.email}'),
          ],
        ),
      ),
    );
  }
}
