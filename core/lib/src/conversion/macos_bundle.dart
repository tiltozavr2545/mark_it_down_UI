import 'dart:io';

/// Native libraries in a macOS app bundle, alongside the Flutter frameworks.
String get macosBundleFrameworks =>
    '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks';
