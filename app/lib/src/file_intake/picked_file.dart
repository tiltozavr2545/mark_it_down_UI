import 'dart:typed_data';

/// То общее, что умеют отдать все четыре источника файла (диалог, drag&drop,
/// «Поделиться», буфер обмена), прежде чем попасть в единую точку приёма —
/// [FileIntakeController.accept]. Источники различаются только тем, как эти
/// байты добыты; дальше ветвление запрещено, см.
/// `docs/client-architecture.md#приём-файла-четыре-входа-одна-точка`.
class PickedFile {
  final String? filename;
  final String? mimeType;
  final Uint8List bytes;

  const PickedFile({required this.bytes, this.filename, this.mimeType});
}
