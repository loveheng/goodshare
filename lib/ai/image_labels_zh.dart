/// ML Kit 基础图片标注模型的离线中文映射（2026-09-29）。
///
/// 模型 base 变体（**bundled**，离线可用）输出英文 ImageNet 类名（约 400 类常见物体）。
/// 本表覆盖高频常见类，未命中则回退英文原文（[imageLabelZh] 返回 null 即不映射）。
///
/// 纯静态表、零依赖、端侧离线，不引入翻译层——刻意避开 Play 语言包动态下发
/// （translation 在国内不可达），与 base 模型离线特性一致，国内无 GMS 也能中文化。
const Map<String, String> kImageLabelZh = {
  // 人物
  'person': '人物',
  // 动物
  'dog': '狗', 'cat': '猫', 'bird': '鸟', 'horse': '马', 'sheep': '羊', 'cow': '牛',
  'pig': '猪', 'fish': '鱼', 'rabbit': '兔子', 'monkey': '猴子', 'bear': '熊',
  'elephant': '大象', 'zebra': '斑马', 'giraffe': '长颈鹿', 'lion': '狮子',
  'tiger': '老虎', 'snake': '蛇', 'spider': '蜘蛛', 'butterfly': '蝴蝶', 'bee': '蜜蜂',
  'duck': '鸭子', 'chicken': '鸡', 'goose': '鹅', 'penguin': '企鹅', 'owl': '猫头鹰',
  'parrot': '鹦鹉', 'fox': '狐狸', 'wolf': '狼', 'deer': '鹿', 'goat': '山羊',
  'camel': '骆驼', 'kangaroo': '袋鼠', 'squirrel': '松鼠', 'whale': '鲸鱼', 'shark': '鲨鱼',
  'hamster': '仓鼠', 'ant': '蚂蚁', 'mosquito': '蚊子', 'beetle': '甲虫',
  // 植物与自然
  'tree': '树', 'flower': '花', 'plant': '植物', 'leaf': '叶子', 'grass': '草',
  'rose': '玫瑰', 'sunflower': '向日葵', 'palm': '棕榈', 'mushroom': '蘑菇',
  'sky': '天空', 'cloud': '云', 'water': '水', 'sea': '海', 'beach': '海滩',
  'mountain': '山', 'river': '河', 'lake': '湖', 'stone': '石头', 'sand': '沙',
  // 食物
  'food': '食物', 'fruit': '水果', 'vegetable': '蔬菜', 'apple': '苹果', 'banana': '香蕉',
  'orange': '橙子', 'grape': '葡萄', 'strawberry': '草莓', 'watermelon': '西瓜',
  'pineapple': '菠萝', 'peach': '桃', 'pear': '梨', 'lemon': '柠檬', 'kiwi': '猕猴桃',
  'carrot': '胡萝卜', 'broccoli': '西兰花', 'corn': '玉米', 'tomato': '番茄',
  'potato': '土豆', 'onion': '洋葱', 'bread': '面包', 'cake': '蛋糕', 'pizza': '披萨',
  'burger': '汉堡', 'egg': '蛋', 'cheese': '奶酪', 'rice': '米饭', 'noodle': '面条',
  'soup': '汤', 'coffee': '咖啡', 'tea': '茶', 'wine': '酒', 'beer': '啤酒',
  // 交通
  'car': '汽车', 'truck': '卡车', 'bus': '公交', 'motorcycle': '摩托车', 'bicycle': '自行车',
  'boat': '船', 'airplane': '飞机', 'train': '火车', 'ship': '轮船', 'helicopter': '直升机',
  'wheel': '轮子', 'traffic light': '红绿灯', 'road': '道路', 'bridge': '桥', 'street': '街道',
  // 电子设备
  'phone': '手机', 'laptop': '笔记本', 'computer': '电脑', 'keyboard': '键盘',
  'mouse': '鼠标', 'tv': '电视', 'camera': '相机', 'screen': '屏幕', 'speaker': '音箱',
  'headphones': '耳机', 'remote': '遥控器', 'charger': '充电器', 'battery': '电池',
  // 家具与家居
  'chair': '椅子', 'couch': '沙发', 'bed': '床', 'table': '桌子', 'desk': '书桌',
  'bookshelf': '书架', 'lamp': '台灯', 'clock': '时钟', 'mirror': '镜子', 'window': '窗',
  'door': '门', 'curtain': '窗帘', 'pillow': '枕头', 'blanket': '毯子', 'vase': '花瓶',
  // 容器与日用品
  'bottle': '瓶子', 'cup': '杯子', 'bowl': '碗', 'plate': '盘子', 'fork': '叉子',
  'knife': '刀', 'spoon': '勺', 'bag': '包', 'umbrella': '伞', 'scissors': '剪刀',
  'pen': '笔', 'pencil': '铅笔', 'book': '书', 'glasses': '眼镜', 'hat': '帽子',
  'shoe': '鞋', 'shirt': '衬衫', 'dress': '裙子', 'pants': '裤子', 'watch': '手表',
  'key': '钥匙', 'lock': '锁', 'money': '钱', 'coin': '硬币', 'wallet': '钱包',
  'towel': '毛巾', 'soap': '肥皂', 'toothbrush': '牙刷',
  // 乐器
  'guitar': '吉他', 'piano': '钢琴', 'violin': '小提琴', 'drum': '鼓', 'trumpet': '小号',
  // 运动与玩具
  'ball': '球', 'soccer': '足球', 'basketball': '篮球', 'tennis': '网球', 'helmet': '头盔',
  'skateboard': '滑板', 'tent': '帐篷', 'kite': '风筝', 'toy': '玩具',
  // 建筑与场所
  'building': '建筑', 'house': '房子', 'castle': '城堡', 'tower': '塔', 'fence': '栅栏',
  'bench': '长椅', 'fountain': '喷泉', 'statue': '雕像', 'flag': '旗帜',
  // 其他
  'fire': '火', 'candle': '蜡烛', 'light': '灯', 'tool': '工具', 'hammer': '锤子',
  'screwdriver': '螺丝刀', 'box': '盒子', 'gift': '礼物', 'balloon': '气球',
  'star': '星星', 'heart': '心', 'smile': '笑脸', 'sign': '标志', 'logo': '标识',
  'cathedral': '教堂', 'library': '图书馆', 'hospital': '医院', 'school': '学校',
  'restaurant': '餐厅', 'hotel': '酒店', 'park': '公园', 'playground': '游乐场',
};

/// 把模型英文标签映射为中文；未命中返回 null（调用方保留英文原文）。
String? imageLabelZh(String english) => kImageLabelZh[english.toLowerCase()];
