import 'dart:typed_data';

import '../stream_info.dart';
import 'conversion_failure.dart';
import 'conversion_request.dart';
import 'conversion_result.dart';

/// Контракт одного конвертера. См.
/// `docs/conversion-pipeline.md#2-реестр-конвертеров`.
abstract interface class DocumentConverter {
  /// Стабильный идентификатор (`'csv'`, `'html'`, …) — попадает в
  /// [ConversionResult.converterId] и в тексты ошибок.
  String get id;

  /// Меньше — спрашивается раньше. `0.0` — конкретный формат, `10.0` —
  /// общий (`html`, `plain text`).
  double get priority;

  /// Синхронно и без обращения к диску: решение «мой ли это файл»
  /// принимается по [StreamInfo] и уже прочитанным [head]-байтам, а не
  /// потоку — иначе каждый конвертер в цепочке читал бы файл с начала.
  bool accepts(StreamInfo info, Uint8List head);

  /// Бросает [ConversionCorruptedException] на распознанное, но
  /// нечитаемое содержимое — реестр сам превратит это в понятный отказ.
  /// Любое другое исключение реестр тоже перехватит, не показывая его текст
  /// пользователю.
  Future<ConversionResult> convert(ConversionRequest request);
}

/// Конвертер бросает это, когда формат опознан, но содержимое повреждено.
/// [reason] — уже человекочитаемая причина, не текст исключения библиотеки.
class ConversionCorruptedException implements Exception {
  final String reason;

  const ConversionCorruptedException(this.reason);

  @override
  String toString() => reason;
}

/// Конвертер бросает это, когда рекурсия (`zip`/`epub`) наткнулась на
/// [ConversionLimits], уже превышенный вложенным файлом — реестр превращает
/// это в [LimitExceededFailure], а не в generic «файл повреждён». [reason] —
/// уже человекочитаемое описание лимита.
class ConversionLimitExceededException implements Exception {
  final String reason;

  const ConversionLimitExceededException(this.reason);

  @override
  String toString() => reason;
}

/// Конвертер бросает это, когда **не смог** обработать файл, но формат
/// может уметь следующий в цепочке конвертер (сайдкар отказался или упал, а
/// Dart-реализация того же формата есть). В отличие от
/// [ConversionCorruptedException], реестр не завершает прогон, а переходит к
/// следующему конвертеру, чей `accepts()` тоже сказал «да»: частичный или
/// запасной результат полезнее отказа. Если запасного нет или он тоже
/// провалился, пользователю уходит [failure] — отказ первого конвертера, а
/// не generic-ошибка.
class ConversionDeclinedException implements Exception {
  /// Что показать, если дальше по цепочке никто не справился.
  final ConversionFailure failure;

  /// Человекочитаемая пометка в `warnings`, если справился запасной
  /// конвертер («сайдкар не смог обработать файл, результат получен
  /// встроенным разбором»). Без текстов исключений и stderr.
  final String fallbackWarning;

  /// Диагностика для разработчика (хвост stderr сайдкара и т.п.). Пользователю
  /// не показывается никогда — только для логов и отладки.
  final String? diagnostics;

  const ConversionDeclinedException({
    required this.failure,
    required this.fallbackWarning,
    this.diagnostics,
  });

  @override
  String toString() =>
      'ConversionDeclinedException: $fallbackWarning'
      '${diagnostics == null ? '' : '\n$diagnostics'}';
}
