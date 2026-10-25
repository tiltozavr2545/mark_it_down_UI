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
  String get pasteLinkButton => 'Paste a link';

  @override
  String get linkDialogTitle => 'Link to a page or file';

  @override
  String get linkDialogHint => 'https://…';

  @override
  String get linkDialogNote =>
      'The page or file is downloaded from this link. Your files are not sent anywhere.';

  @override
  String get linkConvertButton => 'Convert';

  @override
  String get cancelButton => 'Cancel';

  @override
  String get downloadingLabel => 'Downloading…';

  @override
  String get convertingLabel => 'Converting…';

  @override
  String get transcribingLabel => 'Recognizing speech…';

  @override
  String transcribingProgressLabel(int percent) {
    return 'Recognizing speech… $percent%';
  }

  @override
  String get transcribingHint =>
      'Offline, on this device. A long recording takes minutes.';

  @override
  String get stoppingLabel => 'Stopping — finishing the current fragment…';

  @override
  String get stopButton => 'Stop';

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
  String get addFilesButton => 'Add files';

  @override
  String get mergeButton => 'Merge';

  @override
  String mergeListTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files to merge',
      one: '$count file to merge',
    );
    return '$_temp0';
  }

  @override
  String mergedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Merged $count files',
      one: 'Merged $count file',
    );
    return '$_temp0';
  }

  @override
  String get mergeOrderHint => 'Files go in this order — drag to change it.';

  @override
  String get mergeWaitingHint =>
      'Merging becomes available once all files are converted.';

  @override
  String get mergeFailedHint =>
      'Remove the files with errors to merge the rest.';

  @override
  String get waitingLabel => 'Queued';

  @override
  String get removeTooltip => 'Remove';

  @override
  String get clearButton => 'Clear';

  @override
  String get backToListButton => 'Back to list';

  @override
  String mergedFileName(String name, int count) {
    return '${name}_and_${count}_more';
  }

  @override
  String get incomingTitle => 'Add to the merge?';

  @override
  String get incomingBody =>
      'There are files on screen already. Add the new ones to them, or start over?';

  @override
  String get startOverButton => 'Start over';

  @override
  String get addButton => 'Add';

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

  @override
  String get errorNetworkTitle => 'Couldn\'t download';

  @override
  String errorNetworkBody(String description) {
    return '$description';
  }
}
