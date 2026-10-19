import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/task_list.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/screen_header.dart';

/// Create a new task list or rename/restyle an existing one.
class ListEditScreen extends StatefulWidget {
  final TaskList? list;

  const ListEditScreen({super.key, this.list});

  @override
  State<ListEditScreen> createState() => _ListEditScreenState();
}

class _ListEditScreenState extends State<ListEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late String _styleId;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.list?.name ?? '');
    _styleId = widget.list?.styleId ?? ListStyle.presets.first.id;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final provider = context.read<TaskProvider>();
    final existing = widget.list;
    if (existing == null) {
      await provider.addList(
        TaskList(
          name: _name.text.trim(),
          styleId: _styleId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else {
      await provider.updateList(
        existing.copyWith(name: _name.text.trim(), styleId: _styleId),
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.list != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit list' : 'New list')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _name,
              autofocus: !isEdit,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'List name'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 26),
            const SectionLabel('COLOUR & ICON'),
            _StylePicker(
              selectedId: _styleId,
              onChanged: (id) => setState(() => _styleId = id),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check, size: 20),
                label: Text(isEdit ? 'Save changes' : 'Create list'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A grid of colour/icon tiles giving the list its identity.
class _StylePicker extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onChanged;

  const _StylePicker({required this.selectedId, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final style in ListStyle.presets)
          GestureDetector(
            onTap: () => onChanged(style.id),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: style.color.withValues(
                  alpha: style.id == selectedId ? 0.24 : 0.12,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: style.id == selectedId ? style.color : p.border,
                  width: style.id == selectedId ? 2 : 1,
                ),
              ),
              child: Icon(style.icon, color: style.color, size: 24),
            ),
          ),
      ],
    );
  }
}
