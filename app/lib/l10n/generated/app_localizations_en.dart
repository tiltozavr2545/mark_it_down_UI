// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get dropHint => 'Drop a file here';

  @override
  String get pickFileButton => 'Choose file';

  @override
  String get pickAnotherButton => 'Choose another file';

  @override
  String get noFilename => '(unnamed)';

  @override
  String get convertingLabel => 'Converting…';

  @override
  String get copyButton => 'Copy';

  @override
  String get copiedConfirmation => 'Copied to clipboard';

  @override
  String get saveAsButton => 'Save as .md';

  @override
  String get savedConfirmation => 'Saved';

  @override
  String get warningsLabel => 'Warnings';

  @override
  String get errorUnsupportedTitle => 'Format not supported';

  @override
  String errorUnsupportedBody(String format) {
    return '$format isn\'t supported yet.';
  }

  @override
  String get errorCorruptedTitle => 'File is corrupted';

  @override
  String errorCorruptedBody(String reason) {
    return 'Couldn\'t read the content: $reason';
  }

  @override
  String get errorLimitTitle => 'Limit exceeded';

  @override
  String errorLimitBody(String description) {
    return '$description';
  }
}
