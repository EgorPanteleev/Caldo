import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/secret.dart';
import '../providers/vault_provider.dart';
import '../services/vault_device.dart';
import '../theme/app_theme.dart';
import 'choice_sheet.dart';
import 'date_time_pickers.dart' show SheetAction, showAppSheet;

/// Copies [text] for a while (`VaultDevice.copy`) and says so.
Future<void> copySecret(BuildContext context, String text) async {
  final s = S.of(context);
  final messenger = ScaffoldMessenger.of(context);
  await VaultDevice.instance.copy(text);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(s.vaultCopied(VaultDevice.clipboardFor.inSeconds)),
        duration: const Duration(seconds: 2),
      ),
    );
}

/// A password typed in, out of sight until the eye is pressed.
class PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;

  /// One being chosen rather than recalled, for the keyboard's suggestions.
  final bool newPassword;
  final bool autofocus;
  final TextInputAction action;
  final VoidCallback? onSubmitted;

  /// Something to put beside the eye — the generator.
  final Widget? extra;

  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.newPassword = false,
    this.autofocus = false,
    this.action = TextInputAction.done,
    this.onSubmitted,
    this.extra,
  });

  @override
  State<PasswordField> createState() => PasswordFieldState();
}

class PasswordFieldState extends State<PasswordField> {
  bool _shown = false;

