import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'app_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'pk.mpl.playback',
    androidNotificationChannelName: 'Playback',
    androidNotificationOngoing: true,
  );
  final services = await AppServices.create();
  runApp(MplApp(services: services));
}
