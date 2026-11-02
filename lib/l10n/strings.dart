import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../models/task.dart';

/// Every word the app says, in English and in Russian.
///
/// Written by hand rather than generated from ARB files: there are two
/// languages and a couple of hundred strings, and a build step to keep in
/// step is more than that is worth. Read through [of] on a screen, so a
/// change of language redraws whatever said anything, and through [current]
/// where there is no screen — a notification, the widget's copy, an isolate
/// answering a reminder's button.
abstract class S {
  const S();

  /// The language's code, as `Locale` and `intl` know it.
  String get code;

  static const supported = [Locale('en'), Locale('ru')];

  /// The language in force, for what has no screen to ask.
  static S current = const SEn();

  static S of(BuildContext context) =>
      Localizations.of<S>(context, S) ?? current;

  static S forCode(String? code) => code == 'ru' ? const SRu() : const SEn();

  /// Makes [code]'s language the one in force, here and in `intl`, which
  /// writes the dates.
  static void use(String code) {
    current = forCode(code);
    Intl.defaultLocale = current.code;
  }

  static const LocalizationsDelegate<S> delegate = _Delegate();

  // ---- The screens and the menu --------------------------------------------
  String get schedule;
  String get calendar;
  String get done;
  String get settings;
  String get menu;
  String get search;

  // ---- Days ----------------------------------------------------------------
  String get today;
  String get tomorrow;
  String get yesterday;

  /// "tomorrow" in the middle of a sentence.
  String get tomorrowInline;
  String get yesterdayInline;
  String get overdue;
  String get noDate;
  String get allDay;

  // ---- Common actions ------------------------------------------------------
  String get cancel;
  String get save;
  String get clear;
  String get delete;
  String get remove;
  String get undo;

  // ---- The update banner ---------------------------------------------------
  String updateOut(String version);
  String downloading(String version, int percent);
  String get allowInstall;
  String get downloadFailed;
  String get update;
  String get notNow;

  // ---- Schedule and the calendar -------------------------------------------
  String get nothingScheduled;
  String get nothingScheduledHint;
  String shownForNext(int days);
  String get expandMonth;
  String get collapseMonth;
  String get nothingOnDay;
  String get addOneBelow;
  String get addOneBelowOrForm;
  String get addWithForm;
  String openCount(int open);
  String get allClear;
  String moreCount(int hidden);
  String get publicHoliday;
  String eventFrom(String time);
  String eventUntil(String time);
  String addTaskOn(String date);
  String get addTask;
  String get newTask;

  // ---- Done ----------------------------------------------------------------
  String get nothingDoneYet;
  String get doneHint;
  String get figureToday;
  String get figureWeek;
  String daysInARow(int days);

  // ---- Search --------------------------------------------------------------
  String get searchField;
  String get searchYourTasks;
  String get searchHint;
  String get nothingFound;
  String noTaskMentions(String query);

  // ---- Settings ------------------------------------------------------------
  String get sectionGeneral;
  String get startScreen;
  String get timesWritten;
  String get language;
  String followPhone(String language);
  String get sectionAppearance;
  String get themeDark;
  String get themeLight;
  String get themeSystem;
  String get sectionCalendar;
  String get weekStartsMonday;
  String get weeksMonSun;
  String get weeksSunSat;
  String get showHolidays;
  String get holidaysOn;
  String get holidaysOff;
  String followDevice(String country);
  String get followDeviceUnsupported;
  String country(String code, String english);
  String get showEvents;
  String get eventsOn;
  String get eventsOff;
  String get calendarsRefused;
  String get noCalendars;
  String get sectionTasks;
  String get newTaskColour;
  String get showCompleted;
  String get showCompletedHint;
  String get clearCompleted;
  String get clearCompletedHint;
  String get clearCompletedQuestion;
  String get clearCompletedWarning;
  String get nothingToClear;
  String removedCompleted(int count);
  String get sectionReminders;
  String get remindWhenDue;
  String get remindOn;
  String get remindOff;
  String timedTasksLead(String lead);
  String allDayAt(String time);
  String get allDayAtHint;
  String get sectionAbout;
  String get about;

