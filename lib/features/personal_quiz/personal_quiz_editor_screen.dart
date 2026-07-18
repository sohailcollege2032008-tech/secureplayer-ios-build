import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'personal_quiz_draft_state.dart';
import 'personal_quiz_generator.dart';
import 'personal_quiz_json_import.dart';

const _kBg = Color(0xFF0D0D0D);
const _kCard = Color(0xFF1A1A2E);
const _kAccent = Color(0xFF6C63FF);

/// Editor for one personal quiz draft — a near-port of Studio's
/// `QuizBlockEditor`/`_QuestionEditorCard`
/// (studio_flutter/lib/features/lecture_editor/lecture_editor_screen.dart),
/// minus everything scope/trigger-related (personal quizzes have no
/// lecture/video/popup concept at all). Autosaves to a local draft file via
/// [PersonalQuizDraftNotifier] — leaving and re-entering preserves
/// in-progress work until "Generate" is pressed.
class PersonalQuizEditorScreen extends ConsumerStatefulWidget {
  const PersonalQuizEditorScreen({super.key, required this.draftId});

  final String draftId;

  @override
  ConsumerState<PersonalQuizEditorScreen> createState() =>
      _PersonalQuizEditorScreenState();
}

class _PersonalQuizEditorScreenState
    extends ConsumerState<PersonalQuizEditorScreen> {
  late final TextEditingController _titleCtrl;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  PersonalQuizDraftNotifier get _notifier =>
      ref.read(personalQuizDraftProvider(widget.draftId).notifier);

  Future<void> _importJson() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => const _JsonImportDialog(),
    );
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final parsed = parsePersonalQuizFromJson(raw);
      final count = _notifier.addQuestionsFromJson(parsed.questions);
      if (parsed.title != null &&
          ref.read(personalQuizDraftProvider(widget.draftId)).title.isEmpty) {
        _notifier.updateTitle(parsed.title!);
      }
      if (!mounted) return;
      var message = 'Imported $count question${count == 1 ? '' : 's'}.';
      if (parsed.multipleQuizzesInArray) {
        message += ' Only the first quiz in the file was used.';
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Invalid JSON: ${e.message}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Future<void> _generate() async {
    final draft = ref.read(personalQuizDraftProvider(widget.draftId));
    if (draft.questions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add at least one question first.')));
      return;
    }
    for (final q in draft.questions) {
      if (q.text.trim().isEmpty || q.options.any((o) => o.trim().isEmpty)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Every question needs text and non-empty options.')));
        return;
      }
    }

    setState(() => _generating = true);
    try {
      await generatePersonalQuiz(draft);
      await _notifier.deleteDraft();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Quiz saved to Personal Quizzes.')));
      context.pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Generate failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(personalQuizDraftProvider(widget.draftId));
    final error = ref.watch(personalQuizDraftErrorProvider(widget.draftId));

    if (_titleCtrl.text != draft.title && !_titleCtrl.selection.isValid) {
      _titleCtrl.text = draft.title;
    }

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        foregroundColor: Colors.white,
        title: const Text('Edit Personal Quiz',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file_outlined),
            tooltip: 'Import from JSON',
            onPressed: _importJson,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (error != null)
              Container(
                width: double.infinity,
                color: Colors.redAccent.withValues(alpha: 0.15),
                padding: const EdgeInsets.all(10),
                child: Text(error,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 12)),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _titleCtrl,
                    onChanged: _notifier.updateTitle,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Quiz Title',
                      labelStyle: TextStyle(color: Colors.white54),
                      enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const _MiniLabel('DIRECTION'),
                  Row(
                    children: [
                      Expanded(
                        child: _DirChip(
                          label: 'Question: RTL',
                          selected: draft.questionDirection == 'rtl',
                          onTap: () => _notifier.updateQuestionDirection('rtl'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _DirChip(
                          label: 'Question: LTR',
                          selected: draft.questionDirection == 'ltr',
                          onTap: () => _notifier.updateQuestionDirection('ltr'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _DirChip(
                          label: 'Explanation: RTL',
                          selected: draft.explanationDirection == 'rtl',
                          onTap: () =>
                              _notifier.updateExplanationDirection('rtl'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _DirChip(
                          label: 'Explanation: LTR',
                          selected: draft.explanationDirection == 'ltr',
                          onTap: () =>
                              _notifier.updateExplanationDirection('ltr'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const _MiniLabel('QUESTIONS'),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _notifier.addQuestion,
                        icon: const Icon(Icons.add_rounded,
                            size: 16, color: _kAccent),
                        label: const Text('Add question',
                            style: TextStyle(color: _kAccent)),
                      ),
                    ],
                  ),
                  if (draft.questions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No questions yet — add one or import JSON.',
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                            fontStyle: FontStyle.italic),
                      ),
                    ),
                  ...draft.questions.asMap().entries.map(
                        (e) => _PersonalQuestionCard(
                          draftId: widget.draftId,
                          index: e.key,
                          question: e.value,
                        ),
                      ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _generating ? null : _generate,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kAccent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.white12,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: _generating
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Generate',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniLabel extends StatelessWidget {
  const _MiniLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.white54,
            letterSpacing: 0.5,
          ),
        ),
      );
}

class _DirChip extends StatelessWidget {
  const _DirChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _kAccent.withValues(alpha: 0.15) : _kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? _kAccent : Colors.white.withValues(alpha: 0.08)),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? _kAccent : Colors.white54, fontSize: 12)),
      ),
    );
  }
}

