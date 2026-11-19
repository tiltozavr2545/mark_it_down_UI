import 'package:flutter/material.dart';

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff4935bd),
        brightness: brightness,
      ).copyWith(
        surface: dark ? const Color(0xff22213b) : Colors.white,
        onSurface: dark ? const Color(0xfff0edff) : const Color(0xff222343),
        onSurfaceVariant: dark
            ? const Color(0xffc1bcdf)
            : const Color(0xff535574),
        primary: dark ? const Color(0xffc6baff) : const Color(0xff4935bd),
        onPrimary: dark ? const Color(0xff28167f) : Colors.white,
        primaryContainer: dark
            ? const Color(0xff383064)
            : const Color(0xffebe6ff),
        onPrimaryContainer: dark
            ? const Color(0xffe4dbff)
            : const Color(0xff33218f),
        outlineVariant: dark
            ? const Color(0xff4d496a)
            : const Color(0xffdcdcee),
        surfaceContainerLow: dark
            ? const Color(0xff282544)
            : const Color(0xfff8f7fd),
      );
  final theme = ThemeData(
    colorScheme: colors,
    fontFamily: 'Sofia Sans',
    scaffoldBackgroundColor: dark
        ? const Color(0xff19182b)
        : const Color(0xfff0f0fa),
  );
  final text = theme.textTheme;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  return theme.copyWith(
    textTheme: text.copyWith(
      headlineLarge: text.headlineLarge?.copyWith(
        fontSize: 40,
        height: 1.04,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
      ),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      bodyLarge: text.bodyLarge?.copyWith(height: 1.35),
      bodySmall: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        iconSize: 19,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        side: BorderSide(color: colors.outlineVariant),
        iconSize: 19,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        iconSize: 19,
      ),
    ),
  );
}
