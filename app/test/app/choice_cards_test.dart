// Copyright (c) Meta Platforms, Inc. and affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_companion/app/choice_cards.dart';

void main() {
  late ChoiceCardStore store;

  setUp(() {
    store = ChoiceCardStore();
  });

  tearDown(() {
    store.dispose();
  });

  CardButton btn(String id) => CardButton(id: id, label: 'Label $id');

  test('show stores the card and status reports it', () {
    final card = store.show(title: 'Hi', text: 'Pick one', buttons: [btn('a')]);
    expect(store.current?.id, card.id);
    final status = store.status();
    expect((status['card'] as Map)['title'], 'Hi');
    expect(status['last_choice'], isNull);
  });

  test('choose records and dismisses', () {
    store.show(title: 'Hi', buttons: [btn('a'), btn('b')]);
    expect(store.choose('b'), isTrue);
    expect(store.current, isNull);
    final choice = store.lastChoice!;
    expect(choice.buttonId, 'b');
    expect((store.status()['last_choice'] as Map)['button_id'], 'b');
  });

  test('unknown buttons and missing cards choose nothing', () {
    expect(store.choose('x'), isFalse);
    store.show(title: 'Hi', buttons: [btn('a')]);
    expect(store.choose('zzz'), isFalse);
    expect(store.current, isNotNull);
    expect(store.lastChoice, isNull);
  });

  test('validation rejects bad cards', () {
    expect(() => store.show(title: '  '), throwsA(isA<ChoiceCardException>()));
    expect(
      () => store.show(
        title: 'T',
        buttons: [btn('a'), btn('b'), btn('c'), btn('d'), btn('e')],
      ),
      throwsA(isA<ChoiceCardException>()),
    );
    expect(
      () => store.show(
        title: 'T',
        buttons: [btn('same'), btn('same')],
      ),
      throwsA(isA<ChoiceCardException>()),
    );
    expect(
      () => CardButton.fromJson({'id': '', 'label': 'x'}),
      throwsA(isA<ChoiceCardException>()),
    );
  });

  test('clear dismisses without recording', () {
    store.show(title: 'Hi', buttons: [btn('a')]);
    store.clear();
    expect(store.current, isNull);
    expect(store.lastChoice, isNull);
  });

  test('cards expire after their TTL', () async {
    store.show(title: 'Brief', ttlSeconds: 1);
    expect(store.current, isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(store.current, isNull);
  });
}