  // ---- The task form -------------------------------------------------------
  String get editTask;
  String get taskField;
  String get required;
  String get notesField;
  String get sectionSubtasks;
  String get addSubtask;
  String get dueDate;
  String get time;
  String get none;
  String repeatField(Repeat repeat);
  String repeatName(Repeat repeat);
  String remindLead(String lead);
  String remindOnDayAt(String time);
  String get remindDayBefore;
  String get noReminder;
  String get sectionPriority;
  String priorityName(Priority priority);
  String get sectionColour;
  String get list;
  String get deleteTaskQuestion;
  String willBeRemoved(String title);

  // ---- Reminders and how far ahead -----------------------------------------
  String get atTheTime;
  String minutesBefore(int minutes);
  String hoursBefore(int hours);
  String daysBefore(int days);
  String get selectTime;
  String get nextWeek;
  String get nextMonth;
  String get previousMonth;
  String get reminderDone;
  String snoozeMinutes(int minutes);
  String get snoozeHour;
  String get reminderChannel;
  String get reminderChannelHint;

  /// What a reminder says under the title: when the task is due, from where
  /// the reminder stands — [day] is null for the same day, [time] for an
  /// all-day task.
  String dueLine({String? day, String? time, required bool past});
}

class _Delegate extends LocalizationsDelegate<S> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) =>
      S.supported.any((l) => l.languageCode == locale.languageCode);

  @override
  Future<S> load(Locale locale) {
    S.use(locale.languageCode);
    return SynchronousFuture(S.current);
  }

  @override
  bool shouldReload(_Delegate old) => false;
}

class SEn extends S {
  const SEn();

  @override
  String get code => 'en';

  @override
  String get schedule => 'Schedule';
  @override
  String get calendar => 'Calendar';
  @override
  String get done => 'Done';
  @override
  String get settings => 'Settings';
  @override
  String get menu => 'Menu';
  @override
  String get search => 'Search';

  @override
  String get today => 'Today';
  @override
  String get tomorrow => 'Tomorrow';
  @override
  String get yesterday => 'Yesterday';
  @override
  String get tomorrowInline => 'tomorrow';
  @override
  String get yesterdayInline => 'yesterday';
  @override
  String get overdue => 'Overdue';
  @override
  String get noDate => 'No date';
  @override
  String get allDay => 'All day';

  @override
  String get cancel => 'Cancel';
  @override
  String get save => 'Save';
  @override
  String get clear => 'Clear';
  @override
  String get delete => 'Delete';
  @override
  String get remove => 'Remove';
  @override
  String get undo => 'Undo';

  @override
  String updateOut(String version) => 'Caldo $version is out';
  @override
  String downloading(String version, int percent) =>
      'Downloading $version — $percent%';
  @override
  String get allowInstall =>
      'Allow Caldo to install apps, then tap Update again';
  @override
  String get downloadFailed => 'Download failed — tap to try again';
  @override
  String get update => 'Update';
  @override
  String get notNow => 'Not now';

  @override
  String get nothingScheduled => 'Nothing scheduled';
  @override
  String get nothingScheduledHint =>
      'Add something below. Anything with a date on it is listed here, '
      'day by day.';
  @override
  String shownForNext(int days) =>
      'Dated tasks are shown for the next $days days.';
  @override
  String get expandMonth => 'Expand the month';
  @override
  String get collapseMonth => 'Collapse the month';
  @override
  String get nothingOnDay => 'Nothing on this day';
  @override
  String get addOneBelow => 'Add one in the field below.';
  @override
  String get addOneBelowOrForm =>
      'Add one below, or tap the icon above for the full form.';
  @override
  String get addWithForm => 'Add with a full form';
  @override
  String openCount(int open) => '$open open';
  @override
  String get allClear => 'All clear';
  @override
  String moreCount(int hidden) => '+$hidden more';
  @override
  String get publicHoliday => 'Public holiday';
  @override
  String eventFrom(String time) => 'From $time';
  @override
  String eventUntil(String time) => 'Until $time';
  @override
  String addTaskOn(String date) => 'Add task on $date';
  @override
  String get addTask => 'Add task';
  @override
  String get newTask => 'New task';

  @override
  String get nothingDoneYet => 'Nothing done yet';
  @override
  String get doneHint => 'Everything you tick off is kept here, day by day.';
  @override
  String get figureToday => 'today';
  @override
  String get figureWeek => 'this week';
  @override
  String daysInARow(int days) => days == 1 ? 'day in a row' : 'days in a row';

