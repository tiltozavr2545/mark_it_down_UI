import 'dart:typed_data';

import '../stream_info.dart';
import 'conversion_failure.dart';
import 'conversion_request.dart';
import 'conversion_result.dart';

/// The contract for a single converter. See
/// `docs/conversion-pipeline.md#2-реестр-конвертеров`.
abstract interface class DocumentConverter {
  /// A stable identifier (`'csv'`, `'html'`, …) — lands in
  /// [ConversionResult.converterId] and in error texts.
  String get id;

  /// Lower is asked earlier. `0.0` is a specific format, `10.0` is
  /// generic (`html`, `plain text`).
  double get priority;

  /// Synchronous and without touching disk: the "is this my file"
  /// decision is made from [StreamInfo] and the already-read [head]
  /// bytes, not the stream — otherwise every converter in the chain
  /// would read the file from the start.
  bool accepts(StreamInfo info, Uint8List head);

  /// Throws [ConversionCorruptedException] for content that's recognized
  /// but unreadable — the registry turns that into an understandable
  /// decline on its own. The registry also catches any other exception,
  /// without showing its text to the user.
  Future<ConversionResult> convert(ConversionRequest request);
}

/// A converter throws this when the format is recognized but the content
/// is damaged. [reason] is already a human-readable cause, not a
/// library exception's text.
class ConversionCorruptedException implements Exception {
  final String reason;

  const ConversionCorruptedException(this.reason);

  @override
  String toString() => reason;
}

/// A converter throws this when recursion (`zip`/`epub`) ran into
/// [ConversionLimits] already exceeded by a nested file — the registry
/// turns this into [LimitExceededFailure] rather than a generic "file
/// damaged". [reason] is already a human-readable description of the
/// limit.
class ConversionLimitExceededException implements Exception {
  final String reason;

  const ConversionLimitExceededException(this.reason);

  @override
  String toString() => reason;
}

/// A converter throws this when it **couldn't** handle the file, but
/// the format might be handled by the next converter in the chain (a
/// sidecar declined or crashed, and a Dart implementation of the same
/// format exists). Unlike [ConversionCorruptedException], the registry
/// doesn't end the run but moves on to the next converter whose
/// `accepts()` also said "yes": a partial or fallback result is more
/// useful than a decline. If there's no fallback, or it fails too, the
/// user gets [failure] — the first converter's decline, not a generic
/// error.
class ConversionDeclinedException implements Exception {
  /// What to show if nobody further down the chain managed it.
  final ConversionFailure failure;

  /// A human-readable note for `warnings` if a fallback converter
  /// handled it ("the sidecar couldn't process the file, the result
  /// came from the built-in parser"). No exception texts or stderr.
  final String fallbackWarning;

  /// Diagnostics for the developer (the sidecar's stderr tail, etc.).
  /// Never shown to the user — logging and debugging only.
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
