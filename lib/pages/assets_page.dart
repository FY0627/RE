import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../theme/app_theme.dart';
import '../theme/app_layout.dart';
import '../widgets/account_detail_motion.dart';
import '../widgets/liquid_glass_surface.dart';
import '../widgets/sliver_wallet_cards.dart';
import '../widgets/wallet_card_occlusion.dart';
import '../widgets/wallet_card_paint_cache.dart';
import '../widgets/wallet_card_shadow.dart';

class _WalletCardRevealClipper extends CustomClipper<Rect> {
  const _WalletCardRevealClipper(this.visibleHeight);
  final double visibleHeight;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-24, -24, size.width + 24,
      visibleHeight >= size.height ? size.height + 28 : visibleHeight);

  @override
  bool shouldReclip(covariant _WalletCardRevealClipper oldClipper) =>
      oldClipper.visibleHeight != visibleHeight;
}

/// Cut out the next card's rounded face, rather than truncating the flight
/// at its top edge. The selected card keeps its exposed corners and shadows.
class _WalletCardFlightClipper extends CustomClipper<Path> {
  const _WalletCardFlightClipper(this.occludingCard, this.cornerRadius);

  final Rect? occludingCard;
  final double cornerRadius;

  @override
  Path getClip(Size size) {
    final bounds = Rect.fromLTRB(-24, -24, size.width + 24, size.height + 28);
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds);
    final occluder = occludingCard;
    if (occluder != null && occluder.overlaps(bounds)) {
      // One rounded hole for the moving card only; no PathOperation.difference
      // and no changes to the collection's cached occlusion geometry.
      path.addRRect(
          RRect.fromRectAndRadius(occluder, Radius.circular(cornerRadius)));
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _WalletCardFlightClipper oldClipper) =>
      oldClipper.occludingCard != occludingCard ||
      oldClipper.cornerRadius != cornerRadius;
}

/// 账户交易明细模型
class AccountTransaction {
  final String title;
  final String time;
  final String category;
  final double amount;
  final IconData icon;

  const AccountTransaction({
    required this.title,
    required this.time,
    required this.category,
    required this.amount,
    required this.icon,
  });
}

/// 资金账户数据模型（对应 Apple Wallet 卡片）
class AccountItem {
  final String id;
  final String name; // 账户全称
  final String provider; // 机构名称
  final String cardType; // 属性，如：信用卡 · 金卡 / 电子钱包
  final String cardNumber; // 卡号尾号或标识
  final double balance; // 当前余额
  final String providerNotice; // 描述文案（图2：来自XX提示语）
  final List<Color> gradientColors; // 卡片渐变主色
  final Color textColor;
  final Color subtextColor;
  final IconData brandIcon;
  final Color brandColor;
  final String? tierBadge; // 如 Gold / Platinum / Premier 等
  final bool isPuppyCard; // 是否为图2所示的秋日线条小狗特色卡
  final List<AccountTransaction> transactions;

  const AccountItem({
    required this.id,
    required this.name,
    required this.provider,
    required this.cardType,
    required this.cardNumber,
    required this.balance,
    required this.providerNotice,
    required this.gradientColors,
    required this.textColor,
    required this.subtextColor,
    required this.brandIcon,
    required this.brandColor,
    this.tierBadge,
    this.isPuppyCard = false,
    required this.transactions,
  });
}

class AssetsPage extends StatefulWidget {
  final bool isDark;
  final ValueChanged<bool>? onDetailModeChanged;
  final ValueChanged<double>? onDetailProgressChanged;

  const AssetsPage({
    super.key,
    required this.isDark,
    this.onDetailModeChanged,
    this.onDetailProgressChanged,
  });

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _detailTransition;
  final _pageKey = GlobalKey();
  final _detailCardKey = GlobalKey();
  final _overviewKey = GlobalKey();
  final _cardSliverKey = GlobalKey();
  // Single-variable switch for comparing the collection's covered pixels.
  static const _clipCoveredCardPixels = true;
  final _cardOcclusionGeometry = WalletCardOcclusionGeometry();
  // Keep the occlusion switch unchanged when comparing shared shadow images.
  static const _cacheCollectionShadows = true;
  final _collectionShadowCache = WalletCardShadowCache();
  // Compare the texture optimizations independently; earlier switches stay put.
  static const _cacheCollectionCardPaint = true;
  static const _compactCollectionTextures = true;
  static const _batchCollectionTextureDraws = true;
  static const _reuseRecentCollectionTextures = true;
  // Keep mounted collection textures pinned through detail/flight transitions.
  static const _retainCollectionDuringDetail = true;
  // Keep the old cleanup-delay diagnostic off for the opacity comparison.
  static const _returnCleanupDelayMs = int.fromEnvironment(
    'WALLET_RETURN_CLEANUP_DELAY_MS',
    defaultValue: 0,
  );
  // Keep flight occlusion identical when comparing return animation timing.
  static const _roundedFlightClip = bool.fromEnvironment(
    'WALLET_ROUNDED_FLIGHT_CLIP',
    defaultValue: true,
  );
  Timer? _returnCleanupTimer;
  bool _isReturning = false;
  int _returnRunId = 0;
  int _currentReturnCleanupDelayMs = 0;
  // Set to 128 only for the capacity diagnostic; compact textures default to 64.
  static const _collectionPaintCacheMiB = 64;
  final _cardPaintCacheBudget = WalletCardPaintCacheBudget(
    maxPixelBytes: _collectionPaintCacheMiB * 1024 * 1024,
    maxIdleEntries: _reuseRecentCollectionTextures ? 4 : 0,
  );
  static const _maxCachedCardFaces = 32;
  final _cardFaces = LinkedHashMap<
      ({AccountItem account, bool hideBalance, bool isolateCardFace}),
      Widget>();
  final _stackScrollController = ScrollController();
  final _detailScrollController = ScrollController(keepScrollOffset: false);
  Rect? _sourceCardRect;
  Rect? _detailCardRect;
  Rect? _overviewSourceRect;
  // 当前展开查看详情的账户 ID（null 表示多卡堆叠视图）
  String? _selectedAccountId;
  int? _selectedCardIndex;
  // 是否隐藏资产金额
  bool _hideBalance = false;
  // 是否关闭了详情卡片下的提示小条
  final Set<String> _dismissedNotices = {};

