import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../models/task.dart';
import '../utils/dates.dart';
import 'words_be.dart';
import 'words_de.dart';
import 'words_en.dart';
import 'words_es.dart';
import 'words_fr.dart';
import 'words_it.dart';
import 'words_kk.dart';
import 'words_nl.dart';
import 'words_pl.dart';
import 'words_ru.dart';
import 'words_tr.dart';
import 'words_uk.dart';

/// How a language counts: which form a noun takes after [n].
enum _Form { one, few, many }

/// One form for one, one for everything else: English, German, Spanish,
/// Italian, Dutch.
_Form _germanic(int n) => n == 1 ? _Form.one : _Form.many;

/// French counts nought as one: "0 jour", "1 jour", "2 jours".
_Form _french(int n) => n < 2 ? _Form.one : _Form.many;

/// Russian, Ukrainian and Belarusian: 1 день, 2 дня, 5 дней — and 21 день,
/// 22 дня, 11 дней.
_Form _eastSlavic(int n) {
  final tens = n % 100;
  final units = n % 10;
  if (units == 1 && tens != 11) return _Form.one;
  if (units >= 2 && units <= 4 && (tens < 12 || tens > 14)) return _Form.few;
  return _Form.many;
}

/// Polish: 1 dzień, 2 dni, 5 dni — like the East Slavic languages, except
/// that only one itself is singular: 21 dni.
_Form _polish(int n) {
  if (n == 1) return _Form.one;
  final tens = n % 100;
  final units = n % 10;
  if (units >= 2 && units <= 4 && (tens < 12 || tens > 14)) return _Form.few;
  return _Form.many;
}

/// Turkish and Kazakh: a noun after a number stays singular — "3 gün".
_Form _none(int n) => _Form.many;

/// Every word the app says, in the language of each country it keeps
/// holidays for.
///
/// One class over a table of words per language (`words_*.dart`) rather than
/// a class per language, or ARB files and a generator: twelve languages of a
/// couple of hundred strings each are data, and data is easiest kept as
/// data. A word missing from a table falls back to the English one, so a
/// new string shows up in English everywhere until it is translated, rather
/// than breaking the build.
///
/// Read through [of] on a screen, so a change of language redraws whatever
/// said anything, and through [current] where there is none — a
/// notification, the widget's copy, an isolate answering a reminder's button.
///
/// A counted word is a list of forms in its table — one, few, many — of
/// which a language gives as many as it has: English two, Russian three,
/// Turkish one.
class S {
  /// The language's code, as `Locale` and `intl` know it.
  final String code;
  final Map<String, Object> _words;
  final _Form Function(int) _form;

  const S._(this.code, this._words, this._form);

  static const _all = {
    'en': S._('en', en, _germanic),
    'be': S._('be', be, _eastSlavic),
    'de': S._('de', de, _germanic),
    'es': S._('es', es, _germanic),
    'fr': S._('fr', fr, _french),
    'it': S._('it', it, _germanic),
    'kk': S._('kk', kk, _none),
    'nl': S._('nl', nl, _germanic),
    'pl': S._('pl', pl, _polish),
    'ru': S._('ru', ru, _eastSlavic),
    'tr': S._('tr', tr, _none),
    'uk': S._('uk', uk, _eastSlavic),
  };

  static final supported = [for (final code in _all.keys) Locale(code)];

  /// Each language named in itself, for choosing between them: whichever
  /// is on screen, the way back to one's own can be read.
  static Map<String, String> get names => {
    for (final s in _all.values) s.code: s._word('languageName'),
  };

  /// The language in force, for what has no screen to ask.
  static S current = _all['en']!;

  static S of(BuildContext context) =>
      Localizations.of<S>(context, S) ?? current;

  static S forCode(String? code) => _all[code] ?? _all['en']!;

  static bool supports(String code) => _all.containsKey(code);

  /// Makes [code]'s language the one in force, here and in `intl`, which
  /// writes the dates.
  static void use(String code) {
    current = forCode(code);
    Intl.defaultLocale = current.code;
  }

  static const LocalizationsDelegate<S> delegate = _Delegate();

  /// Whether this language's own table has [key], rather than falling back
  /// to English. For the test that keeps the tables complete.
  @visibleForTesting
  bool hasOwn(String key) => _words.containsKey(key);

  /// What the table holds for [key], blanks unfilled.
  @visibleForTesting
  Object raw(String key) => _words[key] ?? en[key]!;

  String _word(String key) => (_words[key] ?? en[key]) as String;

  String _fill(String key, Map<String, Object> args) {
    var text = _word(key);
    args.forEach((name, value) => text = text.replaceAll('{$name}', '$value'));
    return text;
  }