  /// Brings it into sight, as a generated password is.
  void show() => setState(() => _shown = true);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return TextField(
      controller: widget.controller,
      obscureText: !_shown,
      autofocus: widget.autofocus,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: widget.action,
      autofillHints: [
        widget.newPassword ? AutofillHints.newPassword : AutofillHints.password,
      ],
      onSubmitted: (_) => widget.onSubmitted?.call(),
      decoration: InputDecoration(
        labelText: widget.label,
        // Out of the way of the keys: Next goes to the next field, not to
        // the eye beside this one.
        suffixIcon: ExcludeFocus(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?widget.extra,
              IconButton(
                icon: Icon(
                  _shown
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: p.faint,
                ),
                tooltip: _shown ? s.vaultHide : s.vaultShow,
                onPressed: () => setState(() => _shown = !_shown),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A button the width of the form: filled in the raised grey, or [quiet]
/// with only a rim. Neutral, as the app's controls are.
class WideButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool busy;
  final bool quiet;
  final VoidCallback onTap;

  const WideButton({
    super.key,
    required this.label,
    this.icon,
    this.busy = false,
    this.quiet = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: quiet ? Colors.transparent : p.panelHi,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: SizedBox(
          height: 50,
          child: Center(
            child: busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 22, color: p.text),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        label,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A sheet's foot: two words, drawn towards the middle.
class _Foot extends StatelessWidget {
  final String left;
  final VoidCallback onLeft;
  final String right;
  final VoidCallback onRight;
  final bool danger;

  const _Foot({
    required this.left,
    required this.onLeft,
    required this.right,
    required this.onRight,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    // Shrunk rather than cut where two long words outrun a small phone.
    Widget fit(Widget child) => Flexible(
      child: FittedBox(fit: BoxFit.scaleDown, child: child),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        fit(
          danger
              ? TextButton(
                  onPressed: onLeft,
                  child: Text(
                    left,
                    style: TextStyle(
                      color: AppColors.overdue,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : SheetAction(label: left, onTap: onLeft),
        ),
        fit(SheetAction(label: right, onTap: onRight)),
      ],
    );
  }
}

/// The sheet's own title, in the weight the other sheets give theirs.
class _Title extends StatelessWidget {
  final String text;

  const _Title(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
  );
}

// ---- A secret ----------------------------------------------------------------

/// Shows [secret]: each line with a button to copy it, hidden ones behind
/// an eye; Edit and Delete at the foot.
Future<void> showSecretSheet(BuildContext context, Secret secret) =>
    showAppSheet<void>(context, child: _SecretView(secret: secret));

class _SecretView extends StatefulWidget {
  final Secret secret;

  const _SecretView({required this.secret});

  @override
  State<_SecretView> createState() => _SecretViewState();
}

class _SecretViewState extends State<_SecretView> {
  late Secret _secret = widget.secret;

  Future<void> _edit() async {
    final saved = await showSecretForm(context, secret: _secret);
    if (saved != null && mounted) setState(() => _secret = saved);
  }

  Future<void> _delete() async {
    final s = S.of(context);
    final vault = context.read<VaultProvider>();
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.vaultDeleteQuestion),
        content: Text(s.cannotBeUndone),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await vault.delete(_secret);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final secret = _secret;
    // The vault locked under the sheet takes the sheet with it.
    final open = context.select<VaultProvider, bool>(
      (v) => v.state == VaultState.open,
    );
    if (!open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Title(secret.title),
          const SizedBox(height: 12),
          if (secret.login.isNotEmpty)
            _Line(label: s.vaultLogin, value: secret.login),
          if (secret.password.isNotEmpty)
            _Line(label: s.vaultPassword, value: secret.password, hidden: true),
          if (secret.website.isNotEmpty)
            _Line(label: s.vaultWebsite, value: secret.website),
          for (final field in secret.fields)
            if (field.value.isNotEmpty)
              _Line(
                label: field.name.isEmpty ? s.vaultField : field.name,
                value: field.value,
                hidden: field.hidden,
              ),
          if (secret.notes.isNotEmpty)
            _Line(label: s.vaultNotes, value: secret.notes, copies: false),
          const SizedBox(height: 10),
          _Foot(
            left: s.delete,
            onLeft: _delete,
            danger: true,
            right: s.vaultEdit,
            onRight: _edit,
          ),
        ],
      ),
    );
  }
}

/// One line of a secret: what it is, small, over its value.
class _Line extends StatefulWidget {
  final String label;
  final String value;
  final bool hidden;
  final bool copies;

  const _Line({
    required this.label,
    required this.value,
    this.hidden = false,
    this.copies = true,
  });

  @override
  State<_Line> createState() => _LineState();
}

class _LineState extends State<_Line> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final hidden = widget.hidden && !_shown;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(color: p.faint, fontSize: 12),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  hidden ? '•' * min(widget.value.length, 16) : widget.value,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 15,
                    // Each character apart, for reading a password out.
                    letterSpacing: widget.hidden ? 0.6 : null,
                  ),
                ),
              ],
            ),
          ),
          if (widget.hidden)
            IconButton(
              icon: Icon(
                _shown
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
                color: p.muted,
              ),
              tooltip: _shown ? s.vaultHide : s.vaultShow,
              onPressed: () => setState(() => _shown = !_shown),
            ),
          if (widget.copies)
            IconButton(
              icon: Icon(Icons.copy_rounded, size: 20, color: p.muted),
              tooltip: s.vaultCopy,
              onPressed: () => copySecret(context, widget.value),
            )
          else
            const SizedBox(width: 10),
        ],
      ),
    );
  }
}

// ---- The form ----------------------------------------------------------------

const secretTitleKey = Key('secret-title');
const secretGenerateKey = Key('secret-generate');

/// Makes a secret, or changes [secret]; gives back the one saved.
Future<Secret?> showSecretForm(BuildContext context, {Secret? secret}) =>
    showAppSheet<Secret>(context, child: _SecretForm(secret: secret));

class _SecretForm extends StatefulWidget {
  final Secret? secret;

  const _SecretForm({this.secret});

  @override
  State<_SecretForm> createState() => _SecretFormState();
}

/// A field of the form's own, with its controllers.
class _FieldRow {
  final TextEditingController name;
  final TextEditingController value;
  bool hidden;

