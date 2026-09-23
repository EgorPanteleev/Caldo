# Caldo

A calendar and to-do app for Android, built with Flutter. Tasks live in lists,
dated tasks show up on a month calendar, and everything is stored locally on
the device.

## Features

Three tabs: **Tasks**, **Calendar**, **Settings**.

- **Tasks** — every task day by day: the overdue backlog, today, tomorrow, the
  next 30 days, and finally everything with no date on it.
- **Calendar** — a swipeable month grid marking each day's tasks with a slim
  bar per task, coloured by the list it belongs to. Drag the grid down (or tap
  its handle) to open the month out until every day spells its tasks out in
  words; the selected day's tasks are listed underneath.
- **Lists** — group tasks into lists, each with its own colour and icon and a
  progress bar of what is done. Reached from the folder button on Tasks.
- **A task** carries notes, an optional due date with or without a time, a
  priority flag, and a repeat rule. Completing a repeating task rolls it
  forward to its next occurrence instead of closing it.
- **Pickers** in the app's own style rather than Material's: a date sheet
  built on the same month grid, and a time sheet on scroll wheels.
- **Appearance** — dark/light/system themes with a smooth cross-fade, six
  accent colours, and a Monday- or Sunday-first week.

## Stack

Flutter with `provider` for state, `sqflite` for local storage,
`shared_preferences` for settings, `google_fonts` (Inter) and `intl` for dates
— the same toolset as its sibling app, Dicty, whose Obsidian-inspired theme
and Telegram-style tab bar it shares.

## Running

```sh
flutter pub get
flutter run                 # a connected device or emulator
flutter build apk --release
```

## Tests

```sh
flutter test
```

Model and provider logic is covered with unit tests, and the screens are
rendered at phone sizes in widget tests (against a real host-side SQLite
database via `sqflite_common_ffi`) so layout overflows fail the build.

## Layout

```
lib/
  db/database.dart        sqflite schema and queries
  models/                 Task, TaskList and their enums
  providers/              TaskProvider (lists, calendar, agenda), SettingsProvider
  screens/                tasks, calendar, lists, task list, editors, settings
  widgets/                month grid, pickers, task row, headers, selection bar
  theme/app_theme.dart    palette, accents, ThemeData
  utils/dates.dart        date formatting
```
