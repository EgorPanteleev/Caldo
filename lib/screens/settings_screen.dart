import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../data/holidays.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/device_calendars.dart';
import '../services/reminders.dart';
import '../services/updates.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/date_time_pickers.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart' show CheckMark;
import '../widgets/theme_switcher.dart';
import 'home_screen.dart' show menuItems;

/// Appearance, calendar and task preferences. Everything here applies
/// immediately — there is nothing to save.
///
/// Each section is one panel of rows, the way the phone's own settings are
/// drawn: a row says what it is and, under that, what it is set to, and a
/// tap either flips its switch or opens a sheet of the choices. It was a
/// stack of separately outlined boxes with a segmented bar, a dropdown or a
/// switch each — three ways of choosing on one screen, and a box round
/// every line of it.
class SettingsScreen extends StatelessWidget {
  /// Opens the shell's menu; null when the screen is shown on its own.
  final VoidCallback? onMenu;

  const SettingsScreen({super.key, this.onMenu});

  /// Apply a theme change with a smooth cross-fade.
  void _setThemeMode(BuildContext context, ThemeMode mode) {
    void apply() => context.read<SettingsProvider>().update(themeMode: mode);
    final switcher = ThemeSwitcher.of(context);
    if (switcher == null) {
      apply();
    } else {
      switcher.change(apply);
    }
  }

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

  /// Turns reminders on or off, asking Android for permission the first time
  /// they are turned on — a notification nobody has agreed to is simply
  /// dropped, and silently, which looks exactly like a broken reminder.
  Future<void> _setReminders(BuildContext context, bool on) async {
    final settings = context.read<SettingsProvider>();
    if (on) await Reminders.instance.requestPermission();
    if (!context.mounted) return;
    // Saving is all that is needed: the scheduler re-sets what is standing
    // against the settings it is handed.
    await settings.update(reminders: on);
  }

