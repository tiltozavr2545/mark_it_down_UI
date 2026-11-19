// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get workspaceTitle => 'Files to Markdown';

  @override
  String get workspaceIntro =>
      'Convert documents, images, audio and links to .md.';

  @override
  String get localProcessing => 'Files stay on this device';

  @override
  String get dropTitle => 'Drop files here';

  @override
  String get mobileIntakeTitle => 'Add your files';

  @override
  String get chooseFilesButton => 'Choose files';

  @override
  String get outputTitle => 'Output';

  @override
  String get separateOutput => 'Separate files';

  @override
  String get separateOutputHint => 'One .md per source';

  @override
  String get mergedOutput => 'One document';

  @override
  String get mergedOutputHint => 'Combine into a single .md';

  @override
  String get batchTitle => 'File queue';

  @override
  String batchCount(int ready, int total) {
    return 'Ready: $ready of $total';
  }

  @override
  String get previewTooltip => 'Open preview';

  @override
  String get saveFolderButton => 'Save to folder';

  @override
  String get savingLabel => 'Saving…';

  @override
  String get saveFolderTitle => 'Choose a folder for Markdown files';

  @override
  String batchSaved(int count) {
    return 'Saved .md files: $count';
  }

  @override
  String batchSavePartial(int saved, int failed) {
    return 'Saved: $saved. Failed: $failed. You can save each result from its preview.';
  }

  @override
  String get saveFailed =>
      'Could not save. Check access to the destination or choose another folder.';

  @override
  String get pickFailed => 'Could not open the selected files.';

  @override
  String get separateFailedHint =>
      'You can save the files that converted successfully.';

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
  String get incomingTitle => 'Add to the file queue?';

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
