import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_config.dart';
import '../../services/schedule_repository.dart';
import '../../theme/poc_theme.dart';
import 'contact_page.dart';

class InfoPage extends ConsumerWidget {
  const InfoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(scheduleRepositoryProvider);
    final lastSync = state.lastSyncAt;
    final lastSyncText = lastSync == null
        ? 'Never'
        : DateFormat('EEE MMM d, h:mm a').format(lastSync);

    return Scaffold(
      appBar: AppBar(title: const Text('Info')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          const _LogoHeader(),
          const _CountdownCard(),
          ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: const Text(AppConfig.venueName),
            subtitle: const Text(AppConfig.venueCityState),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openVenueInMaps(),
          ),
          if (AppConfig.hasScheduleViewUrl) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Printable schedule'),
              subtitle: const Text('Opens the full Google Sheet'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => launchUrl(
                Uri.parse(AppConfig.scheduleViewUrl),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
          if (AppConfig.hasProgramUrl) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Program'),
              subtitle: const Text('Full event descriptions and details'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => launchUrl(
                Uri.parse(AppConfig.programUrl),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Join the Discord'),
            subtitle: AppConfig.hasDiscordUrl
                ? const Text('Opens in Discord or browser')
                : const Text('Discord URL not configured'),
            enabled: AppConfig.hasDiscordUrl,
            onTap: AppConfig.hasDiscordUrl
                ? () => launchUrl(
                      Uri.parse(AppConfig.discordInviteUrl),
                      mode: LaunchMode.externalApplication,
                    )
                : null,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Contact'),
            subtitle: const Text('Reach a director or send app feedback'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ContactPage()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.cloud_download),
            title: const Text('Refresh schedule'),
            subtitle: Text('Last sync: $lastSyncText'),
            trailing: state.isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            onTap: state.isSyncing
                ? null
                : () =>
                    ref.read(scheduleRepositoryProvider.notifier).refresh(),
          ),
          const Divider(),
          const _VersionTile(),
        ],
      ),
    );
  }

  /// Hand the venue off to the device's native maps app: Apple Maps on iOS,
  /// the `geo:` intent on Android (which the system resolves to Google Maps,
  /// Waze, etc.).
  Future<void> _openVenueInMaps() async {
    final q = Uri.encodeQueryComponent(AppConfig.venueMapsQuery);
    final Uri uri = Platform.isIOS
        ? Uri.parse('https://maps.apple.com/?q=$q')
        : Uri.parse('geo:0,0?q=$q');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      // Fall back to a web search if the platform handler refused (e.g. no
      // maps app on Android emulator).
      await launchUrl(
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$q'),
        mode: LaunchMode.externalApplication,
      );
    }
  }
}

class _LogoHeader extends StatelessWidget {
  const _LogoHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/branding/poc-logo.png',
                width: 180,
                height: 180,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Play On Con',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: PocColors.forestDark,
            ),
          ),
          const SizedBox(height: 6),
          const BetaPill(),
        ],
      ),
    );
  }
}

/// Reads the build's CFBundleShortVersionString / versionName at runtime via
/// package_info_plus so the Info tab always matches what TestFlight and Play
/// show — no string to keep in sync by hand.
class _VersionTile extends StatefulWidget {
  const _VersionTile();

  @override
  State<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends State<_VersionTile> {
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _version = info.version);
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = _version;
    return ListTile(
      leading: const Icon(Icons.info_outline),
      title: const Text('Play On Con'),
      subtitle: Text(
        v == null ? 'Convention companion' : 'Convention companion · v$v',
      ),
    );
  }
}

/// Small "BETA" badge surfaced near the app name so attendees know this
/// build is a work-in-progress companion, not the final official app.
class BetaPill extends StatelessWidget {
  const BetaPill({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: PocColors.forestDark.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: PocColors.forestDark.withValues(alpha: 0.30),
        ),
      ),
      child: Text(
        'BETA',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: PocColors.forestDark,
        ),
      ),
    );
  }
}

/// Live countdown to Thursday 4 PM local. Hidden once the moment has passed
/// (or when [POC_EVENT_THURSDAY] isn't configured).
class _CountdownCard extends StatefulWidget {
  const _CountdownCard();

  @override
  State<_CountdownCard> createState() => _CountdownCardState();
}

class _CountdownCardState extends State<_CountdownCard> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _recompute();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _recompute());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _recompute() {
    final start = AppConfig.eventStart;
    if (start == null) {
      _ticker?.cancel();
      return;
    }
    final diff = start.difference(DateTime.now());
    if (diff.isNegative) {
      _ticker?.cancel();
      if (mounted && _remaining != Duration.zero) {
        setState(() => _remaining = Duration.zero);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _remaining = diff);
  }

  @override
  Widget build(BuildContext context) {
    if (AppConfig.eventStart == null || _remaining <= Duration.zero) {
      return const SizedBox.shrink();
    }

    final days = _remaining.inDays;
    final hours = _remaining.inHours % 24;
    final minutes = _remaining.inMinutes % 60;
    final seconds = _remaining.inSeconds % 60;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Card(
        elevation: 0,
        color: PocColors.forestDark.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: PocColors.forestDark.withValues(alpha: 0.16),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Column(
            children: [
              Text(
                'Play On Con starts in',
                style: TextStyle(
                  fontSize: 13,
                  letterSpacing: 0.5,
                  color: PocColors.inkSoft,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _CountdownUnit(value: days, label: days == 1 ? 'day' : 'days'),
                  const _CountdownSep(),
                  _CountdownUnit(value: hours, label: 'h', pad: true),
                  const _CountdownSep(),
                  _CountdownUnit(value: minutes, label: 'm', pad: true),
                  const _CountdownSep(),
                  _CountdownUnit(value: seconds, label: 's', pad: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountdownUnit extends StatelessWidget {
  final int value;
  final String label;
  final bool pad;
  const _CountdownUnit({
    required this.value,
    required this.label,
    this.pad = false,
  });

  @override
  Widget build(BuildContext context) {
    final text = pad ? value.toString().padLeft(2, '0') : value.toString();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: PocColors.forestDark,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: PocColors.inkSoft),
        ),
      ],
    );
  }
}

class _CountdownSep extends StatelessWidget {
  const _CountdownSep();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14, left: 6, right: 6),
      child: Text(
        ':',
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: PocColors.forestDark.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
