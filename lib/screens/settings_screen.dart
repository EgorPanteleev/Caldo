import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../data/holidays.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/backup.dart';
import '../services/device_calendars.dart';
import '../services/reminders.dart';
import '../services/updates.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/choice_sheet.dart';
import '../widgets/date_time_pickers.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart' show CheckMark;
import '../widgets/theme_switcher.dart';
import 'home_screen.dart' show menuItems;

/// Appearance, calendar and task preferences. Everything here applies
/// immediately — there is nothing to save.
///
/// The screen itself is a short list of the kinds of thing that can be set,
/// each saying under its name how it stands, and each opens a page of its
/// own. All of them on one page ran to four screens of scrolling — "too
/// long".
///
/// On every page a section is one panel of rows, the way the phone's own
/// settings are drawn: a row says what it is and, under that, what it is
/// set to, and a tap either flips its switch or opens a sheet of the
/// choices. It was a stack of separately outlined boxes with a segmented
/// bar, a dropdown or a switch each — three ways of choosing on one screen,
/// and a box round every line of it.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _open(BuildContext context, String Function(S s) title, _Rows rows) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _Page(title: title, rows: rows),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final s = S.of(context);
    final shown = [
      for (final screen in settings.shownScreens)
        menuItems[screen.index].label(s),
    ];

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.only(bottom: 90),
        children: [
          // A long press on the title puts the keyboard's numbers on screen,
          // above the add field. Four attempts at one keyboard bug went by
          // on a phone that cannot be plugged into the machine the app is
          // built on; this is how the next one gets measured rather than
          // guessed at. Off by default and not stored.
          GestureDetector(
            onLongPress: () {
              final on = !KeyboardGap.showNumbers.value;
              KeyboardGap.showNumbers.value = on;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    on
                        ? 'Keyboard numbers on — they show above the add field'
                        : 'Keyboard numbers off',
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: ScreenHeader(title: s.settings),
          ),
          _Group(
            children: [
              _Row(
                icon: Icons.menu_open_rounded,
                title: s.pageScreens,
                value: shown.join(', '),
                onTap: () => _open(context, (s) => s.pageScreens, _screens),
              ),
              _Row(
                icon: Icons.tune_rounded,
                title: s.pageGeneral,
                value:
                    '${S.names[settings.languageInForce]} · '
                    '${_timeFormats[settings.use24Hour]}',
                onTap: () => _open(context, (s) => s.pageGeneral, _general),
              ),
              _Row(
                icon: Icons.palette_outlined,
                title: s.pageAppearance,
                value: _themeNames(s)[settings.themeMode],
                onTap: () =>
                    _open(context, (s) => s.pageAppearance, _appearance),
              ),
              _Row(
                icon: Icons.calendar_month_outlined,
                title: s.calendar,
                value: settings.weekStartsMonday
                    ? s.weeksMonSun
                    : s.weeksSunSat,
                onTap: () => _open(context, (s) => s.calendar, _calendar),
              ),
              _Row(
                icon: Icons.task_alt_rounded,
                title: s.pageTasks,
                value: settings.showCompleted
                    ? s.completedShown
                    : s.completedHidden,
                onTap: () => _open(context, (s) => s.pageTasks, _tasks),
              ),
              _Row(
                icon: Icons.notifications_none,
                title: s.pageReminders,
                value: settings.reminders ? s.remindOn : s.remindOff,
                onTap: () => _open(context, (s) => s.pageReminders, _reminders),
              ),
            ],
          ),
          _Group(
            children: [
              _Row(
                icon: Icons.backup_outlined,
                title: s.pageBackup,
                value: switch (settings.lastBackup) {
                  final day? => s.backupLast(Dates.dayDate(day)),
                  null => s.backupNever,
                },
                onTap: () => _open(context, (s) => s.pageBackup, _backup),
              ),
            ],
          ),
          _Group(
            label: s.sectionAbout,
            footnote: s.about,
            children: const [_Version()],
          ),
        ],
      ),
    );
  }
}

