/// Calendar days, counted as days rather than as 24 hours each.
///
/// `add(const Duration(days: 1))` on a local date adds 24 hours, and on the
/// day a daylight saving change makes 23 or 25 hours long that lands an
/// hour either side of midnight — in autumn, on the day before. A month
/// grid built that way showed the 25th of October twice and every day after
/// it a day early; in spring its days came out at one in the morning and
/// matched none of the tasks kept by their midnight. Everything that steps
/// from one day to another goes through here.
library;

/// Strips the time from [date], giving the calendar day it belongs to.
DateTime dayOf(DateTime date) => DateTime(date.year, date.month, date.day);

/// The day [days] calendar days after [day]'s (before it, if negative), at
/// its midnight.
DateTime addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

/// Whole calendar days from [from]'s day to [to]'s. Counted in UTC, so the
/// hour a daylight saving change adds or drops cannot round a day away.
int daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
