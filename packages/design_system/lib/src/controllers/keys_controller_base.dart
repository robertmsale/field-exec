import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

abstract class KeysControllerBase extends GetxController {
  TextEditingController get pemController;

  RxBool get busy;
  RxString get status;

  Future<void> load();
  Future<void> save();
  Future<void> deleteKey();
  Future<void> generate();
  Future<void> copyPublicKey();
}

