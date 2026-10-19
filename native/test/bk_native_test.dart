import 'package:flutter_test/flutter_test.dart';
import 'package:bk_native/bk_native.dart';
import 'package:bk_native/bk_native_platform_interface.dart';
import 'package:bk_native/bk_native_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockBkNativePlatform
    with MockPlatformInterfaceMixin
    implements BkNativePlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final BkNativePlatform initialPlatform = BkNativePlatform.instance;

  test('$MethodChannelBkNative is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelBkNative>());
  });

  test('getPlatformVersion', () async {
    BkNative bkNativePlugin = BkNative();
    MockBkNativePlatform fakePlatform = MockBkNativePlatform();
    BkNativePlatform.instance = fakePlatform;

    expect(await bkNativePlugin.getPlatformVersion(), '42');
  });
}
