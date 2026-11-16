import 'package:flutter/material.dart';
import 'package:supabase/supabase.dart' show AuthException;

import '../l10n/strings.dart';
import '../services/account.dart';
import '../theme/app_theme.dart';
import 'date_time_pickers.dart' show SheetAction, showAppSheet;

/// Signs in: an email address, then the code sent to it. Returns true once
/// signed in.
Future<bool?> showSignInSheet(BuildContext context) =>
    showAppSheet<bool>(context, child: const _SignInSheet());

/// Sets the address of the server this device syncs with.
Future<void> showServerSheet(BuildContext context) =>
    showAppSheet<void>(context, child: const _ServerSheet());

/// The email field in the sign-in sheet, and the code field after it.
const signInEmailKey = Key('sign-in-email');
const signInCodeKey = Key('sign-in-code');

class _SignInSheet extends StatefulWidget {
  const _SignInSheet();

  @override
  State<_SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<_SignInSheet> {
  final _email = TextEditingController();
  final _code = TextEditingController();

  /// The address the code went to; null while it is still being asked for.
  String? _sentTo;
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  /// What went wrong, in words: a code or an address the server turned
  /// down, or no answer at all.
  String _say(Object e, S s) {
    if (e is AuthException) {
      final code = e.code ?? '';
      if (code.contains('otp') || e.statusCode == '403') return s.syncBadCode;
      if (code.contains('email')) return s.syncBadEmail;
    }
    return s.syncUnreachable;
  }

  Future<void> _go() async {
    final s = S.of(context);
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final sentTo = _sentTo;
      if (sentTo == null) {
        final address = _email.text.trim();
        if (!address.contains('@')) {
          throw const AuthException('', code: 'email');
        }
        await Account.instance.sendCode(address);
        if (mounted) setState(() => _sentTo = address);
      } else {
        await Account.instance.verify(sentTo, _code.text);
        if (mounted) Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) setState(() => _problem = _say(e, s));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final sentTo = _sentTo;
    return _Body(
      title: s.syncSignIn,
      note: sentTo == null ? s.syncSignInHint : s.syncCodeSent(sentTo),
      problem: _problem,
      field: sentTo == null
          ? TextField(
              key: signInEmailKey,
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(labelText: s.syncEmail),
              onSubmitted: (_) => _go(),
            )
          : TextField(
              key: signInCodeKey,
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: 10,
              decoration: InputDecoration(
                labelText: s.syncCode,
                counterText: '',
              ),
              onSubmitted: (_) => _go(),
            ),
      action: sentTo == null ? s.syncSendCode : s.syncSignIn,
      busy: _busy,
      onAction: _go,
    );
  }
}

class _ServerSheet extends StatefulWidget {
  const _ServerSheet();

  @override
  State<_ServerSheet> createState() => _ServerSheetState();
}

class _ServerSheetState extends State<_ServerSheet> {
  late final _address = TextEditingController(
    text: Account.instance.server.value ?? '',
  );

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await Account.instance.setServer(_address.text);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return _Body(
      title: s.syncServer,
      field: TextField(
        controller: _address,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: s.syncServer,
          hintText: 'http://192.168.1.10:54321',
        ),
        onSubmitted: (_) => _save(),
      ),
      action: s.save,
      onAction: _save,
    );
  }
}

/// A sheet of one field: a title, a line about it, the field, what went
/// wrong if anything did, and Cancel beside the action.
class _Body extends StatelessWidget {
  final String title;
  final String? note;
  final Widget field;
  final String? problem;
  final String action;
  final bool busy;
  final VoidCallback onAction;

  const _Body({
    required this.title,
    this.note,
    required this.field,
    this.problem,
    required this.action,
    this.busy = false,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
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
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (note != null) ...[
              const SizedBox(height: 4),
              Text(note!, style: TextStyle(color: p.muted)),
            ],
            const SizedBox(height: 12),
            field,
            if (problem != null) ...[
              const SizedBox(height: 8),
              Text(problem!, style: const TextStyle(color: AppColors.overdue)),
            ],
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                SheetAction(
                  label: s.cancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
                busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : SheetAction(label: action, onTap: onAction),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
