// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get dropHint => 'Перетащите файл сюда';

  @override
  String get pickFileButton => 'Выбрать файл';

  @override
  String get pickAnotherButton => 'Выбрать другой файл';

  @override
  String get noFilename => '(без имени)';

  @override
  String get convertingLabel => 'Конвертируется…';

  @override
  String get copyButton => 'Скопировать';

  @override
  String get copiedConfirmation => 'Скопировано в буфер обмена';

  @override
  String get saveAsButton => 'Сохранить как .md';

  @override
  String get savedConfirmation => 'Сохранено';

  @override
  String get warningsLabel => 'Предупреждения';

  @override
  String get errorUnsupportedTitle => 'Формат не поддерживается';

  @override
  String errorUnsupportedBody(String format) {
    return '$format — такой формат пока не умеем конвертировать.';
  }

  @override
  String get errorCorruptedTitle => 'Файл повреждён';

  @override
  String errorCorruptedBody(String reason) {
    return 'Не удалось прочитать содержимое: $reason';
  }

  @override
  String get errorLimitTitle => 'Превышен лимит';

  @override
  String errorLimitBody(String description) {
    return '$description';
  }
}
