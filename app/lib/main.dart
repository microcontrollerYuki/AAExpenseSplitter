import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/home_shell.dart';
import 'theme.dart';

void main() {
  runApp(const ProviderScope(child: AAApp()));
}

class AAApp extends StatelessWidget {
  const AAApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AA记账',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: kPrimaryColor,
        scaffoldBackgroundColor: const Color(0xFFF4F6F5),
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      locale: const Locale('zh', 'CN'),
      home: const HomeShell(),
    );
  }
}
