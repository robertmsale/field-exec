import 'package:flutter/widgets.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:get/get.dart';

abstract class SessionControllerBase extends GetxController {
  InMemoryChatController get chatController;
  TextEditingController get inputController;
  FocusNode get inputFocusNode;

  RxBool get isRunning;
  RxBool get isLoadingMoreHistory;
  RxBool get hasMoreHistory;
  RxBool get needsScrollToBottom;
  RxnString get threadId;
  RxnString get remoteJobId;
  RxnString get thinkingPreview;

  Future<User> resolveUser(UserID id);

  Future<void> sendText(String text);
  Future<void> sendQuickReply(
    String value, {
    String? actionId,
    String? actionGroupId,
    String? actionLabel,
  });
  Future<void> resumeThreadById(String id, {String? preview});
  Future<void> reattachIfNeeded({int backfillLines});
  Future<void> refresh();
  Future<void> loadMoreHistory();
  Future<void> loadImageAttachment(CustomMessage message, {int? index});
  Future<void> resetSession();
  Future<void> clearSessionArtifacts();
  void stop();
}
