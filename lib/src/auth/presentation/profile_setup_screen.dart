import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final profileReadyProvider = FutureProvider<bool>((ref) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return false;
  final profile = await Supabase.instance.client
      .from('profiles')
      .select('handle')
      .eq('id', user.id)
      .maybeSingle();
  return (profile?['handle'] as String?)?.trim().isNotEmpty == true;
});

class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _handleController = TextEditingController();
  final _displayNameController = TextEditingController();
  bool _discoverable = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final userId = Supabase.instance.client.auth.currentUser!.id;
    final profile = await Supabase.instance.client
        .from('profiles')
        .select('display_name, handle, discoverable')
        .eq('id', userId)
        .single();
    if (!mounted) return;
    setState(() {
      _displayNameController.text = profile['display_name'] as String? ?? '';
      _handleController.text = profile['handle'] as String? ?? '';
      _discoverable = profile['discoverable'] as bool? ?? false;
    });
  }

  @override
  void dispose() {
    _handleController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final userId = Supabase.instance.client.auth.currentUser!.id;
      await Supabase.instance.client
          .from('profiles')
          .update({
            'display_name': _displayNameController.text.trim(),
            'handle': _handleController.text.trim().toLowerCase(),
            'discoverable': _discoverable,
          })
          .eq('id', userId);
      ref.invalidate(profileReadyProvider);
    } on PostgrestException catch (error) {
      setState(() {
        _error = error.code == '23505'
            ? 'That handle is already taken.'
            : error.message;
      });
    } catch (error) {
      setState(() => _error = 'Could not save your profile. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Finish your profile')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.alternate_email,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Choose how players find you',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Poker Ledger uses a unique handle for invitations. Your '
                      'email address is never searchable or shown as an account '
                      'lookup result.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _displayNameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value?.trim().isEmpty == true
                          ? 'Enter your display name'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _handleController,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Unique handle',
                        prefixText: '@',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final handle = value?.trim() ?? '';
                        if (handle.length < 3 || handle.length > 24) {
                          return 'Use 3–24 characters';
                        }
                        if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(handle)) {
                          return 'Use only letters, numbers, and underscores';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      value: _discoverable,
                      onChanged: (value) =>
                          setState(() => _discoverable = value),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Allow invitation search'),
                      subtitle: const Text(
                        'Other users can find your handle and display name. '
                        'They cannot see your email.',
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: _saving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Continue'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
