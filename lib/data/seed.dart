import 'models.dart';

AppData seedData() {
  // 首次安装即空白板，只保留 UI 依赖的「未分类」集合骨架
  // （演示模板在清单页灵感库，按需引入）。
  return AppData(
    lists: [],
    tasks: [],
    habits: [],
    journal: {},
  );
}

/// 灵感清单库模板。
class ListTemplate {
  const ListTemplate(this.name, this.desc, this.items);

  final String name;
  final String desc;
  final List<String> items;
}

const inspirationTemplates = <ListTemplate>[
  ListTemplate('豆瓣电影 Top100', '经典片单打卡，一部部看完打勾', [
    '《肖申克的救赎》',
    '《霸王别姬》',
    '《千与千寻》',
    '《泰坦尼克号》',
    '《阿甘正传》',
    '《这个杀手不太冷》',
    '《美丽人生》',
    '《盗梦空间》',
    '《忠犬八公的故事》',
    '《海上钢琴师》',
  ]),
  ListTemplate('每周一次断舍离', '每周整理一处空间，保持清爽', [
    '整理衣柜',
    '清理书桌',
    '手机相册瘦身',
    '清空微信收藏',
    '收拾电脑桌面',
    '厨房橱柜归位',
  ]),
  ListTemplate('每天一件幸福小事', '记录并完成日常小确幸', [
    '看一次日落',
    '给自己泡一杯好茶',
    '散步 20 分钟',
    '早睡一小时',
    '给朋友发条问候',
    '读完一本书的一章',
  ]),
  ListTemplate('2026 年愿望清单', '年度愿望逐条打卡', [
    '完成一次旅行',
    '学会一道拿手菜',
    '坚持运动 100 天',
    '读 24 本书',
    '存下一笔积蓄',
    '学一项新技能',
  ]),
  ListTemplate('100 件解压治愈小手工', '手作小项目清单，逐件完成', [
    '折一只千纸鹤',
    '做一张手工贺卡',
    '编一条手绳',
    '画一幅小画',
    '捏一个粘土小摆件',
    '做一枚干花书签',
  ]),
  ListTemplate('出行行李清单', '出行打包前逐项核对', [
    '身份证 / 证件',
    '充电器与充电宝',
    '换洗衣物',
    '洗漱包',
    '常用药品',
    '雨伞',
  ]),
];