/// What one page of settings draws, from the settings as they stand.
typedef _Rows =
    List<Widget> Function(BuildContext context, SettingsProvider settings, S s);

/// One kind of setting on a page of its own, pushed over the shell, with a
/// way back to the list.
class _Page extends StatelessWidget {
  /// Named in the language in force, which the page itself can change.
  final String Function(S s) title;
  final _Rows rows;

  const _Page({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            ScreenHeader(title: title(S.of(context)), showBack: true),
            ...rows(context, settings, S.of(context)),
          ],
        ),
      ),
    );
  }
}

/// Each choice of clock, written the way a time reads on it.
const _timeFormats = {false: '3:00 PM', true: '15:00'};

Map<ThemeMode, String> _themeNames(S s) => {
  ThemeMode.dark: s.themeDark,
  ThemeMode.light: s.themeLight,
  ThemeMode.system: s.themeSystem,
};

String _screenName(S s, AppScreen screen) => menuItems[screen.index].label(s);

/// Which screen the app opens on, and which are in the menu.
List<Widget> _screens(BuildContext context, SettingsProvider settings, S s) {
  final shown = settings.shownScreens;
  return [
    _Group(
      children: [
        _Row(
          icon: Icons.login_rounded,
          title: s.startScreen,
          value: _screenName(s, settings.startScreen),
          onTap: () async {
            final screen = await choose(
              context,
              title: s.startScreen,
              selected: settings.startScreen,
              options: [
                for (final screen in shown)
                  Option(
                    screen,
                    _screenName(s, screen),
                    icon: menuItems[screen.index].icon,
                  ),
              ],
            );
            if (screen != null) settings.update(startScreen: screen);
          },
        ),
        // The tab bar replaced the menu, and some like the menu: more of the
        // screen, the calendar's day panel above all.
        _Row(
          icon: settings.screensInBar
              ? Icons.call_to_action_outlined
              : Icons.menu_rounded,
          title: s.switchScreens,
          value: settings.screensInBar ? s.tabBar : s.sideMenu,
          onTap: () async {
            final inBar = await choose(
              context,
              title: s.switchScreens,
              selected: settings.screensInBar,
              options: [
                Option(true, s.tabBar, icon: Icons.call_to_action_outlined),
                Option(false, s.sideMenu, icon: Icons.menu_rounded),
              ],
            );
            if (inBar != null) settings.update(screensInBar: inBar);
          },
        ),
      ],
    ),
    _Group(
      label: s.sectionInMenu,
      footnote: s.inMenuHint,
      children: [
        for (final screen in AppScreen.values)
          _SwitchRow(
            icon: menuItems[screen.index].icon,
            title: _screenName(s, screen),
            value: shown.contains(screen),
            // The last screen left in the menu stays there: a menu of
            // Settings alone would be an app with nothing in it.
            enabled: !(shown.length == 1 && shown.contains(screen)),
            onChanged: (on) {
              final hidden = {...settings.hiddenScreens};
              on ? hidden.remove(screen) : hidden.add(screen);
              settings.update(hiddenScreens: hidden);
            },
          ),
      ],
    ),
  ];
}

