
import 'bk_native_platform_interface.dart';

class BkNative {
  Future<String?> getPlatformVersion() {
    return BkNativePlatform.instance.getPlatformVersion();
  }
}
