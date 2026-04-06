import 'package:flutter/material.dart';
import 'screens/webview_screen.dart';

class Biota1App extends StatelessWidget {
  const Biota1App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Biota1',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00b4d8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const WebViewScreen(),
    );
  }
}
