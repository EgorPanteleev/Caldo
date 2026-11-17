import 'dart:convert';

/// A line of a secret beyond the usual ones — a PIN, a card's number, a
/// recovery code — with whether it is kept out of sight like a password.
class SecretField {
  final String name;
  final String value;
  final bool hidden;

  const SecretField({this.name = '', this.value = '', this.hidden = false});

  SecretField copyWith({String? name, String? value, bool? hidden}) =>
      SecretField(
        name: name ?? this.name,
        value: value ?? this.value,
        hidden: hidden ?? this.hidden,
      );

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    if (hidden) 'hidden': true,
  };

  factory SecretField.fromJson(Map<String, Object?> json) => SecretField(
    name: json['name'] as String? ?? '',
    value: json['value'] as String? ?? '',
    hidden: json['hidden'] as bool? ?? false,
  );
}

/// One thing kept in the vault, as it is once opened.
///
/// Everything a user typed — its name included — is sealed together into
/// one box; the database and the server see only the box, its uuid and
/// when it was made.
class Secret {
  /// The row's uuid, made before it is first sealed (the box is bound to
  /// it); null for one not yet saved.
  final String? uuid;
  final String title;
  final String login;
  final String password;
  final String website;
  final String notes;
  final List<SecretField> fields;
  final int createdAt;

  /// When the row was last written, from the database's own stamp.
  final int updatedAt;

  const Secret({
    this.uuid,
    this.title = '',
    this.login = '',
    this.password = '',
    this.website = '',
    this.notes = '',
    this.fields = const [],
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  Secret copyWith({
    String? uuid,
    String? title,
    String? login,
    String? password,
    String? website,
    String? notes,
    List<SecretField>? fields,
    int? createdAt,
    int? updatedAt,
  }) => Secret(
    uuid: uuid ?? this.uuid,
    title: title ?? this.title,
    login: login ?? this.login,
    password: password ?? this.password,
    website: website ?? this.website,
    notes: notes ?? this.notes,
    fields: fields ?? this.fields,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// What goes into the box. Empty lines are left out, so a box says no
  /// more than it has to about what kind of secret it is.
  String seal() => jsonEncode({
    'title': title,
    if (login.isNotEmpty) 'login': login,
    if (password.isNotEmpty) 'password': password,
    if (website.isNotEmpty) 'website': website,
    if (notes.isNotEmpty) 'notes': notes,
    if (fields.isNotEmpty) 'fields': [for (final f in fields) f.toJson()],
  });

  factory Secret.opened(
    String text, {
    required String uuid,
    required int createdAt,
    required int updatedAt,
  }) {
    final json = jsonDecode(text) as Map<String, Object?>;
    return Secret(
      uuid: uuid,
      title: json['title'] as String? ?? '',
      login: json['login'] as String? ?? '',
      password: json['password'] as String? ?? '',
      website: json['website'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      fields: [
        for (final f in json['fields'] as List? ?? const [])
          SecretField.fromJson((f as Map).cast<String, Object?>()),
      ],
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// Whether [query] is in what the list shows of it, or in its website —
  /// never in the password or anything hidden.
  bool matches(String query) {
    final needle = query.toLowerCase();
    return title.toLowerCase().contains(needle) ||
        login.toLowerCase().contains(needle) ||
        website.toLowerCase().contains(needle);
  }
}
