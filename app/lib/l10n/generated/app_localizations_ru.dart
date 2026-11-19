// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get workspaceTitle => 'Файлы в Markdown';

  @override
  String get workspaceIntro =>
      'Преобразуйте документы, изображения, аудио и ссылки в .md.';

  @override
  String get localProcessing => 'Файлы остаются на устройстве';

  @override
  String get dropTitle => 'Перетащите файлы сюда';

  @override
  String get mobileIntakeTitle => 'Добавьте файлы';

  @override
  String get chooseFilesButton => 'Выбрать файлы';

  @override
  String get outputTitle => 'Результат';

  @override
  String get separateOutput => 'Отдельные файлы';

  @override
  String get separateOutputHint => 'По одному .md на исходник';

  @override
  String get mergedOutput => 'Один документ';

  @override
  String get mergedOutputHint => 'Объединить в один .md';

  @override
  String get batchTitle => 'Список файлов';

  @override
  String batchCount(int ready, int total) {
    return 'Готово: $ready из $total';
  }

  @override
  String get previewTooltip => 'Открыть предпросмотр';

  @override
  String get saveFolderButton => 'Сохранить в папку';

  @override
  String get savingLabel => 'Сохраняется…';

  @override
  String get saveFolderTitle => 'Выберите папку для Markdown-файлов';

  @override
  String batchSaved(int count) {
    return 'Сохранено .md-файлов: $count';
  }

  @override
  String batchSavePartial(int saved, int failed) {
    return 'Сохранено: $saved. Не удалось сохранить: $failed. Каждый результат можно сохранить из предпросмотра.';
  }

  @override
  String get saveFailed =>
      'Не удалось сохранить. Проверьте доступ или выберите другую папку.';

  @override
  String get pickFailed => 'Не удалось открыть выбранные файлы.';

  @override
  String get separateFailedHint =>
      'Можно сохранить файлы, которые удалось преобразовать.';

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
  String get mergeButton => 'Объединить';

  @override
  String mergedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Объединено $count файла',
      many: 'Объединено $count файлов',
      few: 'Объединены $count файла',
      one: 'Объединён $count файл',
    );
    return '$_temp0';
  }

  @override
  String get mergeOrderHint =>
      'Перетащите файлы, чтобы изменить порядок в документе.';

  @override
  String get mergeWaitingHint =>
      'Объединение станет доступно после преобразования всех файлов.';

  @override
  String get mergeFailedHint =>
      'Уберите файлы с ошибкой, чтобы объединить остальные.';

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
  String get incomingTitle => 'Добавить к списку файлов?';

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
