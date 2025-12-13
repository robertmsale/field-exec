import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

abstract class InstallKeyControllerBase extends GetxController {
  TextEditingController get targetController;
  TextEditingController get portController;
  TextEditingController get passwordController;

  RxBool get busy;
  RxString get status;

  Future<void> install();
}

