import 'package:flutter/material.dart';

class DashboardView extends StatelessWidget {
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('{TryCatch}')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Text(
          'Welcome to {TryCatch}!',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ),
    );
  }
}
