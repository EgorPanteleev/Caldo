import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/secret.dart';
import '../providers/vault_provider.dart';
import '../services/vault_device.dart';
import '../theme/app_theme.dart';
import '../widgets/desk.dart';
import '../widgets/quick_add_bar.dart' show BarRoom, KeyboardRoom;
import '../widgets/screen_header.dart';
import '../widgets/vault_sheets.dart';

const vaultPasswordKey = Key('vault-password');
const vaultRepeatKey = Key('vault-repeat');
const vaultGoKey = Key('vault-go');

/// Passwords, codes and notes, kept sealed (`VaultProvider`).
///
/// Three faces: making a vault, a locked one, and an open one — a list of
/// secrets by name, each opening to its lines with a copy button apiece.
/// While open and on show, the screen is kept out of screenshots and the
/// recent apps. It reads nothing until it is first shown, and on being
/// shown locked it asks for the fingerprint by itself, if that is on.
class VaultScreen extends StatelessWidget {
  /// Whether this is the screen on show; null when shown on its own.
  final ValueListenable<bool>? shown;

  const VaultScreen({super.key, this.shown});

  @override
  Widget build(BuildContext context) {
    // Read as one that may not be there, as the phone's calendars are: a
    // test that builds the shell for something else need not make one.
    final vault = context.read<VaultProvider?>();
    if (vault == null) return const SizedBox.shrink();
    return _Vault(vault: vault, shown: shown);
  }
}

class _Vault extends StatefulWidget {
  final VaultProvider vault;
  final ValueListenable<bool>? shown;

  const _Vault({required this.vault, this.shown});

  @override
  State<_Vault> createState() => _VaultState();
}

class _VaultState extends State<_Vault> with WidgetsBindingObserver {
  VaultProvider get _vault => widget.vault;

  /// Whether the fingerprint has been asked for by itself since the screen
  /// last came on show, or the app back to it. Once: put away, it is left
  /// for the button.
  bool _fingerAsked = false;
  bool _wasAway = false;
  String? _fingerProblem;