/// The language and the clock.
List<Widget> _general(BuildContext context, SettingsProvider settings, S s) {
  final phone = S.names[SettingsProvider.phoneLanguage]!;
  return [
    _Group(
      children: [
        _Row(
          icon: Icons.translate,
          title: s.language,
          value: settings.language == null
              ? s.followPhone(phone)
              : S.names[settings.language]!,
          onTap: () async {
            final code = await choose(
              context,
              title: s.language,
              selected: settings.language ?? '',
              // Each named in itself, so whichever language is on screen,
              // the way back to one's own can be read.
              options: [
                Option('', s.followPhone(phone)),
                for (final MapEntry(key: code, value: name) in S.names.entries)
                  Option(code, name),
              ],
            );
            if (code == null) return;
            settings.update(
              language: code.isEmpty ? null : code,
              clearLanguage: code.isEmpty,
            );
          },
        ),
        // One clock for every time in the app — the cards, the time picker
        // and its shortcuts, the notifications — which used to disagree: a
        // 12-hour picker set times the cards then wrote on a 24-hour clock.
        _Row(
          icon: Icons.schedule,
          title: s.timesWritten,
          value: _timeFormats[settings.use24Hour]!,
          onTap: () async {
            final h24 = await choose(
              context,
              title: s.timesWritten,
              selected: settings.use24Hour,
              options: [
                for (final MapEntry(key: h24, value: name)
                    in _timeFormats.entries)
                  Option(h24, name),
              ],
            );
            if (h24 != null) settings.update(use24Hour: h24);
          },
        ),
      ],
    ),
  ];
}

/// The theme and the accent.
List<Widget> _appearance(
  BuildContext context,
  SettingsProvider settings,
  S s,
) => [
  _Group(
    children: [
      _Row(
        icon: Icons.contrast,
        title: s.theme,
        value: _themeNames(s)[settings.themeMode]!,
        onTap: () async {
          final mode = await choose(
            context,
            title: s.theme,
            selected: settings.themeMode,
            options: [
              Option(
                ThemeMode.dark,
                s.themeDark,
                icon: Icons.dark_mode_outlined,
              ),
              Option(
                ThemeMode.light,
                s.themeLight,
                icon: Icons.light_mode_outlined,
              ),
              Option(
                ThemeMode.system,
                s.themeSystem,
                icon: Icons.brightness_auto_outlined,
              ),
            ],
          );
          if (mode == null || !context.mounted) return;
          // Cross-faded rather than snapped from one to the other.
          void apply() => settings.update(themeMode: mode);
          final switcher = ThemeSwitcher.of(context);
          switcher == null ? apply() : switcher.change(apply);
        },
      ),
      _AccentPicker(
        title: s.accent,
        selected: settings.accent,
        onChanged: (accent) => settings.update(accent: accent),
      ),
    ],
  ),
];

/// The week, the holidays and the phone's own calendars, a panel each.
List<Widget> _calendar(BuildContext context, SettingsProvider settings, S s) {
  final detected = Holidays.detectCountry();
  final followCountry = detected == null
      ? s.followDeviceUnsupported
      : s.followDevice(s.country(detected, Holidays.countries[detected]!));
  return [
    _Group(
      children: [
        _SwitchRow(
          icon: Icons.calendar_view_week_outlined,
          title: s.weekStartsMonday,
          hint: settings.weekStartsMonday ? s.weeksMonSun : s.weeksSunSat,
          value: settings.weekStartsMonday,
          onChanged: (v) => settings.update(weekStartsMonday: v),
        ),
      ],
    ),
    _Group(
      children: [
        _SwitchRow(
          icon: Icons.celebration_outlined,
          title: s.showHolidays,
          hint: settings.effectiveHolidayCountry == null
              ? s.holidaysOff
              : s.holidaysOn,
          value: settings.showHolidays,
          onChanged: (v) => settings.update(showHolidays: v),
        ),
        if (settings.showHolidays)
          _Row(
            icon: Icons.public,
            title: s.holidayCountry,
            value: settings.holidayCountry == null
                ? followCountry
                : s.country(
                    settings.holidayCountry!,
                    Holidays.countries[settings.holidayCountry]!,
                  ),
            onTap: () async {
              final code = await choose(
                context,
                title: s.holidayCountry,
                selected: settings.holidayCountry ?? '',
                options: [
                  Option('', followCountry),
                  for (final MapEntry(key: code, value: name)
                      in Holidays.countries.entries)
                    Option(code, s.country(code, name)),
                ],
              );
              if (code == null) return;
              settings.update(
                holidayCountry: code.isEmpty ? null : code,
                clearHolidayCountry: code.isEmpty,
              );
            },
          ),
      ],
    ),
    _Group(
      children: [
        _SwitchRow(
          icon: Icons.event_outlined,
          title: s.showEvents,
          hint: settings.showDeviceEvents ? s.eventsOn : s.eventsOff,
          value: settings.showDeviceEvents,
          onChanged: (on) async {
            // Asked of Android first: without the permission there is
            // nothing to show, and a switch that stayed on over nothing
            // would look broken.
            if (on && !await DeviceCalendars.ask()) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(s.calendarsRefused)));
              return;
            }
            settings.update(showDeviceEvents: on);
          },
        ),
        if (settings.showDeviceEvents)
          _CalendarPicker(
            hidden: settings.hiddenCalendars,
            onChanged: (hidden) => settings.update(hiddenCalendars: hidden),
          ),
      ],
    ),
  ];
}