  String _count(String key, int n, [Map<String, Object> args = const {}]) {
    final forms = (_words[key] ?? en[key]) as List<String>;
    final index = switch (_form(n)) {
      _Form.one => 0,
      _Form.few => 1,
      _Form.many => 2,
    };
    var text = forms[index < forms.length ? index : forms.length - 1];
    text = text.replaceAll('{n}', '$n');
    args.forEach((name, value) => text = text.replaceAll('{$name}', '$value'));
    return text;
  }

  // ---- The screens and the menu --------------------------------------------
  String get schedule => _word('schedule');
  String get calendar => _word('calendar');
  String get done => _word('done');
  String get board => _word('board');
  String get notStarted => _word('notStarted');
  String get inProgress => _word('inProgress');
  String get settings => _word('settings');
  String get menu => _word('menu');
  String get search => _word('search');

  // ---- Days ----------------------------------------------------------------
  String get today => _word('today');
  String get tomorrow => _word('tomorrow');
  String get yesterday => _word('yesterday');

  /// "tomorrow" in the middle of a sentence.
  String get tomorrowInline => _word('tomorrowInline');
  String get yesterdayInline => _word('yesterdayInline');
  String get overdue => _word('overdue');
  String get noDate => _word('noDate');
  String get allDay => _word('allDay');

  // ---- Common actions ------------------------------------------------------
  String get cancel => _word('cancel');
  String get save => _word('save');
  String get clear => _word('clear');
  String get delete => _word('delete');
  String get remove => _word('remove');
  String get undo => _word('undo');

  // ---- The update banner ---------------------------------------------------
  String updateOut(String version) => _fill('updateOut', {'version': version});
  String downloading(String version, int percent) =>
      _fill('downloading', {'version': version, 'percent': percent});
  String get allowInstall => _word('allowInstall');
  String get downloadFailed => _word('downloadFailed');
  String get update => _word('update');
  String get notNow => _word('notNow');

  // ---- Schedule and the calendar -------------------------------------------
  String get nothingScheduled => _word('nothingScheduled');
  String get nothingScheduledHint => _word('nothingScheduledHint');
  String shownForNext(int days) => _count('shownForNext', days);
  String get expandMonth => _word('expandMonth');
  String get collapseMonth => _word('collapseMonth');
  String get nothingOnDay => _word('nothingOnDay');
  String get addOneBelow => _word('addOneBelow');
  String get addWithForm => _word('addWithForm');
  String openCount(int open) => _fill('openCount', {'n': open});
  String get allClear => _word('allClear');
  String moreCount(int hidden) => _fill('moreCount', {'n': hidden});
  String get publicHoliday => _word('publicHoliday');
  String eventFrom(String time) => _fill('eventFrom', {'time': time});
  String eventUntil(String time) => _fill('eventUntil', {'time': time});
  String addTaskOn(String date) => _fill('addTaskOn', {'date': date});
  String get addTask => _word('addTask');
  String get newTask => _word('newTask');

  // ---- Done ----------------------------------------------------------------
  String get nothingDoneYet => _word('nothingDoneYet');
  String get doneHint => _word('doneHint');
  String get figureToday => _word('figureToday');
  String get figureWeek => _word('figureWeek');
  String daysInARow(int days) => _count('daysInARow', days);

  // ---- Search --------------------------------------------------------------
  String get searchField => _word('searchField');
  String get searchYourTasks => _word('searchYourTasks');
  String get searchHint => _word('searchHint');
  String get nothingFound => _word('nothingFound');
  String noTaskMentions(String query) =>
      _fill('noTaskMentions', {'query': query});

  // ---- Settings ------------------------------------------------------------
  String get pageScreens => _word('pageScreens');
  String get sectionInMenu => _word('sectionInMenu');
  String get inMenuHint => _word('inMenuHint');
  String get pageGeneral => _word('pageGeneral');
  String get startScreen => _word('startScreen');
  String get timesWritten => _word('timesWritten');
  String get language => _word('language');
  String followPhone(String language) =>
      _fill('followPhone', {'language': language});
  String get pageAppearance => _word('pageAppearance');
  String get theme => _word('theme');
  String get themeDark => _word('themeDark');
  String get themeLight => _word('themeLight');
  String get themeSystem => _word('themeSystem');
  String get accent => _word('accent');
  String get weekStartsMonday => _word('weekStartsMonday');
  String get weeksMonSun => _word('weeksMonSun');
  String get weeksSunSat => _word('weeksSunSat');
  String get showHolidays => _word('showHolidays');
  String get holidaysOn => _word('holidaysOn');
  String get holidaysOff => _word('holidaysOff');
  String followDevice(String country) =>
      _fill('followDevice', {'country': country});
  String get followDeviceUnsupported => _word('followDeviceUnsupported');
  String get holidayCountry => _word('holidayCountry');

