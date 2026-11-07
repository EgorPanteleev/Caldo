import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../data/holidays.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/device_calendars.dart';
import '../services/reminders.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/date_time_pickers.dart';
import '../widgets/quick_add_bar.dart';
import '../widgets/screen_header.dart';
import '../widgets/task_card.dart' show CheckMark;
import '../widgets/theme_switcher.dart';

/// Appearance, calendar and task preferences. Everything here applies
/// immediately — there is nothing to save.
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

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final settings = context.watch<SettingsProvider>();
    final s = S.of(context);

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
          Divider(height: 1, color: p.border),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionLabel(s.sectionGeneral),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    s.startScreen,
                    style: TextStyle(color: p.muted, fontSize: 14),
                  ),
                ),
                _StartScreenSelector(
                  value: settings.startScreen,
                  onChanged: (screen) => context
                      .read<SettingsProvider>()
                      .update(startScreen: screen),
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    s.timesWritten,
                    style: TextStyle(color: p.muted, fontSize: 14),
                  ),
                ),
                _ClockSelector(
                  use24Hour: settings.use24Hour,
                  onChanged: (h24) =>
                      context.read<SettingsProvider>().update(use24Hour: h24),
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    s.language,
                    style: TextStyle(color: p.muted, fontSize: 14),
                  ),
                ),
                _LanguageField(
                  value: settings.language,
                  onChanged: (code) => context.read<SettingsProvider>().update(
                    language: code,
                    clearLanguage: code == null,
                  ),
                ),
                const SizedBox(height: 28),
                SectionLabel(s.sectionAppearance),
                _ThemeModeSelector(
                  value: settings.themeMode,
                  onChanged: (mode) => _setThemeMode(context, mode),
                ),
                const SizedBox(height: 18),
                _AccentPicker(
                  selected: settings.accent,
                  onChanged: (accent) =>
                      context.read<SettingsProvider>().update(accent: accent),
                ),
                const SizedBox(height: 28),
                SectionLabel(s.sectionCalendar),
                _SwitchTile(
                  icon: Icons.calendar_view_week_outlined,
                  title: s.weekStartsMonday,
                  subtitle: settings.weekStartsMonday
                      ? s.weeksMonSun
                      : s.weeksSunSat,
                  value: settings.weekStartsMonday,
                  onChanged: (v) => context.read<SettingsProvider>().update(
                    weekStartsMonday: v,
                  ),
                ),
                const SizedBox(height: 12),
                _SwitchTile(
                  icon: Icons.celebration_outlined,
                  title: s.showHolidays,
                  subtitle: settings.effectiveHolidayCountry == null
                      ? s.holidaysOff
                      : s.holidaysOn,
                  value: settings.showHolidays,
                  onChanged: (v) =>
                      context.read<SettingsProvider>().update(showHolidays: v),
                ),
                if (settings.showHolidays) ...[
                  const SizedBox(height: 12),
                  _CountryField(
                    value: settings.holidayCountry,
                    detected: Holidays.detectCountry(),
                    onChanged: (code) =>
                        context.read<SettingsProvider>().update(
                          holidayCountry: code,
                          clearHolidayCountry: code == null,
                        ),
                  ),
                ],
                const SizedBox(height: 12),
                _SwitchTile(
                  icon: Icons.event_outlined,
                  title: s.showEvents,
                  subtitle: settings.showDeviceEvents
                      ? s.eventsOn
                      : s.eventsOff,
                  value: settings.showDeviceEvents,
                  onChanged: (v) => _setDeviceEvents(context, v),
                ),
                if (settings.showDeviceEvents) ...[
                  const SizedBox(height: 12),
                  _CalendarPicker(
                    hidden: settings.hiddenCalendars,
                    onChanged: (hidden) => context
                        .read<SettingsProvider>()
                        .update(hiddenCalendars: hidden),
                  ),
                ],
                const SizedBox(height: 28),
                SectionLabel(s.sectionTasks),
                _SwitchTile(
                  icon: Icons.visibility_outlined,
                  title: s.showCompleted,
                  subtitle: s.showCompletedHint,
                  value: settings.showCompleted,
                  onChanged: (v) {
                    context.read<SettingsProvider>().update(showCompleted: v);
                    context.read<TaskProvider>().setShowCompleted(v);
                  },
                ),
                const SizedBox(height: 12),
                _ActionTile(
                  icon: Icons.cleaning_services_outlined,
                  title: s.clearCompleted,
                  subtitle: s.clearCompletedHint,
                  onTap: () => _clearCompleted(context),
                ),
                const SizedBox(height: 28),
                SectionLabel(s.sectionReminders),
                _SwitchTile(
                  icon: Icons.notifications_none,
                  title: s.remindWhenDue,
                  subtitle: settings.reminders ? s.remindOn : s.remindOff,
                  value: settings.reminders,
                  onChanged: (v) => _setReminders(context, v),
                ),
                if (settings.reminders) ...[
                  const SizedBox(height: 12),
                  _LeadField(
                    value: settings.reminderLead,
                    onChanged: (v) => context.read<SettingsProvider>().update(
                      reminderLead: v,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ActionTile(
                    icon: Icons.schedule,
                    title: s.allDayAt(
                      Dates.clock(
                        settings.reminderTime,
                        h24: settings.use24Hour,
                      ),
                    ),
                    subtitle: s.allDayAtHint,
                    onTap: () => _pickReminderTime(context),
                  ),
                ],
                const SizedBox(height: 28),
                SectionLabel(s.sectionAbout),
                Text(
                  s.about,
                  style: TextStyle(color: p.muted, fontSize: 13, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Which of the two task screens the app opens on. Takes effect next launch
/// — a screen that jumped out from under the setting being changed would be
/// startling, and the one being looked at is Settings either way.
class _StartScreenSelector extends StatelessWidget {
  final StartScreen value;
  final ValueChanged<StartScreen> onChanged;

  const _StartScreenSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<StartScreen>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        ),
        segments: [
          ButtonSegment(
            value: StartScreen.schedule,
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(S.of(context).schedule),
            ),
          ),
          ButtonSegment(
            value: StartScreen.calendar,
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(S.of(context).calendar),
            ),
          ),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

/// 12-hour or 24-hour, each shown the way a time will read in it. The same
/// choice writes every time in the app — the cards, the time picker and its
/// shortcuts, the notifications — which used to disagree: a 12-hour picker
/// set times the cards then wrote on a 24-hour clock.
class _ClockSelector extends StatelessWidget {
  final bool use24Hour;
  final ValueChanged<bool> onChanged;

  const _ClockSelector({required this.use24Hour, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        ),
        segments: const [
          ButtonSegment(
            value: false,
            label: FittedBox(fit: BoxFit.scaleDown, child: Text('3:00 PM')),
          ),
          ButtonSegment(
            value: true,
            label: FittedBox(fit: BoxFit.scaleDown, child: Text('15:00')),
          ),
        ],
        selected: {use24Hour},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

class _ThemeModeSelector extends StatelessWidget {
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeModeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // Full width + scale-down labels so long words like "System" never
    // overflow on narrow screens or large font scales.
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<ThemeMode>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        ),
        segments: [
          for (final (mode, name) in [
            (ThemeMode.dark, S.of(context).themeDark),
            (ThemeMode.light, S.of(context).themeLight),
            (ThemeMode.system, S.of(context).themeSystem),
          ])
            ButtonSegment(
              value: mode,
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(name)),
            ),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

/// A row of tappable colour swatches for choosing the app accent. Applies
/// immediately, like the theme selector.
class _AccentPicker extends StatelessWidget {
  final AppAccent selected;
  final ValueChanged<AppAccent> onChanged;

  const _AccentPicker({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        for (final accent in AppAccent.presets)
          _Swatch(
            accent: accent,
            isSelected: accent.id == selected.id,
            onTap: () => onChanged(accent),
          ),
      ],
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
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          gradient: accent.gradient,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? p.text : Colors.transparent,
            width: 2.5,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: accent.color.withValues(alpha: 0.5),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: isSelected
            ? const Icon(Icons.check, color: Colors.white, size: 20)
            : null,
      ),
    );
  }
}

/// A settings row carrying a switch.
class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: p.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: p.faint, fontSize: 12.5),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// A tappable settings row that performs an action.
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: p.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: p.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(color: p.faint, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: p.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// The language the app speaks: the phone's, or one chosen here. Each is
/// named in itself, so whichever language is on screen, the way back to
/// one's own can be read.
class _LanguageField extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;

  const _LanguageField({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final names = S.names;
    final phone = names[SettingsProvider.phoneLanguage]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Icon(Icons.translate, size: 20, color: p.muted),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value ?? '',
                isExpanded: true,
                dropdownColor: p.panel,
                borderRadius: BorderRadius.circular(10),
                icon: Icon(Icons.expand_more, color: p.muted),
                style: TextStyle(
                  color: p.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(S.of(context).followPhone(phone)),
                  ),
                  for (final MapEntry(key: code, value: name) in names.entries)
                    DropdownMenuItem(value: code, child: Text(name)),
                ],
                onChanged: (v) => onChanged(v == null || v.isEmpty ? null : v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How far ahead a timed task is announced when it does not say for itself.
/// A task can still choose its own on the form.
class _LeadField extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _LeadField({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    const leads = SettingsProvider.leads;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Icon(Icons.alarm, size: 20, color: p.muted),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: leads.contains(value) ? value : leads.first,
                isExpanded: true,
                dropdownColor: p.panel,
                borderRadius: BorderRadius.circular(10),
                icon: Icon(Icons.expand_more, color: p.muted),
                style: TextStyle(
                  color: p.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                items: [
                  for (final lead in leads)
                    DropdownMenuItem(
                      value: lead,
                      child: Text(
                        S.of(context).timedTasksLead(Dates.lead(lead)),
                      ),
                    ),
                ],
                onChanged: (v) => onChanged(v ?? 0),
              ),
            ),
          ),
        ],
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
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: Column(
            children: [
              if (snapshot.connectionState == ConnectionState.done &&
                  calendars.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    S.of(context).noCalendars,
                    style: TextStyle(color: p.faint, fontSize: 13),
                  ),
                ),
              for (final calendar in calendars)
                InkWell(
                  onTap: () {
                    final hidden = {...widget.hidden};
                    if (!hidden.remove(calendar.id)) hidden.add(calendar.id);
                    widget.onChanged(hidden);
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: Row(
                      children: [
                        _CalendarTick(
                          color: calendar.color,
                          on: !widget.hidden.contains(calendar.id),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                calendar.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: p.text, fontSize: 14.5),
                              ),
                              if (calendar.account.isNotEmpty &&
                                  calendar.account != calendar.name)
                                Text(
                                  calendar.account,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.faint,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
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

/// Chooses whose public holidays to show; "Follow device" reads the country
/// from the phone's locale.
class _CountryField extends StatelessWidget {
  final String? value;
  final String? detected;
  final ValueChanged<String?> onChanged;

  const _CountryField({
    required this.value,
    required this.detected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final followLabel = detected == null
        ? s.followDeviceUnsupported
        : s.followDevice(s.country(detected!, Holidays.countries[detected]!));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Icon(Icons.public, size: 20, color: p.muted),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value ?? '',
                isExpanded: true,
                dropdownColor: p.panel,
                borderRadius: BorderRadius.circular(10),
                icon: Icon(Icons.expand_more, color: p.muted),
                style: TextStyle(
                  color: p.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                items: [
                  DropdownMenuItem(value: '', child: Text(followLabel)),
                  for (final entry in Holidays.countries.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(s.country(entry.key, entry.value)),
                    ),
                ],
                onChanged: (v) => onChanged(v == null || v.isEmpty ? null : v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