  @override
  void initState() {
    super.initState();
    _detailTransition = AnimationController(
      vsync: this,
      duration: AccountDetailMotion.duration,
      reverseDuration: AccountDetailMotion.reverseDuration,
    )
      ..addListener(() {
        widget.onDetailProgressChanged?.call(_detailTransition.value);
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.dismissed &&
            _selectedAccountId != null &&
            _isReturning) {
          _onReturnPoseSettled();
        } else if (status == AnimationStatus.completed) {
          setState(() {});
        }
      });
  }

  void _traceReturn(String name) {
    developer.Timeline.instantSync(name, arguments: {
      'runId': _returnRunId,
      'accountId': _selectedAccountId ?? '',
      'cleanupDelayMs': _currentReturnCleanupDelayMs,
      'reverseDurationMs': AccountDetailMotion.reverseDuration.inMilliseconds,
      'roundedFlightClip': _roundedFlightClip,
      'retainDockTransformLayer': AccountDetailMotion.retainDockTransformLayer,
      'deferDockOpaqueOneFrame': AccountDetailMotion.deferDockOpaqueOneFrame,
      'deferAddOpaqueOneFrame': AccountDetailMotion.deferAddOpaqueOneFrame,
      'revealDockAfterCards': false,
    });
  }

  void _onReturnPoseSettled() {
    _traceReturn('WalletReturn.PoseSettled');
    final runId = _returnRunId;
    if (_currentReturnCleanupDelayMs == 0) {
      _finishReturn(runId);
      return;
    }
    // Keep the original flight and overview at progress 0, with the original
    // collection card still hidden. No additional animation or frame loop runs.
    _returnCleanupTimer?.cancel();
    _returnCleanupTimer = Timer(
      Duration(milliseconds: _currentReturnCleanupDelayMs),
      () => _finishReturn(runId),
    );
  }

  void _finishReturn(int runId) {
    if (!mounted ||
        runId != _returnRunId ||
        !_isReturning ||
        !_detailTransition.isDismissed ||
        _selectedAccountId == null) {
      return;
    }
    _returnCleanupTimer?.cancel();
    _returnCleanupTimer = null;
    final accountId = _selectedAccountId!;
    // This marks the state commit, not completion of raster/GPU cleanup.
    _traceReturn('WalletReturn.CleanupStateCommit');
    setState(() {
      _isReturning = false;
      _selectedAccountId = null;
      _selectedCardIndex = null;
      _sourceCardRect = _detailCardRect = _overviewSourceRect = null;
    });
    widget.onDetailModeChanged?.call(false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || runId != _returnRunId) return;
      developer.Timeline.instantSync(
        'WalletReturn.CleanupFrameBuilt',
        arguments: {
          'runId': runId,
          'accountId': accountId,
        },
      );
    });
  }

  Rect? _cardRect(GlobalKey? key) {
    final page = _pageKey.currentContext?.findRenderObject();
    final card = key?.currentContext?.findRenderObject();
    if (page is! RenderBox || card is! RenderBox || !card.hasSize) {
      return null;
    }
    return card.localToGlobal(Offset.zero, ancestor: page) & card.size;
  }

  Rect? _stackedCardRect(int? index) {
    if (index == null) return null;
    final page = _pageKey.currentContext?.findRenderObject();
    final sliver = _cardSliverKey.currentContext?.findRenderObject();
    if (page == null || sliver is! RenderSliverWalletCards) return null;
    return sliver.cardRect(index, ancestor: page);
  }

  double _stackExitOffset(Size viewport) => _selectedCardIndex == null
      ? 0
      : AccountDetailMotion.stackExit.transform(_detailTransition.value) *
          (viewport.height + 200);

  double get _selectedCardTravelOffset =>
      (_detailCardRect?.top ?? 54) - (_sourceCardRect?.top ?? 260);

  void _openDetail(int index) {
    if (_selectedAccountId != null || _detailTransition.isAnimating) return;
    final source = _stackedCardRect(index);
    var overview = _cardRect(_overviewKey);
    final page = _pageKey.currentContext?.findRenderObject() as RenderBox?;
    if (overview != null &&
        (overview.bottom <= 0 ||
            overview.top >= (page?.size.height ?? double.infinity))) {
      overview = null;
    }
    setState(() {
      _selectedAccountId = _accounts[index].id;
      _selectedCardIndex = index;
      _sourceCardRect = source;
      _detailCardRect = null;
      _overviewSourceRect = overview;
    });
    widget.onDetailModeChanged?.call(true);
    if (MediaQuery.disableAnimationsOf(context)) {
      _detailTransition.value = 1;
    } else {
      _detailTransition.forward(from: 0);
    }
  }

  void _closeDetail() {
    if (_selectedAccountId == null ||
        _detailTransition.isAnimating ||
        _isReturning) {
      return;
    }
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final page = _pageKey.currentContext?.findRenderObject() as RenderBox?;
    final scrollOffset = _detailScrollController.hasClients
        ? _detailScrollController.offset
        : 0.0;
    final viewportWidth = page?.size.width ?? AppLayout.referenceWidth;
    final stackedCardRect = _stackedCardRect(_selectedCardIndex);
    final overviewRect = _cardRect(_overviewKey);
    setState(() {
      _isReturning = true;
      _returnRunId++;
      _currentReturnCleanupDelayMs =
          disableAnimations ? 0 : math.max(0, _returnCleanupDelayMs);
      if (stackedCardRect != null && page != null) {
        // The Sliver keeps resting coordinates while only its card layers move.
        _sourceCardRect = stackedCardRect;
        if (_overviewSourceRect != null && overviewRect != null) {
          _overviewSourceRect =
              overviewRect.shift(Offset(0, _stackExitOffset(page.size)));
        }
      }
      _detailCardRect = _cardRect(_detailCardKey) ??
          Rect.fromLTWH(
              AppLayout.cardInset,
              54 - scrollOffset,
              AppLayout.cardWidth(viewportWidth),
              AppLayout.detailCardHeight(viewportWidth));
    });
    _traceReturn('WalletReturn.Begin');
    if (disableAnimations) {
      _detailTransition.value = 0;
    } else {
      _detailTransition.reverse();
    }
  }

  @override
  void dispose() {
    _returnCleanupTimer?.cancel();
    _returnRunId++;
    _detailTransition.dispose();
    _stackScrollController.dispose();
    _detailScrollController.dispose();
    _cardFaces.clear();
    _cardOcclusionGeometry.clear();
    _collectionShadowCache.clear();
    _cardPaintCacheBudget.dispose();
    super.dispose();
  }

  // 预置丰富逼真的 50 张 Apple Wallet 卡片数据集（极限压力测试模式）
  late final List<AccountItem> _accounts = [
    for (var i = 0; i < 5; i++)
      for (final a in _allAccounts)
        AccountItem(
          id: i == 0 ? a.id : '${a.id}_$i',
          name: i == 0 ? a.name : '${a.name} (${i + 1}号)',
          provider: a.provider,
          cardType: a.cardType,
          cardNumber: a.cardNumber,
          balance: a.balance,
          providerNotice: a.providerNotice,
          gradientColors: a.gradientColors,
          textColor: a.textColor,
          subtextColor: a.subtextColor,
          brandIcon: a.brandIcon,
          brandColor: a.brandColor,
          tierBadge: a.tierBadge,
          isPuppyCard: a.isPuppyCard,
          transactions: a.transactions,
        ),
  ];
  late final List<AccountItem> _allAccounts = [
    // 1. 图2同款：中国银行线条小狗秋日金卡
    AccountItem(
      id: 'boc_puppy',
      name: '中国银行 · 线条小狗金卡',
      provider: '中国银行',
      cardType: '信用卡 · 秋日金卡',
      cardNumber: '•••• 2088',
      balance: 16850.00,
      providerNotice: '“线条小狗金卡秋日版” 可用于日常消费与闪付。',
      gradientColors: const [
        Color(0xFFFBE49D),
        Color(0xFFF6C869),
        Color(0xFFE5A83B),
      ],
      textColor: const Color(0xFF6A4706),
      subtextColor: const Color(0xFF987227),
      brandIcon: Icons.account_balance,
      brandColor: const Color(0xFFB31D23),
      tierBadge: 'Gold',
      isPuppyCard: true,
      transactions: const [
        AccountTransaction(
          title: '星巴克秋季限定拿铁',
          time: '今天 14:20 · 餐饮',
          category: '餐饮',
          amount: -38.00,
          icon: Icons.coffee,
        ),
        AccountTransaction(
          title: '盒马鲜生生鲜采买',
          time: '10月7日 19:45 · 日用',
          category: '日用',
          amount: -156.80,
          icon: Icons.shopping_basket_outlined,
        ),
        AccountTransaction(
          title: '奈雪的茶烘焙点心',
          time: '10月6日 12:10 · 餐饮',
          category: '餐饮',
          amount: -29.00,
          icon: Icons.restaurant_outlined,
        ),
        AccountTransaction(
          title: '万达院线电影票两张',
          time: '10月4日 20:30 · 娱乐',
          category: '娱乐',
          amount: -84.00,
          icon: Icons.movie_outlined,
        ),
        AccountTransaction(
          title: '信用卡还款入账',
          time: '10月1日 10:00 · 还款',
          category: '转账',
          amount: 5000.00,
          icon: Icons.check_circle_outline,
        ),
      ],
    ),

    // 2. 微信支付零钱通
    AccountItem(
      id: 'wechat_pay',
      name: '微信支付 · 零钱通',
      provider: '微信支付',
      cardType: '电子钱包 · 随存随取',
      cardNumber: '零钱通账户',
      balance: 8420.50,
      providerNotice: '已开启微信自动扣款与转账提现免手续费权益。',
      gradientColors: const [
        Color(0xFF07C160),
        Color(0xFF049C4C),
      ],
      textColor: Colors.white,
      subtextColor: const Color(0xFFE2F8EB),
      brandIcon: Icons.chat_bubble_outline_rounded,
      brandColor: Colors.white,
      tierBadge: '微信零钱',
      transactions: const [
        AccountTransaction(
          title: '瑞幸咖啡提神冰美式',
          time: '今天 09:30 · 餐饮',
          category: '餐饮',
          amount: -18.00,
          icon: Icons.local_cafe_outlined,
        ),
        AccountTransaction(
          title: '微信好友群转账收入',
          time: '昨天 20:15 · 转账',
          category: '转账',
          amount: 120.00,
          icon: Icons.attach_money_rounded,
        ),
        AccountTransaction(
          title: '全家便利店日常补给',
          time: '10月5日 18:20 · 日用',
          category: '日用',
          amount: -16.50,
          icon: Icons.storefront_outlined,
        ),
      ],
    ),

    // 3. 支付宝余额宝
    AccountItem(
      id: 'alipay',
      name: '支付宝 · 余额宝',
      provider: '支付宝',
      cardType: '电子钱包 · 理财与支付',
      cardNumber: '余额宝 · 专户',
      balance: 5310.20,
      providerNotice: '已开通天猫淘宝快捷支付与生活缴费代扣。',
      gradientColors: const [
        Color(0xFF1677FF),
        Color(0xFF0754CB),
      ],
      textColor: Colors.white,
      subtextColor: const Color(0xFFD3E7FF),
      brandIcon: Icons.payments_outlined,
      brandColor: Colors.white,
      tierBadge: 'Alipay',
      transactions: const [
        AccountTransaction(
          title: '余额宝日收益结算',
          time: '10月7日 08:00 · 理财',
          category: '理财',
          amount: 1.24,
          icon: Icons.trending_up,
        ),
        AccountTransaction(
          title: '淘宝数码配件旗舰店',
          time: '10月5日 21:10 · 购物',
          category: '购物',
          amount: -89.00,
          icon: Icons.shopping_bag_outlined,
        ),
      ],
    ),

    // 4. HSBC 汇丰银行（图 1 顶部黑金六边形卡）
    AccountItem(
      id: 'hsbc_premier',
      name: 'HSBC 汇丰银行 · 卓越理财',
      provider: 'HSBC',
      cardType: '信用卡 · World Elite',
      cardNumber: '•••• 8820',
      balance: 32600.00,
      providerNotice: '全球多币种免外汇兑换费，尊享机场全球贵宾厅。',
      gradientColors: const [
        Color(0xFF262629),
        Color(0xFF171719),
        Color(0xFF0F0F11),
      ],
      textColor: Colors.white,
      subtextColor: const Color(0xFFA5A5AB),
      brandIcon: Icons.diamond_outlined,
      brandColor: const Color(0xFFDB0011),
      tierBadge: 'Premier',
      transactions: const [
        AccountTransaction(
          title: '国泰航空机票改签',
          time: '10月6日 16:30 · 旅行',
          category: '旅行',
          amount: -620.00,
          icon: Icons.flight_takeoff_outlined,
        ),
        AccountTransaction(
          title: '境外餐饮商务宴请',
          time: '10月3日 20:00 · 餐饮',
          category: '餐饮',
          amount: -1280.00,
          icon: Icons.wine_bar_outlined,
        ),
      ],
    ),

    // 5. Wise 极简多币种卡（图 1 标志性翠绿卡）
    AccountItem(
      id: 'wise_multi',
      name: 'Wise · 多币种国际卡',
      provider: 'Wise',
      cardType: '借记卡 · 40+ 币种',
      cardNumber: '•••• 3319',
      balance: 12450.80,
      providerNotice: '支持以实时真实汇率进行 40+ 种海外货币即时划扣。',
      gradientColors: const [
        Color(0xFF9FE870),
        Color(0xFF86D654),
      ],
      textColor: const Color(0xFF163300),
      subtextColor: const Color(0xFF2E5E0B),
      brandIcon: Icons.bolt_rounded,
      brandColor: const Color(0xFF163300),
      tierBadge: 'Wise',
      transactions: const [
        AccountTransaction(
          title: 'GitHub Copilot 订阅',
          time: '10月4日 03:00 · 订阅',
          category: '软件',
          amount: -72.00,
          icon: Icons.code_rounded,
        ),
        AccountTransaction(
          title: '海外多币种转换入账',
          time: '10月2日 14:15 · 汇兑',
          category: '理财',
          amount: 3200.00,
          icon: Icons.currency_exchange,
        ),
      ],
    ),

    // 6. Suica 西瓜卡（图 1 JR东日本企鹅卡）
    AccountItem(
      id: 'suica_ic',
      name: 'Suica · 西瓜交通卡',
      provider: 'JR 东日本',
      cardType: 'IC 交通储值卡 · 闪付',
      cardNumber: 'JE •••• 9012',
      balance: 315.00,
      providerNotice: '日本关东铁道及全国互通交通、便利店免密极速触碰支付。',
      gradientColors: const [
        Color(0xFF009944),
        Color(0xFF007A33),
      ],
      textColor: Colors.white,
      subtextColor: const Color(0xFFDCFCE7),
      brandIcon: Icons.train_outlined,
      brandColor: Colors.white,
      tierBadge: 'Suica+',
      transactions: const [
        AccountTransaction(
          title: '东京山手线电车划扣',
          time: '10月7日 18:20 · 交通',
          category: '交通',
          amount: -12.50,
          icon: Icons.train_outlined,
        ),
        AccountTransaction(
          title: '罗森便利店简餐饮料',
          time: '10月5日 12:40 · 餐饮',
          category: '餐饮',
          amount: -28.00,
          icon: Icons.local_convenience_store_outlined,
        ),
      ],
    ),

    // 7. 中国银行白金借记卡（图 1 浅蓝青渐变）
    AccountItem(
      id: 'boc_debit',
      name: '中国银行 · 白金借记卡',
      provider: '中国银行',
      cardType: '借记卡 · 白金级',
      cardNumber: '•••• 6829',
      balance: 28500.00,
      providerNotice: '主薪资发放账户，提供活期增利理财服务。',
      gradientColors: const [
        Color(0xFF0093E9),
        Color(0xFF80D0C7),
      ],
      textColor: Colors.white,
      subtextColor: const Color(0xFFE0F7FA),
      brandIcon: Icons.account_balance,
      brandColor: const Color(0xFFB31D23),
      tierBadge: 'Platinum',
      transactions: const [
        AccountTransaction(
          title: '公司秋季薪酬发放',
          time: '10月1日 10:00 · 收入',
          category: '收入',
          amount: 18500.00,
          icon: Icons.monetization_on_outlined,
        ),
        AccountTransaction(
          title: '每月房租自动划扣',
          time: '9月30日 15:30 · 居住',
          category: '房租',
          amount: -3800.00,
          icon: Icons.home_outlined,
        ),
      ],
    ),

    // 8. 招商银行经典白金卡（图 1 黑金质感卡）
    AccountItem(
      id: 'cmb_credit',
      name: '招商银行 · 经典白金卡',
      provider: '招商银行',
      cardType: '信用卡 · 经典白金',
      cardNumber: '•••• 5288',
      balance: -2450.00,
      providerNotice: '还款日：每月20日 · 账单正常 · 尊享机场贵宾礼遇。',
      gradientColors: const [
        Color(0xFF2B2B30),
        Color(0xFF18181A),
      ],
      textColor: const Color(0xFFF2E2C4),
      subtextColor: const Color(0xFF9E9585),
      brandIcon: Icons.credit_card_rounded,
      brandColor: const Color(0xFFE2231A),
      tierBadge: 'Classic',
      transactions: const [
        AccountTransaction(
          title: '苹果在线商店官方配件',
          time: '10月6日 18:40 · 数码',
          category: '购物',
          amount: -299.00,
          icon: Icons.devices_other_outlined,
        ),
        AccountTransaction(
          title: '黑珍珠餐厅双人晚宴',
          time: '10月4日 21:00 · 餐饮',
          category: '餐饮',
          amount: -328.00,
          icon: Icons.local_dining_outlined,
        ),
      ],
    ),

    // 9. 清华大学校园一卡通（图 1 校园卡）
    AccountItem(
      id: 'tsinghua_campus',
      name: '清华大学 · 校园一卡通',
      provider: '清华大学',
      cardType: '校园卡 · 师生消费',
      cardNumber: 'THU •••• 2024',
      balance: 628.00,
      providerNotice: '用于校内食堂就餐、图书馆门禁、校园巴士及超市消费。',
      gradientColors: const [
        Color(0xFF660874),
        Color(0xFF3B2F7E),
      ],
      textColor: Colors.white,
      subtextColor: const Color(0xFFE9D8FD),
      brandIcon: Icons.school_outlined,
      brandColor: Colors.white,
      tierBadge: 'Campus',
      transactions: const [
        AccountTransaction(
          title: '学子餐厅午餐套餐',
          time: '今天 12:10 · 餐饮',
          category: '餐饮',
          amount: -18.50,
          icon: Icons.lunch_dining_outlined,
        ),
        AccountTransaction(
          title: '校园一卡通银校转账',
          time: '10月1日 08:30 · 充值',
          category: '充值',
          amount: 200.00,
          icon: Icons.account_balance_wallet_outlined,
        ),
      ],
    ),

    // 10. 八达通动漫限定卡（图 1 底部动漫卡）
    AccountItem(
      id: 'octopus_transit',
      name: '八达通 · 动漫限定 NFC 卡',
      provider: '八达通',
      cardType: '交通卡 · NFC 闪付',
      cardNumber: 'OCT •••• 5590',
      balance: 260.00,
      providerNotice: '支持香港地铁、巴士、便利店及自动售货机一贴即付。',
      gradientColors: const [
        Color(0xFF38BDF8),
        Color(0xFF6366F1),
        Color(0xFFF472B6),
      ],
      textColor: Colors.white,
      subtextColor: const Color(0xFFF0F9FF),
      brandIcon: Icons.directions_subway_outlined,
      brandColor: Colors.white,
      tierBadge: 'Octopus',
      transactions: const [
        AccountTransaction(
          title: '城市地铁出站划扣',
          time: '今天 18:40 · 交通',
          category: '交通',
          amount: -6.00,
          icon: Icons.subway_outlined,
        ),
        AccountTransaction(
          title: '交通卡自动充值入账',
          time: '10月4日 19:10 · 充值',
          category: '充值',
          amount: 100.00,
          icon: Icons.add_card_outlined,
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final selectedAccount =
        _selectedCardIndex == null ? null : _accounts[_selectedCardIndex!];

    return PopScope(
      canPop: selectedAccount == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _closeDetail();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final overview =
              selectedAccount != null && _overviewSourceRect != null
                  ? RepaintBoundary(child: _buildOverviewCard(context))
                  : null;
          final detail = selectedAccount == null
              ? null
              : _buildAccountDetailView(
                  context, selectedAccount, constraints.biggest);
          return AnimatedBuilder(
            animation: _detailTransition,
            child: _buildStackedCardsView(context, constraints.biggest),
            builder: (context, stackedCards) {
              final progress = _detailTransition.value;
              final lowerCardsOffset = _stackExitOffset(constraints.biggest);
              final inFlight =
                  selectedAccount != null && !_detailTransition.isCompleted;
              final hideStack = selectedAccount != null &&
                  progress >= AccountDetailMotion.secondStageEnd;
              return Stack(
                key: _pageKey,
                fit: StackFit.expand,
                children: [
                  IgnorePointer(
                    ignoring: selectedAccount != null,
                    child: ExcludeSemantics(
                      excluding: selectedAccount != null,
                      // Keep the scroll view mounted through the entire
                      // transition so its position and return geometry survive.
                      child: TickerMode(
                        enabled: !hideStack,
                        child: Offstage(
                          offstage: hideStack,
                          child: stackedCards!,
                        ),
                      ),
                    ),
                  ),
                  if (inFlight && _overviewSourceRect != null)
                    _buildMovingOverview(overview!),
                  if (inFlight)
                    _buildFlyingCard(
                        selectedAccount, constraints.biggest, lowerCardsOffset),
                  if (selectedAccount != null)
                    IgnorePointer(
                      key: const ValueKey('account_detail_layer'),
                      ignoring: _detailTransition.isAnimating || _isReturning,
                      child: detail,
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildFlyingCard(
      AccountItem account, Size viewport, double lowerCardsOffset) {
    final cardWidth = AppLayout.cardWidth(viewport.width);
    final source = _sourceCardRect ??
        Rect.fromLTWH(AppLayout.cardInset, 260, cardWidth,
            AppLayout.stackedCardHeight(viewport.width));
    final destination = _detailCardRect ??
        Rect.fromLTWH(AppLayout.cardInset, 54, cardWidth,
            AppLayout.detailCardHeight(viewport.width));
    final progress = _detailTransition.value;
    final travel = AccountDetailMotion.cardTravel.transform(progress);
    final rect = Rect.lerp(source, destination, travel)!;
    final isLastCard = _accounts.last.id == account.id;
    final nextCardTop = source.top +
        AppLayout.cardPeekOffset(viewport.width) +
        lowerCardsOffset -
        rect.top;
    final occludingCard = isLastCard
        ? null
        : Rect.fromLTWH(
            source.left - rect.left, nextCardTop, source.width, source.height);
    final card = _buildWalletCard(
      account: account,
      isStacked: true,
      isolateCardFace: true,
      height: rect.height,
      detailProgress: travel,
    );
    // Retain the old clip only for independent visual diagnosis. R1 A/B keeps
    // the rounded clip enabled in both runs and leaves all card caches intact.
    final visibleHeight = isLastCard
        ? rect.height
        : nextCardTop.clamp(0.0, rect.height).toDouble();
    return Positioned.fromRect(
      key: const ValueKey('wallet_card_flight'),
      rect: rect,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: _roundedFlightClip
              ? ClipPath(
                  clipper: _WalletCardFlightClipper(
                      occludingCard, _cardOcclusionGeometry.cornerRadius),
                  child: card,
                )
              : ClipRect(
                  clipper: _WalletCardRevealClipper(visibleHeight),
                  child: card,
                ),
        ),
      ),
    );
  }

  // ==========================================
  // 1. Apple Pay 堆叠卡片模式（图 1 效果）
  // ==========================================
  Widget _buildOverviewCard(BuildContext context) {
    final inkColor = widget.isDark ? AppTheme.darkInk : AppTheme.lightInk;
    final mutedColor = widget.isDark ? AppTheme.darkMuted : AppTheme.lightMuted;
    final surfaceColor =
        widget.isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final cardBorderColor =
        widget.isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);

    // 计算总资产与负债
    double totalAssets = 0;
    double totalDebts = 0;
    for (final acc in _accounts) {
      if (acc.balance >= 0) {
        totalAssets += acc.balance;
      } else {
        totalDebts += acc.balance.abs();
      }
    }
    final netAssets = totalAssets - totalDebts;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cardBorderColor, width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: widget.isDark ? 0.25 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部小行：标题与隐蔽眼睛（无前置图标，文字从最左侧开始对齐）
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '净资产总值',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: mutedColor,
                  letterSpacing: 0.3,
                ),
              ),
              // 隐私显隐眼睛小按钮
              GestureDetector(
                onTap: () => setState(() => _hideBalance = !_hideBalance),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: inkColor.withValues(alpha: 0.06),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _hideBalance
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 16,
                    color: inkColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // 核心金额大字（严格左对齐）
          Text(
            _hideBalance ? '••••••••' : '¥ ${_formatNumber(netAssets)}',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.0,
              color: inkColor,
            ),
          ),
          const SizedBox(height: 14),

          // 底部总资产与总负债（左侧严格垂直对齐，无内缩偏移）
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '总资产',
                      style: TextStyle(fontSize: 10, color: mutedColor),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _hideBalance ? '••••' : '¥${_formatNumber(totalAssets)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: inkColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '总负债',
                      style: TextStyle(fontSize: 10, color: mutedColor),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _hideBalance ? '••••' : '-¥${_formatNumber(totalDebts)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE54D2E),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMovingOverview(Widget overview) {
    final source = _overviewSourceRect!;
    final progress = _detailTransition.value;
    final cardRise = ((_sourceCardRect?.top ?? source.bottom) - 54).abs();
    final exitDistance = math.max(source.bottom + 24, cardRise);
    // The same position function runs backwards when returning to the stack.
    final offset =
        -AccountDetailMotion.cardTravel.transform(progress) * exitDistance;
    return Positioned.fromRect(
      key: const ValueKey('overview_flight'),
      rect: source.shift(Offset(0, offset)),
      child: IgnorePointer(
        child: ExcludeSemantics(child: overview),
      ),
    );
  }

  bool _isCardOpaque(int index) =>
      _accounts[index].gradientColors.every((color) => color.a >= 1);

  late final Map<String, int> _accountIndexes = {
    for (var index = 0; index < _accounts.length; index++)
      _accounts[index].id: index,
  };

  Widget _buildStackedCardsView(BuildContext context, Size viewport) {
    final viewportWidth = viewport.width;
    final mutedColor = widget.isDark ? AppTheme.darkMuted : AppTheme.lightMuted;
    final cardPeekOffset = AppLayout.cardPeekOffset(viewportWidth);
    final cardHeight = AppLayout.stackedCardHeight(viewportWidth);
    final retainCollectionPaint =
        _retainCollectionDuringDetail || _selectedCardIndex == null;

    return CustomScrollView(
      key: const ValueKey('stacked_cards_view'),
      controller: _stackScrollController,
      physics: const BouncingScrollPhysics(),
      scrollCacheExtent: ScrollCacheExtent.pixels(cardPeekOffset * 2),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverToBoxAdapter(
            child: AnimatedBuilder(
              animation: _detailTransition,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, -_stackExitOffset(viewport)),
                child: child,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RepaintBoundary(
                    key: _overviewKey,
                    child: Visibility(
                      visible: _selectedAccountId == null,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: _buildOverviewCard(context),
                    ),
                  ),

                  // 分隔间距与分类小标题，与底下的卡片清晰区分
                  const SizedBox(height: 22),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '资金账户与卡包',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                          ),
                        ),
                        Text(
                          '共 ${_accounts.length} 张',
                          style: TextStyle(
                            fontSize: 11,
                            color: mutedColor.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverWalletCards(
            key: _cardSliverKey,
            itemCount: _accounts.length,
            cardExtent: cardHeight,
            peekExtent: cardPeekOffset,
            cornerRadius: _cardOcclusionGeometry.cornerRadius,
            shadowExtent: _cardOcclusionGeometry.shadowExtent,
            hiddenIndex: _selectedCardIndex,
            exitAnimation: _detailTransition,
            exitDistance: viewport.height + 200,
            selectedTravelOffset: _selectedCardTravelOffset,
            isCardOpaque: _isCardOpaque,
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final account = _accounts[index];
                if (!_retainCollectionDuringDetail &&
                    index == _selectedCardIndex) {
                  return SizedBox(
                      key: ValueKey(account.id), height: cardHeight);
                }
                // The Sliver hides the extracted card without recycling its
                // node. Ordinary cards keep their original mask, shadow and
                // texture throughout the translated stack's entry/exit.
                final clipCoveredPixels = _clipCoveredCardPixels &&
                    retainCollectionPaint &&
                    index + 1 < _accounts.length &&
                    _isCardOpaque(index + 1);
                return GestureDetector(
                  key: ValueKey(account.id),
                  onTap: () => _openDetail(index),
                  child: Stack(
                    fit: StackFit.passthrough,
                    clipBehavior: Clip.none,
                    children: [
                      WalletCardCachedPaint(
                        key: const ValueKey('collection_card_texture'),
                        enabled:
                            _cacheCollectionCardPaint && retainCollectionPaint,
                        accountId: account.id,
                        compact: _compactCollectionTextures,
                        batchDraws: _batchCollectionTextureDraws,
                        contentVersion: (
                          account: account,
                          hideBalance: _hideBalance,
                          isDark: widget.isDark,
                          cachedShadow: _cacheCollectionShadows,
                        ),
                        budget: _cardPaintCacheBudget,
                        geometry: _cardOcclusionGeometry,
                        occluderOffset:
                            clipCoveredPixels ? cardPeekOffset : null,
                        child: WalletCardOcclusion(
                          geometry: _cardOcclusionGeometry,
                          occluderOffset:
                              clipCoveredPixels ? cardPeekOffset : null,
                          child: _buildWalletCard(
                            account: account,
                            isStacked: true,
                            // The Sliver isolates the whole card and its shadow.
                            isolateCardFace: false,
                            cacheCollectionShadow: _cacheCollectionShadows &&
                                retainCollectionPaint,
                            height: cardHeight,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
              childCount: _accounts.length,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: true,
              findChildIndexCallback: (key) =>
                  key is ValueKey<String> ? _accountIndexes[key.value] : null,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 105)),
      ],
    );
  }

  // ==========================================
  // 2. 账户详情与消费明细模式（图 2 / 图 3 效果）
  // ==========================================
  Widget _buildAccountDetailView(
      BuildContext context, AccountItem account, Size viewport) {
    final inkColor = widget.isDark ? AppTheme.darkInk : AppTheme.lightInk;
    final mutedColor = widget.isDark ? AppTheme.darkMuted : AppTheme.lightMuted;
    final surfaceColor =
        widget.isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final lineColor =
        widget.isDark ? const Color(0xFF2C2C2E) : AppTheme.lightLine;

    final showNotice = !_dismissedNotices.contains(account.id);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (details) {
        // 右滑返回卡片堆叠模式（左滑不响应，防止误操作切页）
        if ((details.primaryVelocity ?? 0) > 260) {
          _closeDetail();
        }
      },
      child: Stack(
        key: ValueKey('detail_${account.id}'),
        children: [
          // 1. 底层：可纵向滚动的账单流水内容（顶部留出间距避让悬浮按钮）
          ListView(
            controller: _detailScrollController,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 54, 16, 40),
            children: [
              // 上方：选中的全幅卡片展示（图2 上部）
              RepaintBoundary(
                key: _detailCardKey,
                child: AnimatedBuilder(
                  animation: _detailTransition,
                  builder: (context, child) => Opacity(
                    opacity: _detailTransition.isCompleted ? 1 : 0,
                    child: child,
                  ),
                  child: _buildWalletCard(
                    account: account,
                    isStacked: false,
                    isolateCardFace: true,
                    height: AppLayout.detailCardHeight(viewport.width),
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _detailTransition,
                builder: (context, child) {
                  final progress = AccountDetailMotion.contentEntrance
                      .transform(_detailTransition.value);
                  return Opacity(
                    opacity: progress,
                    child: Transform.translate(
                      offset: Offset(0, (1 - progress) * viewport.height * .66),
                      child: child,
                    ),
                  );
                },
                child: RepaintBoundary(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 16),

                      // 图2 同款：卡片下方通知白条「来自：中国银行 “...”」
                      if (showNotice)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: surfaceColor,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            children: [
                              // 银行/机构 Logo 圆标
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: account.brandColor
                                      .withValues(alpha: 0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(account.brandIcon,
                                    size: 20, color: account.brandColor),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '来自：${account.provider}',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: inkColor,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      account.providerNotice,
                                      style: TextStyle(
                                          fontSize: 11, color: mutedColor),
                                    ),
                                  ],
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _dismissedNotices.add(account.id);
                                  });
                                },
                                child: Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: inkColor.withValues(alpha: 0.06),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(Icons.close,
                                      size: 13, color: mutedColor),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (showNotice) const SizedBox(height: 16),

                      // 该账户的余额与基本信息卡片
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: surfaceColor,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '账户当前余额',
                                  style: TextStyle(
                                      fontSize: 12, color: mutedColor),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: inkColor.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    account.cardType,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                      color: inkColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _hideBalance
                                  ? '••••••••'
                                  : '¥ ${_formatNumber(account.balance)}',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.8,
                                color: account.balance < 0
                                    ? const Color(0xFFE54D2E)
                                    : inkColor,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Divider(height: 1, color: lineColor),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _buildQuickActionBtn(
                                  label: account.balance < 0 ? '立即还款' : '充值转入',
                                  icon: Icons.payments_outlined,
                                  inkColor: inkColor,
                                ),
                                _buildQuickActionBtn(
                                  label: '转账汇款',
                                  icon: Icons.swap_horiz_rounded,
                                  inkColor: inkColor,
                                ),
                                _buildQuickActionBtn(
                                  label: '记一笔',
                                  icon: Icons.edit_note_rounded,
                                  inkColor: inkColor,
                                ),
                                _buildQuickActionBtn(
                                  label: '卡片管理',
                                  icon: Icons.settings_outlined,
                                  inkColor: inkColor,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // 消费记录标题
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '近期交易记录',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: inkColor,
                            ),
                          ),
                          Text(
                            '共 ${account.transactions.length} 笔明细',
                            style: TextStyle(fontSize: 11, color: mutedColor),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // 消费记录流水列表
                      if (account.transactions.isEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          alignment: Alignment.center,
                          child: Text('该账户暂无更多流水记录',
                              style:
                                  TextStyle(color: mutedColor, fontSize: 12)),
                        )
                      else
                        ...account.transactions.map((tx) {
                          return _buildTransactionRow(
                            tx: tx,
                            inkColor: inkColor,
                            mutedColor: mutedColor,
                            surfaceColor: surfaceColor,
                          );
                        }),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // 2. 顶层：上下滑动界面时始终保持在原位的液态玻璃操作栏（Pinned Top Bar）
          Positioned(
            top: 8,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 左上角：液态玻璃圆形关闭按钮（点击返回一级）
                AnimatedBuilder(
                  animation: _detailTransition,
                  builder: (context, child) => CenteredControlTransition(
                    progress: AccountDetailMotion.topButtons
                        .transform(_detailTransition.value),
                    isCircular: true,
                    child: child!,
                  ),
                  child: _buildLiquidGlassCircleButton(
                    icon: Icons.close_rounded,
                    onTap: _closeDetail,
                    inkColor: inkColor,
                    isDark: widget.isDark,
                  ),
                ),

                // 右上角：液态玻璃合并胶囊按钮（图 3 同款：搜索 + 更多）
                AnimatedBuilder(
                  animation: _detailTransition,
                  builder: (context, child) => CenteredControlTransition(
                    progress: AccountDetailMotion.topButtons
                        .transform(_detailTransition.value),
                    child: child!,
                  ),
                  child: _buildLiquidGlassCombinedButton(
                    inkColor: inkColor,
                    isDark: widget.isDark,
                    onSearch: () {},
                    onMore: () {},
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 导航栏同款材质：液态玻璃圆形按钮
  Widget _buildLiquidGlassCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    required Color inkColor,
    required bool isDark,
  }) {
    return LiquidGlassSurface(
      isDark: isDark,
      shape: BoxShape.circle,
      width: 38,
      height: 38,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(
            child: Icon(icon, size: 18, color: inkColor),
          ),
        ),
      ),
    );
  }

  /// 导航栏同款材质：液态玻璃合并胶囊按钮（图 3 同款：搜索 + 更多）
  Widget _buildLiquidGlassCombinedButton({
    required Color inkColor,
    required bool isDark,
    VoidCallback? onSearch,
    VoidCallback? onMore,
  }) {
    return LiquidGlassSurface(
      isDark: isDark,
      shape: BoxShape.rectangle,
      borderRadius: BorderRadius.circular(19),
      width: 84,
      height: 38,
      child: Material(
        color: Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius:
                    const BorderRadius.horizontal(left: Radius.circular(19)),
                onTap: onSearch,
                child: Center(
                  child: Icon(Icons.search_rounded, size: 17, color: inkColor),
                ),
              ),
            ),
            Container(
              width: 0.75,
              height: 16,
              color: inkColor.withValues(alpha: isDark ? 0.22 : 0.18),
            ),
            Expanded(
              child: InkWell(
                borderRadius:
                    const BorderRadius.horizontal(right: Radius.circular(19)),
                onTap: onMore,
                child: Center(
                  child:
                      Icon(Icons.more_horiz_rounded, size: 18, color: inkColor),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionBtn({
    required String label,
    required IconData icon,
    required Color inkColor,
  }) {
    return Column(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: inkColor.withValues(alpha: 0.05),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: inkColor),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500, color: inkColor),
        ),
      ],
    );
  }

  Widget _buildTransactionRow({
    required AccountTransaction tx,
    required Color inkColor,
    required Color mutedColor,
    required Color surfaceColor,
  }) {
    final isIncome = tx.amount > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: inkColor.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(tx.icon, size: 18, color: inkColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: inkColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tx.time,
                  style: TextStyle(fontSize: 11, color: mutedColor),
                ),
              ],
            ),
          ),
          Text(
            '${isIncome ? "+" : ""}¥${tx.amount.abs().toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isIncome ? const Color(0xFF34C759) : inkColor,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // 3. 拟物化 Apple Pay 实体质感卡片
  // ==========================================
  Widget _buildWalletCard({
    required AccountItem account,
    required bool isStacked,
    required bool isolateCardFace,
    required double height,
    bool cacheCollectionShadow = false,
    double? detailProgress,
  }) {
    final elevation = detailProgress ?? (isStacked ? 0.0 : 1.0);
    final borderRadius = BorderRadius.circular(20);
    final shadow = BoxShadow(
      color: Colors.black.withValues(alpha: .12 + .10 * elevation),
      blurRadius: 4 + 14 * elevation,
      offset: Offset(0, -1.5 + 9.5 * elevation),
    );
    final face = _walletCardFace(account, isolateCardFace: isolateCardFace);
    if (cacheCollectionShadow) {
      return SizedBox(
        height: height,
        child: WalletCardShadow(
          cache: _collectionShadowCache,
          borderRadius: borderRadius,
          shadow: shadow,
          child: face,
        ),
      );
    }
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [shadow],
      ),
      child: face,
    );
  }

  Widget _walletCardFace(AccountItem account, {required bool isolateCardFace}) {
    // Collection and moving cards share the cache, but need different roots.
    final key = (
      account: account,
      hideBalance: _hideBalance,
      isolateCardFace: isolateCardFace,
    );
    final cached = _cardFaces.remove(key);
    if (cached != null) {
      _cardFaces[key] = cached;
      return cached;
    }
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: account.gradientColors,
          ),
        ),
        child: Stack(
          children: [
            // 卡面信息内容布局（纯净单层模式）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 顶部行：机构标志、卡片名称、芯片/闪付图标及余额
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color:
                                    account.textColor.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                account.brandIcon,
                                size: 15,
                                color: account.textColor,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    account.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: account.textColor,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                  Text(
                                    account.cardType,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w500,
                                      color: account.subtextColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 右侧：NFC闪付与余额露出
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.contactless_outlined,
                            size: 15,
                            color: account.textColor.withValues(alpha: 0.8),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _hideBalance
                                ? '••••'
                                : '¥ ${_formatNumber(account.balance)}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: account.textColor,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  // 卡面下部信息（展开后清晰可见）
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          account.cardNumber,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                            color: account.textColor,
                          ),
                        ),
                      ),
                      if (account.tierBadge != null && !account.isPuppyCard)
                        Text(
                          account.tierBadge!,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: account.textColor.withValues(alpha: 0.8),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final face = isolateCardFace ? RepaintBoundary(child: content) : content;
    _cardFaces[key] = face;
    if (_cardFaces.length > _maxCachedCardFaces) {
      _cardFaces.remove(_cardFaces.keys.first);
    }
    return face;
  }

  String _formatNumber(double num) {
    final isNegative = num < 0;
    final absNum = num.abs();
    final parts = absNum.toStringAsFixed(2).split('.');
    final integerPart = parts[0];
    final decimalPart = parts[1];

    final reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    final formattedInt =
        integerPart.replaceAllMapped(reg, (Match m) => '${m[1]},');
    return '${isNegative ? "-" : ""}$formattedInt.$decimalPart';
  }
}
