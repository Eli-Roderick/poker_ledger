import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/migration_service.dart';
import '../../routing/app_shell.dart';

class MigrationScreen extends ConsumerStatefulWidget {
  const MigrationScreen({super.key});

  @override
  ConsumerState<MigrationScreen> createState() => _MigrationScreenState();
}

class _MigrationScreenState extends ConsumerState<MigrationScreen> {
  Map<String, int> _localCounts = {};
  bool _isLoading = true;
  bool _isMigrating = false;
  MigrationResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLocalCounts();
  }

  Future<void> _loadLocalCounts() async {
    final counts = await MigrationService.getLocalDataCounts();
    setState(() {
      _localCounts = counts;
      _isLoading = false;
    });
  }

  Future<void> _startMigration() async {
    setState(() {
      _isMigrating = true;
      _error = null;
    });

    final result = await MigrationService.migrateToSupabase();

    setState(() {
      _isMigrating = false;
      _result = result;
      if (!result.success) {
        _error = result.error;
      }
    });
  }

  Future<void> _deleteLocalAndContinue() async {
    await MigrationService.deleteLocalDatabase();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppShell()),
        (route) => false,
      );
    }
  }

  Future<void> _skipMigration() async {
    await MigrationService.deleteLocalDatabase();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppShell()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data Migration'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_result != null && _result!.success) {
      return _buildSuccessView();
    }

    return _buildMigrationPrompt();
  }

  Widget _buildMigrationPrompt() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.cloud_upload_outlined,
          size: 80,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 24),
        Text(
          'Local Data Found',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'We found existing data on this device. Would you like to migrate it to your new account?',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Data to migrate:',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 12),
                _DataRow(label: 'Players', count: _localCounts['players'] ?? 0),
                _DataRow(label: 'Games', count: _localCounts['sessions'] ?? 0),
                _DataRow(label: 'Quick Adds', count: _localCounts['quickAdds'] ?? 0),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Text(
              _error!,
              style: TextStyle(color: Colors.red.shade700),
            ),
          ),
        ],
        const Spacer(),
        FilledButton(
          onPressed: _isMigrating ? null : _startMigration,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _isMigrating
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 12),
                      Text('Migrating...'),
                    ],
                  )
                : const Text('Migrate Data'),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _isMigrating ? null : _skipMigration,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Skip & Delete Local Data'),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Icon(
          Icons.check_circle,
          size: 100,
          color: Colors.green.shade400,
        ),
        const SizedBox(height: 24),
        Text(
          'Migration Complete!',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Successfully imported:',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 12),
                _DataRow(label: 'Players', count: _result!.playersImported),
                _DataRow(label: 'Games', count: _result!.sessionsImported),
                _DataRow(label: 'Game Players', count: _result!.sessionPlayersImported),
                _DataRow(label: 'Rebuys', count: _result!.rebuysImported),
                _DataRow(label: 'Quick Adds', count: _result!.quickAddsImported),
                const Divider(),
                _DataRow(label: 'Total Records', count: _result!.totalImported, bold: true),
              ],
            ),
          ),
        ),
        const Spacer(),
        FilledButton(
          onPressed: _deleteLocalAndContinue,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Continue to App'),
          ),
        ),
      ],
    );
  }
}

class _DataRow extends StatelessWidget {
  final String label;
  final int count;
  final bool bold;

  const _DataRow({
    required this.label,
    required this.count,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: bold
                ? Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold)
                : null,
          ),
          Text(
            count.toString(),
            style: bold
                ? Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold)
                : Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
