import 'package:caldo/models/task.dart';
import 'package:caldo/services/reminders.dart';
import 'package:caldo/utils/dates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int ms(DateTime d) => d.millisecondsSinceEpoch;

  Task taskDue(DateTime due, {bool hasTime = false, bool done = false}) => Task(
    listId: 1,
    title: 'Test',
    dueAt: ms(due),
    hasTime: hasTime,
    done: done,
    createdAt: 0,
  );

  group('Repeat.next', () {
    test('adds a day, a week', () {
      final from = DateTime(2026, 3, 10, 9, 30);
      expect(Repeat.daily.next(from), DateTime(2026, 3, 11, 9, 30));
      expect(Repeat.weekly.next(from), DateTime(2026, 3, 17, 9, 30));
    });

    test('keeps the day of month and the time', () {
      final from = DateTime(2026, 3, 10, 9, 30);
      expect(Repeat.monthly.next(from), DateTime(2026, 4, 10, 9, 30));
      expect(Repeat.yearly.next(from), DateTime(2027, 3, 10, 9, 30));
    });

    test('clamps to the last day of a shorter month', () {
      expect(Repeat.monthly.next(DateTime(2026, 1, 31)), DateTime(2026, 2, 28));
      // 2028 is a leap year.
      expect(Repeat.monthly.next(DateTime(2028, 1, 31)), DateTime(2028, 2, 29));
    });

    test('rolls over the year boundary', () {
      expect(
        Repeat.monthly.next(DateTime(2026, 12, 15)),
        DateTime(2027, 1, 15),
      );
    });

    test('never returns a date when the task does not repeat', () {
      expect(Repeat.none.next(DateTime(2026, 3, 10)), isNull);
    });
  });

  group('Task.isOverdue', () {
    final now = DateTime.now();

    test('an all-day task is overdue only once its day has passed', () {
      expect(taskDue(now.subtract(const Duration(days: 1))).isOverdue, isTrue);
      expect(taskDue(now).isOverdue, isFalse);
      expect(taskDue(now.add(const Duration(days: 1))).isOverdue, isFalse);
    });

    test('a timed task is overdue as soon as its time has passed', () {
      final past = now.subtract(const Duration(hours: 2));
      expect(taskDue(past, hasTime: true).isOverdue, isTrue);
      expect(
        taskDue(now.add(const Duration(hours: 2)), hasTime: true).isOverdue,
        isFalse,
      );
    });

    test('a done or undated task is never overdue', () {
      final past = now.subtract(const Duration(days: 3));
      expect(taskDue(past, done: true).isOverdue, isFalse);
      expect(
        const Task(listId: 1, title: 'No date', createdAt: 0).isOverdue,
        isFalse,
      );
    });
  });

  group('serialisation', () {
    test('survives a round trip through the database map', () {
      final task = Task(
        id: 7,
        listId: 3,
        title: 'Water the plants',
        notes: 'the big one too',
        dueAt: ms(DateTime(2026, 5, 4, 18)),
        hasTime: true,
        done: true,
        priority: Priority.high,
        repeat: Repeat.weekly,
        styleId: 'teal',
        createdAt: 123,
        completedAt: 456,
      );
      final copy = Task.fromMap(task.toMap());
      expect(copy.id, task.id);
      expect(copy.listId, task.listId);
      expect(copy.title, task.title);
      expect(copy.notes, task.notes);
      expect(copy.dueAt, task.dueAt);
      expect(copy.hasTime, isTrue);
      expect(copy.done, isTrue);
      expect(copy.priority, Priority.high);
      expect(copy.repeat, Repeat.weekly);
      expect(copy.styleId, 'teal');
      expect(copy.completedAt, 456);
    });

    test('copyWith can clear the colour a task was given', () {
      final task = const Task(
        listId: 1,
        title: 'x',
        styleId: 'pink',
        createdAt: 0,
      );
      expect(task.copyWith(styleId: 'blue').styleId, 'blue');
      expect(task.copyWith(clearStyleId: true).styleId, isNull);
    });

    test('a hand-placed position survives the round trip', () {
      final placed = taskDue(DateTime(2026, 5, 4)).copyWith(sortOrder: 2);
      expect(Task.fromMap(placed.toMap()).sortOrder, 2);
      expect(placed.copyWith(clearSortOrder: true).sortOrder, isNull);
      // Null is "never dragged", which is not the same as "first".
      expect(
        Task.fromMap(taskDue(DateTime(2026, 5, 4)).toMap()).sortOrder,
        isNull,
      );
    });

    test('copyWith can clear the due date and the completion', () {
      final task = taskDue(DateTime(2026, 5, 4)).copyWith(completedAt: 1);
      final cleared = task.copyWith(clearDueAt: true, clearCompletedAt: true);
      expect(cleared.dueAt, isNull);
      expect(cleared.completedAt, isNull);
    });

    test('an unknown repeat rule falls back to none', () {
      expect(Repeat.byName('fortnightly'), Repeat.none);
      expect(Priority.byIndex(99), Priority.none);
    });
  });

  group('when a task is announced', () {
    const nine = 9 * 60;

    test('a timed task is announced at its own time', () {
      final at = DateTime(2026, 5, 4, 18, 30);
      final task = taskDue(at, hasTime: true).copyWith(id: 1);
      expect(Reminders.whenToAnnounce(task, nine), at);
    });

    test('an all-day task is announced at the hour settings names', () {
      final task = taskDue(DateTime(2026, 5, 4)).copyWith(id: 1);
      expect(Reminders.whenToAnnounce(task, nine), DateTime(2026, 5, 4, 9));
      expect(
        Reminders.whenToAnnounce(task, 7 * 60 + 45),
        DateTime(2026, 5, 4, 7, 45),
      );
    });

    test(
      'nothing is announced for a task that is done, undated or unsaved',
      () {
        final due = DateTime(2026, 5, 4);
        expect(
          Reminders.whenToAnnounce(
            taskDue(due, done: true).copyWith(id: 1),
            nine,
          ),
          isNull,
        );
        expect(
          Reminders.whenToAnnounce(
            const Task(listId: 1, title: 'x', createdAt: 0).copyWith(id: 1),
            nine,
          ),
          isNull,
        );
        // No id means no alarm to hang it on: the row has not been written yet.
        expect(Reminders.whenToAnnounce(taskDue(due), nine), isNull);
      },
    );

    test('a timed task comes the default lead ahead, or its own', () {
      final at = DateTime(2026, 5, 4, 18, 30);
      final task = taskDue(at, hasTime: true).copyWith(id: 1);
      expect(
        Reminders.whenToAnnounce(task, nine, lead: 15),
        DateTime(2026, 5, 4, 18, 15),
      );
      // Its own lead wins over the default, a day of it included.
      expect(
        Reminders.whenToAnnounce(
          task.copyWith(remindBefore: 60),
          nine,
          lead: 15,
        ),
        DateTime(2026, 5, 4, 17, 30),
      );
      expect(
        Reminders.whenToAnnounce(
          task.copyWith(remindBefore: Duration.minutesPerDay),
          nine,
        ),
        DateTime(2026, 5, 3, 18, 30),
      );
      // At the time, chosen for itself, is not the same as following Settings.
      expect(
        Reminders.whenToAnnounce(
          task.copyWith(remindBefore: 0),
          nine,
          lead: 15,
        ),
        at,
      );
    });

    test('an all-day task takes only whole days of a lead', () {
      final task = taskDue(DateTime(2026, 5, 4)).copyWith(id: 1);
      // The default lead is for timed tasks; this one is at the hour.
      expect(
        Reminders.whenToAnnounce(task, nine, lead: 30),
        DateTime(2026, 5, 4, 9),
      );
      expect(
        Reminders.whenToAnnounce(task.copyWith(remindBefore: 15), nine),
        DateTime(2026, 5, 4, 9),
      );
      // The day before crosses into the month before, at the same hour.
      expect(
        Reminders.whenToAnnounce(
          taskDue(
            DateTime(2026, 5, 1),
          ).copyWith(id: 1, remindBefore: Duration.minutesPerDay),
          nine,
        ),
        DateTime(2026, 4, 30, 9),
      );
      // Days and weeks ahead, for a birthday that wants a present bought.
      expect(
        Reminders.whenToAnnounce(
          task.copyWith(remindBefore: 3 * Duration.minutesPerDay),
          nine,
        ),
        DateTime(2026, 5, 1, 9),
      );
      expect(
        Reminders.whenToAnnounce(
          task.copyWith(remindBefore: 14 * Duration.minutesPerDay),
          nine,
        ),
        DateTime(2026, 4, 20, 9),
      );
    });

    test('a silent task is never announced, and a snooze always wins', () {
      final at = DateTime(2026, 5, 4, 18, 30);
      final task = taskDue(at, hasTime: true).copyWith(id: 1);
      expect(
        Reminders.whenToAnnounce(
          task.copyWith(remindBefore: Task.silent),
          nine,
        ),
        isNull,
      );
      final later = DateTime(2026, 5, 4, 18, 45);
      final snoozed = task.copyWith(
        remindBefore: 15,
        snoozedUntil: later.millisecondsSinceEpoch,
      );
      expect(Reminders.whenToAnnounce(snoozed, nine, lead: 60), later);
      // Done is done, snoozed or not.
      expect(
        Reminders.whenToAnnounce(snoozed.copyWith(done: true), nine),
        isNull,
      );
    });
  });

  group('ticking off', () {
    test('a one-off task is closed, and a snooze on it ends', () {
      final task = taskDue(
        DateTime(2026, 5, 4),
      ).copyWith(id: 1, snoozedUntil: 5);
      final done = task.completed(42);
      expect(done.done, isTrue);
      expect(done.completedAt, 42);
      expect(done.snoozedUntil, isNull);
      expect(done.reopened().done, isFalse);
      expect(done.reopened().completedAt, isNull);
    });

    test('a repeating task rolls on with its checklist cleared', () {
      final task = taskDue(DateTime(2026, 1, 31)).copyWith(
        id: 1,
        repeat: Repeat.monthly,
        snoozedUntil: 5,
        subtasks: const [Subtask('a', done: true)],
      );
      expect(task.rollsOn, isTrue);
      final next = task.completed(42);
      expect(next.done, isFalse);
      expect(next.due, DateTime(2026, 2, 28));
      expect(next.subtasks.single.done, isFalse);
      expect(next.snoozedUntil, isNull);
    });

    test('a lead and a snooze survive the database', () {
      final task = taskDue(
        DateTime(2026, 5, 4),
      ).copyWith(remindBefore: Task.silent, snoozedUntil: 7);
      final back = Task.fromMap(task.toMap());
      expect(back.remindBefore, Task.silent);
      expect(back.snoozedUntil, 7);
      expect(
        back.copyWith(clearRemindBefore: true, clearSnoozedUntil: true),
        isA<Task>()
            .having((t) => t.remindBefore, 'remindBefore', isNull)
            .having((t) => t.snoozedUntil, 'snoozedUntil', isNull),
      );
    });
  });

  group('how far ahead a reminder reads', () {
    test('minutes, hours and days', () {
      expect(Dates.lead(0), 'at the time');
      expect(Dates.lead(15), '15 min before');
      expect(Dates.lead(60), '1 hour before');
      expect(Dates.lead(120), '2 hours before');
      expect(Dates.lead(Duration.minutesPerDay), '1 day before');
      expect(Dates.lead(3 * Duration.minutesPerDay), '3 days before');
      expect(Dates.lead(7 * Duration.minutesPerDay), '1 week before');
      expect(Dates.lead(14 * Duration.minutesPerDay), '2 weeks before');
    });
  });
}
