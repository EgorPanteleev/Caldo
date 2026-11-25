/// Whether an agent's last words at a turn's end leave something for the
/// user to answer: a question ("Want me to open a PR?"), or an offer ("Let
/// me know if you'd like the tests too."). Such a chat isn't done but waits
/// for the user, and says so rather than "Finished".
///
/// Read from the words alone, as no agent says it otherwise, and only the
/// last paragraph — with the one before, if the last is a list of choices
/// it introduced — so a question quoted halfway through a report is not
/// taken for one put to the user.
bool asksBack(String text) {
  final tail = _tail(text);
  if (tail.isEmpty) return false;
  if (_question.hasMatch(tail)) return true;
  final lower = tail.toLowerCase();
  return _offers.any(lower.contains);
}

/// The paragraphs read: code, links and markup taken out, as a `?` in a
/// URL or a snippet asks nothing.
String _tail(String text) {
  final plain = text
      .replaceAll(RegExp(r'```[\s\S]*?(```|$)'), '\n\n')
      .replaceAll(RegExp(r'`[^`\n]*`'), '')
      .replaceAll(RegExp(r'\]\([^)\s]*\)'), ']')
      .replaceAll(RegExp(r'https?://\S+'), '')
      .replaceAll(RegExp(r'\*\*|__'), '');
  final paragraphs = [
    for (final p in plain.split(RegExp(r'\n\s*\n')))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  if (paragraphs.isEmpty) return '';
  final last = paragraphs.last;
  final listed = last
      .split('\n')
      .every((line) => _item.hasMatch(line) || line.startsWith(' '));
  return listed && paragraphs.length > 1
      ? '${paragraphs[paragraphs.length - 2]}\n$last'
      : last;
}

/// A line of a list: `- a`, `* a`, `1. a`, `2) a`.
final _item = RegExp(r'^\s*([-*•]|\d+[.)])\s');

/// A sentence ending in a question mark, or the full-width one.
final _question = RegExp('[?？]["\'»”)\\]]*(\\s|\$)');

/// What an offer is said with, in the languages Caldo is used in, lower
/// case. Questions need none of these: their mark tells them.
const _offers = [
  // English
  'let me know',
  'if you\'d like',
  'if you would like',
  'if you want',
  'if you prefer',
  'if you need',
  'want me to',
  'would you like',
  'should i ',
  'shall i ',
  'i can also',
  'happy to',
  'say the word',
  'just say',
  // Russian
  'если хотите',
  'если хочешь',
  'если нужно',
  'если надо',
  'если скажете',
  'если скажешь',
  'дайте знать',
  'дай знать',
  'могу также',
  'могу ещё',
  'могу еще',
  'могу сразу',
  'скажите, ',
  'скажи, ',
  // Ukrainian, Belarusian
  'якщо хочете',
  'якщо потрібно',
  'калі хочаце',
  // German
  'soll ich',
  'möchtest du',
  'möchten sie',
  'wenn du willst',
  'sag bescheid',
  // French, Spanish, Italian
  'si vous voulez',
  'si tu veux',
  'voulez-vous',
  'si quieres',
  'si lo deseas',
  'se vuoi',
  // Polish, Dutch, Turkish
  'jeśli chcesz',
  'czy mam',
  'als je wilt',
  'zal ik',
  'istersen',
];
