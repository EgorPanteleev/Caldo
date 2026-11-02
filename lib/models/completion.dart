/// One tick in the Done log: what was ticked off and when.
///
/// Kept apart from the task it came from, with the title and colour the task
/// had at the time. A repeating task is one row ticked many times and a done
/// task can be cleared away or deleted; the log is of the ticks, so it keeps
/// every round of a repeating task and outlives the task itself.
class Completion {
  final int? id;

  /// The task ticked, which may since have been deleted.
  final int? taskId;

  final String title;
  final int listId;
  final String? styleId;

  /// Epoch millis of the tick.
  final int doneAt;

  const Completion({
    this.id,
    required this.taskId,
    required this.title,
    required this.listId,
    this.styleId,
    required this.doneAt,
  });

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(doneAt);

  Map<String, Object?> toMap() => {
    'id': id,
    'task_id': taskId,
    'title': title,
    'list_id': listId,
    'style_id': styleId,
    'done_at': doneAt,
  };

  factory Completion.fromMap(Map<String, Object?> map) => Completion(
    id: map['id'] as int?,
    taskId: map['task_id'] as int?,
    title: map['title'] as String? ?? '',
    listId: map['list_id'] as int? ?? 1,
    styleId: map['style_id'] as String?,
    doneAt: map['done_at'] as int? ?? 0,
  );
}
