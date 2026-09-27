import 'dart:io';

/// 取本机局域网 IPv4（Wi-Fi 场景展示给桌面端直连用）。
Future<String?> lanIpv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  for (final itf in interfaces) {
    for (final addr in itf.addresses) {
      // 优先 wlan 段常见私网地址
      if (addr.address.startsWith('192.168.') ||
          addr.address.startsWith('10.') ||
          addr.address.startsWith('172.')) {
        return addr.address;
      }
    }
  }
  return interfaces.isEmpty ? null : interfaces.first.addresses.first.address;
}