  @override
  String get searchField => 'Title or notes';
  @override
  String get searchYourTasks => 'Search your tasks';
  @override
  String get searchHint => 'Matches titles and notes, across every list.';
  @override
  String get nothingFound => 'Nothing found';
  @override
  String noTaskMentions(String query) => 'No task mentions "$query".';

  @override
  String get sectionGeneral => 'GENERAL';
  @override
  String get startScreen => 'Screen the app opens on';
  @override
  String get timesWritten => 'Times are written';
  @override
  String get language => 'Language';
  @override
  String followPhone(String language) => 'As the phone ($language)';
  @override
  String get sectionAppearance => 'APPEARANCE';
  @override
  String get themeDark => 'Dark';
  @override
  String get themeLight => 'Light';
  @override
  String get themeSystem => 'System';
  @override
  String get sectionCalendar => 'CALENDAR';
  @override
  String get weekStartsMonday => 'Start week on Monday';
  @override
  String get weeksMonSun => 'Weeks run Monday to Sunday';
  @override
  String get weeksSunSat => 'Weeks run Sunday to Saturday';
  @override
  String get showHolidays => 'Show public holidays';
  @override
  String get holidaysOn => 'Marked in green on the calendar';
  @override
  String get holidaysOff => 'No holidays are marked';
  @override
  String followDevice(String country) => 'Follow device ($country)';
  @override
  String get followDeviceUnsupported => 'Follow device (not supported yet)';
  @override
  String country(String code, String english) => english;
  @override
  String get showEvents => 'Show events from your calendars';
  @override
  String get eventsOn => 'Read from this phone, never changed';
  @override
  String get eventsOff => 'Only what is in Caldo is shown';
  @override
  String get calendarsRefused => 'Caldo was not allowed to read your calendars';
  @override
  String get noCalendars => 'There are no calendars on this phone';
  @override
  String get sectionTasks => 'TASKS';
  @override
  String get newTaskColour => 'Colour new tasks start in';
  @override
  String get showCompleted => 'Show completed tasks';
  @override
  String get showCompletedHint =>
      'Keep ticked-off tasks listed under the open ones';
  @override
  String get clearCompleted => 'Clear completed tasks';
  @override
  String get clearCompletedHint =>
      'Remove every ticked-off task from all lists';
  @override
  String get clearCompletedQuestion => 'Clear completed tasks?';
  @override
  String get clearCompletedWarning =>
      'Every completed task in every list will be removed. '
      'This cannot be undone.';
  @override
  String get nothingToClear => 'No completed tasks to clear';
  @override
  String removedCompleted(int count) =>
      'Removed $count completed ${count == 1 ? 'task' : 'tasks'}';
  @override
  String get sectionReminders => 'REMINDERS';
  @override
  String get remindWhenDue => 'Remind me when a task is due';
  @override
  String get remindOn => 'A notification for each task with a date';
  @override
  String get remindOff => 'Nothing is announced';
  @override
  String timedTasksLead(String lead) => 'Timed tasks $lead';
  @override
  String allDayAt(String time) => 'All-day tasks at $time';
  @override
  String get allDayAtHint => 'A task with no time of day is announced then';
  @override
  String get sectionAbout => 'ABOUT';
  @override
  String get about =>
      'Caldo keeps your calendar and to-do list in one place, '
      'stored on this device only.';

  @override
  String get editTask => 'Edit task';
  @override
  String get taskField => 'Task';
  @override
  String get required => 'Required';
  @override
  String get notesField => 'Notes (optional)';
  @override
  String get sectionSubtasks => 'SUBTASKS';
  @override
  String get addSubtask => 'Add a subtask';
  @override
  String get dueDate => 'Due date';
  @override
  String get time => 'Time';
  @override
  String get none => 'None';
  @override
  String repeatField(Repeat repeat) =>
      'Repeat: ${repeatName(repeat).toLowerCase()}';
  @override
  String repeatName(Repeat repeat) => repeat.label;
  @override
  String remindLead(String lead) => 'Remind $lead';
  @override
  String remindOnDayAt(String time) => 'Remind on the day, at $time';
  @override
  String get remindDayBefore => 'Remind the day before';
  @override
  String get noReminder => 'No reminder';
  @override
  String get sectionPriority => 'PRIORITY';
  @override
  String priorityName(Priority priority) => priority.label;
  @override
  String get sectionColour => 'COLOUR';
  @override
  String get list => 'List';
  @override
  String get deleteTaskQuestion => 'Delete task?';
  @override
  String willBeRemoved(String title) => '"$title" will be removed.';

