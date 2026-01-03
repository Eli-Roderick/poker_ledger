import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../groups/data/group_providers.dart';
import '../../players/domain/player.dart';
import '../data/session_detail_providers.dart';
import '../data/session_providers.dart';
import '../domain/session_models.dart';
import 'session_summary_screen.dart';

/// Multi-page game setup wizard - simplified
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

  void _goToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(sessionDetailProvider(widget.sessionId));
    final sessionName = asyncState.valueOrNull?.session.name;
    
    final isFinalized = asyncState.valueOrNull?.session.finalized ?? false;
    
    return Scaffold(
      appBar: AppBar(
        title: Text((sessionName == null || sessionName.trim().isEmpty) 
            ? 'Game #${widget.sessionId}' 
            : sessionName),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: isFinalized ? [
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: 'Share to groups',
            onPressed: () => _showShareToGroupsDialog(context, ref, widget.sessionId),
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share summary',
            onPressed: () async {
              final detail = await ref.read(sessionDetailProvider(widget.sessionId).future);
              final summary = _buildShareSummaryText(detail);
              await SharePlus.instance.share(ShareParams(text: summary, subject: 'Poker Game Summary'));
            },
          ),
        ] : null,
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (data) {
          final session = data.session;
          final hasSettlementMode = session.settlementMode != null;
          final hasEnoughPlayers = data.participants.length >= 2;

          return Column(
            children: [
              // Simple progress bar - more obviously clickable
              _SimpleProgressBar(
                currentPage: _currentPage,
                onTap: (page) {
                  if (page < _currentPage || (page == 1 && hasEnoughPlayers) || (page == 2 && hasSettlementMode && hasEnoughPlayers)) {
                    _goToPage(page);
                  }
                },
              ),
              
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  children: [
                    // Page 0: Players (now first)
                    _PlayersPage(
                      sessionId: widget.sessionId,
                      participants: data.participants,
                      allPlayers: data.allPlayers,
                      onContinue: () => _goToPage(1),
                    ),
                    // Page 1: Settlement Mode (now second)
                    _SettlementModePage(
                      sessionId: widget.sessionId,
                      currentMode: session.settlementMode,
                      participants: data.participants,
                      allPlayers: data.allPlayers,
                      onBack: () => _goToPage(0),
                      onContinue: () => _goToPage(2),
                    ),
                    // Page 2: Summary
                    _SummaryPageWrapper(
                      sessionId: widget.sessionId,
                      onBack: () => _goToPage(1),
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

// Simple compact progress bar - more obviously clickable
class _SimpleProgressBar extends StatelessWidget {
  final int currentPage;
  final Function(int) onTap;

  const _SimpleProgressBar({required this.currentPage, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _StepChip(label: 'Players', isActive: currentPage == 0, onTap: () => onTap(0)),
          const Expanded(child: Divider()),
          _StepChip(label: 'Mode', isActive: currentPage == 1, onTap: () => onTap(1)),
          const Expanded(child: Divider()),
          _StepChip(label: 'Summary', isActive: currentPage == 2, onTap: () => onTap(2)),
        ],
      ),
    );
  }
}

class _StepChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _StepChip({required this.label, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = isActive ? Theme.of(context).colorScheme.primary : Colors.grey;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: color,
            decoration: TextDecoration.underline,
            decorationColor: color.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

// Page 0: Players (now first) - with Add Player button, list with buy-ins, rebuy, delete
class _PlayersPage extends ConsumerWidget {
  final int sessionId;
  final List<SessionPlayer> participants;
  final List<Player> allPlayers;
  final VoidCallback onContinue;

  const _PlayersPage({
    required this.sessionId,
    required this.participants,
    required this.allPlayers,
    required this.onContinue,
  });

  String _fmtCents(int cents) {
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    return fmt.format(cents / 100);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasEnoughPlayers = participants.length >= 2;
    final existingIds = participants.map((e) => e.playerId).toSet();
    final availablePlayers = allPlayers.where((p) => p.id != null && !existingIds.contains(p.id)).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title
          const Text('Add players', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 16),
          
          // Add Player button
          OutlinedButton.icon(
            onPressed: availablePlayers.isEmpty ? null : () => _showAddPlayerDialog(context, ref, availablePlayers),
            icon: const Icon(Icons.person_add),
            label: Text(availablePlayers.isEmpty ? 'All players added' : 'Add Player'),
          ),
          const SizedBox(height: 16),
          
          // Player list
          Expanded(
            child: participants.isEmpty
                ? Center(child: Text('No players yet', style: TextStyle(color: Colors.grey.shade600)))
                : ListView.separated(
                    itemCount: participants.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final sp = participants[index];
                      final player = allPlayers.firstWhere((p) => p.id == sp.playerId);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(player.name),
                        subtitle: Text('Buy-Ins Total: ${_fmtCents(sp.buyInCentsTotal)}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline, size: 20),
                              tooltip: 'Rebuy',
                              onPressed: () => _showRebuyDialog(context, ref, sp, player.name),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              tooltip: 'Remove',
                              onPressed: () async {
                                await ref.read(sessionDetailProvider(sessionId).notifier).deletePlayer(
                                  sessionPlayerId: sp.id!,
                                );
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          
          // Bottom navigation
          FilledButton(
            onPressed: hasEnoughPlayers ? onContinue : null,
            child: Text(hasEnoughPlayers ? 'Next' : 'Add ${2 - participants.length} more player${participants.length == 1 ? '' : 's'}'),
          ),
        ],
      ),
    );
  }

  void _showAddPlayerDialog(BuildContext context, WidgetRef ref, List<Player> availablePlayers) {
    final buyInController = TextEditingController(text: '20.00');
    Player? selectedPlayer;
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Player'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<Player>(
                decoration: const InputDecoration(labelText: 'Player'),
                items: availablePlayers.map((p) => DropdownMenuItem(value: p, child: Text(p.name))).toList(),
                onChanged: (p) => setDialogState(() => selectedPlayer = p),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: buyInController,
                decoration: const InputDecoration(labelText: 'Buy-in amount'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 16),
              // Preset buy-in buttons - 3 buttons, evenly spaced
              Row(
                children: [20, 50, 100].map((amount) => 
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: TextButton(
                        onPressed: () => setDialogState(() => buyInController.text = '$amount.00'),
                        child: Text('\$$amount', maxLines: 1),
                      ),
                    ),
                  ),
                ).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: selectedPlayer == null ? null : () async {
                final cents = _parseMoneyToCents(buyInController.text);
                if (ctx.mounted) Navigator.pop(ctx);
                await ref.read(sessionDetailProvider(sessionId).notifier).addPlayer(
                  playerId: selectedPlayer!.id!,
                  initialBuyInCents: cents,
                );
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _showRebuyDialog(BuildContext context, WidgetRef ref, SessionPlayer sp, String playerName) {
    final controller = TextEditingController(text: '20.00');
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rebuy for $playerName'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Amount'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final cents = _parseMoneyToCents(controller.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (cents > 0) {
                await ref.read(sessionDetailProvider(sessionId).notifier).addRebuy(
                  sessionPlayerId: sp.id!,
                  amountCents: cents,
                );
              }
            },
            child: const Text('Add Rebuy'),
          ),
        ],
      ),
    );
  }

  int _parseMoneyToCents(String input) {
    final cleaned = input.replaceAll(RegExp('[^0-9.,]'), '').replaceAll(',', '.');
    final value = double.tryParse(cleaned) ?? 0.0;
    return (value * 100).round();
  }
}

// Page 1: Settlement Mode (now second) - with banker dropdown
class _SettlementModePage extends ConsumerStatefulWidget {
  final int sessionId;
  final String? currentMode;
  final List<SessionPlayer> participants;
  final List<Player> allPlayers;
  final VoidCallback onBack;
  final VoidCallback onContinue;

  const _SettlementModePage({
    required this.sessionId,
    required this.currentMode,
    required this.participants,
    required this.allPlayers,
    required this.onBack,
    required this.onContinue,
  });

  @override
  ConsumerState<_SettlementModePage> createState() => _SettlementModePageState();
}

class _SettlementModePageState extends ConsumerState<_SettlementModePage> {
  String? _selectedMode;
  int? _selectedBankerSpId; // session_player id

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.currentMode;
  }

  @override
  void didUpdateWidget(_SettlementModePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selectedMode = widget.currentMode;
  }

  @override
  Widget build(BuildContext context) {
    final canContinue = _selectedMode == 'pairwise' || 
        (_selectedMode == 'banker' && _selectedBankerSpId != null);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Select settlement mode', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 16),
          
          // Pairwise option
          _ModeOption(
            title: 'Pairwise',
            description: 'Players settle directly with each other',
            isSelected: _selectedMode == 'pairwise',
            onTap: () => setState(() {
              _selectedMode = 'pairwise';
              _selectedBankerSpId = null;
            }),
          ),
          const SizedBox(height: 12),
          
          // Banker option
          _ModeOption(
            title: 'Banker',
            description: 'One player collects and pays out all money',
            isSelected: _selectedMode == 'banker',
            onTap: () => setState(() => _selectedMode = 'banker'),
          ),
          
          // Banker dropdown (only show when banker mode selected)
          if (_selectedMode == 'banker') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              decoration: const InputDecoration(
                labelText: 'Select banker',
                border: OutlineInputBorder(),
              ),
              initialValue: _selectedBankerSpId,
              items: widget.participants.map((sp) {
                final player = widget.allPlayers.firstWhere((p) => p.id == sp.playerId);
                return DropdownMenuItem(value: sp.id, child: Text(player.name));
              }).toList(),
              onChanged: (id) => setState(() => _selectedBankerSpId = id),
            ),
          ],
          
          const Spacer(),
          
          // Bottom navigation
          Row(
            children: [
              OutlinedButton(onPressed: widget.onBack, child: const Text('Back')),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton(
                  onPressed: canContinue ? () async {
                    // Save mode with optimistic update
                    await ref.read(sessionDetailProvider(widget.sessionId).notifier).setSettlementMode(
                      mode: _selectedMode!,
                    );
                    // Set banker if banker mode
                    if (_selectedMode == 'banker' && _selectedBankerSpId != null) {
                      await ref.read(sessionDetailProvider(widget.sessionId).notifier).setBanker(
                        bankerSessionPlayerId: _selectedBankerSpId,
                      );
                    }
                    widget.onContinue();
                  } : null,
                  child: const Text('Next'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  final String title;
  final String description;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeOption({
    required this.title,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(description, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

// Page 2: Summary wrapper with title and Back + Next buttons (like mode page)
class _SummaryPageWrapper extends ConsumerWidget {
  final int sessionId;
  final VoidCallback onBack;

  const _SummaryPageWrapper({required this.sessionId, required this.onBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(sessionDetailProvider(sessionId));
    
    return asyncState.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => Center(child: Text('Error: $e')),
      data: (data) {
        final participants = data.participants;
        final cashedOutCount = participants.where((p) => p.cashOutCents != null).length;
        final allCashedOut = participants.isNotEmpty && cashedOutCount == participants.length;
        final missingCashOuts = participants.length - cashedOutCount;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SessionSummaryScreen(sessionId: sessionId, showAppBar: false),
            ),
            // Bottom navigation - same layout as mode page
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  OutlinedButton(onPressed: onBack, child: const Text('Back')),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton(
                      onPressed: allCashedOut ? () => _showFinalizeDialog(context, ref, data) : null,
                      child: Text(allCashedOut 
                          ? 'Finalize Game' 
                          : 'Enter $missingCashOuts more cash out${missingCashOuts == 1 ? '' : 's'}'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showFinalizeDialog(BuildContext context, WidgetRef ref, SessionDetailState data) async {
    final result = await showDialog<_FinalizeResult?>(
      context: context,
      builder: (ctx) => _WizardFinalizeDialog(data: data),
    );
    
    if (result == null) return;
    
    // Finalize the game
    await ref.read(sessionRepositoryProvider).finalizeSession(sessionId);
    ref.invalidate(sessionDetailProvider(sessionId));
    
    // Share to groups if requested
    if (result.shareToGroups && result.selectedGroupIds.isNotEmpty) {
      await ref.read(groupRepositoryProvider).updateSessionGroups(
        sessionId,
        result.selectedGroupIds.toList(),
      );
    }
    
    // Share settlement summary if requested
    if (result.shareSummary && context.mounted) {
      final summary = _buildShareText(data);
      await SharePlus.instance.share(ShareParams(text: summary, subject: 'Poker Game Summary'));
    }
    
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Game finalized')),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }
  
  String _buildShareText(SessionDetailState detail) {
    final buf = StringBuffer();
    final fmt = NumberFormat.simpleCurrency();
    buf.writeln('Poker Game Summary');
    final isBanker = detail.session.settlementMode == 'banker' && detail.session.bankerSessionPlayerId != null;
    String bankerName = '';
    if (isBanker) {
      final bankerSp = detail.participants.firstWhere((sp) => sp.id == detail.session.bankerSessionPlayerId);
      bankerName = detail.allPlayers.firstWhere((p) => p.id == bankerSp.playerId).name;
    }
    buf.writeln('Mode: ${detail.session.settlementMode}${isBanker ? ' (Banker: $bankerName)' : ''}');
    buf.writeln('');
    buf.writeln('Players:');
    for (final p in detail.participants) {
      final name = detail.allPlayers.firstWhere((e) => e.id == p.playerId).name;
      final buy = fmt.format(p.buyInCentsTotal / 100);
      final cash = fmt.format((p.cashOutCents ?? 0) / 100);
      buf.writeln('- $name: buy-ins $buy, cash-out $cash');
    }
    return buf.toString();
  }
}

class _FinalizeResult {
  final bool shareToGroups;
  final Set<int> selectedGroupIds;
  final bool shareSummary;
  const _FinalizeResult({
    required this.shareToGroups,
    required this.selectedGroupIds,
    required this.shareSummary,
  });
}

class _WizardFinalizeDialog extends ConsumerStatefulWidget {
  final SessionDetailState data;
  const _WizardFinalizeDialog({required this.data});

  @override
  ConsumerState<_WizardFinalizeDialog> createState() => _WizardFinalizeDialogState();
}

class _WizardFinalizeDialogState extends ConsumerState<_WizardFinalizeDialog> {
  bool _shareToGroups = false;
  bool _shareSummary = false;
  final Set<int> _selectedGroupIds = {};

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(myGroupsProvider);

    return AlertDialog(
      title: const Text('Finalize Game'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This will lock the game and mark it complete.'),
            const SizedBox(height: 16),
            
            // Share summary option
            SwitchListTile(
              title: const Text('Share settlement'),
              subtitle: const Text('Share as text message'),
              value: _shareSummary,
              onChanged: (v) => setState(() => _shareSummary = v),
              contentPadding: EdgeInsets.zero,
            ),
            
            const Divider(),
            
            // Share to groups option
            SwitchListTile(
              title: const Text('Share to groups'),
              subtitle: const Text('Let group members see this game'),
              value: _shareToGroups,
              onChanged: (v) => setState(() => _shareToGroups = v),
              contentPadding: EdgeInsets.zero,
            ),
            
            if (_shareToGroups) ...[
              const SizedBox(height: 8),
              groupsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Error loading groups: $e'),
                data: (groups) {
                  if (groups.isEmpty) {
                    return const Text('No groups available');
                  }
                  return Column(
                    children: groups.map((g) => CheckboxListTile(
                      title: Text(g.name),
                      value: _selectedGroupIds.contains(g.id),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selectedGroupIds.add(g.id);
                        } else {
                          _selectedGroupIds.remove(g.id);
                        }
                      }),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    )).toList(),
                  );
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _FinalizeResult(
            shareToGroups: _shareToGroups,
            selectedGroupIds: _selectedGroupIds,
            shareSummary: _shareSummary,
          )),
          child: const Text('Finalize'),
        ),
      ],
    );
  }
}

// Helper function to show share to groups dialog
Future<void> _showShareToGroupsDialog(BuildContext context, WidgetRef ref, int sessionId) async {
  final groups = await ref.read(myGroupsProvider.future);
  final currentGroupIds = await ref.read(groupRepositoryProvider).getSessionGroupIds(sessionId);
  
  if (groups.isEmpty) {
    if (context.mounted) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('No Groups'),
          content: const Text('Create a group first to share sessions with friends.'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    return;
  }

  final selectedGroupIds = Set<int>.from(currentGroupIds);

  if (!context.mounted) return;
  
  await showDialog(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Share to Groups'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select which groups can see this session:',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 8),
              ...groups.map((group) => CheckboxListTile(
                title: Text(group.name),
                subtitle: Text('${group.memberCount} member${group.memberCount == 1 ? '' : 's'}'),
                value: selectedGroupIds.contains(group.id),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      selectedGroupIds.add(group.id);
                    } else {
                      selectedGroupIds.remove(group.id);
                    }
                  });
                },
              )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await ref.read(groupRepositoryProvider).updateSessionGroups(
                sessionId,
                selectedGroupIds.toList(),
              );
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      selectedGroupIds.isEmpty
                          ? 'Game is now private'
                          : 'Game shared to ${selectedGroupIds.length} group${selectedGroupIds.length == 1 ? '' : 's'}',
                    ),
                  ),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

// Helper function to build share summary text
String _buildShareSummaryText(SessionDetailState detail) {
  final buf = StringBuffer();
  final fmt = NumberFormat.simpleCurrency();
  buf.writeln('Poker Game Summary');
  final isBanker = detail.session.settlementMode == 'banker' && detail.session.bankerSessionPlayerId != null;
  String bankerName = '';
  if (isBanker) {
    final bankerSp = detail.participants.firstWhere((sp) => sp.id == detail.session.bankerSessionPlayerId);
    bankerName = detail.allPlayers.firstWhere((p) => p.id == bankerSp.playerId).name;
  }
  buf.writeln('Mode: ${detail.session.settlementMode}${isBanker ? ' (Banker: $bankerName)' : ''}');
  buf.writeln('');
  buf.writeln('Players:');
  for (final p in detail.participants) {
    final name = detail.allPlayers.firstWhere((e) => e.id == p.playerId).name;
    final buy = fmt.format(p.buyInCentsTotal / 100);
    final cash = fmt.format((p.cashOutCents ?? 0) / 100);
    buf.writeln('- $name: buy-ins $buy, cash-out $cash');
  }
  return buf.toString();
}
