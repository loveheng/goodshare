/// 目标语言码（BCP-47，与 ML Kit `TranslateLanguage.bcpCode` 同口径）。
///
/// 单独成文件的原因：动作层（[TranslateCommand] 校验）与 AI 翻译层都要用它，
/// 而翻译层还牵着 `subtitle.dart` / `path_provider`，动作层不该被这些拖进来。
/// 单一事实源：设置页下拉、命令校验、语言包下载共用本表。
const kTargetLanguages = ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru'];

const _languageLabels = {
  'zh': '中文',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
  'fr': '法语',
  'de': '德语',
  'es': '西班牙语',
  'ru': '俄语',
};

/// 语言码 → 中文名（设置页展示用）。未知码原样返回。
String languageLabel(String code) => _languageLabels[code] ?? code;

/// 是否为受支持的目标语言（动作层校验入口）。
bool isSupportedTarget(String code) => kTargetLanguages.contains(code);