  @override
  String get atTheTime => 'at the time';
  @override
  String minutesBefore(int minutes) => '$minutes min before';
  @override
  String hoursBefore(int hours) =>
      hours == 1 ? '1 hour before' : '$hours hours before';
  @override
  String daysBefore(int days) =>
      days == 1 ? '1 day before' : '$days days before';
  @override
  String get selectTime => 'Select time';
  @override
  String get nextWeek => 'Next week';
  @override
  String get nextMonth => 'Next month';
  @override
  String get previousMonth => 'Previous month';
  @override
  String get reminderDone => 'Done';
  @override
  String snoozeMinutes(int minutes) => 'Snooze $minutes min';
  @override
  String get snoozeHour => 'Snooze 1 hour';
  @override
  String get reminderChannel => 'Task reminders';
  @override
  String get reminderChannelHint =>
      'One notification per task, when it is due.';

  @override
  String dueLine({String? day, String? time, required bool past}) {
    final head = past ? 'Was due' : 'Due';
    if (time == null) return '$head ${day ?? 'today'}';
    return day == null ? '$head at $time' : '$head $day at $time';
  }
}

/// Russian. Counted words go through [_plural], since Russian has three
/// forms where English has two: 1 день, 2 дня, 5 дней.
class SRu extends S {
  const SRu();

  @override
  String get code => 'ru';

  static String _plural(int n, String one, String few, String many) {
    final tens = n % 100;
    final units = n % 10;
    if (units == 1 && tens != 11) return one;
    if (units >= 2 && units <= 4 && (tens < 12 || tens > 14)) return few;
    return many;
  }

  @override
  String get schedule => 'Расписание';
  @override
  String get calendar => 'Календарь';
  @override
  String get done => 'Сделано';
  @override
  String get settings => 'Настройки';
  @override
  String get menu => 'Меню';
  @override
  String get search => 'Поиск';

  @override
  String get today => 'Сегодня';
  @override
  String get tomorrow => 'Завтра';
  @override
  String get yesterday => 'Вчера';
  @override
  String get tomorrowInline => 'завтра';
  @override
  String get yesterdayInline => 'вчера';
  @override
  String get overdue => 'Просрочено';
  @override
  String get noDate => 'Без даты';
  @override
  String get allDay => 'Весь день';

  @override
  String get cancel => 'Отмена';
  @override
  String get save => 'Сохранить';
  @override
  String get clear => 'Очистить';
  @override
  String get delete => 'Удалить';
  @override
  String get remove => 'Убрать';
  @override
  String get undo => 'Отменить';

  @override
  String updateOut(String version) => 'Вышла Caldo $version';
  @override
  String downloading(String version, int percent) =>
      'Загрузка $version — $percent%';
  @override
  String get allowInstall =>
      'Разрешите Caldo устанавливать приложения и снова нажмите «Обновить»';
  @override
  String get downloadFailed => 'Не удалось загрузить — нажмите ещё раз';
  @override
  String get update => 'Обновить';
  @override
  String get notNow => 'Не сейчас';

  @override
  String get nothingScheduled => 'Ничего не запланировано';
  @override
  String get nothingScheduledHint =>
      'Добавьте задачу ниже. Всё, у чего есть дата, появится здесь по дням.';
  @override
  String shownForNext(int days) =>
      'Задачи с датой показаны на $days '
      '${_plural(days, 'день', 'дня', 'дней')} вперёд.';
  @override
  String get expandMonth => 'Развернуть месяц';
  @override
  String get collapseMonth => 'Свернуть месяц';
  @override
  String get nothingOnDay => 'В этот день ничего нет';
  @override
  String get addOneBelow => 'Добавьте задачу в поле ниже.';
  @override
  String get addOneBelowOrForm =>
      'Добавьте задачу ниже или откройте полную форму значком вверху.';
  @override
  String get addWithForm => 'Добавить через форму';
  @override
  String openCount(int open) => 'Осталось: $open';
  @override
  String get allClear => 'Всё сделано';
  @override
  String moreCount(int hidden) => '+ ещё $hidden';
  @override
  String get publicHoliday => 'Праздник';
  @override
  String eventFrom(String time) => 'С $time';
  @override
  String eventUntil(String time) => 'До $time';
  @override
  String addTaskOn(String date) => 'Задача на $date';
  @override
  String get addTask => 'Добавить задачу';
  @override
  String get newTask => 'Новая задача';

