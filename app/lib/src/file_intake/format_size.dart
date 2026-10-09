/// Человекочитаемый размер файла, как в «Готово, когда» из плана: `184 КБ`.
String formatSize(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;

  if (bytes < kb) return '$bytes Б';
  if (bytes < mb) return '${(bytes / kb).round()} КБ';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} МБ';
  return '${(bytes / gb).toStringAsFixed(1)} ГБ';
}
