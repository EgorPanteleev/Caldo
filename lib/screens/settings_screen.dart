import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/holidays.dart';
import '../providers/settings_provider.dart';
import '../providers/task_provider.dart';
import '../services/reminders.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import '../widgets/colour_selector.dart';
import '../widgets/date_time_pickers.dart';
import '../widgets/screen_header.dart';
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear completed tasks?'),
        content: const Text(
            'Every completed task in every list will be removed. '
            'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final removed = await context.read<TaskProvider>().clearCompleted();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(removed == 0
          ? 'No completed tasks to clear'
          : 'Removed $removed completed ${removed == 1 ? "task" : "tasks"}')),
    );
  }

  /// Turns reminders on or off, asking Android for permission the first time
  /// they are turned on — a notification nobody has agreed to is simply
  /// dropped, and silently, which looks exactly like a broken reminder.
  Future<void> _setReminders(BuildContext context, bool on) async {
    final settings = context.read<SettingsProvider>();
    if (on) await Reminders.instance.requestPermission();
    if (!context.mounted) return;
    await settings.update(reminders: on);
    if (!context.mounted) return;
    // The alarms are set from the agenda, so a change of mind has to go
    // through the thing that holds it.
    await context.read<TaskProvider>().loadTasks();
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
    if (!context.mounted) return;
    await context.read<TaskProvider>().loadTasks();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.only(bottom: 90),
        children: [
          ScreenHeader(title: 'Settings', onMenu: onMenu),
          Divider(height: 1, color: p.border),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('APPEARANCE'),
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
                const SectionLabel('CALENDAR'),
                _SwitchTile(
                  icon: Icons.calendar_view_week_outlined,
                  title: 'Start week on Monday',
                  subtitle: settings.weekStartsMonday
                      ? 'Weeks run Monday to Sunday'
                      : 'Weeks run Sunday to Saturday',
                  value: settings.weekStartsMonday,
                  onChanged: (v) => context
                      .read<SettingsProvider>()
                      .update(weekStartsMonday: v),
                ),
                const SizedBox(height: 12),
                _SwitchTile(
                  icon: Icons.celebration_outlined,
                  title: 'Show public holidays',
                  subtitle: settings.effectiveHolidayCountry == null
                      ? 'No holidays are marked'
                      : 'Marked in green on the calendar',
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
                const SizedBox(height: 28),
                const SectionLabel('TASKS'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Colour new tasks start in',
                    style: TextStyle(color: p.muted, fontSize: 14),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ColourSelector(
                    value: settings.defaultTaskStyleId,
                    // The link swatch means "whatever list it goes into", so
                    // it shows the colour of the list a new task lands in.
                    listColor: context
                            .watch<TaskProvider>()
                            .lists
                            .map((l) => l.style.color)
                            .firstOrNull ??
                        AppTheme.accentOf(context).color,
                    onChanged: (v) => context.read<SettingsProvider>().update(
                      defaultTaskStyleId: v,
                      clearDefaultTaskStyle: v == null,
                    ),
                  ),
                ),
                _SwitchTile(
                  icon: Icons.visibility_outlined,
                  title: 'Show completed tasks',
                  subtitle: 'Keep ticked-off tasks listed under the open ones',
                  value: settings.showCompleted,
                  onChanged: (v) {
                    context.read<SettingsProvider>().update(showCompleted: v);
                    context.read<TaskProvider>().setShowCompleted(v);
                  },
                ),
                const SizedBox(height: 12),
                _ActionTile(
                  icon: Icons.cleaning_services_outlined,
                  title: 'Clear completed tasks',
                  subtitle: 'Remove every ticked-off task from all lists',
                  onTap: () => _clearCompleted(context),
                ),
                const SizedBox(height: 28),
                const SectionLabel('REMINDERS'),
                _SwitchTile(
                  icon: Icons.notifications_none,
                  title: 'Remind me when a task is due',
                  subtitle: settings.reminders
                      ? 'A notification at the time it is due'
                      : 'Nothing is announced',
                  value: settings.reminders,
                  onChanged: (v) => _setReminders(context, v),
                ),
                if (settings.reminders) ...[
                  const SizedBox(height: 12),
                  _ActionTile(
                    icon: Icons.schedule,
                    title: 'All-day tasks at '
                        '${Dates.clock(settings.reminderTime)}',
                    subtitle: 'A task with no time of day is announced then',
                    onTap: () => _pickReminderTime(context),
                  ),
                ],
                const SizedBox(height: 28),
                const SectionLabel('ABOUT'),
                Text(
                  'Caldo keeps your calendar and to-do list in one place, '
                  'stored on this device only.',
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
        segments: const [
          ButtonSegment(
            value: ThemeMode.dark,
            label: FittedBox(fit: BoxFit.scaleDown, child: Text('Dark')),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            label: FittedBox(fit: BoxFit.scaleDown, child: Text('Light')),
          ),
          ButtonSegment(
            value: ThemeMode.system,
            label: FittedBox(fit: BoxFit.scaleDown, child: Text('System')),
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
                Text(title,
                    style: TextStyle(
                        color: p.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(color: p.faint, fontSize: 12.5)),
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
                    Text(title,
                        style: TextStyle(
                            color: p.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(color: p.faint, fontSize: 12.5)),
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
    final followLabel = detected == null
        ? 'Follow device (not supported yet)'
        : 'Follow device (${Holidays.countries[detected]})';
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
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
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
