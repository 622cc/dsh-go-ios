import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

/// Moments worth re-checking remote links: the network changed (Wi-Fi ↔
/// cellular, VPN up/down) or the app came back to the foreground, where
/// Android may have frozen sockets for a while.
///
/// Emits nothing for the initial connectivity state.
Stream<void> networkKicks() {
  late final StreamController<void> controller;
  StreamSubscription<List<ConnectivityResult>>? connectivity;
  AppLifecycleListener? lifecycle;
  List<ConnectivityResult>? last;

  ConnectivityResult primaryOf(List<ConnectivityResult> list) {
    if (list.contains(ConnectivityResult.vpn)) return ConnectivityResult.vpn;
    if (list.contains(ConnectivityResult.ethernet)) return ConnectivityResult.ethernet;
    if (list.contains(ConnectivityResult.wifi)) return ConnectivityResult.wifi;
    if (list.contains(ConnectivityResult.mobile)) return ConnectivityResult.mobile;
    if (list.contains(ConnectivityResult.other)) return ConnectivityResult.other;
    return ConnectivityResult.none;
  }

  controller = StreamController<void>.broadcast(
    onListen: () {
      try {
        connectivity = Connectivity().onConnectivityChanged.listen((results) {
          final previous = last;
          last = results;
          if (previous == null) return;
          final prevPrimary = primaryOf(previous);
          final nextPrimary = primaryOf(results);
          if (prevPrimary == nextPrimary) return;
          // Coming back online, or switching primary route (Wi-Fi ↔ cellular):
          // sockets that were bound to the old interface are dead.
          if (nextPrimary != ConnectivityResult.none) controller.add(null);
        }, onError: (_) {});
      } catch (_) {
        // No plugin (tests, desktop without NetworkManager): resume-only.
      }
      lifecycle = AppLifecycleListener(onResume: () => controller.add(null));
    },
    onCancel: () {
      unawaited(connectivity?.cancel());
      lifecycle?.dispose();
      connectivity = null;
      lifecycle = null;
      last = null;
    },
  );
  return controller.stream;
}
