import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// Shown in the empty drop zone before any file is accepted
  ///
  /// In en, this message translates to:
  /// **'Drop a file here'**
  String get dropHint;

  /// No description provided for @pickFileButton.
  ///
  /// In en, this message translates to:
  /// **'Choose file'**
  String get pickFileButton;

  /// No description provided for @pickAnotherButton.
  ///
  /// In en, this message translates to:
  /// **'Choose another file'**
  String get pickAnotherButton;

  /// No description provided for @noFilename.
  ///
  /// In en, this message translates to:
  /// **'(unnamed)'**
  String get noFilename;

  /// Opens the dialog for converting a web page or a file by its URL
  ///
  /// In en, this message translates to:
  /// **'Paste a link'**
  String get pasteLinkButton;

  /// No description provided for @linkDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Link to a page or file'**
  String get linkDialogTitle;

  /// No description provided for @linkDialogHint.
  ///
  /// In en, this message translates to:
  /// **'https://…'**
  String get linkDialogHint;

  /// Under the URL field: the only network use of the app is downloading what the link points to
  ///
  /// In en, this message translates to:
  /// **'The page or file is downloaded from this link. Your files are not sent anywhere.'**
  String get linkDialogNote;

  /// No description provided for @linkConvertButton.
  ///
  /// In en, this message translates to:
  /// **'Convert'**
  String get linkConvertButton;

  /// No description provided for @cancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelButton;

  /// Shown next to the spinner while the linked page or file is being downloaded
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get downloadingLabel;

  /// Shown next to the spinner while conversion runs
  ///
  /// In en, this message translates to:
  /// **'Converting…'**
  String get convertingLabel;

  /// Audio file: speech recognition started, progress not known (decoding and loading the model, or the file has no duration in its metadata)
  ///
  /// In en, this message translates to:
  /// **'Recognizing speech…'**
  String get transcribingLabel;

  /// Audio file: share of the recording already recognized
  ///
  /// In en, this message translates to:
  /// **'Recognizing speech… {percent}%'**
  String transcribingProgressLabel(int percent);

  /// Under the speech recognition progress bar
  ///
  /// In en, this message translates to:
  /// **'Offline, on this device. A long recording takes minutes.'**
  String get transcribingHint;

  /// After Stop was pressed: whisper finishes the current 30-second window
  ///
  /// In en, this message translates to:
  /// **'Stopping — finishing the current fragment…'**
  String get stoppingLabel;

  /// Stops speech recognition; what is already recognized is kept
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stopButton;

  /// No description provided for @copyButton.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copyButton;

  /// No description provided for @copiedConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedConfirmation;

  /// No description provided for @saveAsButton.
  ///
  /// In en, this message translates to:
  /// **'Save as .md'**
  String get saveAsButton;

  /// No description provided for @savedConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get savedConfirmation;

  /// No description provided for @warningsLabel.
  ///
  /// In en, this message translates to:
  /// **'Warnings'**
  String get warningsLabel;

  /// Adds files to the merge list; on a single file's result, starts a merge with it
  ///
  /// In en, this message translates to:
  /// **'Add files'**
  String get addFilesButton;

  /// Joins all files of the list into one Markdown document
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get mergeButton;

  /// Title of the merge list
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} file to merge} other{{count} files to merge}}'**
  String mergeListTitle(int count);

  /// Title of the merged result preview
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Merged {count} file} other{Merged {count} files}}'**
  String mergedTitle(int count);

  /// No description provided for @mergeOrderHint.
  ///
  /// In en, this message translates to:
  /// **'Files go in this order — drag to change it.'**
  String get mergeOrderHint;

  /// No description provided for @mergeWaitingHint.
  ///
  /// In en, this message translates to:
  /// **'Merging becomes available once all files are converted.'**
  String get mergeWaitingHint;

  /// A failed file blocks the merge until it's removed from the list
  ///
  /// In en, this message translates to:
  /// **'Remove the files with errors to merge the rest.'**
  String get mergeFailedHint;

  /// A merge list item waiting for its turn to be converted
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get waitingLabel;

  /// No description provided for @removeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeTooltip;

  /// Empties the merge list and goes back to the start screen
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clearButton;

  /// No description provided for @backToListButton.
  ///
  /// In en, this message translates to:
  /// **'Back to list'**
  String get backToListButton;

  /// Suggested name (without .md) for saving a merge: the first file's name and how many others follow it
  ///
  /// In en, this message translates to:
  /// **'{name}_and_{count}_more'**
  String mergedFileName(String name, int count);

  /// A file was dropped or shared while a result or the merge list is on screen
  ///
  /// In en, this message translates to:
  /// **'Add to the merge?'**
  String get incomingTitle;

  /// No description provided for @incomingBody.
  ///
  /// In en, this message translates to:
  /// **'There are files on screen already. Add the new ones to them, or start over?'**
  String get incomingBody;

  /// No description provided for @startOverButton.
  ///
  /// In en, this message translates to:
  /// **'Start over'**
  String get startOverButton;

  /// No description provided for @addButton.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get addButton;

  /// No description provided for @errorUnsupportedTitle.
  ///
  /// In en, this message translates to:
  /// **'Format not supported'**
  String get errorUnsupportedTitle;

  /// Shown when no converter accepted the detected format
  ///
  /// In en, this message translates to:
  /// **'{format} isn\'t supported yet.'**
  String errorUnsupportedBody(String format);

  /// No description provided for @errorCorruptedTitle.
  ///
  /// In en, this message translates to:
  /// **'File is corrupted'**
  String get errorCorruptedTitle;

  /// Shown when the format is recognized but the content can't be parsed
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read the content: {reason}'**
  String errorCorruptedBody(String reason);

  /// No description provided for @errorLimitTitle.
  ///
  /// In en, this message translates to:
  /// **'Limit exceeded'**
  String get errorLimitTitle;

  /// Shown when a ConversionLimits value is exceeded
  ///
  /// In en, this message translates to:
  /// **'{description}'**
  String errorLimitBody(String description);

  /// No description provided for @errorNetworkTitle.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t download'**
  String get errorNetworkTitle;

  /// Link mode: the page or file couldn't be downloaded (no connection, HTTP error)
  ///
  /// In en, this message translates to:
  /// **'{description}'**
  String errorNetworkBody(String description);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
