import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/captions.dart';

void main() {
  test('captions drop markdown and stay short', () {
    final caption = captionFromReply(
      '**Hello** [porch](https://example.com) ```code```',
    );
    expect(caption, 'Hello porch');
    expect(captionFromReply('x' * 400).length, captionLimit);
    expect(captionFromReply('x' * 400).endsWith('…'), isTrue);
  });

  test('spoken replies allow more text than the caption', () {
    final text = 'word ' * 80;
    expect(speakableReply(text).length, lessThanOrEqualTo(spokenLimit));
    expect(
        speakableReply(text).length, greaterThan(captionFromReply(text).length));
  });

  test('activity codes become gadget-style captions', () {
    expect(activityCaption('thinking'), 'Thinking…');
    expect(activityCaption('using tool'), 'Using a tool…');
    expect(activityCaption('  '), isNull);
    expect(activityCaption('checking_mail'), 'Checking mail');
  });

  test('activity codes naming a phone tool get the rich tool label', () {
    // The descriptive toolLabel wins over the title-cased fallback.
    expect(activityCaption('take_photo'), 'Taking a photo…');
    expect(activityCaption('speak_text'), 'Speaking…');
    expect(activityCaption('get_device_health'), 'Checking device health…');
    // Unknown codes still fall back to title case.
    expect(activityCaption('checking_platform_tools'), 'Checking platform tools');
  });
}
