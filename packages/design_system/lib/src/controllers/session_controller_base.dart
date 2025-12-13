import 'package:flutter/widgets.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:get/get.dart';

abstract class SessionControllerBase extends GetxController {
  InMemoryChatController get chatController;
  TextEditingController get inputController;

  RxBool get isRunning;
  RxnString get threadId;
  RxnString get remoteJobId;
  RxnString get thinkingPreview;

  Future<User> resolveUser(UserID id);

  Future<void> sendText(String text);
  Future<void> sendQuickReply(String value);
  Future<void> resumeThreadById(String id, {String? preview});
  void stop();
}
