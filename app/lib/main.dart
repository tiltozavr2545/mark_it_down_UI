import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/generated/app_localizations.dart';
import 'src/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: MarkItDownApp()));
}

class MarkItDownApp extends StatelessWidget {
  /// `null` — the system locale (normal behavior). This parameter exists
  /// for deterministic screen tests in a specific language.
  final Locale? locale;

  const MarkItDownApp({super.key, this.locale});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MarkItDown UI',
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