  _FieldRow(SecretField field)
    : name = TextEditingController(text: field.name),
      value = TextEditingController(text: field.value),
      hidden = field.hidden;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

class _SecretFormState extends State<_SecretForm> {
  late final Secret _old = widget.secret ?? const Secret();
  late final _title = TextEditingController(text: _old.title);
  late final _login = TextEditingController(text: _old.login);
  late final _password = TextEditingController(text: _old.password);
  late final _website = TextEditingController(text: _old.website);
  late final _notes = TextEditingController(text: _old.notes);
  late final _fields = [for (final f in _old.fields) _FieldRow(f)];
  final _passwordField = GlobalKey<PasswordFieldState>();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    for (final c in [_title, _login, _password, _website, _notes]) {
      c.dispose();
    }
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _generate() async {
    final made = await _showGenerator(context);
    if (made == null || !mounted) return;
    _password.text = made;
    _passwordField.currentState?.show();
  }

  Future<void> _save() async {
    final s = S.of(context);
    if (_busy) return;
    if (_title.text.trim().isEmpty) {
      setState(() => _problem = s.vaultNameMissing);
      return;
    }
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final saved = await context.read<VaultProvider>().save(
      _old.copyWith(
        title: _title.text.trim(),
        login: _login.text.trim(),
        password: _password.text,
        website: _website.text.trim(),
        notes: _notes.text.trimRight(),
        fields: [
          for (final f in _fields)
            if (f.name.text.trim().isNotEmpty || f.value.text.isNotEmpty)
              SecretField(
                name: f.name.text.trim(),
                value: f.value.text,
                hidden: f.hidden,
              ),
        ],
      ),
    );
    navigator.pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    const gap = SizedBox(height: 10);
    return Padding(
      // A sheet is not lifted the way a screen is, so it makes the
      // keyboard's room out of its own height.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Title(widget.secret == null ? s.vaultNew : s.vaultEdit),
            const SizedBox(height: 12),
            TextField(
              key: secretTitleKey,
              controller: _title,
              autofocus: widget.secret == null,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: s.vaultName),
            ),
            gap,
            TextField(
              controller: _login,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: s.vaultLogin),
            ),
            gap,
            PasswordField(
              key: _passwordField,
              controller: _password,
              label: s.vaultPassword,
              newPassword: true,
              action: TextInputAction.next,
              extra: IconButton(
                key: secretGenerateKey,
                icon: Icon(Icons.casino_outlined, color: p.faint),
                tooltip: s.vaultGenerate,
                onPressed: _generate,
              ),
            ),
            gap,
            TextField(
              controller: _website,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(labelText: s.vaultWebsite),
            ),
            gap,
            for (final f in _fields) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: f.name,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(labelText: s.vaultFieldName),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: f.value,
                      obscureText: f.hidden,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(labelText: s.vaultFieldValue),
                    ),
                  ),
                  // What a press does, as the password's own eye says.
                  IconButton(
                    icon: Icon(
                      f.hidden
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: p.faint,
                    ),
                    tooltip: f.hidden ? s.vaultShow : s.vaultHide,
                    onPressed: () => setState(() => f.hidden = !f.hidden),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: p.faint),
                    tooltip: s.remove,
                    onPressed: () => setState(() {
                      _fields.remove(f);
                      f.dispose();
                    }),
                  ),
                ],
              ),
              gap,
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(
                  () => _fields.add(_FieldRow(const SecretField(hidden: true))),
                ),
                icon: Icon(Icons.add_rounded, color: p.muted),
                label: Text(s.vaultAddField, style: TextStyle(color: p.muted)),
              ),
            ),
            gap,
            TextField(
              controller: _notes,
              minLines: 2,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: s.vaultNotes),
            ),
            if (_problem != null) ...[
              const SizedBox(height: 8),
              Text(_problem!, style: TextStyle(color: AppColors.overdue)),
            ],
            const SizedBox(height: 14),
            _busy
                ? const Center(
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _Foot(
                    left: s.cancel,
                    onLeft: () => Navigator.of(context).pop(),
                    right: s.save,
                    onRight: _save,
                  ),
          ],
        ),
      ),
    );
  }
}

// ---- The generator -----------------------------------------------------------

Future<String?> _showGenerator(BuildContext context) =>
    showAppSheet<String>(context, child: const _Generator());

