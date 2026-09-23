# Caldo

A calendar and to-do app for Android, built with Flutter. Tasks live in lists,
dated tasks show up on a month calendar, and everything is stored locally on
the device.

## Features

- **Today** — the overdue backlog, what is due today, and the next 30 days,
  every list mixed together and soonest first.
- **Calendar** — a swipeable month grid with a dot per task, coloured by the
  list it belongs to; tap a day to see and add its tasks.
- **Lists** — group tasks into lists, each with its own colour and icon and a
  progress bar of what is done.
- **Tasks** — notes, an optional due date with or without a time, a priority
  flag, and a repeat rule. Completing a repeating task rolls it forward to its
  next occurrence instead of closing it.
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
  screens/                agenda, calendar, lists, task list, editors, settings
  widgets/                task row, headers, theme cross-fade, selection bar
  theme/app_theme.dart    palette, accents, ThemeData
  utils/dates.dart        date formatting
```
