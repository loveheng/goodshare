import 'package:shared_preferences/shared_preferences.dart';

const _kMachineModeEnabled = 'machine_mode_enabled';

/// 机器码（JSON 调试入口）全局开关（2026-10-02 拍板，默认关闭）。
///
/// 关闭时详情页 `⋯` 菜单完全不出现「机器码」项——普通人无入口，
/// **双态呈现能力（human_md / machine_json 仍可被 AI/MCP 产出）不受影响**，
/// 只是不给人肉切换按钮；开启后菜单出现「机器码」项，可切人类态 / 机器态。
Future<bool> getMachineModeEnabled() async =>
    (await SharedPreferences.getInstance()).getBool(_kMachineModeEnabled) ?? false;

Future<void> setMachineModeEnabled(bool v) async =>
    (await SharedPreferences.getInstance()).setBool(_kMachineModeEnabled, v);
