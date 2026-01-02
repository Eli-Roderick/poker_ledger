import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../players/domain/player.dart';
import '../data/session_detail_providers.dart';
import '../data/session_providers.dart';
import '../domain/session_models.dart';
import 'session_summary_screen.dart';

/// Multi-page game setup wizard
/// Page 1: Settlement mode selection (Banker/Pairwise)
/// Page 2: Player selection
/// Page 3: Cash outs & Settlement (existing summary screen)
class GameSetupWizard extends ConsumerStatefulWidget {
  final int sessionId;
  const GameSetupWizard({super.key, required this.sessionId});

  @override
  ConsumerState<GameSetupWizard> createState() => _GameSetupWizardState();
}

class _GameSetupWizardState extends ConsumerState<GameSetupWizard> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < 2) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(sessionDetailProvider(widget.sessionId));
    final sessionName = asyncState.valueOrNull?.session.name;
    return Scaffold(
      appBar: AppBar(
        title: Text((sessionName == null || sessionName.trim().isEmpty) 
            ? 'Game #${widget.sessionId}' 
            : sessionName),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (data) {
          final session = data.session;
          final hasSettlementMode = session.settlementMode != null;
          final hasEnoughPlayers = data.participants.length >= 2;

          // Determine which page to show based on session state
          if (!hasSettlementMode && _currentPage != 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _pageController.jumpToPage(0);
            });
          }

          return Column(
            children: [
              // Progress indicator
              _ProgressIndicator(
                currentPage: _currentPage,
                hasSettlementMode: hasSettlementMode,
                hasEnoughPlayers: hasEnoughPlayers,
              ),
              
              // Page content
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  children: [
                    _SettlementModePage(
                      sessionId: widget.sessionId,
                      currentMode: session.settlementMode,
                      onModeSelected: (mode) async {
                        await ref.read(sessionRepositoryProvider).setSettlementMode(
                          sessionId: widget.sessionId,
                          mode: mode,
                        );
                        ref.invalidate(sessionDetailProvider(widget.sessionId));
                        _nextPage();
                      },
                    ),
                    _PlayerSelectionPage(
                      sessionId: widget.sessionId,
                      participants: data.participants,
                      allPlayers: data.allPlayers,
                      isBankerMode: session.settlementMode == 'banker',
                      onContinue: _nextPage,
                      onBack: _previousPage,
                    ),
                    _CashOutsPage(
                      sessionId: widget.sessionId,
                      data: data,
                      onBack: _previousPage,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// Progress indicator showing current step
class _ProgressIndicator extends StatelessWidget {
  final int currentPage;
  final bool hasSettlementMode;
  final bool hasEnoughPlayers;

  const _ProgressIndicator({
    required this.currentPage,
    required this.hasSettlementMode,
    required this.hasEnoughPlayers,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          _StepDot(
            label: 'Mode',
            isActive: currentPage == 0,
            isCompleted: hasSettlementMode,
          ),
          Expanded(child: _StepLine(isCompleted: hasSettlementMode)),
          _StepDot(
            label: 'Players',
            isActive: currentPage == 1,
            isCompleted: hasEnoughPlayers,
          ),
          Expanded(child: _StepLine(isCompleted: hasEnoughPlayers)),
          _StepDot(
            label: 'Settle',
            isActive: currentPage == 2,
            isCompleted: false,
          ),
        ],
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isCompleted;

  const _StepDot({
    required this.label,
    required this.isActive,
    required this.isCompleted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isCompleted 
        ? Colors.green 
        : isActive 
            ? theme.colorScheme.primary 
            : Colors.grey.shade400;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isCompleted || isActive ? color : Colors.transparent,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: isCompleted
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : Text(
                    label[0],
                    style: TextStyle(
                      color: isActive ? Colors.white : color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? theme.colorScheme.primary : Colors.grey,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  final bool isCompleted;

  const _StepLine({required this.isCompleted});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 2,
      margin: const EdgeInsets.only(bottom: 20),
      color: isCompleted ? Colors.green : Colors.grey.shade300,
    );
  }
}

// Page 1: Settlement Mode Selection
class _SettlementModePage extends StatelessWidget {
  final int sessionId;
  final String? currentMode;
  final Function(String) onModeSelected;

  const _SettlementModePage({
    required this.sessionId,
    required this.currentMode,
    required this.onModeSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Icon(
            Icons.account_balance_wallet,
            size: 64,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'How will you settle up?',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Choose how players will pay each other at the end of the game',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.grey.shade600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Options
          Expanded(
            child: Column(
              children: [
                _SettlementModeCard(
                  icon: Icons.swap_horiz,
                  title: 'Pairwise',
                  description: 'Players settle directly with each other at the end. The app calculates the minimum number of transfers needed.',
                  example: 'Best for: Casual games where everyone pays at the end',
                  isSelected: currentMode == 'pairwise',
                  onTap: () => onModeSelected('pairwise'),
                  color: Colors.blue,
                ),
                const SizedBox(height: 16),
                _SettlementModeCard(
                  icon: Icons.account_balance,
                  title: 'Banker',
                  description: 'One person acts as the banker. Everyone buys chips from the banker upfront, and the banker pays out winners at the end.',
                  example: 'Best for: Games with real chips where one person handles the money',
                  isSelected: currentMode == 'banker',
                  onTap: () => onModeSelected('banker'),
                  color: Colors.green,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettlementModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String example;
  final bool isSelected;
  final VoidCallback onTap;
  final Color color;

  const _SettlementModeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.example,
    required this.isSelected,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? color : Colors.grey.shade300,
              width: isSelected ? 2 : 1,
            ),
            color: isSelected ? color.withValues(alpha: 0.1) : null,
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.2),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        example,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.grey.shade700,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: color, size: 28),
            ],
          ),
        ),
      ),
    );
  }
}

// Page 2: Player Selection
class _PlayerSelectionPage extends ConsumerStatefulWidget {
  final int sessionId;
  final List<SessionPlayer> participants;
  final List<Player> allPlayers;
  final bool isBankerMode;
  final VoidCallback onContinue;
  final VoidCallback onBack;

  const _PlayerSelectionPage({
    required this.sessionId,
    required this.participants,
    required this.allPlayers,
    required this.isBankerMode,
    required this.onContinue,
    required this.onBack,
  });

  @override
  ConsumerState<_PlayerSelectionPage> createState() => _PlayerSelectionPageState();
}

class _PlayerSelectionPageState extends ConsumerState<_PlayerSelectionPage> {
  final _buyInController = TextEditingController(text: '20.00');

  @override
  void dispose() {
    _buyInController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existingIds = widget.participants.map((e) => e.playerId).toSet();
    final availablePlayers = widget.allPlayers
        .where((p) => p.id != null && !existingIds.contains(p.id))
        .toList();
    final hasEnoughPlayers = widget.participants.length >= 2;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Row(
                  children: [
                    Icon(Icons.people, size: 32, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Who\'s playing?',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Add at least 2 players to continue',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Player count badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: hasEnoughPlayers ? Colors.green : Colors.orange,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${widget.participants.length} player${widget.participants.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Buy-in amount (only for banker mode)
                if (widget.isBankerMode) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.attach_money, color: Colors.green),
                        const SizedBox(width: 12),
                        const Text('Default buy-in:'),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: _buyInController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Current participants
                if (widget.participants.isNotEmpty) ...[
                  Text(
                    'In this game:',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.participants.map((sp) {
                      final player = widget.allPlayers.firstWhere((p) => p.id == sp.playerId);
                      return Chip(
                        avatar: CircleAvatar(
                          backgroundColor: theme.colorScheme.primary,
                          child: Text(
                            player.name[0].toUpperCase(),
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                        label: Text(player.name),
                        deleteIcon: const Icon(Icons.close, size: 18),
                        onDeleted: () async {
                          await ref.read(sessionRepositoryProvider).deleteSessionPlayer(sp.id!);
                          ref.invalidate(sessionDetailProvider(widget.sessionId));
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                ],

                // Available players to add
                Text(
                  'Add players:',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: availablePlayers.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle, size: 48, color: Colors.green.shade300),
                              const SizedBox(height: 8),
                              Text(
                                'All players added!',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: availablePlayers.length,
                          itemBuilder: (context, index) {
                            final player = availablePlayers[index];
                            return _PlayerListTile(
                              player: player,
                              isBankerMode: widget.isBankerMode,
                              defaultBuyIn: _buyInController.text,
                              onAdd: (buyInCents) async {
                                await ref.read(sessionRepositoryProvider).addPlayerToSession(
                                  sessionId: widget.sessionId,
                                  playerId: player.id!,
                                  initialBuyInCents: buyInCents,
                                  paidUpfront: widget.isBankerMode,
                                );
                                ref.invalidate(sessionDetailProvider(widget.sessionId));
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),

        // Bottom navigation
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SafeArea(
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back'),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: hasEnoughPlayers ? widget.onContinue : null,
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Continue to Cash Outs'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PlayerListTile extends StatelessWidget {
  final Player player;
  final bool isBankerMode;
  final String defaultBuyIn;
  final Function(int) onAdd;

  const _PlayerListTile({
    required this.player,
    required this.isBankerMode,
    required this.defaultBuyIn,
    required this.onAdd,
  });

  int _parseMoneyToCents(String input) {
    final cleaned = input.replaceAll(RegExp('[^0-9.,]'), '').replaceAll(',', '.');
    final value = double.tryParse(cleaned) ?? 0.0;
    return (value * 100).round();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            player.name[0].toUpperCase(),
            style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
          ),
        ),
        title: Text(player.name),
        subtitle: player.email != null ? Text(player.email!) : null,
        trailing: FilledButton.tonal(
          onPressed: () {
            final cents = isBankerMode ? _parseMoneyToCents(defaultBuyIn) : 0;
            onAdd(cents);
          },
          child: const Text('Add'),
        ),
      ),
    );
  }
}

// Page 3: Cash Outs (wrapper around existing summary screen functionality)
class _CashOutsPage extends ConsumerWidget {
  final int sessionId;
  final SessionDetailState data;
  final VoidCallback onBack;

  const _CashOutsPage({
    required this.sessionId,
    required this.data,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Navigate to the full summary screen
    return SessionSummaryScreen(sessionId: sessionId);
  }
}
