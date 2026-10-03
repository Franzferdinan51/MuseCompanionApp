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
import 'package:muse_companion/app/chat.dart';

void main() {
  test('addSending records a sending message with a fresh id', () {
    final history = ChatHistory();
    addTearDown(history.close);
    final id = history.addSending('hello');
    expect(history.messages, hasLength(1));
    final message = history.messages.single;
    expect(message.id, id);
    expect(message.text, 'hello');
    expect(message.status, ChatStatus.sending);
    expect(message.error, isEmpty);
  });

  test('markSent and markFailed update status and error', () {
    final history = ChatHistory();
    addTearDown(history.close);
    final first = history.addSending('one');
    final second = history.addSending('two');
    history.markSent(first);
    history.markFailed(second, 'link down');
    expect(history.messages[0].status, ChatStatus.sent);
    expect(history.messages[0].error, isEmpty);
    expect(history.messages[1].status, ChatStatus.failed);
    expect(history.messages[1].error, 'link down');
  });

  test('markRetrying returns a failed message to sending', () {
    final history = ChatHistory();
    addTearDown(history.close);
    final id = history.addSending('one');
    history.markFailed(id, 'link down');
    history.markRetrying(id);
    expect(history.messages.single.status, ChatStatus.sending);
    expect(history.messages.single.error, isEmpty);
  });

  test('unknown ids are ignored', () {
    final history = ChatHistory();
    addTearDown(history.close);
    history.markSent(42);
    history.markFailed(42, 'x');
    history.markRetrying(42);
    expect(history.messages, isEmpty);
  });

  test('history is capped at maxMessages, oldest first', () {
    final history = ChatHistory(maxMessages: 3);
    addTearDown(history.close);
    for (var i = 0; i < 5; i++) {
      history.addSending('m$i');
    }
    expect(
        history.messages.map((m) => m.text), ['m2', 'm3', 'm4']);
  });

  test('every mutation notifies the stream', () async {
    final history = ChatHistory();
    addTearDown(history.close);
    var events = 0;
    final sub = history.stream.listen((_) => events++);
    final id = history.addSending('one');
    history.markSent(id);
    history.markFailed(id, 'x');
    history.markRetrying(id);
    await pumpEventQueue();
    expect(events, 4);
    await sub.cancel();
  });
}
