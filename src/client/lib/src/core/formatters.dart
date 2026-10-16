/// Elapsed time in its two most significant units: "42s", "12m 5s",
/// "3h 20m", "42d 1h" — readable at any scale, unlike a bare hour count.
String formatElapsed(Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  if (d.inDays > 0) {
    final hours = d.inHours.remainder(24);
    return hours > 0 ? '${d.inDays}d ${hours}h' : '${d.inDays}d';
  }
  if (d.inHours > 0) {
    final minutes = d.inMinutes.remainder(60);
    return minutes > 0 ? '${d.inHours}h ${minutes}m' : '${d.inHours}h';
  }
  if (d.inMinutes > 0) {
    final seconds = d.inSeconds.remainder(60);
    return seconds > 0 ? '${d.inMinutes}m ${seconds}s' : '${d.inMinutes}m';
  }
  return '${d.inSeconds}s';
}

/// How long ago something last happened, as a sentence fragment that stays
/// stable for a while: "just now", "5 min ago", "3 hours ago", "2 days ago".
String formatUpdatedAgo(Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) {
    return d.inHours == 1 ? '1 hour ago' : '${d.inHours} hours ago';
  }
  return d.inDays == 1 ? '1 day ago' : '${d.inDays} days ago';
}

/// A trip's length: whole minutes are precise enough ("8m", "1h 5m").
String formatTripDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  if (hours > 0) return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  return '${d.inMinutes < 1 ? 1 : minutes}m';
}

/// Local wall-clock time, "08:05".
String formatClock(DateTime time) {
  final local = time.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

String formatDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  final km = meters / 1000;
  return '${km.toStringAsFixed(km < 10 ? 1 : 0)} km';
}

const monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];

const weekdayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
  'Sunday',
];

/// "Thursday, 8 October".
String formatLongDay(DateTime day) =>
    '${weekdayNames[day.weekday - 1]}, ${day.day} ${monthNames[day.month - 1]}';

/// "8 Oct", or "8 Oct 2025" outside the current year.
String formatShortDate(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final label = '${local.day} ${monthNames[local.month - 1].substring(0, 3)}';
  return local.year == (now ?? DateTime.now()).year
      ? label
      : '$label ${local.year}';
}

/// Time left until something, in whole minutes: "3h 20m", "5m". Under a
/// minute reads "<1m" rather than counting seconds nobody can act on.
String formatUntil(Duration duration) {
  if (duration.inMinutes < 1) return '<1m';
  return formatElapsed(Duration(minutes: duration.inMinutes));
}
