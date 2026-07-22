import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../routing/app_shell.dart';

class OnboardingChecklistScreen extends StatefulWidget {
  const OnboardingChecklistScreen({super.key});

  @override
  State<OnboardingChecklistScreen> createState() =>
      _OnboardingChecklistScreenState();
}

class _OnboardingChecklistScreenState extends State<OnboardingChecklistScreen> {
  bool _loading = true;
  bool _hasParticipated = false;
  bool _hasStarted = false;
  bool _hasFinalized = false;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('session_players')
          .select('session_id, sessions!inner(phase, finalized)')
          .eq('profile_id', user.id);
      var started = false;
      var finalized = false;
      for (final row in rows) {
        final session = row['sessions'] as Map<String, dynamic>?;
        final phase = session?['phase'] as String?;
        started =
            started ||
            phase == 'live' ||
            phase == 'settling' ||
            phase == 'finalized';
        finalized =
            finalized || phase == 'finalized' || session?['finalized'] == true;
      }
      if (mounted) {
        setState(() {
          _hasParticipated = rows.isNotEmpty;
          _hasStarted = started;
          _hasFinalized = finalized;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _continue() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      await Supabase.instance.client
          .from('profiles')
          .update({'tutorial_completed': true})
          .eq('id', user.id);
    }
    if (mounted) {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const AppShell()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Getting started'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _loading ? null : _continue,
            child: const Text('Skip'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Icon(
                  Icons.casino,
                  size: 64,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Your first poker ledger',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Poker Ledger will guide each game. These milestones update '
                  'from actions you actually complete.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_loading)
                  const LinearProgressIndicator()
                else ...[
                  const _ChecklistTile(
                    complete: true,
                    title: 'Complete your profile',
                    subtitle: 'Your handle makes account invitations possible.',
                  ),
                  _ChecklistTile(
                    complete: _hasParticipated,
                    title: 'Accept or invite a player',
                    subtitle: 'Players join only after explicit acceptance.',
                  ),
                  _ChecklistTile(
                    complete: _hasStarted,
                    title: 'Start a game',
                    subtitle: 'Choose the settlement mode at the checkpoint.',
                  ),
                  _ChecklistTile(
                    complete: _hasFinalized,
                    title: 'Finalize a balanced ledger',
                    subtitle: 'Finalization creates a locked audit revision.',
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading ? null : _continue,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Open Poker Ledger'),
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

class _ChecklistTile extends StatelessWidget {
  final bool complete;
  final String title;
  final String subtitle;

  const _ChecklistTile({
    required this.complete,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          complete ? Icons.check_circle : Icons.radio_button_unchecked,
          color: complete ? Colors.green : null,
        ),
        title: Text(title),
        subtitle: Text(subtitle),
      ),
    );
  }
}