/// Makes a password of [length] from letters of both cases, and digits and
/// symbols if asked, with at least one of each kind asked for.
String makePassword({
  int length = 20,
  bool digits = true,
  bool symbols = true,
  Random? random,
}) {
  final rng = random ?? Random.secure();
  const lower = 'abcdefghijklmnopqrstuvwxyz';
  const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  const numbers = '0123456789';
  const marks = '!@#\$%^&*()-_=+[]{};:,.?/';
  final kinds = [lower, upper, if (digits) numbers, if (symbols) marks];
  final all = kinds.join();
  while (true) {
    final made = String.fromCharCodes([
      for (var i = 0; i < length; i++) all.codeUnitAt(rng.nextInt(all.length)),
    ]);
    if (kinds.every((k) => made.split('').any(k.contains))) return made;
  }
}

class _Generator extends StatefulWidget {
  const _Generator();

  @override
  State<_Generator> createState() => _GeneratorState();
}

class _GeneratorState extends State<_Generator> {
  int _length = 20;
  bool _digits = true;
  bool _symbols = true;
  late String _made = _make();

  String _make() =>
      makePassword(length: _length, digits: _digits, symbols: _symbols);

  void _again() => setState(() => _made = _make());

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Title(s.vaultGenerate),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            decoration: BoxDecoration(
              color: p.panel,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _made,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 17,
                      letterSpacing: 0.6,
                      height: 1.35,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh_rounded, color: p.muted),
                  tooltip: s.vaultGenerate,
                  onPressed: _again,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(s.vaultLength(_length), style: TextStyle(color: p.muted)),
              Expanded(
                child: Slider(
                  value: _length.toDouble(),
                  min: 8,
                  max: 64,
                  divisions: 56,
                  onChanged: (v) => setState(() {
                    _length = v.round();
                    _made = _make();
                  }),
                ),
              ),
            ],
          ),
          SwitchListTile(
            value: _digits,
            onChanged: (on) => setState(() {
              _digits = on;
              _made = _make();
            }),
            title: Text(s.vaultDigits),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _symbols,
            onChanged: (on) => setState(() {
              _symbols = on;
              _made = _make();
            }),
            title: Text(s.vaultSymbols),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 6),
          _Foot(
            left: s.cancel,
            onLeft: () => Navigator.of(context).pop(),
            right: s.vaultUse,
            onRight: () => Navigator.of(context).pop(_made),
          ),
        ],
      ),
    );
  }
}

// ---- Settings ----------------------------------------------------------------

/// The fingerprint, how soon it locks, and the master password.
Future<void> showVaultSettings(BuildContext context) =>
    showAppSheet<void>(context, child: const _VaultSettings());

class _VaultSettings extends StatelessWidget {
  const _VaultSettings();

  static String lockName(S s, int minutes) =>
      minutes == 0 ? s.vaultLockAtOnce : s.vaultMinutes(minutes);

  Future<void> _finger(BuildContext context, bool on) async {
    final s = S.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<VaultProvider>().setFinger(on);
    } on FingerException catch (e) {
      if (e.problem == FingerProblem.cancelled) return;
      messenger.showSnackBar(
        SnackBar(content: Text(e.message ?? s.vaultFingerFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final vault = context.watch<VaultProvider>();
    if (vault.state != VaultState.open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).pop();
      });
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: _Title(s.vaultSettings),
          ),
          if (vault.fingerAvailable)
            SwitchListTile(
              secondary: Icon(Icons.fingerprint_rounded, color: p.muted),
              value: vault.fingerOn,
              onChanged: (on) => _finger(context, on),
              title: Text(s.vaultFingerSwitch),
              subtitle: Text(
                s.vaultFingerHint,
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ),
          ListTile(
            leading: Icon(Icons.timer_outlined, color: p.muted),
            title: Text(s.vaultLockAfter),
            subtitle: Text(
              lockName(s, vault.lockAfter),
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
            onTap: () async {
              final minutes = await choose(
                context,
                title: s.vaultLockAfter,
                selected: vault.lockAfter,
                options: [
                  for (final m in VaultProvider.lockChoices)
                    Option(m, lockName(s, m)),
                ],
              );
              if (minutes != null) await vault.setLockAfter(minutes);
            },
          ),
          ListTile(
            leading: Icon(Icons.password_rounded, color: p.muted),
            title: Text(s.vaultChangePassword),
            onTap: () =>
                showAppSheet<void>(context, child: const _ChangePassword()),
          ),
        ],
      ),
    );
  }
}

