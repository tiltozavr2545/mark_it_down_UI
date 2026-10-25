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
  String get pasteLinkButton => 'Вставить ссылку';

  @override
  String get linkDialogTitle => 'Ссылка на страницу или файл';

  @override
  String get linkDialogHint => 'https://…';

  @override
  String get linkDialogNote =>
      'Страница или файл скачаются по этой ссылке. Ваши файлы никуда не отправляются.';

  @override
  String get linkConvertButton => 'Конвертировать';

  @override
  String get cancelButton => 'Отмена';

  @override
  String get downloadingLabel => 'Скачивается…';

  @override
  String get convertingLabel => 'Конвертируется…';

  @override
  String get transcribingLabel => 'Распознаётся речь…';

  @override
  String transcribingProgressLabel(int percent) {
    return 'Распознаётся речь… $percent %';
  }

  @override
  String get transcribingHint =>
      'Офлайн, на этом устройстве. Длинная запись — это минуты.';

  @override
  String get stoppingLabel =>
      'Останавливается — дожидаемся текущего фрагмента…';

  @override
  String get stopButton => 'Остановить';

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
  String get addFilesButton => 'Добавить файлы';

  @override
  String get mergeButton => 'Склеить';

  @override
  String mergeListTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count файла для склейки',
      many: '$count файлов для склейки',
      few: '$count файла для склейки',
      one: '$count файл для склейки',
    );
    return '$_temp0';
  }

  @override
  String mergedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Склеено $count файла',
      many: 'Склеено $count файлов',
      few: 'Склеено $count файла',
      one: 'Склеен $count файл',
    );
    return '$_temp0';
  }

  @override
  String get mergeOrderHint =>
      'Файлы пойдут в этом порядке — перетащите, чтобы поменять.';

  @override
  String get mergeWaitingHint =>
      'Склеить можно, когда все файлы сконвертируются.';

  @override
  String get mergeFailedHint =>
      'Уберите файлы с ошибкой, чтобы склеить остальные.';

  @override
  String get waitingLabel => 'В очереди';

  @override
  String get removeTooltip => 'Убрать';

  @override
  String get clearButton => 'Очистить';

  @override
  String get backToListButton => 'К списку';

  @override
  String mergedFileName(String name, int count) {
    return '${name}_и_ещё_$count';
  }

  @override
  String get incomingTitle => 'Добавить к склейке?';

  @override
  String get incomingBody =>
      'На экране уже есть файлы. Добавить новое к ним или начать заново?';

  @override
  String get startOverButton => 'Начать заново';

  @override
  String get addButton => 'Добавить';

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

  @override
  String get errorNetworkTitle => 'Не удалось скачать';

  @override
  String errorNetworkBody(String description) {
    return '$description';
  }
}
