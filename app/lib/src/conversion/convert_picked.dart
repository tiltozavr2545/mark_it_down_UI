import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';

import '../file_intake/picked_file.dart';
import 'isolated_convert.dart';
import 'ocr_data.dart';
import 'speech_data.dart';

/// What's known about [file] before it's parsed.
StreamInfo infoFor(PickedFile file) => StreamInfo.fromHead(
  file.bytes,
  filename: file.filename,
  mimeType: file.mimeType,
  localPath: file.localPath,
  url: file.url,
);

/// Speech-recognition hooks of one [convertPicked] call.
class SpeechHooks {
  /// Recognition is about to start: keep [control] to cancel it.
  final void Function(TranscriptionControl control) onStart;

  /// The percentage or the "stopping" flag changed (polled every half
  /// second — the isolate is busy in whisper_full and doesn't send
  /// messages).
  final void Function(int progress, bool stopping) onProgress;

  /// The isolate finished and [control] is about to be freed: drop any
  /// reference to it.
  final void Function(TranscriptionControl control) onEnd;

  const SpeechHooks({
    required this.onStart,
    required this.onProgress,
    required this.onEnd,
  });
}

typedef PickedConverter =
    Future<ConversionOutcome?> Function(
      PickedFile file,
      StreamInfo info, {
      required bool Function() isCurrent,
      SpeechHooks? speech,
    });

/// [convertPicked], replaceable in tests: a real conversion needs an
/// isolate and the OCR/speech models.
final pickedConverterProvider = Provider<PickedConverter>(
  (ref) => convertPicked,
);

/// Converts one picked file — the path every intake shares, single file and
/// merge list alike, so the two can't start handling a file differently.
///
/// Returns `null` if [isCurrent] turned false while the speech model was
/// being prepared: the file is no longer wanted, and nothing was converted.
Future<ConversionOutcome?> convertPicked(
  PickedFile file,
  StreamInfo info, {
  required bool Function() isCurrent,
  SpeechHooks? speech,
}) async {
  TranscriptionSettings? transcription;
  TranscriptionControl? control;
  Timer? poll;
  // AudioConverter does the speech recognition, and it takes minutes, not
  // seconds — that's why its files get the progress bar and "Stop" button.
  if (AudioConverter.handles(info.detectedType.kind)) {
    transcription = await transcriptionSettings();
    // Another file arrived while we waited for the model.
    if (!isCurrent()) return null;
    if (transcription != null) {
      control = TranscriptionControl();
      transcription = transcription.withControl(control);
      speech?.onStart(control);
      var progress = 0;
      var stopping = false;
      // Progress is written by native code into shared memory — we poll
      // instead of waiting for messages.
      poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
        // The percentage moves in steps of 5 — without the comparison the
        // listener would rebuild twice a second for nothing.
        if (!isCurrent() ||
            control!.progress == progress && control.cancelled == stopping) {
          return;
        }
        progress = control.progress;
        stopping = control.cancelled;
        speech?.onProgress(progress, stopping);
      });
    }
  }

  try {
    return await isolatedConvert(
      file.bytes,
      info,
      ocr: await ocrSettings(),
      transcription: transcription,
    );
  } finally {
    poll?.cancel();
    // Release only after the isolate finishes: native code writes to
    // control up to the last window.
    if (control != null) {
      speech?.onEnd(control);
      control.dispose();
    }
  }
}
