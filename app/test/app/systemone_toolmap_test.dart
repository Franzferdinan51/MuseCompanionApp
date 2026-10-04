import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/systemone_client.dart';
import 'package:muse_companion/app/systemone_toolmap.dart';

const _allTools = [
  'take_photo',
  'speak_text',
  'get_device_health',
  'get_location',
  'list_notifications',
  'set_alarm',
  'set_timer',
  'show_notification',
  'open_url',
  'launch_app',
  'vibrate',
  'get_clipboard',
  'set_clipboard',
  'toggle_flashlight',
  'usb_list_devices',
  'usb_list_volumes',
  'usb_list_files',
  'usb_serial_list',
];

void main() {
  group('filterToolsByRanking', () {
    test('matches camera concept for a photo task', () {
      final ranked = [
        const RankedTool(id: 'camera', relevance: 0.9),
        const RankedTool(id: 'tts', relevance: 0.2),
      ];
      final picked = filterToolsByRanking(_allTools, ranked);
      expect(picked, contains('take_photo'));
      expect(picked.length, lessThanOrEqualTo(8));
    });

    test('empty ranking falls back to at least 2 tools', () {
      final picked = filterToolsByRanking(_allTools, const []);
      expect(picked.length, greaterThanOrEqualTo(2));
      expect(picked, contains('speak_text'));
    });

    test('caps at 8 tools max', () {
      final ranked = [
        for (final id in ['camera', 'tts', 'alarm', 'timer', 'usb', 'location',
            'notification', 'browser', 'app', 'clipboard', 'flashlight'])
          RankedTool(id: id, relevance: 0.9),
      ];
      final picked = filterToolsByRanking(_allTools, ranked);
      expect(picked.length, lessThanOrEqualTo(8));
    });

    test('fuzzy match: "alarms" hits set_alarm', () {
      final ranked = [const RankedTool(id: 'alarms', relevance: 0.8)];
      final picked = filterToolsByRanking(_allTools, ranked);
      expect(picked, contains('set_alarm'));
    });

    test('usb concept matches all usb tools', () {
      final ranked = [const RankedTool(id: 'usb', relevance: 0.85)];
      final picked = filterToolsByRanking(_allTools, ranked);
      expect(picked, contains('usb_list_devices'));
      expect(picked, contains('usb_serial_list'));
    });
  });
}