  @override
  String get nothingDoneYet => 'Пока ничего не сделано';
  @override
  String get doneHint => 'Всё, что вы отметите, сохраняется здесь по дням.';
  @override
  String get figureToday => 'сегодня';
  @override
  String get figureWeek => 'за неделю';
  @override
  String daysInARow(int days) =>
      '${_plural(days, 'день', 'дня', 'дней')} подряд';

  @override
  String get searchField => 'Название или заметки';
  @override
  String get searchYourTasks => 'Поиск по задачам';
  @override
  String get searchHint => 'Ищет в названиях и заметках всех списков.';
  @override
  String get nothingFound => 'Ничего не найдено';
  @override
  String noTaskMentions(String query) =>
      'Ни одна задача не упоминает «$query».';

  @override
  String get sectionGeneral => 'ОБЩИЕ';
  @override
  String get startScreen => 'Экран при запуске';
  @override
  String get timesWritten => 'Формат времени';
  @override
  String get language => 'Язык';
  @override
  String followPhone(String language) => 'Как на телефоне ($language)';
  @override
  String get sectionAppearance => 'ОФОРМЛЕНИЕ';
  @override
  String get themeDark => 'Тёмная';
  @override
  String get themeLight => 'Светлая';
  @override
  String get themeSystem => 'Системная';
  @override
  String get sectionCalendar => 'КАЛЕНДАРЬ';
  @override
  String get weekStartsMonday => 'Неделя с понедельника';
  @override
  String get weeksMonSun => 'С понедельника по воскресенье';
  @override
  String get weeksSunSat => 'С воскресенья по субботу';
  @override
  String get showHolidays => 'Показывать праздники';
  @override
  String get holidaysOn => 'Отмечены в календаре зелёным';
  @override
  String get holidaysOff => 'Праздники не отмечаются';
  @override
  String followDevice(String country) => 'Как на устройстве ($country)';
  @override
  String get followDeviceUnsupported =>
      'Как на устройстве (пока не поддерживается)';
  @override
  String country(String code, String english) => _countries[code] ?? english;

  static const _countries = {
    'AU': 'Австралия',
    'BY': 'Беларусь',
    'CA': 'Канада',
    'DE': 'Германия',
    'ES': 'Испания',
    'FR': 'Франция',
    'GB': 'Великобритания',
    'IT': 'Италия',
    'KZ': 'Казахстан',
    'NL': 'Нидерланды',
    'PL': 'Польша',
    'RU': 'Россия',
    'TR': 'Турция',
    'UA': 'Украина',
    'US': 'США',
  };

  @override
  String get showEvents => 'Показывать события из календарей';
  @override
  String get eventsOn => 'Читаются с телефона и не изменяются';
  @override
  String get eventsOff => 'Показывается только то, что есть в Caldo';
  @override
  String get calendarsRefused => 'Caldo не получил доступа к календарям';
  @override
  String get noCalendars => 'На телефоне нет календарей';
  @override
  String get sectionTasks => 'ЗАДАЧИ';
  @override
  String get newTaskColour => 'Цвет новых задач';
  @override
  String get showCompleted => 'Показывать выполненные';
  @override
  String get showCompletedHint => 'Отмеченные задачи остаются под открытыми';
  @override
  String get clearCompleted => 'Удалить выполненные';
  @override
  String get clearCompletedHint =>
      'Убрать все отмеченные задачи из всех списков';
  @override
  String get clearCompletedQuestion => 'Удалить выполненные задачи?';
  @override
  String get clearCompletedWarning =>
      'Все выполненные задачи во всех списках будут удалены. '
      'Это нельзя отменить.';
  @override
  String get nothingToClear => 'Выполненных задач нет';
  @override
  String removedCompleted(int count) => 'Удалено выполненных задач: $count';
  @override
  String get sectionReminders => 'НАПОМИНАНИЯ';
  @override
  String get remindWhenDue => 'Напоминать о задачах';
  @override
  String get remindOn => 'Уведомление для каждой задачи с датой';
  @override
  String get remindOff => 'Уведомлений нет';
  @override
  String timedTasksLead(String lead) => 'Задачи со временем — $lead';
  @override
  String allDayAt(String time) => 'Задачи на весь день — в $time';
  @override
  String get allDayAtHint => 'Задача без времени напоминается в этот час';
  @override
  String get sectionAbout => 'О ПРИЛОЖЕНИИ';
  @override
  String get about =>
      'Caldo хранит календарь и список дел в одном месте — '
      'только на этом устройстве.';

