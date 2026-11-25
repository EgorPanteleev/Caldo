part of 'agents_screen.dart';

class _ModelPicker extends StatelessWidget {
  final AgentKind kind;
  final String? model;
  final ValueChanged<String?> onPick;

  const _ModelPicker({
    required this.kind,
    required this.model,
    required this.onPick,
  });

  Future<void> _choose(BuildContext context) async {
    final got = await showAppSheet<({String? model, bool custom})>(
      context,
      maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      child: _ModelChoices(kind: kind, model: model),
    );
    if (got == null || !context.mounted) return;
    if (!got.custom) {
      onPick(got.model);
      return;
    }

    final s = S.of(context);
    var typed = kind.models.contains(model) ? '' : model ?? '';
    final custom = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.chatModel),
        content: TextFormField(
          initialValue: typed,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (value) => typed = value,
          onFieldSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, typed),
            child: Text(s.save),
          ),
        ],
      ),
    );
    if (custom == null || !context.mounted) return;
    final trimmed = custom.trim();
    onPick(trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final s = S.of(context);
    final label = kind.modelLabels[model] ?? model ?? s.chatDefault;
    return Material(
      color: p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(Icons.auto_awesome_outlined, color: p.muted, size: 20),
        title: Text(
          label,
          style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
        ),
        trailing: Icon(Icons.unfold_more, color: p.muted, size: 20),
        onTap: () => _choose(context),
      ),
    );
  }
}

class _ModelChoices extends StatefulWidget {
  final AgentKind kind;
  final String? model;

  const _ModelChoices({required this.kind, required this.model});

  @override
  State<_ModelChoices> createState() => _ModelChoicesState();
}

class _ModelChoicesState extends State<_ModelChoices> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = AppTheme.of(context);
    final kind = widget.kind;
    final model = widget.model;
    final matches = [
      for (final id in kind.models)
        if (id.toLowerCase().contains(_query) ||
            (kind.modelLabels[id] ?? '').toLowerCase().contains(_query))
          id,
    ];

    Widget option(String label, {String? id, bool custom = false}) {
      final selected = custom
          ? model != null && !kind.models.contains(model)
          : model == id;
      return ListTile(
        selected: selected,
        selectedColor: p.text,
        selectedTileColor: p.field,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        title: Text(label),
        subtitle: id != null && id != label
            ? Text(id, style: TextStyle(color: p.muted))
            : null,
        trailing: selected ? Icon(Icons.check, color: p.text, size: 19) : null,
        onTap: () => Navigator.pop(context, (model: id, custom: custom)),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        12 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              s.chatModel,
              style: TextStyle(
                color: p.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (kind.models.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextField(
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: s.search,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                ),
              ),
            ),
          if (_query.isEmpty) option(s.chatDefault),
          for (final id in matches) option(kind.modelLabels[id] ?? id, id: id),
          if (_query.isNotEmpty && matches.isEmpty)
            ListTile(
              title: Text(s.nothingFound, style: TextStyle(color: p.muted)),
            ),
          option(
            s.chatOther,
            id: kind.models.contains(model) ? null : model,
            custom: true,
          ),
        ],
      ),
    );
  }
}
