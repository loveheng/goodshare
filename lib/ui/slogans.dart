import 'package:flutter/material.dart';

import '../update/remote_config_store.dart';

/// 文青风口号落点键：对应四个界面，作为远端配置 `config.slogans` 的 map key。
class SloganKeys {
  const SloganKeys._();
  static const splash = 'splash';
  static const empty = 'empty';
  static const about = 'about';
  static const detailFooter = 'detailFooter';
}

/// 本地默认口号（产品文案基线）：离线 / 远端未下发该 key 时回退使用。
///
/// 远端 `config.slogans` 可部分覆盖（只下发改动的 key），未覆盖的 key 仍用本地默认。
const Map<String, String> kDefaultSlogans = {
  SloganKeys.splash: '收下微小的喜欢，等待被需要的瞬间。',
  SloganKeys.empty: '把零碎的喜欢收进口袋，在需要的时候开成花。',
  SloganKeys.about: '时间会模糊记忆，但你的喜好，一直在这里安放。',
  SloganKeys.detailFooter: '未必次次有用，但每次想起，它都在这里等回应。',
};

/// 取某落点的口号文本：远端配置 `config.slogans[key]` 优先，缺省回退本地默认值。
String sloganFor(String key) {
  final remote = RemoteConfigStore.instance.current.slogans;
  final fromRemote = remote != null ? remote[key] : null;
  if (fromRemote != null && fromRemote.isNotEmpty) return fromRemote;
  return kDefaultSlogans[key] ?? '';
}

/// 文青风排版样式：系统衬线兜底（`fontFamily: 'serif'`，零体积、不捆绑字体）+ Light
/// 字重 + 1.5 字间距 + `onSurfaceVariant` 文字色。底色沿用 M3 动态表面，本层不硬编码颜色
/// （契合设计 §2.1 禁止硬编码非品牌色 / §2.2 默认系统字体）。
/// 字号映射 M3 textTheme 双档（[large] 大档 titleMedium / 小档 bodyMedium），
/// 随系统文字缩放（textScaler）自动缩放，不写裸 fontSize 字面量（arch-guard R7）。
TextStyle poeticTextStyle(
  BuildContext context, {
  bool large = true,
  double letterSpacing = 1.5,
}) {
  final theme = Theme.of(context);
  final base = large ? theme.textTheme.titleMedium! : theme.textTheme.bodyMedium!;
  return base.copyWith(
    fontFamily: 'serif',
    fontWeight: FontWeight.w300,
    letterSpacing: letterSpacing,
    height: 1.7,
    color: theme.colorScheme.onSurfaceVariant,
  );
}

/// 文青风口号文本组件（统一排版，避免各页面写散样式）。
class PoeticText extends StatelessWidget {
  const PoeticText(
    this.text, {
    super.key,
    this.large = true,
    this.letterSpacing = 1.5,
    this.align,
  });

  final String text;
  final bool large;
  final double letterSpacing;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: align,
        style: poeticTextStyle(
          context,
          large: large,
          letterSpacing: letterSpacing,
        ),
      );
}
