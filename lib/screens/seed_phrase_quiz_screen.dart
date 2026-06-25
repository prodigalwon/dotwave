import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';

/// Post-backup confirmation quiz. After the user taps "I wrote it down"
/// on the seed-phrase screen, they land here and must prove they
/// actually recorded the phrase by identifying 5 words at random
/// positions. Standard UX pattern for modern wallets (MetaMask, Trust,
/// Ledger Live) — prevents the "I'll just skip this and deal with it
/// later" failure mode that locks users out of recovery.
///
/// Design choices:
///
/// - **5 questions** (not 3). Higher friction, lower chance of lucky
///   guessing or half-attention "write it down later" users slipping
///   through.
/// - **Wizard, one-question-per-screen.** Five questions × four
///   options each = 20 controls; cramming them onto one screen feels
///   overwhelming. One at a time reads cleanly, progresses visibly,
///   and lets us show the position prominently.
/// - **Decoys from within the same phrase.** The user has seen all
///   12 words, so decoys drawn from other positions test whether they
///   memorized *which word goes where* rather than just whether they
///   recognize the word at all. Harder than BIP39-wordlist decoys,
///   no extra asset dependency.
/// - **Fail → retry with fresh positions.** Same screen, new random
///   positions + new decoys, selections cleared. A secondary "show my
///   phrase again" link pops back to the phrase view so the user can
///   re-read without losing progress elsewhere.
class SeedPhraseQuizScreen extends StatefulWidget {
  /// Space-separated mnemonic (e.g. from `crateCoreGenerateAccount`).
  final String phrase;

  /// Address for the account being confirmed. Purely passed through
  /// to `onPass` for the caller's navigation — the quiz doesn't use
  /// it directly.
  final String address;

  /// Called when all 5 answers are correct. Caller navigates to the
  /// next step (SetPassphraseScreen) from here.
  final VoidCallback onPass;

  const SeedPhraseQuizScreen({
    super.key,
    required this.phrase,
    required this.address,
    required this.onPass,
  });

  @override
  State<SeedPhraseQuizScreen> createState() => _SeedPhraseQuizScreenState();
}

class _SeedPhraseQuizScreenState extends State<SeedPhraseQuizScreen> {
  static const int _numQuestions = 5;

  late List<String> _words;
  late List<_Question> _questions;
  int _currentIdx = 0;

  @override
  void initState() {
    super.initState();
    _words = widget.phrase.split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    _buildQuestions();
  }

  /// Pick `_numQuestions` distinct positions at random; for each,
  /// build a 4-option set consisting of the correct word plus 3
  /// decoys drawn from the other 11 words (deduped — BIP39 phrases
  /// can technically repeat words, though it's rare).
  void _buildQuestions() {
    final rng = math.Random.secure();
    final positions = <int>[];
    final available = List<int>.generate(_words.length, (i) => i)..shuffle(rng);
    positions.addAll(available.take(_numQuestions));
    positions.sort();

    _questions = positions.map((pos) {
      final correct = _words[pos];
      final pool = _words.toSet().where((w) => w != correct).toList()
        ..shuffle(rng);
      final decoys = pool.take(3).toList();
      final options = [correct, ...decoys]..shuffle(rng);
      return _Question(position: pos, correct: correct, options: options);
    }).toList();
    _currentIdx = 0;
  }

  void _selectAnswer(String word) {
    setState(() {
      _questions[_currentIdx].selected = word;
    });
    // Advance on a small delay so the user sees their selection
    // register before the next screen slides in.
    Future.delayed(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      if (_currentIdx < _numQuestions - 1) {
        setState(() => _currentIdx++);
      } else {
        _verify();
      }
    });
  }

  void _verify() {
    final wrongCount =
        _questions.where((q) => q.selected != q.correct).length;
    if (wrongCount == 0) {
      widget.onPass();
      return;
    }
    _showFailDialog(wrongCount);
  }

  Future<void> _showFailDialog(int wrongCount) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface2,
        title: Text(
          wrongCount == _numQuestions
              ? "That's not the phrase"
              : '$wrongCount incorrect',
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          'The words you picked don\'t match your seed phrase. '
          'Go back and double-check what you wrote down, then try '
          'again with new questions.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context); // pop quiz → back to phrase view
            },
            child: const Text(
              'Show my phrase',
              style: TextStyle(color: AppTheme.textTertiary),
            ),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(_buildQuestions);
            },
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _questions[_currentIdx];
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Confirm Your Phrase'),
        backgroundColor: AppTheme.bg,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ProgressStrip(
                current: _currentIdx + 1,
                total: _numQuestions,
              ),
              const SizedBox(height: 36),
              Text(
                'Tap the word at position',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '#${q.position + 1}',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 56,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 40),
              for (final opt in q.options) ...[
                _ChoiceTile(
                  word: opt,
                  selected: q.selected == opt,
                  onTap: q.selected == null ? () => _selectAnswer(opt) : null,
                ),
                const SizedBox(height: 12),
              ],
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Show my phrase again',
                  style: TextStyle(color: AppTheme.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Question {
  final int position;
  final String correct;
  final List<String> options;
  String? selected;

  _Question({
    required this.position,
    required this.correct,
    required this.options,
  });
}

class _ProgressStrip extends StatelessWidget {
  final int current;
  final int total;
  const _ProgressStrip({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 1; i <= total; i++) ...[
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: i <= current ? AppTheme.accent : AppTheme.borderSubtle,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (i < total) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  final String word;
  final bool selected;
  final VoidCallback? onTap;

  const _ChoiceTile({
    required this.word,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.accent.withOpacity(0.15) : AppTheme.surface2,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppTheme.accent : AppTheme.borderSubtle,
              width: 1.5,
            ),
          ),
          child: Center(
            child: Text(
              word,
              style: TextStyle(
                color: selected ? AppTheme.accent : AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
