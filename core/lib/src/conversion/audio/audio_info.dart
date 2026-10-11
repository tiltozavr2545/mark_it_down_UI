/// Теги аудиофайла, сведённые из ID3, Vorbis comment, `ilst` MP4 и
/// `LIST/INFO` WAV к одному набору полей. Заполняется «первый выигрывает»:
/// ID3v2 читается раньше ID3v1, и обрезанное до 30 символов название из v1
/// не перетирает полное.
class AudioTags {
  String? title;
  String? artist;
  String? albumArtist;
  String? album;
  String? year;
  String? genre;
  String? track;
  String? composer;
  String? comment;
  String? lyrics;

  /// Ключ — нормализованное имя поля (`title`, `artist`…), как его называет
  /// Vorbis comment; остальные форматы переводят свои имена в эти.
  void set(String field, String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    switch (field) {
      case 'title':
        title ??= trimmed;
      case 'artist':
        artist ??= trimmed;
      case 'albumartist':
        albumArtist ??= trimmed;
      case 'album':
        album ??= trimmed;
      case 'year':
        year ??= trimmed;
      case 'genre':
        genre ??= trimmed;
      case 'track':
        track ??= trimmed;
      case 'composer':
        composer ??= trimmed;
      case 'comment':
        comment ??= trimmed;
      case 'lyrics':
        lyrics ??= trimmed;
    }
  }
}

/// Что известно о звуке и контейнере. Всё необязательно: битый или
/// обрезанный файл даёт то, что удалось прочитать.
class AudioInfo {
  final tags = AudioTags();
  Duration? duration;
  String? codec;
  int? sampleRate;
  int? channels;
  int? bitrateKbps;

  /// Битрейт средний (VBR), а не постоянный — пишется с `~`.
  bool variableBitrate = false;

  /// Размер видеодорожки, если это видео (MP4/MOV/3GP).
  int? videoWidth;
  int? videoHeight;
  bool hasVideo = false;
  bool hasAudio = false;

  /// Структура где-то указывала за пределы файла или была неправдоподобной.
  bool damaged = false;
}

/// Названия жанров ID3v1 по номеру (0–79, стандартная часть таблицы).
/// В ID3v2 жанр тоже часто пишется номером: `(17)` или `17`.
const id3Genres = [
  'Blues', 'Classic Rock', 'Country', 'Dance', 'Disco', 'Funk', 'Grunge', //
  'Hip-Hop', 'Jazz', 'Metal', 'New Age', 'Oldies', 'Other', 'Pop', 'R&B', //
  'Rap', 'Reggae', 'Rock', 'Techno', 'Industrial', 'Alternative', 'Ska', //
  'Death Metal', 'Pranks', 'Soundtrack', 'Euro-Techno', 'Ambient', //
  'Trip-Hop', 'Vocal', 'Jazz+Funk', 'Fusion', 'Trance', 'Classical', //
  'Instrumental', 'Acid', 'House', 'Game', 'Sound Clip', 'Gospel', 'Noise', //
  'Alternative Rock', 'Bass', 'Soul', 'Punk', 'Space', 'Meditative', //
  'Instrumental Pop', 'Instrumental Rock', 'Ethnic', 'Gothic', 'Darkwave', //
  'Techno-Industrial', 'Electronic', 'Pop-Folk', 'Eurodance', 'Dream', //
  'Southern Rock', 'Comedy', 'Cult', 'Gangsta', 'Top 40', 'Christian Rap', //
  'Pop/Funk', 'Jungle', 'Native American', 'Cabaret', 'New Wave', //
  'Psychedelic', 'Rave', 'Showtunes', 'Trailer', 'Lo-Fi', 'Tribal', //
  'Acid Punk', 'Acid Jazz', 'Polka', 'Retro', 'Musical', 'Rock & Roll', //
  'Hard Rock', //
];

/// `17`, `(17)`, `(17)Rock`, `Rock` → человеческое название жанра.
String? normalizeGenre(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  final match = RegExp(r'^\((\d+)\)(.*)$').firstMatch(value);
  if (match != null) {
    final rest = match[2]!.trim();
    return rest.isNotEmpty ? rest : _genreByNumber(int.parse(match[1]!));
  }
  final number = int.tryParse(value);
  if (number != null) return _genreByNumber(number);
  return value.isEmpty ? null : value;
}

String? _genreByNumber(int number) =>
    number >= 0 && number < id3Genres.length ? id3Genres[number] : null;
