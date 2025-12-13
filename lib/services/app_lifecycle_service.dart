import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

class AppLifecycleService with WidgetsBindingObserver {
  AppLifecycleState? _state;
  final stateRx = Rxn<AppLifecycleState>();

  AppLifecycleState? get state => _state;

  bool get isForeground => _state == null || _state == AppLifecycleState.resumed;

  void start() {
    WidgetsBinding.instance.addObserver(this);
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _state = state;
    stateRx.value = state;
  }
}