class _PersonalQuestionCard extends ConsumerStatefulWidget {
  const _PersonalQuestionCard({
    required this.draftId,
    required this.index,
    required this.question,
  });

  final String draftId;
  final int index;
  final PersonalQuizQuestionDraft question;

  @override
  ConsumerState<_PersonalQuestionCard> createState() =>
      _PersonalQuestionCardState();
}

class _PersonalQuestionCardState extends ConsumerState<_PersonalQuestionCard> {
  late TextEditingController _textCtrl;
  late TextEditingController _explCtrl;
  late List<TextEditingController> _optCtrls;

  @override
  void initState() {
    super.initState();
    _buildControllers();
  }

  void _buildControllers() {
    _textCtrl = TextEditingController(text: widget.question.text);
    _explCtrl = TextEditingController(text: widget.question.explanation);
    _optCtrls =
        widget.question.options.map((o) => TextEditingController(text: o)).toList();
  }

  void _disposeControllers() {
    _textCtrl.dispose();
    _explCtrl.dispose();
    for (final c in _optCtrls) {
      c.dispose();
    }
  }

  @override
  void didUpdateWidget(_PersonalQuestionCard old) {
    super.didUpdateWidget(old);
    if (old.question.id != widget.question.id ||
        old.question.options.length != widget.question.options.length) {
      _disposeControllers();
      _buildControllers();
    }
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  PersonalQuizDraftNotifier get _notifier =>
      ref.read(personalQuizDraftProvider(widget.draftId).notifier);

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      dialogTitle: 'Select question image',
    );
    final path = result?.files.singleOrNull?.path;
    if (path != null) {
      _notifier.setQuestionImage(widget.question.id, path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.question;
    final n = _notifier;
    final hasOverride = q.questionDirectionOverride != null ||
        q.explanationDirectionOverride != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Q${widget.index + 1}',
                  style: const TextStyle(
                      color: _kAccent, fontWeight: FontWeight.w700, fontSize: 13)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                color: Colors.redAccent,
                tooltip: 'Remove question',
                onPressed: () => n.removeQuestion(q.id),
              ),
            ],
          ),
          TextField(
            controller: _textCtrl,
            onChanged: (v) => n.updateQuestionText(q.id, v),
            maxLines: null,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Question text',
              labelStyle: TextStyle(color: Colors.white38),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                q.imagePath.isNotEmpty ? Icons.image_rounded : Icons.image_outlined,
                size: 16,
                color: q.imagePath.isNotEmpty ? Colors.greenAccent : Colors.white38,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  q.imagePath.isEmpty
                      ? 'No image'
                      : q.imagePath.split(RegExp(r'[\\/]')).last,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: _pickImage,
                child: Text(q.imagePath.isEmpty ? 'Attach image' : 'Change',
                    style: const TextStyle(color: _kAccent)),
              ),
              if (q.imagePath.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 14),
                  color: Colors.redAccent,
                  tooltip: 'Remove image',
                  onPressed: () => n.setQuestionImage(q.id, null),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ...List.generate(_optCtrls.length, (optIdx) {
            final isCorrect = q.correctIndex == optIdx;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      isCorrect
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: isCorrect ? Colors.greenAccent : Colors.white38,
                    ),
                    tooltip: 'Mark as correct answer',
                    onPressed: () => n.updateQuestionCorrect(q.id, optIdx),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _optCtrls[optIdx],
                      onChanged: (v) => n.updateQuestionOption(q.id, optIdx, v),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(isDense: true),
                    ),
                  ),
                  if (_optCtrls.length > 2)
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 14),
                      color: Colors.white38,
                      onPressed: () => n.removeQuestionOption(q.id, optIdx),
                    ),
                ],
              ),
            );
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => n.addQuestionOption(q.id),
              icon: const Icon(Icons.add_rounded, size: 15, color: _kAccent),
              label: const Text('Add option', style: TextStyle(color: _kAccent)),
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _explCtrl,
            onChanged: (v) => n.updateQuestionExplanation(q.id, v),
            maxLines: null,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: const InputDecoration(
              labelText: 'Explanation (optional)',
              labelStyle: TextStyle(color: Colors.white38),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                height: 24,
                width: 24,
                child: Checkbox(
                  value: hasOverride,
                  activeColor: _kAccent,
                  onChanged: (checked) {
                    if (checked == true) {
                      n.updateQuestionDirectionOverride(q.id, 'rtl');
                      n.updateExplanationDirectionOverride(q.id, 'rtl');
                    } else {
                      n.updateQuestionDirectionOverride(q.id, null);
                      n.updateExplanationDirectionOverride(q.id, null);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              const Text('Override direction for this question',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
          if (hasOverride) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Question:',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                DropdownButton<String>(
                  value: q.questionDirectionOverride ?? 'rtl',
                  isDense: true,
                  dropdownColor: _kCard,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  items: const [
                    DropdownMenuItem(value: 'rtl', child: Text('RTL')),
                    DropdownMenuItem(value: 'ltr', child: Text('LTR')),
                  ],
                  onChanged: (v) {
                    if (v != null) n.updateQuestionDirectionOverride(q.id, v);
                  },
                ),
                const Text('Explanation:',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                DropdownButton<String>(
                  value: q.explanationDirectionOverride ?? 'rtl',
                  isDense: true,
                  dropdownColor: _kCard,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  items: const [
                    DropdownMenuItem(value: 'rtl', child: Text('RTL')),
                    DropdownMenuItem(value: 'ltr', child: Text('LTR')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      n.updateExplanationDirectionOverride(q.id, v);
                    }
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _JsonImportDialog extends StatefulWidget {
  const _JsonImportDialog();

  @override
  State<_JsonImportDialog> createState() => _JsonImportDialogState();
}

class _JsonImportDialogState extends State<_JsonImportDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pickJsonFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json', 'txt'],
      dialogTitle: 'Select quiz JSON file',
    );
    final path = result?.files.singleOrNull?.path;
    if (path == null) return;
    try {
      final content = await File(path).readAsString();
      setState(() => _ctrl.text = content);
    } catch (_) {
      // Leave the text box as-is; user can paste manually instead.
    }
  }

  static const _example = '''
[{"title": "My Quiz", "questions": [{"text": "Question?",
"options": ["A", "B", "C"], "correct_index": 0,
"explanation": "Why A is correct."}]}]''';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kCard,
      title: const Text('Import from JSON', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Paste the quiz JSON below, or',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                ),
                TextButton.icon(
                  onPressed: _pickJsonFile,
                  icon: const Icon(Icons.upload_file_outlined, size: 15),
                  label: const Text('Upload'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              maxLines: 10,
              style: const TextStyle(
                  color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: _example,
                hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white24)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          style: FilledButton.styleFrom(backgroundColor: _kAccent),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
