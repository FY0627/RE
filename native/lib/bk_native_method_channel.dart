import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bk_native_platform_interface.dart';

/// An implementation of [BkNativePlatform] that uses method channels.
class MethodChannelBkNative extends BkNativePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('bk_native');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
