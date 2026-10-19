import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'bk_native_method_channel.dart';

abstract class BkNativePlatform extends PlatformInterface {
  /// Constructs a BkNativePlatform.
  BkNativePlatform() : super(token: _token);

  static final Object _token = Object();

  static BkNativePlatform _instance = MethodChannelBkNative();

  /// The default instance of [BkNativePlatform] to use.
  ///
  /// Defaults to [MethodChannelBkNative].
  static BkNativePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [BkNativePlatform] when
  /// they register themselves.
  static set instance(BkNativePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