class _ChangePassword extends StatefulWidget {
  const _ChangePassword();

  @override
  State<_ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends State<_ChangePassword> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _change() async {
    final s = S.of(context);
    if (_busy) return;
    final wrong = _next.text.length < VaultProvider.shortest
        ? s.vaultPasswordShort(VaultProvider.shortest)
        : _next.text != _repeat.text
        ? s.vaultPasswordsDiffer
        : null;
    setState(() => _problem = wrong);
    if (wrong != null) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final changed = await context.read<VaultProvider>().changePassword(
      _current.text,
      _next.text,
    );
    if (!mounted) return;
    if (!changed) {
      setState(() {
        _busy = false;
        _problem = s.vaultWrongPassword;
      });
      return;
    }
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(s.vaultPasswordChanged)));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Title(s.vaultChangePassword),
            const SizedBox(height: 4),
            Text(s.vaultChangeNote, style: TextStyle(color: p.muted)),
            const SizedBox(height: 12),
            PasswordField(
              controller: _current,
              label: s.vaultCurrentPassword,
              autofocus: true,
              action: TextInputAction.next,
            ),
            const SizedBox(height: 10),
            PasswordField(
              controller: _next,
              label: s.vaultNewPassword,
              newPassword: true,
              action: TextInputAction.next,
            ),
            const SizedBox(height: 10),
            PasswordField(
              controller: _repeat,
              label: s.vaultRepeatPassword,
              newPassword: true,
              onSubmitted: _change,
            ),
            if (_problem != null) ...[
              const SizedBox(height: 8),
              Text(_problem!, style: TextStyle(color: AppColors.overdue)),
            ],
            const SizedBox(height: 14),
            _busy
                ? const Center(
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _Foot(
                    left: s.cancel,
                    onLeft: () => Navigator.of(context).pop(),
                    right: s.save,
                    onRight: _change,
                  ),
          ],
        ),
      ),
    );
  }
}

// ---- Another vault's password ------------------------------------------------

/// Asks for the master password of a vault made on another device, whose
/// secrets this one cannot open, and brings them in.
Future<void> showOtherPassword(BuildContext context) =>
    showAppSheet<void>(context, child: const _OtherPassword());

class _OtherPassword extends StatefulWidget {
  const _OtherPassword();

  @override
  State<_OtherPassword> createState() => _OtherPasswordState();
}

class _OtherPasswordState extends State<_OtherPassword> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _bring() async {
    final s = S.of(context);
    if (_busy || _password.text.isEmpty) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final opened = await context.read<VaultProvider>().unlock(_password.text);
    if (!mounted) return;
    if (opened) {
      navigator.pop();
      return;
    }
    setState(() {
      _busy = false;
      _problem = s.vaultWrongPassword;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Title(s.vaultOtherPassword),
            const SizedBox(height: 4),
            Text(s.vaultOtherNote, style: TextStyle(color: p.muted)),
            const SizedBox(height: 12),
            PasswordField(
              controller: _password,
              label: s.vaultMasterPassword,
              autofocus: true,
              onSubmitted: _bring,
            ),
            if (_problem != null) ...[
              const SizedBox(height: 8),
              Text(_problem!, style: TextStyle(color: AppColors.overdue)),
            ],
            const SizedBox(height: 14),
            _busy
                ? const Center(
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _Foot(
                    left: s.cancel,
                    onLeft: () => Navigator.of(context).pop(),
                    right: s.vaultUnlock,
                    onRight: _bring,
                  ),
          ],
        ),
      ),
    );
  }
}