/// Whether done tasks stay listed, and clearing them out. The clearing is a
/// panel of its own: it is the one thing in Settings that cannot be taken
/// back, and it should not sit in a row under a switch that can.
List<Widget> _tasks(BuildContext context, SettingsProvider settings, S s) => [
  _Group(
    children: [
      _SwitchRow(
        icon: Icons.visibility_outlined,
        title: s.showCompleted,
        hint: s.showCompletedHint,
        value: settings.showCompleted,
        onChanged: (v) {
          settings.update(showCompleted: v);
          context.read<TaskProvider>().setShowCompleted(v);
        },
      ),
    ],
  ),
  _Group(
    children: [
      // Red, and without a chevron: it is not a setting to open but a thing
      // done.
      _Row(
        icon: Icons.delete_sweep_outlined,
        title: s.clearCompleted,
        value: s.clearCompletedHint,
        danger: true,
        onTap: () => _clearCompleted(context),
      ),
    ],
  ),
];

Future<void> _clearCompleted(BuildContext context) async {
  final s = S.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.clearCompletedQuestion),
      content: Text(s.clearCompletedWarning),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(s.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(s.clear),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final removed = await context.read<TaskProvider>().clearCompleted();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        removed == 0 ? s.nothingToClear : s.removedCompleted(removed),
      ),
    ),
  );
}

/// Saving everything to a file kept somewhere else, and reading it back.
/// A panel of its own on the list rather than a row among the settings:
/// it is the one thing on it that is not a setting, and the one that says
/// how long it has been left.
List<Widget> _backup(BuildContext context, SettingsProvider settings, S s) => [
  _Group(
    footnote: s.backupNote,
    children: [
      _Row(
        icon: Icons.save_alt_rounded,
        title: s.backupSave,
        value: s.backupSaveHint,
        onTap: () => _saveBackup(context),
      ),
      _Row(
        icon: Icons.settings_backup_restore_rounded,
        title: s.backupRestore,
        value: s.backupRestoreHint,
        onTap: () => _restoreBackup(context),
      ),
    ],
  ),
  _Group(
    footnote: settings.autoBackup > 0 ? s.backupAutoNote : null,
    children: [
      _Row(
        icon: Icons.update_rounded,
        title: s.backupAuto,
        value: _autoBackupNames(s)[settings.autoBackup],
        onTap: () => _chooseAutoBackup(context, settings),
      ),
      if (settings.autoBackup > 0)
        _Row(
          icon: Icons.folder_outlined,
          title: s.backupFolder,
          value: settings.autoBackupFailed
              ? s.backupAutoFailed
              : settings.backupFolderName,
          warn: settings.autoBackupFailed,
          onTap: () => _chooseBackupFolder(context, settings),
        ),
    ],
  ),
];

Map<int, String> _autoBackupNames(S s) => {
  0: s.backupAutoOff,
  1: s.backupDaily,
  7: s.backupWeekly,
};

