/// 视觉间距 / 圆角令牌（设计 §2 视觉系统单一事实源）。
///
/// 用途：Padding / Margin / 圆角一律走本文件常量，禁止在组件里写 13、17 之类
/// 非规范魔术数字。旧代码渐进迁移，新代码强制。
///
/// 取值依据：盘点全仓既有间距（8/12/16/20/24）与圆角（8/12/16）归并成规范刻度。
class Insets {
  const Insets._();

  /// 4：极紧凑（图标与文字夹缝）
  static const double xs = 4;

  /// 8：紧凑（列表项内小间隙、SizedBox 高度）
  static const double sm = 8;

  /// 12：默认（卡片内边距、网格间距、Wrap 间距）
  static const double md = 12;

  /// 16：标准外边距（页面左右留白、BottomSheet 横边距）
  static const double lg = 16;

  /// 20：宽松（详情页 ListView 左右留白）
  static const double xl = 20;

  /// 24：大间距（详情页 ListView 底部留白）
  static const double xxl = 24;
}

/// 圆角刻度（2026-09-30 mymind 视觉基准：大圆角，卡片档 xl=20）。
class Radii {
  const Radii._();

  /// 8：小圆角（缩略图、开关容器）
  static const double sm = 8;

  /// 12：默认圆角（容器、机器态框）
  static const double md = 12;

  /// 16：中圆角（按钮、BottomSheet 内元素）
  static const double lg = 16;

  /// 20：大圆角（卡片、媒体封面卡——mymind 基准，ui-spec §2.3）
  static const double xl = 20;
}
