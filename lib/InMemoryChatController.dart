import 'dart:async';

import 'package:flutter_chat_core/flutter_chat_core.dart';

/// Simple in-memory chat controller (no Hive dependency).
class InMemoryChatController
    with UploadProgressMixin, ScrollToMessageMixin
    implements ChatController {
  final _operationsController = StreamController<ChatOperation>.broadcast();
  final List<Message> _messages = [];

  @override
  List<Message> get messages => List.unmodifiable(_messages);

  @override
  Stream<ChatOperation> get operationsStream => _operationsController.stream;

  @override
  Future<void> insertMessage(
    Message message, {
    int? index,
    bool animated = true,
  }) async {
    if (_messages.any((m) => m.id == message.id)) return;

    _messages.add(message);
    _messages.sort(
      (a, b) => (a.createdAt?.millisecondsSinceEpoch ?? 0).compareTo(
        b.createdAt?.millisecondsSinceEpoch ?? 0,
      ),
    );
    final insertIndex = _messages.indexOf(message);
    _operationsController.add(
      ChatOperation.insert(message, insertIndex, animated: animated),
    );
  }

  @override
  Future<void> removeMessage(Message message, {bool animated = true}) async {
    final index = _messages.indexWhere((m) => m.id == message.id);
    if (index != -1) {
      final removed = _messages.removeAt(index);
      _operationsController.add(
        ChatOperation.remove(removed, index, animated: animated),
      );
    }
  }

  @override
  Future<void> updateMessage(Message oldMessage, Message newMessage) async {
    final index = _messages.indexWhere((m) => m.id == oldMessage.id);
    if (index != -1) {
      if (_messages[index] == newMessage) return;
      final actual = _messages[index];
      _messages[index] = newMessage;
      _operationsController.add(
        ChatOperation.update(actual, newMessage, index),
      );
    }
  }

  @override
  Future<void> setMessages(
    List<Message> messages, {
    bool animated = true,
  }) async {
    _messages.clear();
    _messages.addAll(messages);
    _operationsController.add(ChatOperation.set(messages, animated: animated));
  }

  @override
  Future<void> insertAllMessages(
    List<Message> messages, {
    int? index,
    bool animated = true,
  }) async {
    if (messages.isEmpty) return;
    final originalLength = _messages.length;
    _messages.addAll(messages);
    _messages.sort(
      (a, b) => (a.createdAt?.millisecondsSinceEpoch ?? 0).compareTo(
        b.createdAt?.millisecondsSinceEpoch ?? 0,
      ),
    );
    _operationsController.add(
      ChatOperation.insertAll(messages, originalLength, animated: animated),
    );
  }

  @override
  void dispose() {
    _operationsController.close();
    disposeUploadProgress();
    disposeScrollMethods();
  }
}