/// Turning it on asks for the folder first, when there is none yet: with
/// nowhere to write, a switch left on would be a backup that never happens.
Future<void> _chooseAutoBackup(
  BuildContext context,
  SettingsProvider settings,
) async {
  final s = S.of(context);
  final days = await choose(
    context,
    title: s.backupAuto,
    selected: settings.autoBackup,
    options: [
      for (final MapEntry(key: days, value: name) in _autoBackupNames(
        s,
      ).entries)
        Option(days, name),
    ],
  );
  if (days == null || days == settings.autoBackup || !context.mounted) return;
  final first = settings.autoBackup == 0 && days > 0;
  if (first && settings.backupFolder == null) {
    if (!await _pickBackupFolder(context, settings)) return;
  }
  await settings.setAutoBackup(days);
  // One now, so the folder is seen to fill.
  if (first) await Backup.autoIfDue(settings, now: true);
}

Future<void> _chooseBackupFolder(
  BuildContext context,
  SettingsProvider settings,
) async {
  if (await _pickBackupFolder(context, settings)) {
    await Backup.autoIfDue(settings, now: true);
  }
}

/// False if no folder was chosen.
Future<bool> _pickBackupFolder(
  BuildContext context,
  SettingsProvider settings,
) async {
  final s = S.of(context);
  final ({String uri, String name})? folder;
  try {
    folder = await Backup.chooseFolder();
  } on BackupException {
    if (context.mounted) _say(context, s.backupNotSaved);
    return false;
  }
  if (folder == null) return false;
  await settings.setBackupFolder(folder.uri, folder.name);
  return true;
}

String _backupProblem(S s, BackupProblem problem) => switch (problem) {
  BackupProblem.notCaldo => s.backupNotCaldo,
  BackupProblem.newer => s.backupNewer,
  BackupProblem.unreadable => s.backupUnreadable,
};

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<void> _saveBackup(BuildContext context) async {
  final s = S.of(context);
  final bool saved;
  try {
    saved = await Backup.save(context.read<SettingsProvider>());
  } on BackupException {
    if (context.mounted) _say(context, s.backupNotSaved);
    return;
  }
  if (saved && context.mounted) _say(context, s.backupSaved);
}

