import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markitdown_core/markitdown_core.dart';

import '../conversion/convert_picked.dart';
import 'picked_file.dart';

enum FileIntakePhase { idle, converting, ready, failed }

class FileIntakeState {
  final FileIntakePhase phase;

  /// `null` while the link is downloading ([link]) or if it failed to download.
  final StreamInfo? info;

  /// The link currently downloading ("link" mode).
  final String? link;
  final ConversionResult? result;
  final ConversionFailure? failure;

  /// Speech recognition is in progress: show [speechProgress] and "Stop".
  final bool transcribing;

  /// 0-100; 0 means the audio is still decoding or the model is loading.
  final int speechProgress;

  /// "Stop" was pressed — waiting for the end of the current 30-second window.
  final bool stopping;

  const FileIntakeState._(
    this.phase, {
    this.info,
    this.link,
    this.result,
    this.failure,
    this.transcribing = false,
    this.speechProgress = 0,
    this.stopping = false,
  });

  const FileIntakeState.idle() : this._(FileIntakePhase.idle);

  const FileIntakeState.converting(
    StreamInfo info, {
    bool transcribing = false,
    int speechProgress = 0,
    bool stopping = false,
  }) : this._(
         FileIntakePhase.converting,
         info: info,
         transcribing: transcribing,
         speechProgress: speechProgress,
         stopping: stopping,
       );

  const FileIntakeState.downloading(String link)
    : this._(FileIntakePhase.converting, link: link);

  const FileIntakeState.ready(StreamInfo info, ConversionResult result)
    : this._(FileIntakePhase.ready, info: info, result: result);

  const FileIntakeState.failed(StreamInfo? info, ConversionFailure failure)
    : this._(FileIntakePhase.failed, info: info, failure: failure);
}

/// The single entry point for receiving a file — see [PickedFile]. Conversion
/// starts automatically right after intake, with no separate button — see
/// the Stage 1 plan.
class FileIntakeController extends Notifier<FileIntakeState> {
  TranscriptionControl? _control;

  /// Number of the last accepted file. While conversion is running, intake
  /// stays open (drop, "Share"), and a new file replaces the current one:
  /// the result and `finally` of the old call must not touch the new state.
  int _generation = 0;

  @override
  FileIntakeState build() => const FileIntakeState.idle();

  Future<void> accept(PickedFile file) async {
    final generation = _supersede();
    bool current() => generation == _generation;
    final info = infoFor(file);
    state = FileIntakeState.converting(info);

    final outcome = await ref
        .read(pickedConverterProvider)
        .call(
          file,
          info,
          isCurrent: current,
          speech: SpeechHooks(
            onStart: (control) {
              _control = control;
              state = FileIntakeState.converting(info, transcribing: true);
            },
            onProgress: (progress, stopping) {
              state = FileIntakeState.converting(
                info,
                transcribing: true,
                speechProgress: progress,
                stopping: stopping,
              );
            },
            onEnd: (control) {
              if (identical(_control, control)) _control = null;
            },
          ),
        );

    if (outcome == null || !current()) return;
    switch (outcome) {
      case ConversionSuccess(result: final result):
        state = FileIntakeState.ready(info, result);
      case ConversionError(failure: final failure):
        state = FileIntakeState.failed(info, failure);
    }
  }

  /// "Link" mode: download the page or file at [text] (a link, or text with
  /// a link from "Share") and then proceed as a file via [accept]: the same
  /// conversion, the same speech-recognition progress for audio by link.
  Future<void> acceptUrl(String text) async {
    final generation = _supersede();
    state = FileIntakeState.downloading(parseUserUrl(text)?.toString() ?? text);
    final DownloadedUrl downloaded;
    try {
      downloaded = await downloadUrl(text);
    } on WebFetchException catch (e) {
      if (generation == _generation) {
        state = FileIntakeState.failed(null, NetworkFailure(e.reason));
      }
      return;
    }
    // While it was downloading, the person could have picked a file or another link.
    if (generation != _generation) return;
    await accept(
      PickedFile(
        bytes: downloaded.bytes,
        filename: downloaded.filename,
        mimeType: downloaded.mimeType,
        url: downloaded.url,
      ),
    );
  }

  /// Stop speech recognition: what's already been recognized arrives as a
  /// result with a warning that the transcript is incomplete.
  void stopTranscription() {
    final control = _control;
    final info = state.info;
    if (control == null ||
        info == null ||
        state.phase != FileIntakePhase.converting) {
      return;
    }
    control.cancel();
    state = FileIntakeState.converting(
      info,
      transcribing: true,
      speechProgress: control.progress,
      stopping: true,
    );
  }

  void clear() {
    _supersede();
    state = const FileIntakeState.idle();
  }

  /// The current conversion is no longer needed: its speech recognition is
  /// stopped (otherwise it would burn CPU for minutes for nothing), and the
  /// result is discarded.
  int _supersede() {
    _control?.cancel();
    _control = null;
    return ++_generation;
  }
}

final fileIntakeControllerProvider =
    NotifierProvider<FileIntakeController, FileIntakeState>(
      FileIntakeController.new,
    );