  @override
  String get editTask => 'Изменить задачу';
  @override
  String get taskField => 'Задача';
  @override
  String get required => 'Обязательно';
  @override
  String get notesField => 'Заметки (необязательно)';
  @override
  String get sectionSubtasks => 'ПОДЗАДАЧИ';
  @override
  String get addSubtask => 'Добавить подзадачу';
  @override
  String get dueDate => 'Дата';
  @override
  String get time => 'Время';
  @override
  String get none => 'Нет';
  @override
  String repeatField(Repeat repeat) =>
      'Повтор: ${switch (repeat) {
        Repeat.none => 'никогда',
        Repeat.daily => 'каждый день',
        Repeat.weekly => 'каждую неделю',
        Repeat.monthly => 'каждый месяц',
        Repeat.yearly => 'каждый год',
      }}';
  @override
  String repeatName(Repeat repeat) => switch (repeat) {
    Repeat.none => 'Никогда',
    Repeat.daily => 'Каждый день',
    Repeat.weekly => 'Каждую неделю',
    Repeat.monthly => 'Каждый месяц',
    Repeat.yearly => 'Каждый год',
  };
  @override
  String remindLead(String lead) => 'Напомнить $lead';
  @override
  String remindOnDayAt(String time) => 'Напомнить в тот же день в $time';
  @override
  String get remindDayBefore => 'Напомнить накануне';
  @override
  String get noReminder => 'Без напоминания';
  @override
  String get sectionPriority => 'ПРИОРИТЕТ';
  @override
  String priorityName(Priority priority) => switch (priority) {
    Priority.none => 'Нет',
    Priority.low => 'Низкий',
    Priority.medium => 'Средний',
    Priority.high => 'Высокий',
  };
  @override
  String get sectionColour => 'ЦВЕТ';
  @override
  String get list => 'Список';
  @override
  String get deleteTaskQuestion => 'Удалить задачу?';
  @override
  String willBeRemoved(String title) => 'Задача «$title» будет удалена.';

  @override
  String get atTheTime => 'в срок';
  @override
  String minutesBefore(int minutes) => 'за $minutes мин';
  @override
  String hoursBefore(int hours) => hours == 1
      ? 'за час'
      : 'за $hours ${_plural(hours, 'час', 'часа', 'часов')}';
  @override
  String daysBefore(int days) => days == 1
      ? 'за день'
      : 'за $days ${_plural(days, 'день', 'дня', 'дней')}';
  @override
  String get selectTime => 'Время';
  @override
  String get nextWeek => 'Через неделю';
  @override
  String get nextMonth => 'Следующий месяц';
  @override
  String get previousMonth => 'Предыдущий месяц';
  @override
  String get reminderDone => 'Готово';
  @override
  String snoozeMinutes(int minutes) => 'Отложить на $minutes мин';
  @override
  String get snoozeHour => 'Отложить на час';
  @override
  String get reminderChannel => 'Напоминания о задачах';
  @override
  String get reminderChannelHint => 'Уведомление о каждой задаче в её срок.';

  @override
  String dueLine({String? day, String? time, required bool past}) {
    final head = past ? 'Срок прошёл' : 'Срок';
    final when = day ?? 'сегодня';
    return time == null ? '$head: $when' : '$head: $when в $time';
  }
}