  bool get _shown => widget.shown?.value ?? true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.shown?.addListener(_follow);
    _vault.addListener(_secure);
    _follow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.shown?.removeListener(_follow);
    _vault.removeListener(_secure);
    VaultDevice.instance.secure(false);
    super.dispose();
  }

  void _follow() {
    if (_shown) {
      _vault.start().then((_) => _offerFinger());
    } else {
      _fingerAsked = false;
    }
    _secure();
  }

  void _secure() =>
      VaultDevice.instance.secure(_shown && _vault.state == VaultState.open);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_vault.asking) return;
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _wasAway = true;
      case AppLifecycleState.resumed when _wasAway:
        _wasAway = false;
        _fingerAsked = false;
        // After the vault has had its say on whether the time away locked it.
        WidgetsBinding.instance.addPostFrameCallback((_) => _offerFinger());
      default:
    }
  }

  void _offerFinger() {
    if (!mounted || _fingerAsked || !_shown) return;
    if (_vault.state != VaultState.locked || !_vault.fingerOn) return;
    _fingerAsked = true;
    _unlockByFinger();
  }

  Future<void> _unlockByFinger() async {
    final s = S.of(context);
    setState(() => _fingerProblem = null);
    try {
      await _vault.unlockWithFinger();
    } on FingerException catch (e) {
      if (!mounted) return;
      setState(
        () => _fingerProblem = switch (e.problem) {
          FingerProblem.cancelled => null,
          FingerProblem.gone => s.vaultFingerGone,
          FingerProblem.failed => e.message ?? s.vaultFingerFailed,
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final vault = context.watch<VaultProvider>();
    final open = vault.state == VaultState.open;
    return Scaffold(
      // Each screen decides what the keyboard does to it (the shell); this
      // one's fields are at the top, and the rest can be scrolled up to.
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          DeskColumn(
            child: ScreenHeader(
              title: s.vault,
              count: open && vault.secrets.isNotEmpty
                  ? vault.secrets.length
                  : null,
              actions: [
                if (open) ...[
                  IconButton(
                    icon: Icon(Icons.add_rounded, color: p.muted),
                    tooltip: s.vaultNew,
                    onPressed: () => showSecretForm(context),
                  ),
                  IconButton(
                    icon: Icon(Icons.tune_rounded, color: p.muted),
                    tooltip: s.vaultSettings,
                    onPressed: () => showVaultSettings(context),
                  ),
                  IconButton(
                    icon: Icon(Icons.lock_outline_rounded, color: p.muted),
                    tooltip: s.vaultLock,
                    onPressed: vault.lock,
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: switch (vault.state) {
              VaultState.loading => const _Waiting(),
              VaultState.none when vault.looking => _Waiting(
                words: s.vaultLooking,
              ),
              VaultState.none => const _SetUp(),
              VaultState.locked => _Locked(
                onFinger: vault.fingerOn ? _unlockByFinger : null,
                fingerProblem: _fingerProblem,
              ),
              VaultState.open => const _Open(),
            },
          ),
        ],
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  final String? words;

  const _Waiting({this.words});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          if (words != null) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                words!,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A form at the top of the screen, a phone's width at most: where the
/// keyboard leaves it in sight.
class _Form extends StatelessWidget {
  final List<Widget> children;

  const _Form({required this.children});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + BarRoom.of(context)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...children, const KeyboardRoom()],
          ),
        ),
      ),
    );
  }
}

/// The lock, a line under it and a line of explanation.
class _Heading extends StatelessWidget {
  final IconData icon;
  final String title;
  final String note;

  const _Heading({required this.icon, required this.title, required this.note});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Column(
      children: [
        Icon(icon, size: 44, color: p.faint),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          note,
          textAlign: TextAlign.center,
          style: TextStyle(color: p.muted, fontSize: 13.5, height: 1.4),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  final String? text;

  const _Problem(this.text);

  @override
  Widget build(BuildContext context) {
    if (text == null) return const SizedBox(height: 14);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text!,
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.overdue),
      ),
    );
  }
}

class _SetUp extends StatefulWidget {
  const _SetUp();

  @override
  State<_SetUp> createState() => _SetUpState();
}

class _SetUpState extends State<_SetUp> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _finger = true;
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final s = S.of(context);
    final vault = context.read<VaultProvider>();
    if (_busy) return;
    final wrong = _password.text.length < VaultProvider.shortest
        ? s.vaultPasswordShort(VaultProvider.shortest)
        : _password.text != _repeat.text
        ? s.vaultPasswordsDiffer
        : null;
    setState(() => _problem = wrong);
    if (wrong != null) return;
    setState(() => _busy = true);
    FocusManager.instance.primaryFocus?.unfocus();
    final finger = _finger && vault.fingerAvailable;
    try {
      await vault.create(_password.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!finger) return;
    try {
      await vault.setFinger(true);
    } on FingerException catch (e) {
      // Made either way; the fingerprint can be turned on in its settings.
      debugPrint('Fingerprint not set up: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final vault = context.watch<VaultProvider>();
    return _Form(
      children: [
        _Heading(
          icon: Icons.shield_outlined,
          title: s.vaultSetUpTitle,
          note: s.vaultSetUpNote,
        ),
        PasswordField(
          key: vaultPasswordKey,
          controller: _password,
          label: s.vaultMasterPassword,
          newPassword: true,
          action: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        PasswordField(
          key: vaultRepeatKey,
          controller: _repeat,
          label: s.vaultRepeatPassword,
          newPassword: true,
          onSubmitted: _create,
        ),
        if (vault.fingerAvailable) ...[
          const SizedBox(height: 6),
          SwitchListTile(
            value: _finger,
            onChanged: (on) => setState(() => _finger = on),
            title: Text(s.vaultFingerSwitch),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        ],
        _Problem(_problem),
        WideButton(
          key: vaultGoKey,
          label: s.vaultCreate,
          busy: _busy,
          onTap: _create,
        ),
      ],
    );
  }
}

class _Locked extends StatefulWidget {
  /// Asks for the fingerprint; null when it is not set up here.
  final VoidCallback? onFinger;
  final String? fingerProblem;

  const _Locked({this.onFinger, this.fingerProblem});

  @override
  State<_Locked> createState() => _LockedState();
}

class _LockedState extends State<_Locked> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final s = S.of(context);
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final opened = await context.read<VaultProvider>().unlock(_password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = opened ? null : s.vaultWrongPassword;
    });
    if (opened) _password.clear();
  }

  Future<void> _forgot() async {
    final s = S.of(context);
    final vault = context.read<VaultProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.vaultForgotQuestion),
        content: Text(s.vaultForgotWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.overdue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.vaultDelete),
          ),
        ],
      ),
    );
    if (ok == true) await vault.deleteVault();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    return _Form(
      children: [
        _Heading(
          icon: Icons.lock_outline_rounded,
          title: s.vaultLocked,
          note: s.vaultUnlockHint,
        ),
        PasswordField(
          key: vaultPasswordKey,
          controller: _password,
          label: s.vaultMasterPassword,
          onSubmitted: _unlock,
        ),
        _Problem(_problem ?? widget.fingerProblem),
        WideButton(
          key: vaultGoKey,
          label: s.vaultUnlock,
          busy: _busy,
          onTap: _unlock,
        ),
        if (widget.onFinger != null) ...[
          const SizedBox(height: 10),
          WideButton(
            label: s.vaultUseFinger,
            icon: Icons.fingerprint_rounded,
            quiet: true,
            onTap: widget.onFinger!,
          ),
        ],
        const SizedBox(height: 28),
        Center(
          child: TextButton(
            onPressed: _forgot,
            child: Text(s.vaultForgot, style: TextStyle(color: p.faint)),
          ),
        ),
      ],
    );
  }
}

