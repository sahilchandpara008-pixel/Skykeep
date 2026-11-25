import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../config.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Profile › Settings › Measurement preferences: the optional sharing choices from the first-run consent.
class MeasurementPreferencesScreen extends StatefulWidget {
  const MeasurementPreferencesScreen({super.key});
  @override
  State<MeasurementPreferencesScreen> createState() => _MeasurementPreferencesScreenState();
}

class _MeasurementPreferencesScreenState extends State<MeasurementPreferencesScreen> {
  late final _m = AppScope.read(context).measurement;
  late bool _usage = _m.analytics, _ads = _m.advertising;
  bool _saving = false;

  Future<void> _save(bool usage, bool ads) async {
    setState(() => _saving = true);
    await _m.save(analytics: usage, advertising: ads);
    if (!mounted) return;
    toast(context, 'Choices saved');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Measurement preferences')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Your choice, your privacy', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('These choices are optional. Your account, plan, storage, videos and payments work the same when they are off.',
              style: TextStyle(color: C.muted)),
          const SizedBox(height: 12),
          Card(child: Column(children: [
            SwitchListTile(
              title: const Text('App analytics'),
              subtitle: const Text('Share basic app activity with ${Config.appName} to understand use, sessions and returning users.'),
              value: _usage,
              onChanged: _saving ? null : (v) => setState(() => _usage = v),
            ),
            const Divider(height: 1),
            SwitchListTile(
              title: const Text('Advertising measurement with Meta'),
              subtitle: const Text('Share app activity and verified purchases with Meta to measure and improve our ads. This uses the Meta SDK, '
                  'a random install ID, the advertising ID (unless you turned off ad personalisation on your phone), IP address and '
                  'basic device information. No passwords, search text or private files are shared.'),
              value: _ads,
              onChanged: _saving ? null : (v) => setState(() => _ads = v),
            ),
          ])),
          const SizedBox(height: 12),
          const Text('Turning sharing off stops future events. It cannot recall events Meta has already received.',
              style: TextStyle(color: C.muted, fontSize: 13)),
          TextButton(
            onPressed: () => launchUrl(Uri.parse('${Config.websiteUrl}/privacy'), mode: LaunchMode.externalApplication),
            child: const Text('Read the privacy policy'),
          ),
          const SizedBox(height: 8),
          GradientButton(label: _saving ? 'Saving…' : 'Save choices', onPressed: _saving ? null : () => _save(_usage, _ads)),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _saving ? null : () => _save(false, false), child: const Text('Essential only')),
        ]),
      );
}
