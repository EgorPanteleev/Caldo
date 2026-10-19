import 'dart:io';

import 'package:caldo/db/database.dart';
import 'package:caldo/models/task.dart';
import 'package:caldo/models/task_list.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Points sqflite at the host's sqlite and at a directory of this suite's
/// own, so test files running in parallel never share a database file.
void initTestDatabase() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  databaseFactory.setDatabasesPath(
    Directory.systemTemp.createTempSync('caldo_test').path,
  );
}

/// Deletes the on-disk test database so each test starts from the schema the
/// app creates on first run.
Future<void> resetTestDatabase() async {
  await AppDatabase.instance.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase('$dir/caldo.db');
}

/// A provider holding a "Work" list opened with three tasks: a timed one due
/// today, an overdue weekly one, and an undated one.
Future<TaskProvider> seedProvider() async {
  final now = DateTime.now();
  final today = dayOf(now);
  final provider = TaskProvider();
  await provider.loadLists();
  final work = await provider.addList(
    TaskList(
      name: 'Work',
      styleId: 'blue',
      createdAt: now.millisecondsSinceEpoch,
    ),
  );
  await provider.openList(work.id!);
  await provider.add(
    Task(
      listId: work.id!,
      title: 'Ship',
      notes: 'tag it first',
      dueAt: today.add(const Duration(hours: 15)).millisecondsSinceEpoch,
      hasTime: true,
      priority: Priority.high,
      createdAt: now.millisecondsSinceEpoch,
    ),
  );
  await provider.add(
    Task(
      listId: work.id!,
      title: 'Water',
      dueAt: today.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      repeat: Repeat.weekly,
      createdAt: now.millisecondsSinceEpoch,
    ),
  );
  await provider.add(
    Task(
      listId: work.id!,
      title: 'Someday idea',
      createdAt: now.millisecondsSinceEpoch,
    ),
  );
  await provider.loadTasks();
  await provider.loadMonth(today);
  return provider;
}