class _Open extends StatefulWidget {
  const _Open();

  @override
  State<_Open> createState() => _OpenState();
}

class _OpenState extends State<_Open> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final vault = context.watch<VaultProvider>();
    final elsewhere = vault.sealedElsewhere;
    if (vault.secrets.isEmpty && elsewhere == 0) {
      return EmptyState(
        icon: Icons.key_outlined,
        title: s.vaultEmpty,
        message: s.vaultEmptyHint,
      );
    }
    final query = _query.text.trim();
    final shown = [
      for (final secret in vault.secrets)
        if (query.isEmpty || secret.matches(query)) secret,
    ];
    return DeskGutter(
      builder: (context, gutter) => ListView(
        padding: EdgeInsets.fromLTRB(
          16 + gutter,
          0,
          16 + gutter,
          24 + BarRoom.of(context),
        ),
        children: [
          if (vault.secrets.isNotEmpty)
            TextField(
              controller: _query,
              onChanged: (_) => setState(() {}),
              autocorrect: false,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: s.vaultSearch,
                prefixIcon: Icon(Icons.search, color: p.faint),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close_rounded, color: p.faint),
                        onPressed: () => setState(_query.clear),
                      ),
              ),
            ),
          if (elsewhere > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Material(
                color: p.panel,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => showOtherPassword(context),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.vaultSealedElsewhere(elsewhere),
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right, size: 20, color: p.faint),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          if (shown.isEmpty && query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                s.nothingFound,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted),
              ),
            )
          else if (shown.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Material(
                color: p.panel,
                child: Column(
                  children: [
                    for (var i = 0; i < shown.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          indent: 16 + 38 + 14,
                          color: p.border,
                        ),
                      _SecretRow(secret: shown[i]),
                    ],
                  ],
                ),
              ),
            ),
          const KeyboardRoom(),
        ],
      ),
    );
  }
}

/// A secret on the list: its initial, its name and its login, and the
/// password a tap away from the clipboard.
class _SecretRow extends StatelessWidget {
  final Secret secret;

  const _SecretRow({required this.secret});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final title = secret.title.trim();
    final under = secret.login.isNotEmpty ? secret.login : secret.website;
    return InkWell(
      onTap: () => showSecretSheet(context, secret),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.field,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                title.isEmpty ? '•' : title.characters.first.toUpperCase(),
                style: TextStyle(
                  color: p.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (under.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      under,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
            if (secret.password.isNotEmpty)
              IconButton(
                icon: Icon(Icons.copy_rounded, size: 20, color: p.muted),
                tooltip: s.vaultCopyPassword,
                onPressed: () => copySecret(context, secret.password),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
