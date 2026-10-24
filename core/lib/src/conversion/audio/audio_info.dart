/// An audio file's tags, consolidated from ID3, Vorbis comment, MP4
/// `ilst` and WAV `LIST/INFO` into one set of fields. Filled
/// "first one wins": ID3v2 is read before ID3v1, so a title truncated to
/// 30 characters from v1 doesn't overwrite the full one.
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

  /// The key is a normalized field name (`title`, `artist`…), the way
  /// Vorbis comment calls it; other formats translate their own names
  /// into these.
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

/// What's known about the audio and its container. Everything's
/// optional: a corrupt or truncated file yields whatever could be read.
class AudioInfo {
  final tags = AudioTags();
  Duration? duration;
  String? codec;
  int? sampleRate;
  int? channels;
  int? bitrateKbps;

  /// The bitrate is an average (VBR) rather than constant — written
  /// with a `~`.
  bool variableBitrate = false;

  /// The video track's size, if this is video (MP4/MOV/3GP).
  int? videoWidth;
  int? videoHeight;
  bool hasVideo = false;
  bool hasAudio = false;

  /// The structure pointed outside the file somewhere, or was
  /// implausible.
  bool damaged = false;
}

/// ID3v1 genre names by number (0–79, the standard part of the table).
/// In ID3v2 the genre is also often written as a number: `(17)` or `17`.
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

/// `17`, `(17)`, `(17)Rock`, `Rock` → a human-readable genre name.
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
