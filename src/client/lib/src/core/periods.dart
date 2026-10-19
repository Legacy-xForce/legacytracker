import 'formatters.dart';

enum PeriodKind { week, month, custom }

/// A span of whole local days: [from] is its first midnight, [to] the
/// midnight after its last day.
class Period {
  const Period(this.kind, this.from, this.to);

  /// The week (Monday to Sunday, like the calendar) or month containing
  /// [date].
  factory Period.containing(PeriodKind kind, DateTime date) {
    if (kind == PeriodKind.month) {
      return Period(
        kind,
        DateTime(date.year, date.month),
        DateTime(date.year, date.month + 1),
      );
    }
    final from = DateTime(date.year, date.month, date.day - (date.weekday - 1));
    return Period(
      PeriodKind.week,
      from,
      DateTime(from.year, from.month, from.day + 7),
    );
  }

  /// From the first to the last day, both included, in either order.
  factory Period.custom(DateTime first, DateTime last) {
    final (a, b) = first.isAfter(last) ? (last, first) : (first, last);
    return Period(
      PeriodKind.custom,
      DateTime(a.year, a.month, a.day),
      DateTime(b.year, b.month, b.day + 1),
    );
  }

  /// The longest range the server answers, in days.
  static const maxDays = 366;

  final PeriodKind kind;
  final DateTime from;
  final DateTime to;

  /// The period's last day (not the midnight after it).
  DateTime get lastDay => DateTime(to.year, to.month, to.day - 1);

  // Calendar days, not a Duration: a day across a DST change is 23 or 25 h.
  int get days => DateTime.utc(
    to.year,
    to.month,
    to.day,
  ).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

  /// Still going on (or not started yet): nothing later to step to.
  bool isCurrentOrLater([DateTime? now]) => to.isAfter(now ?? DateTime.now());

  /// The previous (-1) or next (+1) week or month. A custom range moves by
  /// its own length.
  Period shift(int delta) => switch (kind) {
    PeriodKind.month => Period.containing(
      kind,
      DateTime(from.year, from.month + delta),
    ),
    PeriodKind.week => Period.containing(
      kind,
      DateTime(from.year, from.month, from.day + 7 * delta),
    ),
    PeriodKind.custom => Period(
      kind,
      DateTime(from.year, from.month, from.day + days * delta),
      DateTime(to.year, to.month, to.day + days * delta),
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is Period &&
      other.kind == kind &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(kind, from, to);
}

String _short(DateTime date, bool withYear) {
  final label = '${date.day} ${monthNames[date.month - 1].substring(0, 3)}';
  return withYear ? '$label ${date.year}' : label;
}

/// "October 2026", "12 – 18 Oct", "28 Dec 2025 – 3 Jan 2026".
String formatPeriod(Period period, {DateTime? now}) {
  final from = period.from;
  if (period.kind == PeriodKind.month) {
    return '${monthNames[from.month - 1]} ${from.year}';
  }
  final last = period.lastDay;
  final sameYear = from.year == last.year;
  final withYear = !sameYear || last.year != (now ?? DateTime.now()).year;
  if (from == last) return _short(last, withYear);
  if (sameYear && from.month == last.month) {
    return '${from.day} – ${_short(last, withYear)}';
  }
  return '${_short(from, !sameYear)} – ${_short(last, withYear)}';
}
