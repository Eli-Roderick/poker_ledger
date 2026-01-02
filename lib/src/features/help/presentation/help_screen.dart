import 'package:flutter/material.dart';

enum HelpPage {
  sessions,
  sessionDetail,
  players,
  groups,
  groupDetail,
  analytics,
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
        title: Text('${content.title} Help'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSection(
            context,
            'Overview',
            content.overview,
            Icons.info_outline,
          ),
          const SizedBox(height: 24),
          _buildSection(
            context,
            'How to Use',
            content.howToUse,
            Icons.play_circle_outline,
          ),
          const SizedBox(height: 24),
          _buildSection(
            context,
            'Tips',
            content.tips,
            Icons.lightbulb_outline,
          ),
          if (content.faq.isNotEmpty) ...[
            const SizedBox(height: 24),
            _buildSection(
              context,
              'Frequently Asked Questions',
              content.faq,
              Icons.question_answer_outlined,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, List<String> items, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...items.map((item) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 6),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        )),
      ],
    );
  }

  _HelpContent _getPageContent(HelpPage page) {
    switch (page) {
      case HelpPage.sessions:
        return _HelpContent(
          title: 'Sessions',
          overview: [
            'The Sessions screen displays all your poker games in a list.',
            'Each session shows the date, time, number of players, and whether it\'s been finalized.',
            'You can filter sessions by date range and status (all, in progress, or finalized).',
          ],
          howToUse: [
            'Tap the "+" button to create a new session',
            'Tap on any session to view its details and manage players',
            'Pull down to refresh the list',
            'Tap the filter button to show only sessions within a specific date range or status',
            'Long-press on a session to rename it (only if you\'re the owner)',
            'Swipe left on a session you own to delete it',
          ],
          tips: [
            'Sessions with a green checkmark have been finalized and settled',
            'Sessions with a play icon are still in progress',
            'You can only delete sessions that haven\'t been finalized',
            'The owner badge shows who created the session',
          ],
          faq: [
            'Q: What\'s the difference between "in progress" and "finalized"?\nA: In progress sessions can still be edited. Finalized sessions are locked and show the final settlement.',
            'Q: Can I edit a session after finalizing it?\nA: No, finalizing locks the session. You must unfinalize it first if needed.',
            'Q: Why can\'t I see some sessions?\nA: Check your filters. You might be filtering by date or status.',
          ],
        );
      
      case HelpPage.sessionDetail:
        return _HelpContent(
          title: 'Session Details',
          overview: [
            'The Session Details screen is where you manage everything for a specific poker game.',
            'Here you can add players, track buy-ins, record cash-outs, and calculate settlements.',
            'The settlement system automatically calculates who owes whom based on the final results.',
          ],
          howToUse: [
            'Tap "Add player" to add participants to the session',
            'For each player, set their initial buy-in amount and whether they paid upfront',
            'Add rebuys during the game by tapping the "+" button next to a player',
            'Enter final cash-out amounts when the game ends',
            'Choose settlement mode: Pairwise (default) or Banker',
            'Tap "Finalize session" when everything is complete to lock the results',
            'Share the session summary with players or export it as CSV',
          ],
          tips: [
            'Pairwise settlement: Each player settles directly with others using minimal transfers',
            'Banker settlement: One person (the banker) handles all transactions',
            'Cash-out amounts automatically calculate profit/loss for each player',
            'You can see live settlement updates as you enter cash-out amounts',
            'Unfinalized sessions can be edited; finalized ones are locked',
          ],
          faq: [
            'Q: What\'s the difference between buy-in and cash-out?\nA: Buy-in is what players put in to play. Cash-out is what they take out at the end. The difference is their profit/loss.',
            'Q: Can I change the settlement mode after finalizing?\nA: Yes, but you need to unfinalize the session first.',
            'Q: What are rebuys?\nA: Additional money a player adds during the game. They\'re added to their total buy-in.',
          ],
        );
      
      case HelpPage.players:
        return _HelpContent(
          title: 'Players',
          overview: [
            'The Players screen manages your roster of poker players.',
            'Players are people you frequently play with and can quickly add to sessions.',
            'You can link players to user accounts or keep them as guest entries.',
          ],
          howToUse: [
            'Tap "+" to add a new player to your roster',
            'Search for existing users by email or display name to link them',
            'Linked players sync with their user account data',
            'Search the list using the search bar at the top',
            'Tap the filter button to show deactivated accounts',
            'Tap on a player to see their details',
          ],
          tips: [
            'Linked players have a filled circle avatar and show their account name',
            'Guest players have an outlined avatar and show "Legacy guest" if they existed before linking was required',
            'You cannot add the same user account as a player twice',
            'Linking players ensures their data stays consistent across sessions',
          ],
          faq: [
            'Q: What\'s the difference between linked and guest players?\nA: Linked players are connected to user accounts. Guest players are standalone entries.',
            'Q: Can I convert a guest player to a linked one?\nA: Yes, tap the link button on legacy guest players to connect them to a user account.',
            'Q: Why can\'t I create new guest players?\nA: To maintain data consistency, all new players must be linked to existing user accounts.',
          ],
        );
      
      case HelpPage.groups:
        return _HelpContent(
          title: 'Groups',
          overview: [
            'Groups let you organize and share poker sessions with friends.',
            'Create groups for your regular poker circles, then share sessions to see combined analytics.',
            'Group members can view all shared sessions and contribute to the group statistics.',
          ],
          howToUse: [
            'Tap "+" to create a new group',
            'Tap on a group to view its details and members',
            'Invite members by searching for their user accounts',
            'Share sessions to groups from the session detail screen',
            'View group analytics to see combined statistics',
            'Transfer ownership or remove members from the group detail screen',
          ],
          tips: [
            'Only group owners can invite new members',
            'You can share sessions with multiple groups',
            'Group analytics combine data from all shared sessions',
            'Members can view but not edit shared sessions',
            'The owner badge shows who manages the group',
          ],
          faq: [
            'Q: Who can see shared sessions?\nA: All group members can view shared sessions and see them in analytics.',
            'Q: Can I unshare a session?\nA: Yes, go to the session detail screen and remove it from the group.',
            'Q: What happens if I leave a group?\nA: You\'ll lose access to that group\'s shared sessions and analytics.',
          ],
        );
      
      case HelpPage.groupDetail:
        return _HelpContent(
          title: 'Group Details',
          overview: [
            'The Group Details screen shows information about a specific group.',
            'Manage members, view shared sessions, and handle group administration here.',
          ],
          howToUse: [
            'View all group members and their roles',
            'Invite new members by tapping the invite button',
            'Transfer ownership to another member',
            'Remove members from the group',
            'Leave the group if you\'re a member',
            'Delete the entire group if you\'re the owner',
          ],
          tips: [
            'Only owners can invite new members and transfer ownership',
            'Groups must have at least one owner',
            'Removing a member doesn\'t delete their shared sessions',
            'You can\'t leave a group if you\'re the only owner',
          ],
          faq: [
            'Q: What\'s the difference between owner and member?\nA: Owners can manage the group (invite, remove, transfer). Members can only view and participate.',
            'Q: Can a group have multiple owners?\nA: Yes, you can transfer ownership to make others owners too.',
            'Q: If I delete a group, what happens to the sessions?\nA: The sessions remain but are no longer shared with that group.',
          ],
        );
      
      case HelpPage.analytics:
        return _HelpContent(
          title: 'Analytics',
          overview: [
            'The Analytics screen provides insights into your poker performance and statistics.',
            'View profit/loss trends, player performance, session history, and more.',
            'Filter by date range, group, and specific players to focus on what matters.',
          ],
          howToUse: [
            'View KPIs at the top: total sessions, unique players, and net profit/loss',
            'See top performers in the Top Players section',
            'Tap "View all" to see complete player rankings',
            'Browse session history with results for each game',
            'Tap the filter button to adjust date range, group, or player filters',
            'Export analytics as CSV for external analysis',
          ],
          tips: [
            'Green numbers indicate profit, red indicates loss',
            'Sort players by different metrics: profit, sessions, average, etc.',
            'Group analytics combine data from all shared sessions',
            'Use filters to focus on specific time periods or player groups',
            'Tap any session in the list to see its detailed summary',
          ],
          faq: [
            'Q: Why are some sessions missing from analytics?\nA: Only finalized sessions appear in analytics. In-progress sessions aren\'t included.',
            'Q: What\'s the difference between personal and group analytics?\nA: Personal shows only your sessions. Group analytics include all sessions shared with that group.',
            'Q: How is net profit calculated?\nA: Net profit = Total cash-outs - Total buy-ins across all sessions.',
          ],
        );
    }
  }
}

class _HelpContent {
  final String title;
  final List<String> overview;
  final List<String> howToUse;
  final List<String> tips;
  final List<String> faq;

  const _HelpContent({
    required this.title,
    required this.overview,
    required this.howToUse,
    required this.tips,
    required this.faq,
  });
}

// Extension to easily navigate to help from any screen
extension HelpNavigation on BuildContext {
  void showHelp(HelpPage page) {
    Navigator.of(this).push(
      MaterialPageRoute(
        builder: (_) => HelpScreen(page: page),
      ),
    );
  }
}
