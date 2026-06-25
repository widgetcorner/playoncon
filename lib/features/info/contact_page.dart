import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Mirrors playoncon.com/contactus — one row per contact, tap to open the
/// device mail app with the address prefilled. No subject line (per the
/// director's request).
///
/// An "App feedback" row at the bottom routes app-specific issues to the
/// app's maintainer rather than the convention staff.
class ContactPage extends StatelessWidget {
  const ContactPage({super.key});

  static const List<_Contact> _conContacts = [
    _Contact(
      title: 'Promotions',
      role: 'General promotional questions',
      email: 'promotions@playoncon.com',
    ),
    _Contact(
      title: 'Lind Rodgers',
      role: 'Programming Director — panels, stages, shows',
      email: 'programming@playoncon.com',
    ),
    _Contact(
      title: 'Celestine Cookson',
      role: 'Operations Director — staff opportunities',
      email: 'operations@playoncon.com',
    ),
    _Contact(
      title: 'Pam Muller',
      role: 'Gaming Director — tournaments, library, gaming',
      email: 'gaming@playoncon.com',
    ),
    _Contact(
      title: 'Casey Davis',
      role: 'Parties Director — hosting & party volunteering',
      email: 'parties@playoncon.com',
    ),
    _Contact(
      title: 'Wes Wilson',
      role: 'Events Director — scheduled events feedback',
      email: 'events@playoncon.com',
    ),
    _Contact(
      title: 'Dan Gilbert',
      role: 'Con Chairman — any aspect of the con',
      email: 'dan@playoncon.com',
    ),
  ];

  static const _Contact _appFeedback = _Contact(
    title: 'App feedback',
    role: 'Bugs or suggestions for this app',
    email: 'support@widgetcorner.com',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contact')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          for (int i = 0; i < _conContacts.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _ContactTile(contact: _conContacts[i]),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1),
          _ContactTile(contact: _appFeedback),
        ],
      ),
    );
  }
}

class _Contact {
  final String title;
  final String role;
  final String email;
  const _Contact({
    required this.title,
    required this.role,
    required this.email,
  });
}

class _ContactTile extends StatelessWidget {
  final _Contact contact;
  const _ContactTile({required this.contact});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.mail_outline),
      title: Text(contact.title),
      subtitle: Text('${contact.role}\n${contact.email}'),
      isThreeLine: true,
      trailing: const Icon(Icons.open_in_new),
      onTap: () => launchUrl(
        Uri(scheme: 'mailto', path: contact.email),
        mode: LaunchMode.externalApplication,
      ),
    );
  }
}
