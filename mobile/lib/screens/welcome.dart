import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../config.dart';
import '../services/push.dart';
import '../theme.dart';

/// First launch: Terms & Privacy consent with the optional measurement choice (analytics and Meta ad
/// measurement), then Android's notification permission prompt. Shown once per install; the guest account is
/// already created in the background. The choice can be changed in Profile › Settings › Measurement preferences.
class WelcomeGate extends StatefulWidget {
  const WelcomeGate({super.key, required this.child});
  final Widget child;
  static const prefKey = 'terms_accepted_v1';
  static const _perm = MethodChannel('app/perm');

  /// Android 13+ shows "Allow SkyKeep to send you notifications?"; older versions allow by default.
  static Future<void> askNotifications() async {
    try {
      await _perm.invokeMethod<void>('notifications');
    } catch (_) {/* not on Android / tests */}
  }

  @override
  State<WelcomeGate> createState() => _WelcomeGateState();
}

class _WelcomeGateState extends State<WelcomeGate> {
  bool? _accepted;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _accepted ??= AppScope.read(context).prefs.getBool(WelcomeGate.prefKey) ?? false;
  }

  Future<void> _agree(bool allowMeasurement) async {
    final app = AppScope.read(context);
    await app.prefs.setBool(WelcomeGate.prefKey, true);
    if (!mounted) return;
    setState(() => _accepted = true);
    unawaited(app.measurement.save(analytics: allowMeasurement, advertising: allowMeasurement));
    await WelcomeGate.askNotifications();
    unawaited(Push.register());
  }

  @override
  Widget build(BuildContext context) => _accepted == true ? widget.child : ConsentScreen(onAgree: _agree);
}

class ConsentScreen extends StatelessWidget {
  const ConsentScreen({super.key, required this.onAgree});

  /// true: "Agree and continue" (also allows optional measurement); false: terms only.
  final void Function(bool allowMeasurement) onAgree;

  static void _open(String path) => launchUrl(Uri.parse('${Config.websiteUrl}$path'), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: C.heroGradient),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(20),
          child: SafeArea(child: Center(child: SingleChildScrollView(child: Container(
            constraints: const BoxConstraints(maxWidth: 440),
            padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(28), border: Border.all(color: C.border),
                boxShadow: const [BoxShadow(color: Color(0x1A0F172A), blurRadius: 24, offset: Offset(0, 8))]),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Center(child: CloudMark(size: 84)),
              const SizedBox(height: 18),
              const Text('Terms of Service and Privacy Policy', textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: C.text)),
              const SizedBox(height: 12),
              const Text(
                  'Welcome to ${Config.appName}. By using this app, you acknowledge that you understand how we collect, use and '
                  'protect your personal data, as well as your rights and responsibilities as a user. '
                  'Please review and accept our Privacy Policy and Terms & Conditions. Either button accepts the terms. '
                  '"Agree and continue" also allows optional app analytics and ad measurement with Meta (app activity, '
                  'a random install ID, the advertising ID and basic device information). You can change this anytime in '
                  'Profile › Settings › Measurement preferences.',
                  textAlign: TextAlign.center, style: TextStyle(color: C.muted, height: 1.45)),
              Wrap(alignment: WrapAlignment.center, children: [
                TextButton(onPressed: () => _open('/privacy'), child: const Text('Privacy Policy')),
                TextButton(onPressed: () => _open('/terms'), child: const Text('Terms & Conditions')),
              ]),
              const SizedBox(height: 8),
              GradientButton(label: 'Agree and continue', onPressed: () => onAgree(true)),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => onAgree(false), child: const Text('Continue without optional sharing')),
            ]),
          )))),
        ),
      );
}
