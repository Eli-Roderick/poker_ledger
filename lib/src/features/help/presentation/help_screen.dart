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
  
  const HelpScreen({
    super.key,
    required this.page,
  });

  @override
  Widget build(BuildContext context) {
    final content = _getPageContent(page);
    
    return Scaffold(
      appBar: AppBar(
        title: Text(content.title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            content.description,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          ...content.points.map((point) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('• ', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
                Expanded(
                  child: Text(point, style: Theme.of(context).textTheme.bodyMedium),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }

  _HelpContent _getPageContent(HelpPage page) {
    switch (page) {
      case HelpPage.sessions:
        return const _HelpContent(
          title: 'Sessions',
          description: 'Your poker games live here. Each session tracks players, buy-ins, and settlements.',
          points: [
            'Tap + to start a new game',
            'Tap any session to manage it',
            'Use filters to find specific games',
            'Swipe left to delete (only your own sessions)',
            'Green check = finalized, play icon = in progress',
          ],
        );
      
      case HelpPage.sessionDetail:
        return const _HelpContent(
          title: 'Session Details',
          description: 'Manage your poker game here. Add players, track money, and settle up at the end.',
          points: [
            'Add players and set their buy-ins',
            'Use the + button for rebuys during the game',
            'Enter cash-outs when the game ends',
            'Pick Pairwise (everyone settles directly) or Banker (one person handles it all)',
            'Hit Finalize when done to lock everything',
            'Share or export the summary',
          ],
        );
      
      case HelpPage.players:
        return const _HelpContent(
          title: 'Players',
          description: 'Your poker buddies. Link them to accounts so their stats sync across sessions.',
          points: [
            'Tap + to add a new player',
            'Search by email to link to an existing account',
            'Linked players show a link icon and can be tapped to view their profile',
            'Guest players (not linked) can be edited by tapping them',
            'Use the eye icon to show/hide inactive players',
          ],
        );
      
      case HelpPage.groups:
        return const _HelpContent(
          title: 'Groups',
          description: 'Share sessions with your poker crew. Everyone sees the same stats.',
          points: [
            'Tap + to create a group',
            'Invite friends by searching their email',
            'Share sessions from the session detail screen',
            'Group analytics show combined stats from all shared sessions',
            'Only owners can invite or remove members',
          ],
        );
      
      case HelpPage.groupDetail:
        return const _HelpContent(
          title: 'Group Details',
          description: 'Manage your group members here.',
          points: [
            'See all members and who owns the group',
            'Owners can invite new members by email',
            'Owners can remove members from the group',
            'Non-owners can leave the group',
          ],
        );
      
      case HelpPage.analytics:
        return const _HelpContent(
          title: 'Analytics',
          description: 'See how you and your friends are doing. Filter by date or group.',
          points: [
            'Top cards show total sessions, players, and net profit/loss',
            'Tap the title to switch between your sessions and group sessions',
            'Use the filter icon to narrow down by date range',
            'Tap any player to see their detailed stats and history',
            'Export to CSV if you want the raw data',
          ],
        );
      
      case HelpPage.playerProfile:
        return const _HelpContent(
          title: 'Player Profile',
          description: 'View stats for a linked player. Follow them to see their private stats.',
          points: [
            'Summary shows sessions, buy-ins, cash-outs, and net profit',
            'Follow users to see stats from their private sessions',
            'Filter by mutual groups to see shared session stats',
            'View their recent session history',
            'Tap any session to see the full breakdown',
          ],
        );
      
      case HelpPage.profile:
        return const _HelpContent(
          title: 'Your Profile',
          description: 'Manage your account and see sessions you\'re linked to.',
          points: [
            'View your account info and display name',
            'Accept or reject follow requests from other users',
            'See sessions where you\'re a linked player',
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
    Navigator.of(this).push(
      MaterialPageRoute(
        builder: (_) => HelpScreen(page: page),
      ),
    );
  }
}