  /// A country's name, in this language when the table has it.
  String country(String code, String english) =>
      (_words['country.$code'] as String?) ?? english;
  String get showEvents => _word('showEvents');
  String get eventsOn => _word('eventsOn');
  String get eventsOff => _word('eventsOff');
  String get calendarsRefused => _word('calendarsRefused');
  String get noCalendars => _word('noCalendars');
  String get pageTasks => _word('pageTasks');
  String get completedShown => _word('completedShown');
  String get completedHidden => _word('completedHidden');
  String get showCompleted => _word('showCompleted');
  String get showCompletedHint => _word('showCompletedHint');
  String get clearCompleted => _word('clearCompleted');
  String get clearCompletedHint => _word('clearCompletedHint');
  String get clearCompletedQuestion => _word('clearCompletedQuestion');
  String get clearCompletedWarning => _word('clearCompletedWarning');
  String get nothingToClear => _word('nothingToClear');
  String removedCompleted(int count) => _count('removedCompleted', count);
  String get pageReminders => _word('pageReminders');
  String get remindWhenDue => _word('remindWhenDue');
  String get remindOn => _word('remindOn');
  String get remindOff => _word('remindOff');
  String get timedTasks => _word('timedTasks');
  String get allDayTasks => _word('allDayTasks');
  String get sectionAbout => _word('sectionAbout');
  String get about => _word('about');
  String version(String version) => _fill('version', {'version': version});
  String get pageBackup => _word('pageBackup');
  String get backupNever => _word('backupNever');
  String backupLast(String day) => _fill('backupLast', {'day': day});
  String get backupSave => _word('backupSave');
  String get backupSaveHint => _word('backupSaveHint');
  String get backupRestore => _word('backupRestore');
  String get backupRestoreHint => _word('backupRestoreHint');
  String get backupNote => _word('backupNote');
  String get backupSaved => _word('backupSaved');
  String get backupNotSaved => _word('backupNotSaved');
  String get backupNotCaldo => _word('backupNotCaldo');
  String get backupNewer => _word('backupNewer');
  String get backupUnreadable => _word('backupUnreadable');
  String get restoreQuestion => _word('restoreQuestion');
  String restoreWarning({
    required String day,
    required int tasks,
    required int groups,
  }) => _fill('restoreWarning', {
    'day': day,
    'tasks': _count('backupTasks', tasks),
    'groups': _count('backupGroups', groups),
  });
  String get restore => _word('restore');
  String restored(int count) => _count('restored', count);

  // ---- The task form -------------------------------------------------------
  String get editTask => _word('editTask');
  String get taskField => _word('taskField');
  String get required => _word('required');
  String get notesField => _word('notesField');
  String get sectionSubtasks => _word('sectionSubtasks');
  String get addSubtask => _word('addSubtask');
  String get allGroups => _word('allGroups');
  String get newGroup => _word('newGroup');
  String get editGroup => _word('editGroup');
  String get groupName => _word('groupName');
  String get sectionGroup => _word('sectionGroup');
  String deleteGroupQuestion(String name) =>
      _fill('deleteGroupQuestion', {'name': name});
  String groupTasksMoveTo(String group) =>
      _fill('groupTasksMoveTo', {'group': group});
  String get personal => _word('personal');
  String get dueDate => _word('dueDate');
  String get time => _word('time');
  String get none => _word('none');
  String get endsAt => _word('endsAt');
  String get endBeforeStart => _word('endBeforeStart');
  String get dayAsList => _word('dayAsList');
  String get dayAsHours => _word('dayAsHours');
  String get putOffDay => _word('putOffDay');
  String get pickDay => _word('pickDay');
  String get repeatLabel => _word('repeatLabel');

  /// A rule written out: "Every day", "Every 2 weeks · Mon, Thu", "Every
  /// month · last day · until 31 Dec". Pieces after the first are joined
  /// with a dot rather than built into one sentence, which twelve
  /// languages' grammar would each want built differently.
  String repeatName(Repeat repeat) {
    if (repeat.isNone) return _word('repeat.none');
    final weekdaysOnly = setEquals(
      repeat.weekdays,
      Repeat.weekdaysOnly.weekdays,
    );
    final base = repeat.every > 1
        ? _count('repeatEvery.${repeat.unit.name}', repeat.every)
        : repeat.unit == RepeatUnit.week && weekdaysOnly
        ? _word('repeat.weekdays')
        : _word('repeat.${_plainKey[repeat.unit]}');
    final until = repeat.until;
    return [
      base,
      if (repeat.unit == RepeatUnit.week &&
          repeat.weekdays.isNotEmpty &&
          !(weekdaysOnly && repeat.every == 1))
        [
          for (final d in repeat.weekdays.toList()..sort()) weekdayShort(d),
        ].join(', '),
      if (repeat.unit == RepeatUnit.month && repeat.monthEnd)
        _word('repeatLastDay'),
      if (until != null) _fill('repeatUntil', {'date': Dates.shortDay(until)}),
      if (repeat.left case final left?) _count('repeatLeft', left),
    ].join(' · ');
  }

