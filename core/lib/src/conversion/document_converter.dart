import 'dart:typed_data';

import '../stream_info.dart';
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