  /// Shows the phone's own calendars, asking Android first: without the
  /// permission there is nothing to show, and a switch that stayed on over
  /// nothing would look broken.
  Future<void> _setDeviceEvents(BuildContext context, bool on) async {
    final settings = context.read<SettingsProvider>();
    if (on && !await DeviceCalendars.ask()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.of(context).calendarsRefused)));
      return;
    }
    await settings.update(showDeviceEvents: on);
  }

  /// Picks the hour an all-day task is announced at.
  Future<void> _pickReminderTime(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    final picked = await showAppTimePicker(
      context: context,
      initial: settings.reminderTime,
    );
    if (picked == null || !context.mounted) return;
    await settings.update(reminderMinutes: picked.hour * 60 + picked.minute);
  }

  /// Puts a screen in the menu or takes it out. The last one left cannot be
  /// taken out — its switch is disabled — since a menu of Settings alone
  /// would be an app with nothing in it.
  void _showScreen(BuildContext context, AppScreen screen, bool on) {
    final settings = context.read<SettingsProvider>();
    final hidden = {...settings.hiddenScreens};
    on ? hidden.remove(screen) : hidden.add(screen);
    settings.update(hiddenScreens: hidden);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final s = S.of(context);
    final read = context.read<SettingsProvider>();
    final shown = settings.shownScreens;
    String screenName(AppScreen screen) => menuItems[screen.index].label(s);
    final themeNames = {
      ThemeMode.dark: s.themeDark,
      ThemeMode.light: s.themeLight,
      ThemeMode.system: s.themeSystem,
    };
    final phone = S.names[SettingsProvider.phoneLanguage]!;
    final detected = Holidays.detectCountry();
    final followCountry = detected == null
        ? s.followDeviceUnsupported
        : s.followDevice(s.country(detected, Holidays.countries[detected]!));
    final timeFormats = {false: '3:00 PM', true: '15:00'};

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
            child: ScreenHeader(title: s.settings, onMenu: onMenu),
          ),
          _Group(
            label: s.sectionScreens,
            footnote: s.inMenuHint,
            children: [
              _Row(
                icon: Icons.login_rounded,
                title: s.startScreen,
                value: screenName(settings.startScreen),
                onTap: () async {
                  final screen = await _choose(
                    context,
                    title: s.startScreen,
                    selected: settings.startScreen,
                    options: [
                      for (final screen in shown)
                        _Option(
                          screen,
                          screenName(screen),
                          icon: menuItems[screen.index].icon,
                        ),
                    ],
                  );
                  if (screen != null) read.update(startScreen: screen);
                },
              ),
              for (final screen in AppScreen.values)
                _SwitchRow(
                  icon: menuItems[screen.index].icon,
                  title: screenName(screen),
                  value: shown.contains(screen),
                  // The last screen left in the menu stays there.
                  enabled: !(shown.length == 1 && shown.contains(screen)),
                  onChanged: (on) => _showScreen(context, screen, on),
                ),
            ],
          ),
          _Group(
            label: s.sectionGeneral,
            children: [
              _Row(
                icon: Icons.translate,
                title: s.language,
                value: settings.language == null
                    ? s.followPhone(phone)
                    : S.names[settings.language]!,
                onTap: () async {
                  final code = await _choose(
                    context,
                    title: s.language,
                    selected: settings.language ?? '',
                    // Each named in itself, so whichever language is on
                    // screen, the way back to one's own can be read.
                    options: [
                      _Option('', s.followPhone(phone)),
                      for (final MapEntry(key: code, value: name)
                          in S.names.entries)
                        _Option(code, name),
                    ],
                  );
                  if (code == null) return;
                  read.update(
                    language: code.isEmpty ? null : code,
                    clearLanguage: code.isEmpty,
                  );
                },
              ),
              // One clock for every time in the app — the cards, the time
              // picker and its shortcuts, the notifications — which used to
              // disagree: a 12-hour picker set times the cards then wrote on
              // a 24-hour clock. Each choice is shown the way a time reads in
              // it.
              _Row(
                icon: Icons.schedule,
                title: s.timesWritten,
                value: timeFormats[settings.use24Hour]!,
                onTap: () async {
                  final h24 = await _choose(
                    context,
                    title: s.timesWritten,
                    selected: settings.use24Hour,
                    options: [
                      for (final MapEntry(key: h24, value: name)
                          in timeFormats.entries)
                        _Option(h24, name),
                    ],
                  );
                  if (h24 != null) read.update(use24Hour: h24);
                },
              ),
            ],
          ),
          _Group(
            label: s.sectionAppearance,
            children: [
              _Row(
                icon: Icons.contrast,
                title: s.theme,
                value: themeNames[settings.themeMode]!,
                onTap: () async {
                  final mode = await _choose(
                    context,
                    title: s.theme,
                    selected: settings.themeMode,
                    options: [
                      _Option(
                        ThemeMode.dark,
                        s.themeDark,
                        icon: Icons.dark_mode_outlined,
                      ),
                      _Option(
                        ThemeMode.light,
                        s.themeLight,
                        icon: Icons.light_mode_outlined,
                      ),
                      _Option(
                        ThemeMode.system,
                        s.themeSystem,
                        icon: Icons.brightness_auto_outlined,
                      ),
                    ],
                  );
                  if (mode != null && context.mounted) {
                    _setThemeMode(context, mode);
                  }
                },
              ),
              _AccentPicker(
                title: s.accent,
                selected: settings.accent,
                onChanged: (accent) => read.update(accent: accent),
              ),
            ],
          ),
          _Group(
            label: s.sectionCalendar,
            children: [
              _SwitchRow(
                icon: Icons.calendar_view_week_outlined,
                title: s.weekStartsMonday,
                value: settings.weekStartsMonday,
                hint: settings.weekStartsMonday ? s.weeksMonSun : s.weeksSunSat,
                onChanged: (v) => read.update(weekStartsMonday: v),
              ),
              _SwitchRow(
                icon: Icons.celebration_outlined,
                title: s.showHolidays,
                hint: settings.effectiveHolidayCountry == null
                    ? s.holidaysOff
                    : s.holidaysOn,
                value: settings.showHolidays,
                onChanged: (v) => read.update(showHolidays: v),
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
                    final code = await _choose(
                      context,
                      title: s.holidayCountry,
                      selected: settings.holidayCountry ?? '',
                      options: [
                        _Option('', followCountry),
                        for (final MapEntry(key: code, value: name)
                            in Holidays.countries.entries)
                          _Option(code, s.country(code, name)),
                      ],
                    );
                    if (code == null) return;
                    read.update(
                      holidayCountry: code.isEmpty ? null : code,
                      clearHolidayCountry: code.isEmpty,
                    );
                  },
                ),
              _SwitchRow(
                icon: Icons.event_outlined,
                title: s.showEvents,
                hint: settings.showDeviceEvents ? s.eventsOn : s.eventsOff,
                value: settings.showDeviceEvents,
                onChanged: (v) => _setDeviceEvents(context, v),
              ),
              if (settings.showDeviceEvents)
                _CalendarPicker(
                  hidden: settings.hiddenCalendars,
                  onChanged: (hidden) => read.update(hiddenCalendars: hidden),
                ),
            ],
          ),
          _Group(
            label: s.sectionTasks,
            children: [
              _SwitchRow(
                icon: Icons.visibility_outlined,
                title: s.showCompleted,
                hint: s.showCompletedHint,
                value: settings.showCompleted,
                onChanged: (v) {
                  read.update(showCompleted: v);
                  context.read<TaskProvider>().setShowCompleted(v);
                },
              ),
              // Red, and without a chevron: it is not a setting to open but
              // a thing done, and the one on this screen that cannot be
              // taken back.
              _Row(
                icon: Icons.delete_sweep_outlined,
                title: s.clearCompleted,
                value: s.clearCompletedHint,
                danger: true,
                onTap: () => _clearCompleted(context),
              ),
            ],
          ),
          _Group(
            label: s.sectionReminders,
            children: [
              _SwitchRow(
                icon: Icons.notifications_none,
                title: s.remindWhenDue,
                hint: settings.reminders ? s.remindOn : s.remindOff,
                value: settings.reminders,
                onChanged: (v) => _setReminders(context, v),
              ),
              if (settings.reminders) ...[
                // How far ahead a timed task is announced when it does not
                // say for itself; a task can still choose its own.
                _Row(
                  icon: Icons.alarm,
                  title: s.timedTasks,
                  value: _capital(Dates.lead(settings.reminderLead)),
                  onTap: () async {
                    const leads = SettingsProvider.leads;
                    final lead = await _choose(
                      context,
                      title: s.timedTasks,
                      selected: leads.contains(settings.reminderLead)
                          ? settings.reminderLead
                          : leads.first,
                      options: [
                        for (final lead in leads)
                          _Option(lead, _capital(Dates.lead(lead))),
                      ],
                    );
                    if (lead != null) read.update(reminderLead: lead);
                  },
                ),
                _Row(
                  icon: Icons.wb_sunny_outlined,
                  title: s.allDayTasks,
                  value: Dates.clock(
                    settings.reminderTime,
                    h24: settings.use24Hour,
                  ),
                  onTap: () => _pickReminderTime(context),
                ),
              ],
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

/// [text] with a capital first letter, for a phrase made to run on in a
/// sentence ("at the time") standing on a line of its own.
String _capital(String text) => text.isEmpty
    ? text
    : Characters(text).first.toUpperCase() + Characters(text).skip(1).string;

/// A section: its name above, its rows on one panel with a hairline between
/// each, and a line of explanation under it when it needs one.
class _Group extends StatelessWidget {
  final String label;
  final List<Widget> children;
  final String? footnote;

  const _Group({required this.label, required this.children, this.footnote});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: SectionLabel(label),
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

  const _Row({
    this.icon,
    this.leading,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
    this.danger = false,
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
                          color: p.muted,
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

/// One of the choices a sheet offers.
class _Option<T> {
  final T value;
  final String label;
  final IconData? icon;

  const _Option(this.value, this.label, {this.icon});
}

/// Offers [options] in a sheet from the foot of the screen, the one in force
/// ticked, and gives back the one tapped — or null if the sheet was put away.
Future<T?> _choose<T>(
  BuildContext context, {
  required String title,
  required T selected,
  required List<_Option<T>> options,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.7,
    ),
    builder: (_) => PickerSheet(
      child: _Choices<T>(title: title, selected: selected, options: options),
    ),
  );
}

class _Choices<T> extends StatefulWidget {
  final String title;
  final T selected;
  final List<_Option<T>> options;

  const _Choices({
    required this.title,
    required this.selected,
    required this.options,
  });

  @override
  State<_Choices<T>> createState() => _ChoicesState<T>();
}

class _ChoicesState<T> extends State<_Choices<T>> {
  final _ticked = GlobalKey();

  @override
  void initState() {
    super.initState();
    // A long list opens on the choice in force rather than at its top: the
    // holiday countries run past the sheet, and the one ticked may be among
    // the last of them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ticked = _ticked.currentContext;
      if (ticked != null) Scrollable.ensureVisible(ticked, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
            child: Text(
              widget.title,
              style: TextStyle(
                color: p.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final option in widget.options)
            _Choice(
              key: option.value == widget.selected ? _ticked : null,
              option: option,
              ticked: option.value == widget.selected,
            ),
        ],
      ),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  final _Option<T> option;
  final bool ticked;

  const _Choice({super.key, required this.option, required this.ticked});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return InkWell(
      onTap: () => Navigator.pop(context, option.value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 20, 14),
        child: Row(
          children: [
            if (option.icon != null) ...[
              Icon(option.icon, size: 21, color: ticked ? p.text : p.muted),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Text(
                option.label,
                style: TextStyle(
                  color: ticked ? p.text : p.muted,
                  fontSize: 15.5,
                  fontWeight: ticked ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (ticked) Icon(Icons.check_rounded, size: 22, color: p.text),
          ],
        ),
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