  static const _plainKey = {
    RepeatUnit.day: 'daily',
    RepeatUnit.week: 'weekly',
    RepeatUnit.month: 'monthly',
    RepeatUnit.year: 'yearly',
  };

  /// A weekday's short name, by `DateTime.weekday`: "Mon", "пн".
  String weekdayShort(int weekday) =>
      DateFormat.E().format(DateTime(2024, 1, weekday));

  String unitName(RepeatUnit unit) => _word('unit.${unit.name}');
  String get repeatEveryLabel => _word('repeatEveryLabel');
  String repeatOnDay(int day) => _fill('repeatOnDay', {'n': day});
  String get repeatOnLastDay => _word('repeatOnLastDay');
  String get repeatEnds => _word('repeatEnds');
  String get endsOn => _word('endsOn');
  String endsAfter(int n) => _count('endsAfter', n);
  String remindLead(String lead) => _fill('remindLead', {'lead': lead});
  String remindOnDayAt(String time) => _fill('remindOnDayAt', {'time': time});
  String get remindDayBefore => _word('remindDayBefore');
  String get reminderLabel => _word('reminderLabel');
  String get noReminder => _word('noReminder');
  String get sectionPriority => _word('sectionPriority');
  String priorityName(Priority priority) => _word('priority.${priority.name}');
  String get sectionColour => _word('sectionColour');
  String get list => _word('list');
  String get deleteTaskQuestion => _word('deleteTaskQuestion');
  String willBeRemoved(String title) =>
      _fill('willBeRemoved', {'title': title});

  // ---- Several tasks at once -----------------------------------------------
  String selectedCount(int n) => _count('selectedCount', n);
  String get moveToDay => _word('moveToDay');
  String get moveToGroup => _word('moveToGroup');
  String get markDone => _word('markDone');
  String get markNotDone => _word('markNotDone');
  String get clearSelection => _word('clearSelection');
  String deleteTasksQuestion(int n) => _count('deleteTasksQuestion', n);
  String get cannotBeUndone => _word('cannotBeUndone');

  // ---- Reminders and how far ahead -----------------------------------------
  String get atTheTime => _word('atTheTime');
  String minutesBefore(int minutes) => _fill('minutesBefore', {'n': minutes});
  String hoursBefore(int hours) =>
      hours == 1 ? _word('hourBefore') : _count('hoursBefore', hours);
  String daysBefore(int days) =>
      days == 1 ? _word('dayBefore') : _count('daysBefore', days);
  String weeksBefore(int weeks) =>
      weeks == 1 ? _word('weekBefore') : _count('weeksBefore', weeks);
  String get selectTime => _word('selectTime');
  String get nextWeek => _word('nextWeek');
  String get nextMonth => _word('nextMonth');
  String get previousMonth => _word('previousMonth');
  String get reminderDone => _word('reminderDone');
  String snoozeMinutes(int minutes) => _fill('snoozeMinutes', {'n': minutes});
  String get snoozeHour => _word('snoozeHour');
  String get reminderDismiss => _word('reminderDismiss');
  String get fullScreenReminders => _word('fullScreenReminders');
  String get fullScreenOn => _word('fullScreenOn');
  String get fullScreenOff => _word('fullScreenOff');
  String get fullScreenOffer => _word('fullScreenOffer');
  String get allow => _word('allow');
  String get reminderChannel => _word('reminderChannel');
  String get reminderChannelHint => _word('reminderChannelHint');

  /// What a reminder says under the title: when the task is due, from where
  /// the reminder stands — [day] is null for the same day, [time] for an
  /// all-day task.
  String dueLine({String? day, String? time, required bool past}) {
    final head = past ? 'wasDue' : 'due';
    if (time == null) {
      return day == null
          ? _word('due.today')
          : _fill('$head.day', {'day': day});
    }
    return day == null
        ? _fill('$head.at', {'time': time})
        : _fill('$head.dayAt', {'day': day, 'time': time});
  }
}

class _Delegate extends LocalizationsDelegate<S> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => S.supports(locale.languageCode);

  @override
  Future<S> load(Locale locale) {
    S.use(locale.languageCode);
    return SynchronousFuture(S.current);
  }

  @override
  bool shouldReload(_Delegate old) => false;
}