/// Reads the file first and says what is in it before anything is
/// replaced: a restore cannot be taken back, and the date and the count are
/// how a wrong file is caught.
Future<void> _restoreBackup(BuildContext context) async {
  final s = S.of(context);
  final Backup? backup;
  try {
    backup = await Backup.open();
  } on BackupException catch (e) {
    if (context.mounted) _say(context, _backupProblem(s, e.problem));
    return;
  }
  if (backup == null || !context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.restoreQuestion),
      content: Text(
        s.restoreWarning(
          day: Dates.dayDate(backup!.savedAt),
          tasks: backup.taskCount,
          groups: backup.groupCount,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(s.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(s.restore),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await backup.restore(
    context.read<SettingsProvider>(),
    context.read<TaskProvider>(),
  );
  // In the restored language, which may not be the one the tap was made in.
  if (context.mounted) _say(context, S.current.restored(backup.taskCount));
}

/// Whether tasks are announced, and when.
List<Widget> _reminders(
  BuildContext context,
  SettingsProvider settings,
  S s,
) => [
  _Group(
    children: [
      _SwitchRow(
        icon: Icons.notifications_none,
        title: s.remindWhenDue,
        hint: settings.reminders ? s.remindOn : s.remindOff,
        value: settings.reminders,
        onChanged: (on) async {
          // Permission is asked for the first time they are turned on — a
          // notification nobody has agreed to is dropped, and silently,
          // which looks exactly like a broken reminder. Saving is all that
          // is needed after that: the scheduler re-sets what is standing
          // against the settings it is handed.
          if (on) await Reminders.instance.requestPermission();
          await settings.update(reminders: on);
        },
      ),
    ],
  ),
  if (settings.reminders)
    _Group(
      children: [
        // How far ahead a timed task is announced when it does not say for
        // itself; a task can still choose its own.
        _Row(
          icon: Icons.alarm,
          title: s.timedTasks,
          value: _capital(Dates.lead(settings.reminderLead)),
          onTap: () async {
            const leads = SettingsProvider.leads;
            final lead = await choose(
              context,
              title: s.timedTasks,
              selected: leads.contains(settings.reminderLead)
                  ? settings.reminderLead
                  : leads.first,
              options: [
                for (final lead in leads)
                  Option(lead, _capital(Dates.lead(lead))),
              ],
            );
            if (lead != null) settings.update(reminderLead: lead);
          },
        ),
        _Row(
          icon: Icons.wb_sunny_outlined,
          title: s.allDayTasks,
          value: Dates.clock(settings.reminderTime, h24: settings.use24Hour),
          onTap: () async {
            final picked = await showAppTimePicker(
              context: context,
              initial: settings.reminderTime,
            );
            if (picked == null) return;
            await settings.update(
              reminderMinutes: picked.hour * 60 + picked.minute,
            );
          },
        ),
      ],
    ),
  if (settings.reminders)
    _Group(
      children: [
        _SwitchRow(
          icon: Icons.fullscreen_rounded,
          title: s.fullScreenReminders,
          hint: settings.fullScreenReminders ? s.fullScreenOn : s.fullScreenOff,
          value: settings.fullScreenReminders,
          onChanged: (on) async {
            if (on) await Reminders.instance.requestFullScreen();
            await settings.update(fullScreenReminders: on);
          },
        ),
      ],
    ),
];

/// [text] with a capital first letter, for a phrase made to run on in a
/// sentence ("at the time") standing on a line of its own.
String _capital(String text) => text.isEmpty
    ? text
    : Characters(text).first.toUpperCase() + Characters(text).skip(1).string;

/// A section: its name above when it needs one, its rows on one panel with
/// a hairline between each, and a line of explanation under it when it
/// needs one.
class _Group extends StatelessWidget {
  final String? label;
  final List<Widget> children;
  final String? footnote;

  const _Group({this.label, required this.children, this.footnote});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, label == null ? 10 : 18, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: SectionLabel(label!),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Material(
              color: p.panel,
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const _Hairline(),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
          if (footnote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                footnote!,
                style: TextStyle(color: p.faint, fontSize: 12.5, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }
}

/// The line between two rows, starting where their titles do rather than at
/// the panel's edge, so the icons down the side read as one column.
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: _Row.textStart,
    color: AppTheme.of(context).border,
  );
}

/// A row of a section: an icon, what the row is, and under it what it is
/// set to. A tap does what the row is for.
class _Row extends StatelessWidget {
  final IconData? icon;

  /// Drawn in the icon's place, when the row has something of its own.
  final Widget? leading;
  final String title;

  /// What the row is set to, or what it does.
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Drawn in red, for the one thing here that cannot be taken back.
  final bool danger;

  /// The value in red, for a setting that is not doing what it says.
  final bool warn;

  const _Row({
    this.icon,
    this.leading,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.warn = false,
  });

  /// Where the titles start, from the panel's edge.
  static const textStart = 16.0 + 24 + 16;

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final colour = danger ? AppColors.overdue : null;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 58),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 10, trailing == null ? 12 : 8, 10),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child:
                    leading ?? Icon(icon, size: 21, color: colour ?? p.muted),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colour ?? p.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (value != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        value!,
                        style: TextStyle(
                          color: warn ? AppColors.overdue : p.muted,
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing ??
                  (onTap == null || danger
                      ? const SizedBox.shrink()
                      : Icon(Icons.chevron_right, size: 20, color: p.faint)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row with a switch, which the whole row flips.
class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? hint;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    this.hint,
    required this.value,
    this.enabled = true,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _Row(
      icon: icon,
      title: title,
      value: hint,
      onTap: enabled ? () => onChanged(!value) : null,
      // Shrunk to its own size: the whole row is the tap target, and the
      // switch's padding to 48 points made every row with one taller than
      // the rows without.
      trailing: Switch(
        value: value,
        onChanged: enabled ? onChanged : null,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// The accent swatches, under their name, in the row's own column.
class _AccentPicker extends StatelessWidget {
  final String title;
  final AppAccent selected;
  final ValueChanged<AppAccent> onChanged;

  const _AccentPicker({
    required this.title,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                child: Icon(Icons.palette_outlined, size: 21, color: p.muted),
              ),
              const SizedBox(width: 16),
              Text(
                title,
                style: TextStyle(
                  color: p.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: _Row.textStart - 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final accent in AppAccent.presets)
                  _Swatch(
                    accent: accent,
                    isSelected: accent.id == selected.id,
                    onTap: () => onChanged(accent),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final AppAccent accent;
  final bool isSelected;
  final VoidCallback onTap;

  const _Swatch({
    required this.accent,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          gradient: accent.gradient,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? p.text : Colors.transparent,
            width: 2,
          ),
        ),
        child: isSelected
            ? const Icon(Icons.check, color: Colors.white, size: 18)
            : null,
      ),
    );
  }
}

/// The phone's calendars, each ticked to have its events shown. A holidays
/// calendar is the one most worth unticking: Caldo marks those itself.
class _CalendarPicker extends StatefulWidget {
  final Set<String> hidden;
  final ValueChanged<Set<String>> onChanged;

  const _CalendarPicker({required this.hidden, required this.onChanged});

  @override
  State<_CalendarPicker> createState() => _CalendarPickerState();
}

class _CalendarPickerState extends State<_CalendarPicker> {
  late final Future<List<DeviceCalendar>> _calendars =
      DeviceCalendars.calendars();

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return FutureBuilder<List<DeviceCalendar>>(
      future: _calendars,
      builder: (context, snapshot) {
        final calendars = snapshot.data ?? const <DeviceCalendar>[];
        if (snapshot.connectionState == ConnectionState.done &&
            calendars.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(_Row.textStart, 14, 16, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                S.of(context).noCalendars,
                style: TextStyle(color: p.faint, fontSize: 13),
              ),
            ),
          );
        }
        return Column(
          children: [
            for (var i = 0; i < calendars.length; i++) ...[
              if (i > 0) const _Hairline(),
              _Row(
                leading: Align(
                  child: _CalendarTick(
                    color: calendars[i].color,
                    on: !widget.hidden.contains(calendars[i].id),
                  ),
                ),
                title: calendars[i].name,
                value:
                    calendars[i].account.isNotEmpty &&
                        calendars[i].account != calendars[i].name
                    ? calendars[i].account
                    : null,
                trailing: const SizedBox.shrink(),
                onTap: () {
                  final hidden = {...widget.hidden};
                  if (!hidden.remove(calendars[i].id)) {
                    hidden.add(calendars[i].id);
                  }
                  widget.onChanged(hidden);
                },
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A calendar's tick, in the calendar's own colour, as a task's tick is in
/// the task's.
class _CalendarTick extends StatelessWidget {
  final Color color;
  final bool on;

  const _CalendarTick({required this.color, required this.on});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: on ? color : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.6),
      ),
      child: on ? const CustomPaint(painter: CheckMark(progress: 1)) : null,
    );
  }
}

/// The app's name and the version installed, so a report of something
/// wrong can say which build it was seen on.
class _Version extends StatefulWidget {
  const _Version();

  @override
  State<_Version> createState() => _VersionState();
}

class _VersionState extends State<_Version> {
  late final Future<String?> _installed = Updates.instance.installed();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _installed,
      builder: (context, snapshot) => _Row(
        icon: Icons.info_outline,
        title: 'Caldo',
        value: snapshot.data == null
            ? null
            : S.of(context).version(snapshot.data!),
      ),
    );
  }
}
