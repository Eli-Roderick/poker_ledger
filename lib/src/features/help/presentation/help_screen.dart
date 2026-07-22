import 'package:flutter/material.dart';

enum HelpPage {
  sessions,
  sessionDetail,
  players,
  playerProfile,
  groups,
  groupDetail,
  analytics,
  profile,
}

class HelpScreen extends StatelessWidget {
  final HelpPage page;

  const HelpScreen({super.key, required this.page});

  @override
  Widget build(BuildContext context) {
    final content = _getPageContent(page);

    return Scaffold(
      appBar: AppBar(title: Text(content.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            content.description,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          ...content.points.map(
            (point) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '• ',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      point,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  _HelpContent _getPageContent(HelpPage page) {
    switch (page) {
      case HelpPage.sessions:
        return const _HelpContent(
          title: 'Games',
          description:
              'Your poker games live here. Each game tracks players, buy-ins, and settlements.',
          points: [
            'Use Hosted and Joined to find every game you can access',
            'New games open in a guided Lobby, Mode, Live, and Summary flow',
            'Enter a join code or accept an invitation before you become a player',
            'Draft, live, settling, and finalized labels show the server-confirmed phase',
            'Finalized ledgers are locked; corrections create a new audit revision',
          ],
        );

      case HelpPage.sessionDetail:
        return const _HelpContent(
          title: 'Game Details',
          description:
              'Manage your poker game here. Add players, track money, and settle up at the end.',
          points: [
            'Invite accounts by handle, or share a short-lived join code',
            'Every player explicitly accepts before joining or affecting stats',
            'Choose Pairwise or Banker at the required mode checkpoint',
            'Record rebuys and cash-outs on the Live Game page',
            'The summary identifies every missing cash-out or balance mismatch',
            'Finalization creates an immutable revision and settlement transfers',
          ],
        );

      case HelpPage.players:
        return const _HelpContent(
          title: 'Players',
          description:
              'The player list is retained only for legacy games and private notes.',
          points: [
            'New games never require a host-owned player record',
            'Invite registered accounts directly from a game by handle or display name',
            'Email addresses and registration status are never searchable',
            'Historical guest names remain snapshots in their original games',
            'Private quick-add notes never change group or canonical game standings',
          ],
        );

      case HelpPage.groups:
        return const _HelpContent(
          title: 'Groups',
          description:
              'Share games with your poker crew. Everyone sees the same stats.',
          points: [
            'Tap + to create a group',
            'Invite accounts by handle; membership starts only after acceptance',
            'A new game is private or attached to exactly one group',
            'Every current accepted member can see each group game’s full ledger',
            'Leaving immediately removes group-only access but preserves games you played',
            'Groups with game history are archived instead of deleted',
          ],
        );

      case HelpPage.groupDetail:
        return const _HelpContent(
          title: 'Group Details',
          description: 'Manage your group members here.',
          points: [
            'See all members and who owns the group',
            'Owners and authorized administrators can invite by handle',
            'Invitees must accept before becoming members',
            'Removing a member does not erase their historical results',
            'Members can always leave, including after a group is archived',
          ],
        );

      case HelpPage.analytics:
        return const _HelpContent(
          title: 'Analytics',
          description:
              'See canonical results from finalized games you played or group games you can access.',
          points: [
            'Personal stats include every finalized game you accepted, regardless of host',
            'Group standings use every finalized game attached to that group',
            'Use the filter icon to narrow down by date range',
            'Historical names use the snapshot saved for that game',
            'CSV exports use the same canonical totals shown on screen',
          ],
        );

      case HelpPage.playerProfile:
        return const _HelpContent(
          title: 'Player Profile',
          description:
              'View stats that are visible through shared participation and current groups.',
          points: [
            'Summary shows games, buy-ins, cash-outs, and net profit',
            'Private-game finances are visible only to accepted participants',
            'Filter by a shared group to see that group’s standings',
            'View their recent game history',
            'Tap any game to see the full breakdown',
          ],
        );

      case HelpPage.profile:
        return const _HelpContent(
          title: 'Your Profile',
          description:
              'Manage your identity and see stats from games you accepted.',
          points: [
            'View your display name and unique invitation handle',
            'Control whether your handle is discoverable for invitations',
            'Personal stats include hosted and joined finalized games',
            'Open joined game history from Games → Joined',
            'Sign out from your account',
          ],
        );
    }
  }
}

class _HelpContent {
  final String title;
  final String description;
  final List<String> points;

  const _HelpContent({
    required this.title,
    required this.description,
    required this.points,
  });
}

extension HelpNavigation on BuildContext {
  void showHelp(HelpPage page) {
    Navigator.of(
      this,
    ).push(MaterialPageRoute(builder: (_) => HelpScreen(page: page)));
  }
}
