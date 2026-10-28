/**
 * CFLark 主页面（单页 + 底部两个页签）
 *
 * 壳层：Stack(渐变背景 + Tabs 撑满 + 顶部覆盖层 Header/ActionBar)
 *  - Tabs 用 barPosition End + barOverlap + barFloatingStyle 拿到系统「沉浸光感」的悬浮胶囊
 *  - 顶部覆盖层用 onAreaChange 测高，内容区按 headerH 让位
 *  - 结果列表必须用 Scroll + Column + ForEach（List 的 layoutWeight 在 TabContent 里撑不满）
 */
import { common, ConfigurationConstant, bundleManager, Want } from '@kit.AbilityKit';
import { promptAction, curves } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial, HdsTabs, HdsTabsFloatingStyle, SystemMaterialParams } from '@kit.UIDesignKit';
import { BarStyle } from '../entryability/EntryAbility';
import { Candidate, ScanConfig, ScanMode, IpVersion, Verdict, Stage, DomainInfo, SpeedScope } from '../core/Types';
import { ConfigStore, ThemeMode, UiConfig, defaultUiConfig, defaultScanConfig, PORT_OPTIONS, LIB_SOURCES, LibSource, maxScanConcurrency, defaultScanConcurrency } from '../core/ConfigStore';
import { I18n, LangMode } from '../core/I18n';
import { UpdateChecker, UpdateStatus, UpdateCheckResult, ReleaseInfo } from '../core/UpdateChecker';
import { Changelog, ChangelogEntry, ChangeItem, ChangeKind } from '../core/Changelog';
import { AppMeta } from '../core/AppMeta';
import { AppBackground } from '../core/AppBackground';
import { Scanner, ScanHooks, CancellationToken, PrecheckResult } from '../core/Scanner';
import { Ranker } from '../core/Ranker';
import { EdgeTunnel, EdgeTunnelConfig, defaultEdgeTunnelConfig, UploadPayload, UploadResult } from '../core/EdgeTunnel';
import { Exporter, ExportFormat, defaultExportOptions } from '../core/Exporter';
import { Geo } from '../core/Geo';
import { DnsService } from '../core/DnsService';
import { FileSaver } from '../core/FileSaver';
import { Diag } from '../core/Diag';
import { picker } from '@kit.CoreFileKit';
import { connection, http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

interface RegionGroup {
  colo: string;
  city: string;
  count: number;
  minLatency: number;
  avgLatency: number;
  items: Candidate[];
}

const OK_C: string = '#10B981';
const WARN_C: string = '#F59E0B';
const BAD_C: string = '#F43F5E';
const PRIMARY: string = '#4F46E5';

// ============================================================================
// 沉浸材质承载层基础设施
//
// 官方约束（本机 SDK component/common.d.ts:22624 systemMaterial）：
//   "This API affects the backgroundColor, borderColor, borderWidth and shadow
//    of the component. You are advised not to use this API together with the
//    aforementioned APIs."
// 也就是说：把 systemMaterial 直接挂在「同时设置了 background/linearGradient/
// border/shadow」的卡片外框上，材质会被这些自绘属性覆盖掉 —— 这正是此前
// 「开关能切、真机几乎看不出变化」的根因。正确做法是把材质放在一个
// 独立的、只有透明底的子节点上（承载层），由它铺满卡片。
// ============================================================================

/** 材质对象缓存：避免每次 build 都 new ImmersiveMaterial（真机会掉帧） */
class MatStore {
  private static cache: Map<string, uiMaterial.Material> = new Map();

  /** 惰性构造沉浸材质；任何异常都退化为 Material.empty（组件级关闭材质） */
  static immersive(style: uiMaterial.ImmersiveStyle, dark: boolean, alpha: number,
    liquid: boolean, shadow: boolean, light: string): uiMaterial.Material {
    const key: string = style.toString() + '|' + (dark ? '1' : '0') + '|' + alpha.toFixed(3) +
      '|' + (liquid ? '1' : '0') + '|' + (shadow ? '1' : '0') + '|' + light;
    const hit: uiMaterial.Material | undefined = MatStore.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    let made: uiMaterial.Material = uiMaterial.Material.empty;
    try {
      const tint: string = dark ? 'rgba(20,22,30,' + alpha.toFixed(3) + ')'
        : 'rgba(255,255,255,' + alpha.toFixed(3) + ')';
      if (liquid) {
        const optLiquid: uiMaterial.ImmersiveOptions = {
          style: style,
          materialColor: tint,
          colorInvert: false,
          applyShadow: shadow,
          interactive: true,
          lightEffect: { color: light.length > 0 ? light : '#33FFFFFF' }
        };
        made = new uiMaterial.ImmersiveMaterial(optLiquid);
      } else {
        const optStatic: uiMaterial.ImmersiveOptions = {
          style: style,
          materialColor: tint,
          colorInvert: false,
          applyShadow: shadow,
          interactive: false
        };
        made = new uiMaterial.ImmersiveMaterial(optStatic);
      }
    } catch (e) {
      made = uiMaterial.Material.empty;
    }
    MatStore.cache.set(key, made);
    return made;
  }
}

/**
 * 材质属性修饰器。
 * systemMaterial 必须在 applyNormalAttribute 回调里设置，且修饰器对象要在
 * 每次 build 时重新构造，这样才能读到最新的响应式状态（开关/档位）。
 */
class GlassCarrierModifier implements AttributeModifier<ToggleAttribute> {
  private mat: uiMaterial.Material | undefined = undefined;
  private radius: number = 20;

  constructor(mat: uiMaterial.Material | undefined, radius: number) {
    this.mat = mat;
    this.radius = radius;
  }

  applyNormalAttribute(instance: ToggleAttribute): void {
    instance.borderRadius(this.radius);
    instance.clip(true);
    instance.backgroundColor(Color.Transparent);
    instance.hitTestBehavior(HitTestMode.None);
    if (this.mat !== undefined && this.mat !== uiMaterial.Material.empty) {
      instance.systemMaterial(this.mat);
    }
  }
}

/**
 * 玻璃承载层：铺满父容器，只负责「系统沉浸材质」。
 * 用 Toggle(Button) 而不是普通容器承载，是因为按钮类组件才有完整的
 * 系统材质表面（普通容器只设 systemMaterial 在真机上不出材质）。
 * 必须显式 matchParent 尺寸，否则塌缩为 0 宽高。
 */
@Component
struct GlassCarrier {
  /** 是否启用系统沉浸材质 */
  @Prop enabledMat: boolean = true;
  /** 材质厚度：0 ULTRA_THIN / 1 THIN / 2 REGULAR / 3 THICK / 4 ULTRA_THICK */
  @Prop thickness: number = 1;
  @Prop carrierRadius: number = 20;
  @Prop darkMode: boolean = true;
  /** 着色浓度 0~0.6，越小越通透 */
  @Prop tintAlpha: number = 0.20;
  /** 交互流光（悬浮导航等可交互表面） */
  @Prop liquid: boolean = false;
  @Prop lightColor: string = '';
  /** 承载层高度（vp）：由卡片实测高度传入，避免 matchParent 把卡片撑满屏幕 */
  @Prop carrierHeight: number = 0;

  private styleOf(): uiMaterial.ImmersiveStyle {
    if (this.thickness <= 0) {
      return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    }
    if (this.thickness === 1) {
      return uiMaterial.ImmersiveStyle.THIN;
    }
    if (this.thickness === 2) {
      return uiMaterial.ImmersiveStyle.REGULAR;
    }
    if (this.thickness === 3) {
      return uiMaterial.ImmersiveStyle.THICK;
    }
    return uiMaterial.ImmersiveStyle.ULTRA_THICK;
  }

  build() {
    Stack() {
      if (this.enabledMat) {
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text('')
            .fontSize(0)
        }
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .backgroundColor(Color.Transparent)
        .enabled(false)
        .focusable(false)
        .hitTestBehavior(HitTestMode.None)
        .attributeModifier(new GlassCarrierModifier(
          MatStore.immersive(this.styleOf(), this.darkMode, this.tintAlpha, this.liquid, false, this.lightColor),
          this.carrierRadius))
      }
    }
    .width('100%')
    .height(this.carrierHeight)
    .hitTestBehavior(HitTestMode.None)
  }
}

@CustomDialog
struct CustomImportDialog {
  controller?: CustomDialogController;
  initialUrl: string = '';
  initialText: string = '';
  /** 跟随页面主题：深色 / 浅色 */
  darkMode: boolean = false;
  /** 跟随页面主题色（主按钮用） */
  accentColor: string = '#C9A3A6';
  /** 是否英文界面（跟随全局 AppStorage，切换语言后立即生效） */
  @StorageProp('lang_en') langEn: boolean = false;
  onUrl: (u: string) => void = () => {};
  onFile: () => void = () => {};
  onSave: (t: string) => void = () => {};
  @State mode: number = 0;
  @State url: string = '';
  @State draft: string = '';

  private t(zh: string, en: string): string {
    return this.langEn ? en : zh;
  }

  aboutToAppear(): void {
    this.url = this.initialUrl;
    this.draft = this.initialText;
  }

  // ---------- 深色 / 浅色两套色 ----------
  private dlgBg(): string {
    return this.darkMode ? '#E81E1E24' : '#EEFFFFFF';
  }
  private optBg(): string {
    return this.darkMode ? '#2A2A31' : '#F4F5F8';
  }
  private lineC(): string {
    return this.darkMode ? '#17FFFFFF' : '#12121218';
  }
  private t1(): string {
    return this.darkMode ? '#F2F2F5' : '#111114';
  }
  private t2(): string {
    return this.darkMode ? '#C9CAD2' : '#333338';
  }
  private t3(): string {
    return this.darkMode ? '#8E8F99' : '#77777F';
  }
  private softC(): string {
    return this.darkMode ? '#33333C' : '#E9EAEE';
  }

  @Builder Btn(label: string, primary: boolean, w: string, act: () => void) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(primary ? '#FFFFFF' : this.t2())
      .textAlign(TextAlign.Center)
      .width(w)
      .height(40)
      .backgroundColor(primary ? this.accentColor : this.softC())
      .borderRadius(12)
      .onClick(act)
  }

  /** 一级选项行：标题 + 说明 + 箭头 */
  @Builder OptionRow(title: string, hint: string, act: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.t1())
        Text(hint)
          .fontSize(11)
          .fontColor(this.t3())
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(18)
        .fontColor(this.t3())
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 14, right: 12, top: 11, bottom: 11 })
    .backgroundColor(this.optBg())
    .borderRadius(12)
    .margin({ bottom: 8 })
    .onClick(act)
  }

  @Builder FieldLabel(label: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.t3())
      .width('100%')
      .margin({ top: 12 })
  }

  build() {
    Column() {
      Row() {
        Text(this.t('自定义导入', 'Custom import'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.t1())
        Blank()
        Text('✕')
          .fontSize(13)
          .fontColor(this.t3())
          .textAlign(TextAlign.Center)
          .width(28)
          .height(28)
          .backgroundColor(this.softC())
          .borderRadius(14)
          .onClick(() => { if (this.controller) { this.controller.close(); } })
      }
      .width('100%')

      if (this.mode === 0) {
        Text(this.t('选择导入方式：来源需一行一个地址或 CIDR，可用 # 注释。', 'Choose an import method: one address or CIDR per line; # starts a comment.'))
          .fontSize(11)
          .fontColor(this.t3())
          .width('100%')
          .margin({ top: 10, bottom: 12 })
        Column() {
          this.OptionRow(this.t('链接导入', 'Import from link'), this.t('从网址拉取 IP 列表，自动识别 v4 / v6', 'Fetch an IP list from a URL; v4/v6 detected automatically'), () => { this.mode = 1; })
          this.OptionRow(this.t('文件导入', 'Import from file'), this.t('选择本地的 txt / csv 文件', 'Choose a local txt / csv file'), () => {
            this.onFile();
            if (this.controller) { this.controller.close(); }
          })
          this.OptionRow(this.t('文本粘贴 / 编辑', 'Paste / edit text'), this.t('直接粘贴或手动修改来源文本', 'Paste directly or edit the source text manually'), () => { this.mode = 2; })
        }
        .width('100%')
      } else if (this.mode === 1) {
        this.FieldLabel(this.t('链接地址', 'Link URL'))
        TextInput({ text: this.url, placeholder: 'https://example.com/ips-v6' })
          .width('100%')
          .height(40)
          .fontSize(12)
          .fontColor(this.t1())
          .placeholderColor(this.t3())
          .backgroundColor(this.optBg())
          .borderRadius(10)
          .margin({ top: 8 })
          .onChange((v: string) => { this.url = v; })
        Row() {
          this.Btn(this.t('返回', 'Back'), false, '48%', () => { this.mode = 0; })
          this.Btn(this.t('拉取导入', 'Fetch and import'), true, '48%', () => {
            this.onUrl(this.url.trim());
            if (this.controller) { this.controller.close(); }
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ top: 14 })
      } else {
        this.FieldLabel(this.t('来源文本', 'Source text'))
        TextArea({ text: this.draft, placeholder: this.t('每行一个：1.2.3.4 / 1.2.3.4:8443 / [2001:db8::1]:443 / CIDR', 'One per line: 1.2.3.4 / 1.2.3.4:8443 / [2001:db8::1]:443 / CIDR') })
          .width('100%')
          .height(176)
          .fontSize(12)
          .fontColor(this.t1())
          .placeholderColor(this.t3())
          .backgroundColor(this.optBg())
          .borderRadius(10)
          .margin({ top: 8 })
          .onChange((v: string) => { this.draft = v; })
        Row() {
          this.Btn(this.t('清空', 'Clear'), false, '48%', () => { this.draft = ''; })
          this.Btn(this.t('保存并启用', 'Save and enable'), true, '48%', () => {
            this.onSave(this.draft);
            if (this.controller) { this.controller.close(); }
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ top: 14 })
      }
    }
    .width('92%')
    .constraintSize({ maxWidth: 400 })
    .padding(18)
    .backgroundColor(this.dlgBg())
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: this.darkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
    })
    .borderRadius(22)
    .border({ width: 1, color: this.lineC() })
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
struct Index {
  @State dark: boolean = AppStorage.get<boolean>('initialDark') ?? true;
  // 导航光感：控制中心按钮式的跟随柔光 + 拖拽弹簧（q 弹）
  private lastColorMode: number = -1;
  @State navGlowPct: number = 50;
  @State navGlowOn: boolean = false;
  @State navStretch: number = 0;
  // ===== 方案 A：高亮胶囊的位置与形变（单一数据源）=====
  @State navPillX: number = 0;
  @State navPillS: number = 1.0;
  @State navPillFlat: number = 0;
  @State navPillY: number = 0;
  @State navPillDragging: boolean = false;
  private navStartX: number = 0;
  private navLastWX: number = 0;
  private navLastMs: number = 0;
  private navVelMs: number = 0;
  private navDrag: boolean = false;
  private navDownX: number = -1;
  private navMoved: boolean = false;
  /** 0=深色 1=浅色 2=跟随系统 */
  @State themeMode: number = ThemeMode.SYSTEM;
  @State curTab: number = 0;
  /** 页签选中态（点击即更新，避免依赖 HDS onChange 的延迟） */
  @State navSel: number = 0;
  /** 当前页面的滚动偏移（任一页滚动时更新，用于「回到顶部」按钮与顶部渐变蒙版） */
  private anyScrollY: number = 0;
  @State showBackTop: boolean = false;
  // 性能：进度/日志先写普通字段，定时批量刷新 @State，避免每条结果都整页重建
  private doneRaw: number = 0;
  private totalRaw: number = 0;
  private passedRaw: number = 0;
  private failedRaw: number = 0;
  private progTimer: number = -1;
  private logBuf: string[] = [];
  private logTimer: number = -1;
  private resultsRaw: Candidate[] = [];
  private resultTimer: number = -1;

  /** 全局沉浸光感总开关 */
  @State globalImmersion: boolean = true;
  /** 材质类型：0 自适应 / 1 沉浸 / 2 无材质 */
  @State matType: number = 0;
  /** 材质等级：0 自适应 / 1 精致 / 2 柔和 / 3 平滑 */
  @State matLevel: number = 0;
  /** 材质对象缓存（切换材质档位时不重复 new，避免卡顿） */
  private matCached: uiMaterial.Material = uiMaterial.Material.empty;
  private matCacheKey: string = '';
  /** 卡片实测高度（vp），供 HDS 材质层撑满卡片；对标 OA measuredCardHeights */
  @State private measuredCardHeights: Map<string, number> = new Map();
  /** 主题色：0 柠檬黄 1 奶油黄 2 鼠尾草绿 3 雾霾蓝 4 灰豆沙粉 5 清透炭黑 */
  @State themeColorIdx: number = 4;
  /** 背景图模糊程度 0~100 */
  @State bgBlurPct: number = 0;
  /** 背景图明亮程度 0~100（50 = 原亮度） */
  @State bgBrightPct: number = 50;
  /** 光感等级 0=弱 1=标准 2=强 3=极致 */
  @State glassLevel: number = 1;

  @State headerH: number = 0;
  @State netOk: boolean = true;
  @State winW: number = 0;
  @State winH: number = 0;
  /**
   * 四个页面 Scroll 的实测视口高度（vp），供 linearGradientBlur 归一化 stops。
   * 手机/平板/横竖屏视口高度不同，必须在运行时取，不能写死。
   */
  @State scanVpH: number = 0;
  @State pingVpH: number = 0;
  @State speedVpH: number = 0;
  @State settingsVpH: number = 0;
  @State pageOpacity: number = 0;
  /**
   * 应用内首帧淡入：pageOpacity 由 runEntrance() 以 140ms FastOutSlowIn 拉到 1；
   * pageScale 固定为 1（不再做整屏缩放）。冷启动前的底色由系统启动窗口
   * （module.json5 的 startWindowIcon / startWindowBackground）负责，与此状态无关。
   */
  @State pageScale: number = 1;
  /** 出口 IP（启动时探测，用来判断是否处于代理环境） */
  @State egressIp: string = '';
  /** 全屏模式下系统状态栏占用的高度（px），由 EntryAbility 写入 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  @StorageProp('navBarPx') navBarPx: number = 0;
  private scanScroller: Scroller = new Scroller();
  private logScroller: Scroller = new Scroller();
  private pingScroller: Scroller = new Scroller();
  private speedScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();


  // 扫描状态
  @State scanning: boolean = false;
  @State phaseText: string = '';
  @State done: number = 0;
  @State total: number = 0;
  @State passed: number = 0;
  @State failed: number = 0;
  @State logs: string[] = [];
  @State results: Candidate[] = [];
  /** 第一轮（ping + colo）通过的节点，按延迟升序 */
  @State pingList: Candidate[] = [];
  /** 参与测速的节点，按速度降序（最终结果页只显示这些） */
  @State speedList: Candidate[] = [];
  /** 与 speedList 同下标的测速状态：0=待测 1=测速中 2=完成 3=失败 */
  @State speedStates: number[] = [];
  /** 筛选页按地区分组 */
  @State groups: RegionGroup[] = [];
  /** 已展开的地区码 */
  @State expandedColos: string[] = [];

  // 配置
  @State mode: number = ScanMode.OFFICIAL;
  @State ipVersion: number = IpVersion.V4;
  @State port: number = 443;
  @State customText: string = '';
  @State importUrl: string = 'https://www.cloudflare.com/ips-v6/';
  @State libIdx: number = 0;
  @State srcIdx: number = 0;
  importDlg: CustomDialogController = new CustomDialogController({
    builder: CustomImportDialog({
      initialUrl: this.importUrl,
      initialText: this.customText,
      darkMode: this.dark,
      accentColor: this.accent(),
      onUrl: (u: string) => {
        this.importUrl = u;
        this.importIpUrl();
      },
      onFile: () => { this.importIpFile(); },
      onSave: (t: string) => {
        this.customText = t.trim();
        this.mode = ScanMode.CUSTOM;
        this.srcIdx = 3;
        this.scheduleScanSave();
        this.toast(this.customText.length > 0 ? this.t('已保存自定义来源', 'Custom source saved') : this.t('自定义来源已清空', 'Custom source cleared'));
      }
    }),
    autoCancel: true,
    customStyle: true
  });
  @State sampleText: string = '2000';
  @State cfgRev: number = 0;
  /** 扫描页「高级选项」是否展开（默认收起，压缩页面长度） */
  @State advParamOpen: boolean = false;
  @State showParamNotes: boolean = false;
  /** 冷启动时的应用内启动页：用应用主题渲染，覆盖系统启动窗口与首帧之间的空档 */
  /** 宽屏扫描页左列实测高度（vp），用于把第二列卡片底部撑到同一水平线 */
  @State scanLeftColH: number = 0;

  /** 宽屏下第二列卡片的最小高度：左列高度减去卡片自身下外边距；手机端返回 0（不干预） */
  private speedCardMinH(): number {
    if (this.winW < 900 || this.scanLeftColH <= 12) {
      return 0;
    }
    return this.scanLeftColH - 12;
  }
  /** 更新日志中当前展开的版本号，空串表示全部折叠 */
  @State changelogOpen: string = '';
  /** 测速页「高级选项」是否展开 */
  @State advSpeedOpen: boolean = false;
  @State advUploadOpen: boolean = false;
  @State bgAdvancedOpen: boolean = false;
  @State concurrencyText: string = defaultScanConcurrency().toString();
  @State latencyText: string = '300';
  /** 延迟上限建议提示（随 IPv4/IPv6 变化） */
  @State latencyHint: string = '';
  @State bgPath: string = '';
  /** 底部胶囊拖动时的指尖 x（-1 表示未触摸） */
  @State pingText: string = '1';
  @State speedCountText: string = '10';
  @State speedRoundsText: string = '1';
  @State speedWindowText: string = '3000';
  /** 合格速度（MB/s），低于该值的测速结果会被淘汰，默认 0.1 */
  @State minSpeedText: string = '0.1';
  @State enableSpeed: boolean = true;
  @State speedScope: number = SpeedScope.ALL;
  @State speedPerRegionText: string = '3';
  @State domain: string = '';
  @State keepAlive: boolean = false;
  @State domainSampling: boolean = false;
  @State regionCode: string = '';
  // 质量预检（第一轮通过后、正式测速前）
  @State precheckActive: boolean = false;
  @State precheckDone: boolean = false;
  @State pcChecked: number = 0;
  @State pcQualified: number = 0;
  @State pcTarget: number = 0;
  @State pcCandidates: number = 0;
  @State pcExhausted: boolean = false;
  @State pcMsg: string = '';
  @State domainInfoText: string = '';
  @State resolving: boolean = false;
  @State testing: boolean = false;
  @State testInfo: string = '';
  /** 应用版本号，Header 上展示 */
  @State appVersion: string = '1.4.0';
  // ===== 语言 =====
  @State langMode: number = LangMode.SYSTEM;
  @State langEn: boolean = false;
  // ===== 设置二级页：-1 首页，>=0 具体分类 =====
  @State settingsSub: number = -1;
  /** 手机：当前内嵌展开的分类（默认展开「外观与主题」） */
  @State settingsAccordion: number = 0;   // 已废弃：手机改为分类详情页，保留字段避免其他地方引用报错
  /** 平板/电脑：左侧菜单选中的分类（默认外观与主题） */
  @State settingsPane: number = 0;
  private settingsSubScroller: Scroller = new Scroller();
  private settingsScrollCache: number = 0;
  // ===== 更新检查 =====
  @State updStatus: number = UpdateStatus.IDLE;
  @State updDetail: string = '';
  @State updLatestVersion: string = '';
  @State updLatestDate: string = '';
  @State updLatestNotes: string = '';
  @State updLatestUrl: string = '';
  @State updHasPackage: boolean = false;
  @State updFromFallback: boolean = false;
  // ===== 更新日志 / 升级说明 =====
  @State showChangelogDialog: boolean = false;
  @State changelogVersion: string = '';
  private static readonly CHANGELOG_SEEN_KEY: string = 'changelog_seen_version';
  /** IPv6 网络诊断：运行状态与结果文本 */
  @State diagBusy: boolean = false;
  @State diagText: string = '';
  private diagWatchdog: number = -1;

  // ---------- edgetunnel 订阅上传 ----------
  @State etEnabled: boolean = false;
  @State etHost: string = '';
  @State etPassword: string = '';
  /** 0=覆盖 1=追加 */
  @State etMode: number = 0;
  @State etCustom: string = '';
  @State etPos: number = 0;
  @State etProxyOn: boolean = false;
  @State etProxyHost: string = '';
  @State etProxyPort: string = '7890';
  @State etProxyUser: string = '';
  @State etProxyPass: string = '';
  @State etStatus: string = '';
  @State etBusy: boolean = false;
  /** 0=登录上传 1=Cloudflare API 直传 */
  @State etWay: number = 0;
  @State etCfAccount: string = '';
  @State etCfNamespace: string = '';
  @State etCfToken: string = '';
  /** 每次最多上传的结果数：0=全部 */
  /** 每次最多上传的结果数（0=全部），默认前 3 */
  @State etTopN: number = 3;
  @State etTopNText: string = '3';

  /** 每轮任务的代次；旧任务的回调看到代次变化后直接丢弃 */
  private scanGen: number = 0;
  private token: CancellationToken = new CancellationToken();
  /** 后台心跳：每 5s 记录一次真实完成数，用来区分“任务冻结”和“UI 未刷新” */
  private heartbeatTimer: number = -1;
  /** 诊断代次：清空/重新开始时让旧诊断回调失效 */
  private diagGen: number = 0;
  /** 扫描参数持久化防抖计时器 */
  private scanSaveTimer: number = -1;
  /** 首帧展开动画是否已播放（保证只播一次） */
  private entranceDone: boolean = false;
  /** 网络提示定时器句柄，-1 表示无待执行任务 */
  private entranceTimer: number = -1;
  private cfg: ScanConfig = defaultScanConfig();
  private ctx: common.UIAbilityContext | undefined = undefined;

  /** 启动即检测网络：没网时明确提示，而不是让用户对着一片空白猜 */
  checkNetwork(): void {
    try {
      const net: connection.NetHandle = connection.getDefaultNetSync();
      if (net.netId === 0) {
        this.netOk = false;
        this.addLog(this.t('未检测到可用网络，请先连接 Wi-Fi 或移动数据', 'No network detected. Connect to Wi-Fi or mobile data first.'));
      } else {
        this.netOk = true;
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.addLog(this.t('网络状态检测失败：', 'Network status check failed: ') + err.message);
    }
  }
  /** 从 cloudflare trace 文本里取 ip= 那一行 */
  private traceIp(text: string): string {
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].indexOf('ip=') === 0) {
        return lines[i].substring(3).trim();
      }
    }
    return '';
  }

  /** 是否私有/保留地址（出现就说明流量经过了本机或内网代理） */
  private isPrivateIp(ip: string): boolean {
    if (ip.length === 0) {
      return false;
    }
    if (ip.indexOf('10.') === 0 || ip.indexOf('127.') === 0 || ip.indexOf('192.168.') === 0) {
      return true;
    }
    if (ip.indexOf('169.254.') === 0) {
      return true;
    }
    const parts: string[] = ip.split('.');
    if (parts.length >= 2) {
      const second: number = parseInt(parts[1], 10);
      if (ip.indexOf('172.') === 0 && second >= 16 && second <= 31) {
        return true;
      }
      if (ip.indexOf('100.') === 0 && second >= 64 && second <= 127) {
        return true;
      }
    }
    if (ip.indexOf('fd') === 0 || ip.indexOf('fe80') === 0 || ip === '::1') {
      return true;
    }
    return false;
  }

  /**
   * 探测网络运行环境。
   *
   * 通过 cloudflare 的 trace 接口拿出口 IP：如果拿到的是私有地址，说明流量走了本机/内网代理，
   * 这种情况下测出来的延迟和速度都不代表真实链路，先提醒用户关掉代理再测。
   * 同时把 warp 状态也带出来（cloudflare 的 WARP 会改出口路径，同样影响结果）。
   */
  checkProxyEnv(): void {
    const req = http.createHttp();
    req.request('https://www.cloudflare.com/cdn-cgi/trace', {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 6000,
      readTimeout: 6000
    }).then((resp: http.HttpResponse) => {
      req.destroy();
      if (resp.responseCode !== http.ResponseCode.OK) {
        return;
      }
      const text: string = typeof resp.result === 'string' ? resp.result as string : '';
      const ip: string = this.traceIp(text);
      this.egressIp = ip;
      const warpOn: boolean = text.indexOf('warp=on') >= 0;
      if (ip.length === 0) {
        return;
      }
      if (this.isPrivateIp(ip) || warpOn) {
        this.addLog(this.t('网络环境：出口 IP ', 'Network: egress IP ') + ip + (warpOn ? this.t('（WARP 已开启）', ' (WARP enabled)') : this.t('（私有地址）', ' (private address)')) +
          this.t('，建议关闭代理后重新测速', ', turn off the proxy and re-run the speed test'));
        setTimeout(() => {
          this.toast(this.t('检测到当前网络经过代理，测速结果会失真，建议先关闭代理', 'A proxy was detected on this network; speed test results will be inaccurate. Turn off the proxy first.'));
        }, 700);
      } else {
        this.addLog(this.t('网络环境：出口 IP ', 'Network: egress IP ') + ip);
      }
    }).catch((e: BusinessError) => {
      req.destroy();
      this.addLog(this.t('网络环境检测失败：', 'Network check failed: ') + e.message);
    });
  }

  aboutToAppear(): void {
    // 首帧布局：EntryAbility 会在 loadContent 之前把主窗口真实尺寸写入 AppStorage，
    // 这里在 build 之前读出来，首帧就按平板 / 手机布局渲染，避免启动时布局重排一次。
    try {
      const wpx: number | undefined = AppStorage.get<number>('initWinWpx');
      const hpx: number | undefined = AppStorage.get<number>('initWinHpx');
      if (wpx !== undefined && wpx > 0) {
        this.winW = this.getUIContext().px2vp(wpx);
      }
      if (hpx !== undefined && hpx > 0) {
        this.winH = this.getUIContext().px2vp(hpx);
      }
    } catch (e) {
      // 读不到就保持 0，等 onAreaChange 首次测量后再校正
    }
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.versionName.length > 0) {
        this.appVersion = info.versionName;
      }
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      this.addLog(this.t('读取版本号失败：', 'Failed to read version: ') + be.message);
    }
    this.ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;

    // EntryAbility 已在进程启动时同步读过主题偏好；拿不到才退回系统颜色
    const cached: boolean | undefined = AppStorage.get<boolean>('initialDark');
    this.dark = cached !== undefined ? cached : this.systemDark();
    this.checkNetwork();
    this.checkProxyEnv();
    ConfigStore.init(this.ctx).then(() => {
      this.themeMode = ConfigStore.theme();
      this.applyThemeMode();
      this.loadConfig();
      this.initEtConfig();
      this.glassLevel = ConfigStore.glassLevel();
      this.loadUi();
      this.maybeShowChangelog();
    }).catch((e: BusinessError) => {
      this.addLog(this.t('读取配置失败：', 'Failed to read settings: ') + e.message);
    });
    BarStyle.apply(this.dark);
    this.runEntrance(true);
  }

  /**
   * 首帧展开动画 + 网络提示。
   * anim=true 仅冷启动首帧一次；主题切换传 false，避免每次改主题都重放缩放动画
   * （v1.1.4 及之前 applyThemeMode 内重复了一份同样的代码，属于缺陷）。
   */
  private runEntrance(anim: boolean): void {
    if (this.entranceDone) {
      return;
    }
    this.entranceDone = true;
    if (anim) {
      animateTo({ duration: 140, curve: Curve.FastOutSlowIn }, () => {
        this.pageOpacity = 1;
        this.pageScale = 1;
      });
    } else {
      this.pageOpacity = 1;
      this.pageScale = 1;
    }
    if (this.entranceTimer >= 0) {
      clearTimeout(this.entranceTimer);
    }
    this.entranceTimer = setTimeout(() => {
      this.entranceTimer = -1;
      if (!this.netOk) {
        this.toast(this.t('当前无网络连接，请先联网再开始优选', 'No network connection. Connect to the internet before starting selection.'));
      }
    }, 900);
  }

  aboutToDisappear(): void {
    if (this.entranceTimer >= 0) {
      clearTimeout(this.entranceTimer);
      this.entranceTimer = -1;
    }
    this.token.cancel();
  }
  /** 系统当前是否深色 */
  private systemDark(): boolean {
    try {
      const c: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return c.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return true;
    }
  }

  /** 按 themeMode 计算实际 dark，并同步系统栏配色 */
  private applyThemeMode(): void {
    if (this.themeMode === ThemeMode.DARK) {
      this.dark = true;
    } else if (this.themeMode === ThemeMode.LIGHT) {
      this.dark = false;
    } else {
      this.dark = this.systemDark();
    }
    BarStyle.apply(this.dark);
    this.syncSystemColorMode();
    this.runEntrance(false);
  }

  /** 让 HdsTabs 材质/Select 菜单/弹窗等系统组件跟随应用主题（它们默认跟随系统深浅色） */
  private syncSystemColorMode(): void {
    let target: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (this.themeMode === ThemeMode.DARK) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (this.themeMode === ThemeMode.LIGHT) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    if (target === this.lastColorMode) {
      return;
    }
    this.lastColorMode = target;
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.getApplicationContext().setColorMode(target);
    } catch (e) {
    }
  }

  /** 主题按钮文案 */
  private themeLabel(): string {
    if (this.themeMode === ThemeMode.DARK) {
      return this.t('深色', 'Dark');
    }
    if (this.themeMode === ThemeMode.LIGHT) {
      return this.t('浅色', 'Light');
    }
    return this.t('跟随系统', 'Follow system');
  }

  loadConfig(): void {
    const c: ScanConfig = ConfigStore.load();
    this.cfg = c;
    this.mode = c.mode;
    this.ipVersion = c.ipVersion;
    this.srcIdx = this.mode === ScanMode.OFFICIAL ? 0 : 3;
    this.port = c.port;
    this.customText = c.customText;
    this.sampleText = c.sampleCount.toString();
    this.concurrencyText = c.scanConcurrency.toString();
    this.latencyText = c.latencyLimitMs.toString();
    this.pingText = c.pingTimes.toString();
    this.speedCountText = c.speedCount.toString();
    this.speedRoundsText = c.speedRounds.toString();
    this.speedWindowText = c.speedWindowMs.toString();
    this.minSpeedText = c.minSpeedMbps.toString();
    this.enableSpeed = c.enableSpeed;
    this.speedScope = c.speedScope;
    this.speedPerRegionText = c.speedPerRegion.toString();
    this.domain = c.domain;
    this.domainSampling = c.domainSampling;
    this.keepAlive = ConfigStore.keepAlive();
    AppBackground.enabled = this.keepAlive;
    this.regionCode = c.regionCode;
    this.latencyHint = this.t('建议：延迟上限建议 260~320ms（默认 300ms；两次 ping 下 220ms 偏低，容易误杀可用节点）', 'Tip: a latency cap of 260–320 ms is recommended (default 300 ms; 220 ms with two pings is too low and may discard usable nodes).');
    this.bgPath = ConfigStore.bgPath();
  }

  /** 选择一张本地图片作为应用背景（复制进沙箱，卸载前一直可用） */
  private async pickBackground(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === undefined) {
      this.toast(this.t('应用上下文未就绪', 'App context not ready'));
      return;
    }
    try {
      const ph: picker.PhotoViewPicker = new picker.PhotoViewPicker();
      const opt: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
      opt.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 1;
      const res: picker.PhotoSelectResult = await ph.select(opt);
      if (res.photoUris.length === 0) {
        return;
      }
      const dst: string = ctx.filesDir + '/bg_custom.jpg';
      const f = fileIo.openSync(res.photoUris[0], fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(f.fd, dst);
      fileIo.closeSync(f);
      this.bgPath = dst;
      await ConfigStore.saveBgPath(dst);
      this.addLog(this.t('已设置自定义背景图', 'Custom background image set'));
      this.toast(this.t('背景已更新', 'Background updated'));
    } catch (e) {
      const err = e as BusinessError;
      this.toast(this.t('选择背景失败：', 'Failed to select background: ') + err.message);
    }
  }

  /** 恢复默认渐变背景 */
  private async clearBackground(): Promise<void> {
    this.bgPath = '';
    await ConfigStore.saveBgPath('');
    this.addLog(this.t('已恢复默认渐变背景', 'Default gradient background restored'));
    this.toast(this.t('已恢复默认背景', 'Default background restored'));
  }

  /** 当前生效的预设背景序号，-1 表示未使用预设 */
  private presetBgIndex(): number {
    if (this.bgPath.length === 0) {
      return -1;
    }
    for (let i = 1; i <= 7; i++) {
      if (this.bgPath.indexOf('bg_preset_' + i + '.jpg') >= 0) {
        return i - 1;
      }
    }
    return -1;
  }

  /** 背景图状态文案 */
  private bgPathLabel(): string {
    const p: number = this.presetBgIndex();
    if (p >= 0) {
      return this.t('当前：预设背景 ', 'Current: preset background ') + (p + 1);
    }
    if (this.bgPath.length > 0) {
      return this.t('当前：图库自定义图片', 'Current: custom image from gallery');
    }
    return this.t('默认使用渐变背景', 'Uses the gradient background by default');
  }

  /** 应用内置预设背景：从 rawfile 复制进沙箱，与图库选择共用同一条渲染/持久化路径 */
  private async usePresetBackground(index: number): Promise<void> {
    const ctx = this.ctx;
    if (ctx === undefined) {
      this.toast(this.t('应用上下文未就绪', 'App context not ready'));
      return;
    }
    try {
      const raw: string = 'bg/preset' + (index + 1) + '.jpg';
      const buf: Uint8Array = ctx.resourceManager.getRawFileContentSync(raw);
      const dst: string = ctx.filesDir + '/bg_preset_' + (index + 1) + '.jpg';
      const f = fileIo.openSync(dst,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, buf.buffer as ArrayBuffer);
      fileIo.closeSync(f);
      this.bgPath = dst;
      await ConfigStore.saveBgPath(dst);
      this.addLog(this.t('已应用预设背景 ', 'Preset background applied: ') + (index + 1));
      this.toast(this.t('背景已更新', 'Background updated'));
    } catch (e) {
      const err = e as BusinessError;
      this.toast(this.t('应用预设背景失败：', 'Failed to apply preset background: ') + err.message);
    }
  }
  /** 进度条左侧文案：同时显示成功/失败数，避免「整数进度」看不出失败 */
  progressLabel(): string {
    if (this.total <= 0) {
      return this.t('就绪', 'Ready');
    }
    let s: string = this.done.toString() + '/' + this.total.toString();
    if (this.passed + this.failed > 0) {
      s += this.t(' · 通过 ', ' · Passed ') + this.passed.toString() + this.t(' · 未通过 ', ' · Failed ') + this.failed.toString();
    }
    return s;
  }

  floatOf(s: string, def: number): number {
    const v: number = parseFloat(s);
    if (isNaN(v)) {
      return def;
    }
    return v;
  }

  /** 合格速度门槛（MB/s），0 表示不淘汰 */
  minSpeedValue(): number {
    const v: number = this.floatOf(this.minSpeedText, 0.1);
    if (v <= 0) {
      return 0;
    }
    return Math.min(100, v);
  }

  intOf(s: string, def: number): number {
    const v: number = parseInt(s, 10);
    if (isNaN(v)) {
      return def;
    }
    return v;
  }

  buildConfig(): ScanConfig {
    const d: ScanConfig = defaultScanConfig();
    const c: ScanConfig = {
      mode: this.mode === ScanMode.CUSTOM ? ScanMode.CUSTOM : ScanMode.OFFICIAL,
      ipVersion: this.ipVersion === IpVersion.V6 ? IpVersion.V6 : IpVersion.V4,
      port: this.port,
      sampleCount: Math.max(1, this.intOf(this.sampleText, d.sampleCount)),
      customText: this.customText,
      pingTimes: Math.max(1, Math.min(5, this.intOf(this.pingText, d.pingTimes))),
      pingIntervalMs: d.pingIntervalMs,
      pingTimeoutMs: this.ipVersion === IpVersion.V6 ? 3000 : d.pingTimeoutMs,
      latencyLimitMs: Math.max(50, Math.min(3000, this.intOf(this.latencyText, d.latencyLimitMs))),
      scanConcurrency: Math.max(1, Math.min(maxScanConcurrency(), this.intOf(this.concurrencyText, d.scanConcurrency))),
      traceHost: d.traceHost,
      tracePath: d.tracePath,
      traceConcurrency: d.traceConcurrency,
      traceTimeoutMs: d.traceTimeoutMs,
      enableSpeed: this.enableSpeed,
      speedScope: this.speedScope,
      speedPerRegion: Math.max(1, Math.min(20, this.intOf(this.speedPerRegionText, d.speedPerRegion))),
      speedCount: Math.max(0, Math.min(999, this.intOf(this.speedCountText, d.speedCount))),
      speedRounds: Math.max(1, Math.min(3, this.intOf(this.speedRoundsText, d.speedRounds))),
      speedUrl: d.speedUrl,
      speedWindowMs: Math.max(1000, Math.min(10000, this.intOf(this.speedWindowText, d.speedWindowMs))),
      minSpeedMbps: Math.max(0, Math.min(100, this.floatOf(this.minSpeedText, d.minSpeedMbps))),
      speedConcurrency: d.speedConcurrency,
      speedGapMs: d.speedGapMs,
      domain: DnsService.normalize(this.domain),
      domainSampling: true,
      regionCode: this.regionCode.trim().toUpperCase(),
      delayWeight: d.delayWeight,
      speedWeight: d.speedWeight,
      resultLimit: d.resultLimit
    };
    return c;
  }

  /** 参数变更后稍后持久化，避免每次输入都写盘 */
  private scheduleScanSave(): void {
    if (this.scanSaveTimer >= 0) {
      clearTimeout(this.scanSaveTimer);
    }
    this.scanSaveTimer = setTimeout(() => {
      this.scanSaveTimer = -1;
      ConfigStore.save(this.buildConfig());
    }, 500);
  }

  /** 切换 IPv4/IPv6 时更新建议值；若当前仍是另一协议的默认值，则自动跟随 */
  private maybeAutoSuggest(v6: boolean): void {
    this.latencyHint = this.t('建议：延迟上限建议 260~320ms（默认 300ms；两次 ping 下 220ms 偏低，容易误杀可用节点）', 'Tip: a latency cap of 260–320 ms is recommended (default 300 ms; 220 ms with two pings is too low and may discard usable nodes).');
    if (v6) {
      this.latencyHint = this.latencyHint;
    }
    this.scheduleScanSave();
  }

  /** 一键应用建议参数（IPv4/IPv6 统一：采样 3000、并发 30、延迟上限 300ms、Ping 1 次、合格速度 0.1MB/s） */
  /** 参数输入框的当前值（直接读 @State，保证按钮/外部修改能立即回显） */
  private paramValue(field: string): string {
    if (field === 'sample') {
      return this.sampleText;
    }
    if (field === 'conc') {
      return this.concurrencyText;
    }
    if (field === 'lat') {
      return this.latencyText;
    }
    if (field === 'ping') {
      return this.pingText;
    }
    if (field === 'minSpeed') {
      return this.minSpeedText;
    }
    return '';
  }

  private applySuggestedParams(): void {
    this.sampleText = '3000';
    this.concurrencyText = '30';
    this.latencyText = '300';
    this.pingText = '1';
    this.minSpeedText = '0.1';
    // 全部写完再换一次 id：TextInput 的 text 只作初值，需重建才能回显被抳截/规范化后的值
    this.cfgRev++;
    this.scheduleScanSave();
    this.toast(this.t('已应用建议参数：采样 3000、并发 30、延迟上限 300ms、Ping 1 次、合格速度 0.1MB/s（IPv4/IPv6 统一）', 'Applied recommended settings: 3000 samples, 30 threads, 300ms latency cap, 1 ping, 0.1MB/s min speed (same for IPv4/IPv6)'));
  }

  /** 滚动回调：只在跨越阈值时改 @State，避免滚动过程中每帧重建整个页面 */
  private onPageScroll(sc: Scroller): void {
    const y: number = sc.currentOffset().yOffset;
    this.anyScrollY = y;
    const show: boolean = y > 420;
    if (show !== this.showBackTop) {
      this.showBackTop = show;
    }
  }

  /** 结果列表节流：每 120ms 合并刷新，避免扫描过程中列表频繁重建 */
  private scheduleResultsSync(): void {
    if (this.resultTimer >= 0) {
      return;
    }
    this.resultTimer = setTimeout(() => {
      this.resultTimer = -1;
      this.results = this.resultsRaw;
      this.splitResults(this.resultsRaw);
    }, 120);
  }

  /** 进度节流：先写普通字段，80ms 合并刷新一次 UI */
  private scheduleProgressSync(): void {
    if (this.progTimer >= 0) {
      return;
    }
    this.progTimer = setTimeout(() => {
      this.progTimer = -1;
      this.done = this.doneRaw;
      this.total = this.totalRaw;
      this.passed = this.passedRaw;
      this.failed = this.failedRaw;
    }, 80);
  }

  addLog(msg: string): void {
    if (this.logs.length > 400) {
      this.logs = this.logs.slice(this.logs.length - 200);
    }
    const d: Date = new Date();
    const p = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    this.logBuf.push(p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) + ' ' + msg);
    while (this.logBuf.length > 200) {
      this.logBuf.shift();
    }
    if (this.logTimer >= 0) {
      return;
    }
    this.logTimer = setTimeout(() => {
      this.logTimer = -1;
      if (this.logBuf.length === 0) {
        return;
      }
      const arr: string[] = this.logs.slice();
      for (let i = 0; i < this.logBuf.length; i++) {
        arr.push(this.logBuf[i]);
      }
      while (arr.length > 200) {
        arr.shift();
      }
      this.logBuf = [];
      this.logs = arr;
      // 日志框固定高度后，自动滚到最新一行
      setTimeout(() => {
        try {
          this.logScroller.scrollEdge(Edge.Bottom);
        } catch (e) {
        }
      }, 30);
    }, 100);
  }

  toast(msg: string): void {
    const opt: promptAction.ShowToastOptions = { message: msg, duration: 2200 };
    promptAction.showToast(opt);
  }

  doResolve(): void {
    const d: string = DnsService.normalize(this.domain);
    if (!DnsService.isValidDomain(d)) {
      this.domainInfoText = this.t('请先填写有效域名，例如 cdn.example.com', 'Enter a valid domain, e.g. cdn.example.com');
      return;
    }
    this.resolving = true;
    this.domainInfoText = this.t('解析中…', 'Resolving…');
    DnsService.resolve(d).then((info: DomainInfo) => {
      this.resolving = false;
      if (info.ok) {
        let cf: number = 0;
        for (let i = 0; i < info.ips.length; i++) {
          this.addLog(this.t('解析到 ', 'Resolved ') + info.ips[i]);
        }
        this.domainInfoText = this.t('解析到 ', 'Resolved ') + info.ips.length.toString() + this.t(' 个地址', ' addresses');
      } else {
        this.domainInfoText = this.t('解析失败：', 'Resolve failed: ') + info.error;
      }
    }).catch((e: BusinessError) => {
      this.resolving = false;
      this.domainInfoText = this.t('解析失败：', 'Resolve failed: ') + e.message;
    });
  }

  startScan(): void {
    if (this.scanning) {
      return;
    }
    this.checkNetwork();
    if (!this.netOk) {
      this.toast(this.t('没有网络连接，无法开始扫描', 'No network connection; cannot start scanning'));
      return;
    }
    const c: ScanConfig = this.buildConfig();
    this.cfg = c;
    ConfigStore.save(c).then(() => {
      return;
    }).catch((e: BusinessError) => {
      this.addLog(this.t('保存配置失败：', 'Failed to save settings: ') + e.message);
    });
    // 新一轮任务：递增代次 + 全新令牌；清掉上一轮节流定时器，旧任务回调一律作废
    this.scanGen++;
    const gen: number = this.scanGen;
    this.token = new CancellationToken();
    const myToken: CancellationToken = this.token;
    this.clearScanTimers();
    this.scanning = true;
    AppBackground.hold('scan');
    setTimeout(() => { this.addLog(this.t('后台保活：', 'Background keep-alive: ') + AppBackground.lastState); }, 1500);
    this.startHeartbeat(gen);
    this.results = [];
    this.pingList = [];
    this.speedList = [];
    this.groups = [];
    this.done = 0;
    this.total = 0;
    this.passed = 0;
    this.failed = 0;
    this.doneRaw = 0;
    this.totalRaw = 0;
    this.passedRaw = 0;
    this.failedRaw = 0;
    this.logs = [];
    this.logBuf = [];
    this.phaseText = this.t('准备中', 'Preparing');
    this.curTab = 0;

    const alive = (): boolean => gen === this.scanGen && !myToken.isCancelled();
    const hooks: ScanHooks = new ScanHooks();
    hooks.onPhase = (phase: number, text: string) => {
      if (alive()) {
        this.phaseText = text;
      }
    };
    hooks.onProgress = (done: number, total: number, passed: number, failed: number) => {
      if (!alive()) {
        return;
      }
      this.doneRaw = done;
      this.totalRaw = total;
      this.passedRaw = passed;
      this.failedRaw = failed;
      this.scheduleProgressSync();
    };
    hooks.onResult = (list: Candidate[]) => {
      if (!alive()) {
        return;
      }
      this.resultsRaw = list;
      this.scheduleResultsSync();
    };
    hooks.onLog = (msg: string) => {
      if (alive()) {
        this.addLog(msg);
      }
    };

    Scanner.runPing(c, hooks, myToken).then((list: Candidate[]) => {
      if (gen !== this.scanGen) {
        return;
      }
      // 用户中途点了「停止」：runPing 仍会正常返回已收集的结果，
      // 这里必须拦住，否则会继续走到「自动进入第二轮测速」。
      if (myToken.isCancelled()) {
        this.scanning = false;
        this.stopHeartbeat();
        this.phaseText = this.t('已停止', 'Stopped');
        this.addLog(this.t('已停止：不再继续后续阶段', 'Stopped: no further stages will run'));
        AppBackground.release('scan');
        return;
      }
      this.results = list;
      this.phaseText = this.t('第一轮完成', 'Round 1 complete');
      this.splitResults(list);
      if (this.pingList.length === 0) {
        // 一个都没通过：明确告诉用户，而不是给一片空白
        const v6: boolean = c.ipVersion === IpVersion.V6;
        const lowCount: number = list.filter((x: Candidate) => x.remark === '合格速度不达标').length;
        this.phaseText = v6 ? this.t('IPv6 无可用节点', 'No usable IPv6 nodes') : this.t('没有可用节点', 'No usable nodes');
        this.addLog(v6
          ? (lowCount > 0
            ? this.t('第一轮没有通过的节点：其中 ', 'No nodes passed round 1; of which ') + lowCount.toString() +
              this.t(' 个因合格速度未达标被淘汰，可调低「合格速度」；若仍无结果，请检查网络是否支持 IPv6。', ' nodes were dropped for being below the minimum speed; lower "Min speed". If there are still no results, check whether your network supports IPv6.')
            : this.t('第一轮没有通过的节点。若当前网络不支持 IPv6，或该网段不可达，都会是这个结果。', 'No nodes passed round 1. This is expected if your network does not support IPv6 or the subnet is unreachable.'))
          : (lowCount > 0
            ? this.t('第一轮没有通过的节点：其中 ', 'No nodes passed round 1; of which ') + lowCount.toString() +
              this.t(' 个因合格速度未达标被淘汰，可调低「合格速度」或设为 0；其余请检查网络连接或调高「延迟上限」。', ' nodes were dropped for being below the minimum speed; lower "Min speed" or set it to 0, and otherwise check your network or raise the "Latency cap".')
            : this.t('第一轮没有通过的节点。请检查网络连接，或调高「延迟上限」。', 'No nodes passed round 1. Check your network connection or raise the "Latency cap".')));
        this.toast(lowCount > 0
          ? (this.t('没有可用节点：', 'No usable nodes: ') + lowCount.toString() + this.t(' 个低于合格速度门槛', ' below the minimum speed'))
          : (v6 ? this.t('当前网络可能不支持 IPv6，未发现可用节点', 'Your network may not support IPv6; no usable nodes found') : this.t('没有可用节点，请检查网络或调高延迟上限', 'No usable nodes. Check your network or raise the latency cap.')));
        this.scanning = false;
        this.curTab = 1;
        AppBackground.release('scan');
        return;
      }
      const scope: number = c.speedScope;
      if (!c.enableSpeed) {
        this.addLog(this.t('第一轮筛选完成（测速已关闭），可在「筛选」页查看地区分布', 'Round 1 filtering complete (speed test off). View region distribution on the "Filter" tab.'));
        this.scanning = false;
        this.curTab = 1;
        AppBackground.release('scan');
        return;
      }
      this.curTab = 1;
      if (scope === SpeedScope.REGION) {
        this.addLog(this.t('第一轮筛选完成：请填地区码后点「开始测速」，程序会先做质量预检再正式测速', 'Round 1 filtering complete: enter a region code and tap "Start speed test"; a quality pre-check runs before the real test'));
        this.scanning = false;
        AppBackground.release('scan');
        return;
      }
      this.addLog(this.t('第一轮筛选完成，开始质量预检（三种测速范围都先预检再测速）', 'Round 1 filtering complete; starting quality pre-check (all three speed test scopes pre-check before the real test)'));
      this.runPrecheck(gen, c, myToken).catch((e: BusinessError) => {
        this.scanning = false;
        this.phaseText = this.t('预检出错', 'Pre-check error');
        AppBackground.release('scan');
        this.addLog(this.t('质量预检异常：', 'Quality pre-check error: ') + e.message);
      });
    }).catch((e: BusinessError) => {
      this.scanning = false;
      this.phaseText = this.t('出错', 'Error');
      AppBackground.release('scan');
      this.addLog(this.t('扫描异常：', 'Scan error: ') + e.message);
    });
  }

  /** 第二轮：只对第一轮通过的节点测速（可先填地区码缩小范围） */
  /** 质量预检进度（%）：已检测 / 候选总数；无候选时退化为 0 */
  private pcBarPct(): number {
    // 进度必须和标签「合格 M / 目标 N」同源，否则跑到目标就停、进度条却停在半截
    if (this.precheckDone) {
      // 跑完就满格（含候选提前耗尽的情况），避免"结束后还空一大截"
      return 100;
    }
    const target: number = this.pcTarget > 0 ? this.pcTarget : 0;
    if (target > 0) {
      const q: number = this.pcQualified / target * 100;
      return q < 0 ? 0 : (q > 100 ? 100 : q);
    }
    const total: number = this.pcCandidates > 0 ? this.pcCandidates : 0;
    if (total <= 0) {
      return this.precheckDone ? 100 : 0;
    }
    const p: number = this.pcChecked / total * 100;
    return p < 0 ? 0 : (p > 100 ? 100 : p);
  }

  /** 第一轮结束后：对通过节点做质量预检；达标足够才进正式测速 */
  private async runPrecheck(gen: number, c: ScanConfig, myToken: CancellationToken): Promise<void> {
    this.precheckActive = true;
    this.precheckDone = false;
    this.pcChecked = 0;
    this.pcQualified = 0;
    this.pcTarget = 0;
    this.pcCandidates = 0;
    this.pcExhausted = false;
    this.pcMsg = this.t('正在按延迟从低到高检测合格速度…', 'Checking minimum speed in ascending latency order…');
    this.phaseText = this.t('质量预检', 'Quality pre-check');
    const alive = (): boolean => gen === this.scanGen && !myToken.isCancelled();
    const hooks: ScanHooks = new ScanHooks();
    hooks.onPhase = (phase: number, text: string) => {
      if (alive()) {
        this.phaseText = text;
      }
    };
    hooks.onLog = (msg: string) => {
      if (alive()) {
        this.addLog(msg);
      }
    };
    hooks.onProgress = (done: number, total: number, passed: number, failed: number) => {
      if (!alive()) {
        return;
      }
      this.doneRaw = done;
      this.totalRaw = total;
      this.scheduleProgressSync();
    };
    hooks.onPrecheckStart = (target: number, candidates: number) => {
      if (!alive()) {
        return;
      }
      this.pcTarget = target;
      this.pcCandidates = candidates;
      this.pcMsg = this.t('候选 ', 'Candidates: ') + candidates.toString() + this.t(' 个，目标达标 ', ', target ') + target.toString() + this.t(' 个', ' nodes');
    };
    hooks.onPrecheckTick = (checked: number, qualified: number, inflight: number, target: number) => {
      if (!alive()) {
        return;
      }
      this.pcChecked = checked;
      this.pcQualified = qualified;
      this.pcTarget = target;
      this.pcMsg = this.t('检测 ', 'Checked ') + checked.toString() + this.t(' · 合格 ', ' · Qualified ') +
        (target > 0 && qualified > target ? target : qualified).toString() +
        this.t(' · 在测 ', ' · Testing ') + inflight.toString() + this.t(' · 目标 ', ' · Target ') + target.toString();
    };
    hooks.onPrecheckDone = (qualified: number, checked: number, exhausted: boolean, target: number) => {
      if (!alive()) {
        return;
      }
      this.pcQualified = qualified;
      this.pcChecked = checked;
      this.pcExhausted = exhausted;
      this.pcTarget = target;
      this.precheckDone = true;
    };
    try {
      const res: PrecheckResult = await Scanner.stagePrecheck(c, this.pingList.slice(), hooks, myToken);
      if (!alive()) {
        return;
      }
      this.precheckActive = false;
      this.precheckDone = true;
      this.scanning = false;
      if (res.cancelled) {
        this.phaseText = this.t('已停止', 'Stopped');
        this.pcMsg = this.t('预检已取消', 'Pre-check cancelled');
        this.addLog(this.t('已停止：质量预检未完成', 'Stopped: quality pre-check not finished'));
        AppBackground.release('scan');
        return;
      }
      if (res.list.length === 0) {
        this.pcMsg = this.t('预检后没有达标节点', 'No nodes met the target after pre-check');
        this.phaseText = this.t('预检完成：0 个达标', 'Pre-check complete: 0 met target');
        this.addLog(this.t('质量预检结束：检测 ', 'Quality pre-check finished: checked ') + res.checked.toString() + this.t(' 个，0 个达标；可调低「合格速度」或检查网络', ' nodes, 0 met target; lower "Min speed" or check your network'));
        this.curTab = 1;
        AppBackground.release('scan');
        return;
      }
      // 筛选页只展示「第一轮通过且具备测速资格」的节点
      this.pingList = res.list.slice();
      this.buildGroups(this.pingList);
      this.speedList = [];
      this.speedStates = [];
      this.addLog(this.t('质量预检完成：检测 ', 'Quality pre-check complete: checked ') + res.checked.toString() + this.t(' 个，达标 ', ' nodes, ') +
        res.list.length.toString() + this.t(' 个，开始正式测速', ' met target, starting the real speed test'));
      this.startHeartbeat(gen);
      AppBackground.release('scan');
      this.startSpeedTest(res.list);
    } catch (e) {
      if (!alive()) {
        return;
      }
      this.precheckActive = false;
      this.scanning = false;
      this.phaseText = this.t('预检出错', 'Pre-check error');
      this.addLog(this.t('质量预检异常：', 'Quality pre-check error: ') + (e as BusinessError).message);
      AppBackground.release('scan');
    }
  }

  /** 筛选页「开始测速」：没预检过就先预检，预检过就直接测速 */
  onStartSpeedClick(): void {
    if (this.scanning) {
      return;
    }
    if (this.pingList.length === 0) {
      this.toast(this.t('请先在「扫描」页完成第一轮筛选', 'Complete round 1 filtering on the "Scan" tab first'));
      return;
    }
    if (!this.precheckDone) {
      this.scanGen++;
      const gen: number = this.scanGen;
      this.token = new CancellationToken();
      const myToken: CancellationToken = this.token;
      this.clearScanTimers();
      this.scanning = true;
      AppBackground.hold('scan');
      this.startHeartbeat(gen);
      this.runPrecheck(gen, this.buildConfig(), myToken).catch((e: BusinessError) => {
        this.scanning = false;
        this.phaseText = this.t('预检出错', 'Pre-check error');
        AppBackground.release('scan');
        this.addLog(this.t('质量预检异常：', 'Quality pre-check error: ') + e.message);
      });
      return;
    }
    this.startSpeedTest();
  }

  startSpeedTest(targets?: Candidate[]): void {
    if (this.scanning) {
      return;
    }
    const base: Candidate[] = (targets !== undefined && targets.length > 0) ? targets : this.pingList;
    if (base.length === 0) {
      this.toast(this.t('请先在「扫描」页完成第一轮筛选', 'Complete round 1 filtering on the "Scan" tab first'));
      return;
    }
    this.precheckActive = false;
    const c: ScanConfig = this.buildConfig();
    this.cfg = c;
    ConfigStore.save(c).then(() => {
      return;
    }).catch((e: BusinessError) => {
      this.addLog(this.t('保存配置失败：', 'Failed to save settings: ') + e.message);
    });
    this.scanGen++;
    const gen: number = this.scanGen;
    this.token = new CancellationToken();
    const myToken: CancellationToken = this.token;
    this.clearScanTimers();
    this.scanning = true;
    this.startHeartbeat(gen);
    this.done = 0;
    this.total = 0;
    this.doneRaw = 0;
    this.totalRaw = 0;
    AppBackground.hold('speed');
    // 换地区/换模式重测时，必须清空上一轮的速度结果，否则会残留别的地区的节点
    this.speedList = [];
    this.phaseText = this.t('准备测速', 'Preparing speed test');
    this.curTab = 2;

    const alive = (): boolean => gen === this.scanGen && !myToken.isCancelled();
    const hooks: ScanHooks = new ScanHooks();
    hooks.onPhase = (phase: number, text: string) => {
      if (alive()) {
        this.phaseText = text;
      }
    };
    hooks.onProgress = (done: number, total: number, passed: number, failed: number) => {
      if (!alive()) {
        return;
      }
      this.doneRaw = done;
      this.totalRaw = total;
      this.scheduleProgressSync();
    };
    hooks.onResult = (list: Candidate[]) => {
      if (!alive()) {
        return;
      }
      this.resultsRaw = list;
      this.scheduleResultsSync();
    };
    hooks.onLog = (msg: string) => {
      if (alive()) {
        this.addLog(msg);
      }
    };
    // 测速页先把「全部待测节点」铺出来，再逐个把状态刷成测速中/完成；
    // 排序留到全部结束再做，避免列表在测速过程中不断上蹿下跳。
    hooks.onSpeedInit = (targets: Candidate[]) => {
      if (!alive()) {
        return;
      }
      this.speedList = targets.slice();
      const st: number[] = [];
      for (let i = 0; i < targets.length; i++) {
        st.push(0);
      }
      this.speedStates = st;
    };
    hooks.onSpeedTick = (index: number, cand: Candidate, done: boolean) => {
      if (!alive()) {
        return;
      }
      const st: number[] = this.speedStates.slice();
      if (index >= 0 && index < st.length) {
        st[index] = done ? (cand.speedOk ? 2 : 3) : 1;
      }
      this.speedStates = st;
      const list: Candidate[] = this.speedList.slice();
      if (index >= 0 && index < list.length) {
        list[index] = cand;
      }
      this.speedList = list;
    };

    Scanner.runSpeed(c, base, hooks, myToken).then(() => {
      if (gen !== this.scanGen) {
        return;
      }
      if (myToken.isCancelled()) {
        // 被用户停止时也要复位 scanning，否则「重新测速」按钮会被
        // startSpeedTest 开头的 if (this.scanning) return 挡住，看起来像没反应。
        this.scanning = false;
        this.phaseText = this.t('已停止', 'Stopped');
        this.addLog(this.t('已停止测速', 'Speed test stopped'));
        AppBackground.release('speed');
        return;
      }
      this.scanning = false;
      this.phaseText = this.t('测速完成', 'Speed test complete');
      Ranker.apply(this.results, c);
      this.splitResults(this.results);
      this.addLog(this.t('第二轮测速完成，共 ', 'Round 2 speed test complete: ') + this.speedList.length.toString() + this.t(' 个节点', ' nodes'));
      // 开了自动上传就把这批结果推到 edgetunnel 订阅；配置不完整时记一条日志后台跳过，
      // 避免每次测速结束都弹失败提示。
      if (this.etEnabled) {
        if (!this.etReady()) {
          this.addLog(this.t('已开启订阅自动上传，但', 'Subscription auto-upload is on, but ') + (this.etWay === 1 ? this.t('API 直传参数', 'API direct upload parameters') : this.t('域名或密码', 'the domain or password')) + this.t('未填，跳过本次上传', ' not set; skipping this upload'));
        } else {
          this.uploadEdgeTunnel(true);
        }
      }
      AppBackground.release('speed');
    }).catch((e: BusinessError) => {
      this.scanning = false;
      this.phaseText = this.t('测速出错', 'Speed test error');
      AppBackground.release('speed');
      this.addLog(this.t('测速异常：', 'Speed test error: ') + e.message);
    });
  }
  stopScan(): void {
    // 1) 递增代次：让所有旧任务的回调（进度/结果/日志/阶段）立刻失效；
    // 2) 取消本轮令牌：正在执行的并发池在安全点停下；
    // 3) 清掉节流定时器与心跳，避免停后还有一次“迟到写入”。
    this.scanGen++;
    this.token.cancel();
    this.scanning = false;
    this.clearScanTimers();
    this.stopHeartbeat();
    this.phaseText = this.t('已停止', 'Stopped');
    this.addLog(this.t('用户停止了扫描', 'User stopped the scan'));
    AppBackground.release('scan');
    AppBackground.release('speed');
  }

  /** 清掉进度/结果/日志的节流定时器，防止旧一轮的迟到刷新覆盖新任务 */
  private clearScanTimers(): void {
    if (this.progTimer >= 0) {
      clearTimeout(this.progTimer);
      this.progTimer = -1;
    }
    if (this.resultTimer >= 0) {
      clearTimeout(this.resultTimer);
      this.resultTimer = -1;
    }
    if (this.logTimer >= 0) {
      clearTimeout(this.logTimer);
      this.logTimer = -1;
    }
    this.logBuf = [];
  }

  /** 后台心跳：每 5s 记一次真实完成数；用于区分“任务冻结”和“UI 没刷新” */
  private startHeartbeat(gen: number): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (gen !== this.scanGen || !this.scanning) {
        this.stopHeartbeat();
        return;
      }
      this.addLog(this.t('运行中 · 完成 ', 'Running · Done ') + this.doneRaw.toString() + '/' + this.totalRaw.toString() +
        this.t(' · 通过 ', ' · Passed ') + this.passedRaw.toString() + this.t('（后台保活', ' (background keep-alive: ') + (AppBackground.enabled ? this.t('开', 'On') : this.t('关', 'Off')) + '）');
    }, 5000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  /** 回到前台：立即用真实计数刷新一次，避免节流定时器在后台被挂起导致界面停在旧进度 */
  onPageShow(): void {
    if (this.navPillX <= 0) {
      this.navPillX = this.navTabCenter(this.curTab);
      this.setPillScale(1.0, 0, 0);
    }
    this.done = this.doneRaw;
    this.total = this.totalRaw;
    this.passed = this.passedRaw;
    this.failed = this.failedRaw;
    if (this.scanning && this.progTimer < 0) {
      this.scheduleProgressSync();
    }
  }

  async doExport(fmt: ExportFormat): Promise<void> {
    if (this.speedList.length === 0) {
      this.toast(this.t('还没有测速结果', 'No speed test results yet'));
      return;
    }
    if (this.ctx === undefined || this.ctx === null) {
      this.toast(this.t('上下文未就绪', 'App context not ready'));
      return;
    }
    const opt = defaultExportOptions();
    opt.format = fmt;
    opt.onlyQualified = false;
    let text: string = '';
    if (fmt === ExportFormat.CSV) {
      text = Exporter.toCsv(this.speedList, opt);
    } else {
      text = Exporter.toText(this.speedList, opt);
    }
    const name: string = Exporter.suggestFileName(fmt, this.cfg);
    try {
      const saved: string = await FileSaver.saveText(this.ctx, name, text);
      if (saved.length === 0) {
        this.toast(this.t('已取消保存', 'Save cancelled'));
        this.addLog(this.t('导出已取消', 'Export cancelled'));
        return;
      }
      this.toast(this.t('已保存：', 'Saved: ') + saved);
      this.addLog(this.t('导出 ', 'Export ') + name + ' → ' + saved);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.toast(this.t('保存失败：', 'Save failed: ') + err.message);
      this.addLog(this.t('导出失败：', 'Export failed: ') + err.message);
    }
  }
  // ---------- 主题色 ----------
  bg1(): string {
    return this.dark ? '#09090B' : '#F3F5FA';
  }

  bg2(): string {
    return this.dark ? '#111114' : '#E9EEFB';
  }

  cardBg(): string {
    const a: string = this.cardLevelAlpha().toFixed(2);
    return this.dark ? ('rgba(48,52,64,' + a + ')') : ('rgba(255,255,255,' + a + ')');
  }

  lineC(): string {
    return this.dark ? 'rgba(255,255,255,0.08)' : 'rgba(15,23,42,0.08)';
  }

  txt(): string {
    return this.dark ? '#FAFAFA' : '#0F172A';
  }

  txt2(): string {
    return this.dark ? '#A1A1AA' : '#475569';
  }

  txt3(): string {
    return this.dark ? '#8B8B95' : '#64748B';
  }

  soft(): string {
    return this.dark ? 'rgba(255,255,255,0.06)' : 'rgba(15,23,42,0.05)';
  }

  inputBg(): string {
    return this.dark ? 'rgba(255,255,255,0.06)' : 'rgba(15,23,42,0.04)';
  }

  coloText(c: Candidate): string {
    if (c.colo.length === 0) {
      return this.t('未知地区', 'Unknown region');
    }
    return Geo.placeZh(c.colo.toUpperCase());
  }

  delayText(c: Candidate): string {
    const d: number = Ranker.delayOf(c);
    if (d < 0) {
      return '—';
    }
    return Math.round(d).toString() + ' ms';
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 页面底色：有自定义背景图时用图片（objectFit Cover 自适应手机/平板/电脑），
      // 并在其上叠一层半透明蒙版保证文字可读；没设置时回落到渐变。
      if (this.bgPath.length > 0) {
        Image('file://' + this.bgPath)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(this.bgBlurPx())
          .brightness(this.bgBrightFactor())
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        // 自定义背景图模式：不再叠加整屏主题遮罩，保留图片原始色彩与明暗；
        // 可读性由卡片自身材质/文字颜色保证（cardLevelAlpha/cardTint 已针对图片模式抬高）
        Blank()
          .width('100%')
          .height(0)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 160,
            colors: this.dark
              ? [['#0C0D12', 0.0], ['#171A24', 0.45], ['#202433', 1.0]]
              : [['#EAEFF6', 0.0], ['#E3E9F2', 0.55], ['#DBE3EE', 1.0]]
          })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        if (!this.dark) {
          // 浅色环境光：主题色极淡渐变，避免整屏纯白刺眼
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 200,
              colors: [[this.accentRgba(0.10), 0.0], [this.accentRgba(0.0), 0.45],
                [this.accentRgba(0.04), 1.0]]
            })
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
            .hitTestBehavior(HitTestMode.None)
        }
        this.AuroraLayer()
      }

      // 正常流式布局：标题区在最顶上直接占位，不再用覆盖层遮罩
        // 顶层：标题层，与模糊条同一垂直位置，全程不做任何模糊
        Column() {
          Stack({ alignContent: Alignment.TopStart }) {


            // 标题文字画在模糊条之上，自身不模糊

            // 标题文字画在模糊层之上，自身不模糊（模糊由各页面 Scroll 的 linearGradientBlur 承担）
            Column() {
              Row() {
                Text('CFLark')
                  .fontSize(26)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.txt())
                Text('v' + this.appVersion)
                  .fontSize(12)
                  .fontColor(this.txt3())
                  .margin({ left: 8, top: 8 })
                Blank()
                Text(this.themeLabel())
                  .fontSize(12)
                  .fontColor(this.txt2())
                  .textAlign(TextAlign.Center)
                  .height(this.CHIP_H)
                  .padding({ left: 12, right: 12 })
                  .borderRadius(this.CHIP_H / 2)
                  .backgroundColor(this.shouldUseCardMaterial() ? Color.Transparent : this.soft())
                  .linearGradient({ angle: 180, colors: this.floatSheen() })
                  .backgroundBlurStyle(this.shouldUseCardMaterial() ? BlurStyle.COMPONENT_THIN : BlurStyle.NONE)
                  .border({ width: 1, color: this.navGlassBorder() })
                .shadow({
                  radius: this.dark ? 12 : 14,
                  color: this.dark ? 'rgba(0,0,0,0.5)' : 'rgba(15,23,42,0.12)',
                  offsetX: 0,
                  offsetY: 4
                })
                .onClick(() => {
                  this.setThemeMode((this.themeMode + 1) % 3);
                })
                .accessibilityText(this.t('切换外观模式，当前', 'Switch appearance mode; current: ') + this.themeLabel())
              }
              .alignItems(VerticalAlign.Center)
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ left: 20, right: 20, top: px2vp(this.statusBarPx) + 10 })
          }
          .width('100%')
        }
        .width('100%')
        .position({ x: 0, y: 0 })
        .onAreaChange((_o: Area, n: Area) => {
          const h: number = Number(n.height);
          if (h > 0 && Math.abs(h - this.headerH) > 0.5) {
            this.headerH = h;
          }
        })

.zIndex(3)


        Stack({ alignContent: Alignment.Top }) {
          // 语言切换时重建内容树：@Builder 的按值参数不会随状态刷新，
          // 只有重建节点才能让「已渲染页面上的文案」立即变成新语言。
          if (this.langEn) {
            this.TabsCore()
          } else {
            this.TabsCore()
          }


        // 顶部滚动边缘模糊已改由各页面 Scroll 的 linearGradientBlur 承担（单节点、无条带、无蒙版）

        }
        .width('100%')
        .layoutWeight(1)
      .width('100%')
      .height('100%')
      // 已开全屏：背景由下层 Stack 铺满，这里把「标题 / 按钮 / 列表」整体压到状态栏下方，
      // 避免标题和状态栏时间、电池图标叠在一起。
    .padding({ top: 0 })
      .opacity(this.pageOpacity)
    .scale({ x: this.pageScale, y: this.pageScale })
      // 底部滚动边缘模糊已改由各页面 Scroll 的 linearGradientBlur 承担
      // 右下角「回到顶部」悬浮按钮：扫描 / 筛选 / 测速 / 设置 四个页面通用，
      // 当前页向下滚动超过一屏（420vp）后出现。
      if (this.showBackTop) {
        Stack() {
          Text('↑')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accentText())
        }
        .width(this.fabSize())
        .height(this.fabSize())
        .borderRadius(this.fabSize() / 2)
        .backgroundColor(this.shouldUseCardMaterial() ? Color.Transparent : (this.dark ? 'rgba(39,39,46,0.92)' : 'rgba(255,255,255,0.94)'))
        .linearGradient({ angle: 180, colors: this.floatSheen() })
        .backgroundBlurStyle(this.shouldUseCardMaterial() ? BlurStyle.COMPONENT_THIN : BlurStyle.NONE)
        .border({ width: 1, color: this.navGlassBorder() })
        .shadow({
          radius: this.dark ? 16 : 18,
          color: this.dark ? 'rgba(0,0,0,0.55)' : 'rgba(15,23,42,0.16)',
          offsetX: 0,
          offsetY: 6
        })
        .margin({ right: this.fabRight(), bottom: this.fabBottom() })
        .onClick(() => {
          if (this.curTab === 0) {
            this.scanScroller.scrollEdge(Edge.Top);
          } else if (this.curTab === 1) {
            this.pingScroller.scrollEdge(Edge.Top);
          } else if (this.curTab === 2) {
            this.speedScroller.scrollEdge(Edge.Top);
          } else {
            this.settingsScroller.scrollEdge(Edge.Top);
          }
          this.anyScrollY = 0;
          if (this.showBackTop) {
            this.showBackTop = false;
          }
        })
      }

      // 参数说明：整屏轻量弹窗（点击遮罩或「知道了」关闭，输入内容不受影响）
      if (this.showParamNotes) {
        this.ParamNotesSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.dark ? '#202433' : '#DBE3EE')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindContentCover($$this.showChangelogDialog, this.UpgradeCover(), {
      modalTransition: ModalTransition.DEFAULT
    })
    .onAreaChange((oldV: Area, newV: Area) => {
      const w: number = newV.width as number;
      if (w > 0 && Math.abs(w - this.winW) > 1) {
        this.winW = w;
        this.navPillX = this.navTabCenter(this.curTab);
      }
    })
  }

  @Builder Header() {
    Column() {
      Text('CFLark')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.txt())
      Text(this.t('Cloudflare 智能优选 · v', 'Cloudflare smart selection · v') + this.appVersion)
        .fontSize(12)
        .fontColor(this.txt3())
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 20, right: 20 })
  }

  @Builder ActionBar() {
    Column() {

      // 进度条独占一行；说明文字放到进度条下方，避免和进度条抢宽度
      Column() {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(9)
            .backgroundColor(this.soft())
            .borderRadius(3)
          Row()
            .width(((this.total > 0 ? this.done / this.total : 0) * 100).toFixed(1) + '%')
            .height(9)
            .linearGradient({
              angle: 90,
              colors: this.progressTint()
            })
            .borderRadius(3)
        }
        .width('100%')
        .height(9)
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text(this.progressLabel())
            .fontSize(12)
            .fontColor(this.txt3())
            .margin({ right: 12, top: 6 })
          if (this.pingList.length > 0) {
            Text(this.t('可用 ', 'Available ') + this.pingList.length.toString() + this.t(' 个', ' nodes'))
              .fontSize(12)
              .fontColor(this.txt3())
              .margin({ top: 6 })
          }
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 10 })
    }
    .width('100%')
    .constraintSize({ maxWidth: 1600 })
    .padding({ left: 0, right: 0, top: 0, bottom: 14 })
  }
  /**
   * 光感等级 → 底部胶囊的系统毛玻璃材质。
   * 只在这 64vp 的小面积上用 BlurStyle —— 卡片之前用 COMPONENT_THICK 时，
   * 平板上的大卡片会被系统把材质自身的灰调放大成深灰，所以卡片保持手绘半透明。
   */


  /** 当前设备是否支持系统沉浸材质（不支持的设备自动退回手绘玻璃） */
  /** 当前生效的材质厚度档位 0..4；关闭材质或设备不支持时返回 -1 */
  private glassThickness(): number {
    if (!this.shouldUseCardMaterial()) {
      return -1;
    }
    const st: uiMaterial.ImmersiveStyle = this.immersiveStyle();
    if (st === uiMaterial.ImmersiveStyle.ULTRA_THIN) {
      return 0;
    }
    if (st === uiMaterial.ImmersiveStyle.THIN) {
      return 1;
    }
    if (st === uiMaterial.ImmersiveStyle.REGULAR) {
      return 2;
    }
    if (st === uiMaterial.ImmersiveStyle.THICK) {
      return 3;
    }
    return 4;
  }

  /** 材质着色浓度：越薄越淡，让背景透上来 */
  private glassTintAlpha(): number {
    const t: number = this.glassThickness();
    if (this.dark) {
      return t <= 1 ? 0.10 : (t === 2 ? 0.14 : 0.18);
    }
    return t <= 1 ? 0.08 : (t === 2 ? 0.12 : 0.16);
  }

  private glassStyleOf(th: number): uiMaterial.ImmersiveStyle {
    if (th <= 0) {
      return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    }
    if (th === 1) {
      return uiMaterial.ImmersiveStyle.THIN;
    }
    if (th === 2) {
      return uiMaterial.ImmersiveStyle.REGULAR;
    }
    if (th === 3) {
      return uiMaterial.ImmersiveStyle.THICK;
    }
    return uiMaterial.ImmersiveStyle.ULTRA_THICK;
  }

  private glassModifier(radius: number): AttributeModifier<ToggleAttribute> {
    const th: number = this.glassThickness();
    return new GlassCarrierModifier(
      MatStore.immersive(this.glassStyleOf(th), this.dark, this.glassTintAlpha(), false, false, ''), radius);
  }

  /**
   * 卡片玻璃底：用 Toggle(ToggleType.Button) 承载系统材质。
   * Toggle 是官方「全页面可渲染 systemMaterial」的白名单组件之一，
   * 普通容器（Stack/Column/Row）在内容区设置材质不会渲染。
   * 放在 background 层：不参与布局，不会把卡片撑高，也不拦截交互。
   */
  @Builder GlassBackdrop() {
    Stack() {
      if (this.shouldUseCardMaterial()) {
        Toggle({ type: ToggleType.Button, isOn: false }) {
          Text('')
            .fontSize(0)
        }
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .backgroundColor(Color.Transparent)
        .enabled(false)
        .focusable(false)
        .hitTestBehavior(HitTestMode.None)
        .attributeModifier(this.glassModifier(20))
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /** 任意 hex 色 + 透明度 → rgba 字符串 */
  private hueRgba(hex: string, alpha: number): string {
    const r: number = Number.parseInt(hex.substring(1, 3), 16);
    const g: number = Number.parseInt(hex.substring(3, 5), 16);
    const b: number = Number.parseInt(hex.substring(5, 7), 16);
    return 'rgba(' + r.toString() + ',' + g.toString() + ',' + b.toString() + ',' + alpha.toFixed(2) + ')';
  }

  /**
   * 背景光斑层：在底色之上铺 3 团柔光。
   * 没有明暗与色彩变化时，系统材质/模糊都没有可折射的内容，
   * 玻璃看起来就只是"更黑一点的块"——这层是玻璃质感的物理前提。
   */
  @Builder AuroraLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Circle()
        .width(this.winW * 1.20)
        .height(this.winW * 1.20)
        .radialGradient({
          center: [this.winW * 0.60, this.winW * 0.60],
          radius: this.winW * 0.60,
          colors: [[this.accentRgba(this.dark ? 0.34 : 0.26), 0.0],
            [this.accentRgba(this.dark ? 0.13 : 0.11), 0.42],
            [this.accentRgba(0.0), 1.0]]
        })
        .position({ x: -this.winW * 0.46, y: -this.winW * 0.34 })
        .fill(Color.Transparent)
      Circle()
        .width(this.winW * 1.05)
        .height(this.winW * 1.05)
        .radialGradient({
          center: [this.winW * 0.525, this.winW * 0.525],
          radius: this.winW * 0.525,
          colors: [[this.hueRgba('#5B7CFA', this.dark ? 0.30 : 0.20), 0.0],
            [this.hueRgba('#5B7CFA', this.dark ? 0.10 : 0.08), 0.40],
            [this.hueRgba('#5B7CFA', 0.0), 1.0]]
        })
        .position({ x: this.winW * 0.40, y: this.winH * 0.26 })
        .fill(Color.Transparent)
      Circle()
        .width(this.winW * 0.95)
        .height(this.winW * 0.95)
        .radialGradient({
          center: [this.winW * 0.475, this.winW * 0.475],
          radius: this.winW * 0.475,
          colors: [[this.hueRgba('#2DD4BF', this.dark ? 0.20 : 0.16), 0.0],
            [this.hueRgba('#2DD4BF', 0.0), 1.0]]
        })
        .position({ x: -this.winW * 0.34, y: this.winH * 0.60 })
        .fill(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  matSupported(): boolean {
    return uiMaterial.isImmersiveMaterialSupported();
  }

  /**
   * 材质等级：自适应 / 精致 / 柔和 / 平滑 → 系统沉浸材质厚度。
   * 自适应时读系统给本机的算力档位（getGlobalMaterialLevel）。
   */
  private styleOfLevel(): uiMaterial.ImmersiveStyle {
    const e: number = this.effLevel();
    if (e === 0) {
      return this.matType === 1 ? uiMaterial.ImmersiveStyle.ULTRA_THICK : uiMaterial.ImmersiveStyle.THICK;
    }
    if (e === 1) {
      return this.matType === 1 ? uiMaterial.ImmersiveStyle.THICK : uiMaterial.ImmersiveStyle.REGULAR;
    }
    return this.matType === 1 ? uiMaterial.ImmersiveStyle.REGULAR : uiMaterial.ImmersiveStyle.THIN;
  }

  /** 材质类型/等级名称，用于设置页状态提示 */
  /** 胶囊底色：随「材质类型/材质等级」变化，使材质选项可见生效 */
  private barTint(): string {
    const a: number = (this.matType === 2 || !this.globalImmersion) ? 0.96 : (this.matLevel === 1 ? 0.84 : (this.matLevel === 2 ? 0.90 : 0.94));
    const s: string = a.toFixed(2);
    if (this.dark) {
      return 'rgba(30,32,40,' + s + ')';
    }
    return 'rgba(255,255,255,' + s + ')';
  }

  private matTypeName(): string {
    if (this.matType === 1) {
      return this.t('沉浸', 'Immersive');
    }
    if (this.matType === 2) {
      return this.t('无材质', 'No material');
    }
    return this.t('自适应', 'Adaptive');
  }

  private matLevelName(): string {
    if (this.matLevel === 1) {
      return this.t('精致', 'Exquisite');
    }
    if (this.matLevel === 2) {
      return this.t('柔和', 'Gentle');
    }
    if (this.matLevel === 3) {
      return this.t('平滑', 'Smooth');
    }
    return this.t('自适应', 'Adaptive');
  }

  /**
   * 底部胶囊的系统沉浸材质。
   * 注意：这里刻意不使用 colorInvert，也不给白色 lightEffect —— 之前正是这两项
   * 让「等级越高、材质越厚」时反而整条导航越拉越白（浅色底 + 白色高光叠加）。
   * 现在改成带一点页面底色的深/浅中性 tint，厚度只影响通透度，不影响白度。
   */
  private tabBarMaterial(): uiMaterial.Material {
    // 缓存：避免每次 rebuild 都 new 一个材质对象（切档卡顿的主因）
    const key: string = (this.matSupported() ? '1' : '0') + '|' + (this.globalImmersion ? '1' : '0') + '|' +
      this.matType.toString() + '|' + this.matLevel.toString() + '|' + (this.dark ? '1' : '0');
    if (this.matCacheKey === key) {
      return this.matCached;
    }
    this.matCacheKey = key;
    if (!this.matSupported() || !this.globalImmersion || this.matType === 2) {
      this.matCached = uiMaterial.Material.empty;
      return this.matCached;
    }
    const opt: uiMaterial.ImmersiveOptions = {
      style: this.styleOfLevel(),
      materialColor: this.dark ? 'rgba(14,16,22,0.42)' : 'rgba(228,233,244,0.18)',
      applyShadow: true,
      interactive: true,
      lightEffect: { color: this.dark ? '#26FFFFFF' : '#33FFFFFF' }
    };
    this.matCached = new uiMaterial.ImmersiveMaterial(opt);
    return this.matCached;
  }

  // ===== HDS 系统材质（对标 OpenAuthenticator） =====

  /** 材质类型 -> hdsMaterial.MaterialType（OA 12136-12144） */
  private hdsMatType(): hdsMaterial.MaterialType {
    if (!this.globalImmersion || !this.matSupported() || this.matType === 2) {
      return hdsMaterial.MaterialType.NONE;
    }
    if (this.matType === 1) {
      return hdsMaterial.MaterialType.IMMERSIVE;
    }
    return hdsMaterial.MaterialType.ADAPTIVE;
  }

  /** 材质等级 -> hdsMaterial.MaterialLevel（OA 12146-12157） */
  private hdsMatLevel(): hdsMaterial.MaterialLevel {
    if (this.matLevel === 1) {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (this.matLevel === 2) {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (this.matLevel === 3) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  /** 全局开关 + 类型非 NONE 才走系统材质（OA shouldUseCardMaterial 12180-12182） */
  private shouldUseCardMaterial(): boolean {
    return this.globalImmersion && this.matType !== 2 && this.matSupported();
  }

  private systemMatParams(): SystemMaterialParams {
    return { materialType: this.hdsMatType(), materialLevel: this.hdsMatLevel() };
  }

  private measuredCardHeight(cardId: string): number {
    const h: number | undefined = this.measuredCardHeights.get(cardId);
    return h === undefined ? 0 : h;
  }

  private updateMeasuredCardHeight(cardId: string, area: Area): void {
    const h: number = area.height as number;
    if (h <= 0 || Math.abs(h - this.measuredCardHeight(cardId)) <= 0.5) {
      return;
    }
    const next: Map<string, number> = new Map(this.measuredCardHeights);
    next.set(cardId, h);
    this.measuredCardHeights = next;
  }

  /** 材质条高度 = 卡片高度；宽度横向多撑出两倍高度，让圆角端点落在裁剪区外（OA 1839-1845） */
  private immersionBarHeight(h: number): number {
    return h;
  }

  private immersionExpandedWidth(h: number): number {
    return Math.max(this.winW, 400) + this.immersionBarHeight(h) * 2;
  }

  /** 卡片系统材质层：HdsTabs 悬浮 bar + systemMaterialEffect（OA 1676-1717） */
  private floatStyle(lightC: string): HdsTabsFloatingStyle {
    const st: HdsTabsFloatingStyle = {
      barBottomMargin: 0,
      systemMaterialEffect: this.systemMatParams(),
      gradientMask: { maskColor: '#09999999' }
    };
    if (lightC.length > 0) {
      st.lightColor = lightC;
    }
    return st;
  }

  /** 真实导航栏的官方沉浸光感样式：底距避开手势区，左右各留 20vp */
  private navFloatStyle(): HdsTabsFloatingStyle {
    // 底距：手势条高度 + 余量；取不到手势条高度时也给一个最小距，避免贴住系统导航栏
    const barH: number = px2vp(this.navBarPx);
    const st: HdsTabsFloatingStyle = {
      barBottomMargin: Math.max(barH + 18, 28),   // 与系统「联系人」悬浮栏对齐：底距 28vp、高度 56vp
      barSideMargin: 20,

      barWidth: { smallWidth: 270, mediumWidth: 270, largeWidth: 400 },
      systemMaterialEffect: this.systemMatParams(),
      // HDS 悬浮页签默认会在页面底部铺一层 maskColor 渐变遮罩（默认 maskHeight = 组件高 +32vp），
      // 浅色下呈灰白带、深色下呈暗带 —— 这就是「屏幕底部比顶部发白」的来源。置为全透明即可。
      gradientMask: { maskColor: '#00000000' }
    };
    // 深色模式不再注入浅色，否则底部条带会发白
    if (!this.dark) {
      st.lightColor = this.accent();
    }
    return st;
  }

  @Builder ImmersionMaterialLayer(cardHeight: number, cardRadius: number, lightC: string) {
    Stack({ alignContent: Alignment.Center }) {
      HdsTabs() {
        TabContent() {
        }
        .backdropBlur(0)
        .tabBar(this.ImmersionMaterialContent(cardHeight))
        .clip(false)
      }
      .width(this.immersionExpandedWidth(cardHeight))
      .height(cardHeight)
      .barWidth(this.immersionExpandedWidth(cardHeight))
      .barHeight(this.immersionBarHeight(cardHeight))
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .barBackgroundStyle({ maskColor: '#00000000' })
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .barFloatingStyle(this.floatStyle(lightC))
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.None)
      .clip(false)
    }
    .width('100%')
    .height(cardHeight)
    .borderRadius(cardRadius)
    .clip(true)
    .backgroundColor(Color.Transparent)
    .hitTestBehavior(HitTestMode.None)
    .zIndex(0)
  }

  @Builder ImmersionMaterialContent(cardHeight: number) {
    Stack()
      .width(this.immersionExpandedWidth(cardHeight))
      .height(this.immersionBarHeight(cardHeight))
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.None)
  }

  /** 材质档位 -> 沉浸材质厚度：精致更厚、柔和中等、平滑更薄；自适应跟随设备等级 */
  private immersiveStyle(): uiMaterial.ImmersiveStyle {
    let lv: number = this.matLevel;
    if (lv === 0) {
      const g: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
      lv = g === uiMaterial.MaterialLevel.EXQUISITE ? 1 : (g === uiMaterial.MaterialLevel.GENTLE ? 2 : 3);
    }
    if (lv === 1) {
      return uiMaterial.ImmersiveStyle.THICK;
    }
    if (lv === 2) {
      return uiMaterial.ImmersiveStyle.REGULAR;
    }
    return uiMaterial.ImmersiveStyle.THIN;
  }

  /** 卡片材质对象；关闭时返回 Material.empty（组件级关闭材质） */
  private cardMaterial(): uiMaterial.Material {
    if (!this.shouldUseCardMaterial()) {
      return uiMaterial.Material.empty;
    }
    const opt: uiMaterial.ImmersiveOptions = {
      style: this.immersiveStyle(),
      materialColor: Color.Transparent,
      colorInvert: this.dark,
      applyShadow: false,
      interactive: false
    };
    return new uiMaterial.ImmersiveMaterial(opt);
  }

  /** 导航栏静止态材质：薄玻璃（THIN）；拖动中由调用方传 undefined */
  private navMaterial(): uiMaterial.Material {
    if (!this.shouldUseCardMaterial()) {
      return uiMaterial.Material.empty;
    }
    const opt: uiMaterial.ImmersiveOptions = {
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: Color.Transparent,
      colorInvert: this.dark,
      applyShadow: false,
      interactive: false
    };
    return new uiMaterial.ImmersiveMaterial(opt);
  }

  /** 卡片系统材质层：组件级 systemMaterial，直接铺满卡片（不再用 HdsTabs 悬浮 bar） */
  /**
   * 历史上这里放的是 systemMaterial 承载层。实测 systemMaterial 在内容区（Stack/Column）不生效
   * （真机日志：Material inactive: out of scope），而且 .height('100%') 在 Scroll 内会按可视区解析，
   * 把卡片撑高、在页面底部留下大片空白。材质已改由卡片自身的 backgroundBlurStyle + 渐变底色实现，
   * 因此这里保留空实现，只为兼容既有调用点。
   */
  @Builder MeasuredImmersionCard(cardId: string, cardRadius: number) {
  }

  /** 光感等级对卡片厚度的影响：等级越高卡片越实、阴影越深 */
  /**
   * 卡片底色不透明度。
   * 叠加自定义背景图时（底图细节多）整体抬高 scrim，保证正文/次要文字可读；
   * 渐变背景保持原档位，避免卡片看起来发灰。
   */
  private cardLevelAlpha(): number {
    const onPhoto: boolean = this.bgPath.length > 0;
    const lift: number = onPhoto ? 0.12 : 0;
    const e: number = this.effLevel();
    if (e < 0) {
      return Math.min(0.98, 0.94 + lift);
    }
    if (e === 0) {
      return Math.min(0.60, 0.24 + lift);
    }
    if (e === 1) {
      return Math.min(0.72, 0.42 + lift);
    }
    return Math.min(0.86, 0.62 + lift);
  }

  private cardShadowR(): number {
    const e: number = this.effLevel();
    if (e < 0) {
      return 4;
    }
    if (e === 0) {
      return 28;
    }
    if (e === 1) {
      return 20;
    }
    return 12;
  }

  /** 光感等级的名称，用于设置页状态提示 */
  private glassLevelName(): string {
    if (this.glassLevel === 0) {
      return this.t('弱', 'Weak');
    }
    if (this.glassLevel === 1) {
      return this.t('标准', 'Standard');
    }
    if (this.glassLevel === 2) {
      return this.t('强', 'Strong');
    }
    return this.t('极致', 'Ultra');
  }

  /** 系统沉浸材质档位名称（对齐 uiMaterial.ImmersiveStyle） */
  private glassStyleName(): string {
    if (this.glassLevel === 0) {
      return 'Ultra Thin';
    }
    if (this.glassLevel === 1) {
      return 'Thin';
    }
    if (this.glassLevel === 2) {
      return 'Regular';
    }
    return 'Thick';
  }

  /** 底部胶囊宽度（vp） */
  private tabBarW(): number {
    if (this.winW >= 900) {
      return 460;
    }
    return this.winW > 240 ? Math.min(320, this.winW * 0.80) : 300;
  }




  /** 主题色（对齐参考项目的 6 套配色，默认灰豆沙粉） */
  private themeColorAt(idx: number): string {
    if (idx === 0) {
      return '#D8C24F'; // 柠檬黄
    }
    if (idx === 1) {
      return '#E8D2A6'; // 奶油黄
    }
    if (idx === 2) {
      return '#A6BFA1'; // 鼠尾草绿
    }
    if (idx === 3) {
      return '#93A9C9'; // 雾霾蓝
    }
    if (idx === 4) {
      return '#C9A3A6'; // 灰豆沙粉
    }
    return '#2E2E33';   // 清透炭黑
  }

  private themeColorName(idx: number): string {
    if (idx === 0) {
      return this.t('柠檬黄', 'Lemon yellow');
    }
    if (idx === 1) {
      return this.t('奶油黄', 'Cream yellow');
    }
    if (idx === 2) {
      return this.t('鼠尾草绿', 'Sage green');
    }
    if (idx === 3) {
      return this.t('雾霾蓝', 'Haze blue');
    }
    if (idx === 4) {
      return this.t('灰豆沙粉', 'Muted rose');
    }
    return this.t('清透炭黑', 'Clear charcoal');
  }

  /** 当前主题色：主按钮、选中 chip、滑块都用它 */
  /** 浅色模式下压暗主题色：小字号文字/图标落在浅玻璃上需要更高对比度 */
  /** 浅色模式下把主题色填充压深一档：白字落在浅粉/浅黄上有足够对比度 */
  private accentFill(): string {
    const c: string = this.accent();
    if (this.dark) {
      return c;
    }
    const hex2 = (v: number): string => (v < 16 ? '0' : '') + v.toString(16);
    const r: number = Math.round(Number.parseInt(c.substring(1, 3), 16) * 0.84);
    const g: number = Math.round(Number.parseInt(c.substring(3, 5), 16) * 0.84);
    const b: number = Math.round(Number.parseInt(c.substring(5, 7), 16) * 0.84);
    return '#' + hex2(r) + hex2(g) + hex2(b);
  }

  private accentText(): string {
    const c: string = this.accent();
    if (this.dark) {
      return c;
    }
    const hex2 = (v: number): string => (v < 16 ? '0' : '') + v.toString(16);
    const r: number = Math.round(Number.parseInt(c.substring(1, 3), 16) * 0.62);
    const g: number = Math.round(Number.parseInt(c.substring(3, 5), 16) * 0.62);
    const b: number = Math.round(Number.parseInt(c.substring(5, 7), 16) * 0.62);
    return '#' + hex2(r) + hex2(g) + hex2(b);
  }

  accent(): string {
    return this.themeColorAt(this.themeColorIdx);
  }

  /** 系统材质档位名称（设置页提示用） */
  private styleName(): string {
    const s: uiMaterial.ImmersiveStyle = this.styleOfLevel();
    if (s === uiMaterial.ImmersiveStyle.ULTRA_THIN || s === uiMaterial.ImmersiveStyle.THIN) {
      return this.t('薄玻璃', 'Thin glass');
    }
    if (s === uiMaterial.ImmersiveStyle.REGULAR) {
      return this.t('中玻璃', 'Medium glass');
    }
    return this.t('厚玻璃', 'Thick glass');
  }

  /** 背景图模糊半径（0~50vp） */
  private bgBlurPx(): number {
    return this.bgBlurPct / 100 * 50;
  }

  /**
   * 滚动视口上下边缘的线性渐变模糊 stops（linearGradientBlur 用）。
   * stops 位置是「占视口高度的比例」，所以必须用 Scroll 实测高度归一化：
   *   顶部模糊带固定 118vp、底部模糊带固定 106.7vp（沿用改造前条带的覆盖范围），
   *   换算成比例后上下两端在平板/手机/横竖屏下都落在真实屏位置，不会漂移。
   * 带内的衰减曲线照搬 OpenAuthenticator 参考 stops 的相对位置与相对强度：
   *   顶部带内 0 / 0.278 / 0.611 / 1 → 模糊 1 / 0.7 / 0.3 / 0
   *   底部带内 0 / 0.444 / 0.722 / 1 → 模糊 0 / 0.35 / 0.7 / 1
   * 单次调用同时表达上下两端，因此所有位置必须严格递增（见下方 clamp）。
   */
  private lgStops(h: number): FractionStop[] {
    const vh: number = h > 0 ? h : (this.winH > 0 ? this.winH : 780);
    // 视口过矮时两带会交叠，clamp 保证 topCut < botStart，避免 stops 非递增被丢弃
    const topCut: number = Math.min(LG_TOP_BAND / vh, 0.45);
    const botStart: number = Math.max(1 - LG_BOTTOM_BAND / vh, 0.55);
    const botSpan: number = 1 - botStart;
    const out: FractionStop[] = [];
    // 顶部：满模糊 → 0
    const s0: FractionStop = [1, 0];
    const s1: FractionStop = [0.7, topCut * 0.278];
    const s2: FractionStop = [0.3, topCut * 0.611];
    const s3: FractionStop = [0, topCut];
    // 中部：清晰
    const s4: FractionStop = [0, botStart];
    // 底部：0 → 满（乘 LG_BOTTOM_RATIO 还原原底部条带 16vp 的峰值强度）
    const s5: FractionStop = [0.35 * LG_BOTTOM_RATIO, botStart + botSpan * 0.444];
    const s6: FractionStop = [0.7 * LG_BOTTOM_RATIO, botStart + botSpan * 0.722];
    const s7: FractionStop = [LG_BOTTOM_RATIO, 1];
    out.push(s0);
    out.push(s1);
    out.push(s2);
    out.push(s3);
    out.push(s4);
    out.push(s5);
    out.push(s6);
    out.push(s7);
    return out;
  }

  /** 背景图亮度系数：50% = 1.0 */
  private bgBrightFactor(): number {
    return this.bgBrightPct / 50;
  }

  /** 就地双语：zh 为唯一键，en 为英文文案 */
  private t(zh: string, en: string): string {
    return this.langEn ? en : zh;
  }

  /** 应用语言模式（立即生效，不改任何用户数据） */
  applyLangMode(mode: number): void {
    this.langMode = I18n.clampMode(mode);
    this.langEn = I18n.resolve(this.langMode);
    AppStorage.setOrCreate('lang_en', this.langEn);
    this.refreshStaticTexts();
  }

  /**
   * 静态初始文案（不能放在字段初始化器里：那时 @State 存储还不存在，会触发 jscrash）。
   * 只在「尚未进入运行态」或「仍是初始文案」时刷新，不覆盖运行中的状态文字。
   */
  private refreshStaticTexts(): void {
    const readyZh: string = '就绪';
    const readyEn: string = 'Ready';
    if (this.phaseText.length === 0 || this.phaseText === readyZh || this.phaseText === readyEn) {
      this.phaseText = this.t(readyZh, readyEn);
    }
    const hint: string = this.latencyHint;
    if (hint.length === 0 || hint.indexOf('260~320') >= 0) {
      this.latencyHint = this.t(
        '建议：延迟上限建议 260~320ms（默认 300ms；两次 ping 下 220ms 偏低，容易误杀可用节点）',
        'Tip: a latency cap of 260–320 ms is recommended (default 300 ms; 220 ms with two pings is too low and may discard usable nodes).');
    }
  }

  loadUi(): void {
    const c: UiConfig = ConfigStore.ui();
    this.globalImmersion = c.globalImmersion;
    this.matType = c.matType;
    this.matLevel = c.matLevel;
    this.themeColorIdx = c.themeColor;
    this.bgBlurPct = c.bgBlur;
    this.bgBrightPct = c.bgBright;
    this.applyLangMode(c.langMode);
  }

  saveUi(): void {
    const c: UiConfig = {
      globalImmersion: this.globalImmersion,
      matType: this.matType,
      matLevel: this.matLevel,
      themeColor: this.themeColorIdx,
      bgBlur: this.bgBlurPct,
      bgBright: this.bgBrightPct,
      langMode: this.langMode
    };
    ConfigStore.saveUi(c).catch((e: BusinessError) => {
      this.addLog(this.t('保存外观设置失败：', 'Failed to save appearance settings: ') + e.message);
    });
  }

  setThemeMode(m: number): void {
    this.themeMode = m;
    this.applyThemeMode();
    ConfigStore.saveTheme(m).catch((e: BusinessError) => {
      this.addLog(this.t('保存主题失败：', 'Failed to save theme: ') + e.message);
    });
  }
  /**
   * 有效玻璃档位：0=精致（强） 1=柔和（中） 2=平滑（轻） -1=无玻璃。
   * 「自适应」跟随设备系统材质等级（uiMaterial.getGlobalMaterialLevel）：
   * EXQUISITE→精致、GENTLE→柔和、SMOOTH→平滑。修正此前反向映射。
   */
  private effLevel(): number {
    if (!this.globalImmersion || this.matType === 2) {
      return -1;
    }
    if (this.matLevel === 1) {
      return 0;
    }
    if (this.matLevel === 2) {
      return 1;
    }
    if (this.matLevel === 3) {
      return 2;
    }
    if (!this.matSupported()) {
      return 1;
    }
    const lv: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
    if (lv === uiMaterial.MaterialLevel.EXQUISITE) {
      return 0;
    }
    if (lv === uiMaterial.MaterialLevel.GENTLE) {
      return 1;
    }
    return 2;
  }

  /**
   * 卡片玻璃的模糊档位（只有材质开启时才真正模糊）。
   * 关闭材质时返回 NONE，交给实心底座保证可读性——
   * 这样总开关的两侧是两套完整设计，而不是同一种卡片的透明度微调。
   */
  private cardBlurStyle(): BlurStyle {
    const e: number = this.effLevel();
    if (e < 0) {
      return BlurStyle.NONE;
    }
    if (e === 0) {
      return this.matType === 1 ? BlurStyle.BACKGROUND_ULTRA_THICK : BlurStyle.BACKGROUND_THICK;
    }
    if (e === 1) {
      return this.matType === 1 ? BlurStyle.BACKGROUND_THICK : BlurStyle.BACKGROUND_REGULAR;
    }
    return this.matType === 1 ? BlurStyle.BACKGROUND_REGULAR : BlurStyle.BACKGROUND_THIN;
  }

  /**
   * 卡片霜面 tint。
   * 开启材质：顶部一道极淡白高光、中部近乎透明、底部压一层暗部——
   * 叠在 backgroundBlurStyle 的模糊底之上，才有"有厚度的玻璃"而不是"糊了一层白"。
   * 关闭材质：实心不透明底座，保证任何背景/图片下文字都稳。
   */
  private cardTint(): Array<[ResourceColor, number]> {
    const e: number = this.effLevel();
    const photo: number = this.bgPath.length > 0 ? 1 : 0;
    if (this.dark) {
      if (e < 0) {
        return [['rgba(36,39,49,0.97)', 0.0], ['rgba(32,35,44,0.97)', 0.55], ['rgba(29,32,40,0.97)', 1.0]];
      }
      const lift: number = photo * 0.05;
      const a0: number = (e === 0 ? 0.12 : (e === 1 ? 0.10 : 0.08)) + lift;
      const a1: number = (e === 0 ? 0.05 : (e === 1 ? 0.045 : 0.04)) + lift * 0.5;
      const a2: number = e === 0 ? 0.22 : (e === 1 ? 0.18 : 0.14);
      return [['rgba(255,255,255,' + a0.toFixed(3) + ')', 0.0],
        ['rgba(255,255,255,' + a1.toFixed(3) + ')', 0.46],
        ['rgba(8,10,16,' + a2.toFixed(3) + ')', 1.0]];
    }
    if (e < 0) {
      return [['rgba(255,255,255,0.99)', 0.0], ['rgba(252,253,255,0.99)', 0.55], ['rgba(248,250,253,0.99)', 1.0]];
    }
    const lift: number = photo * 0.06;
    const b0: number = Math.min(0.82, (e === 0 ? 0.30 : (e === 1 ? 0.40 : 0.52)) + lift);
    const b1: number = Math.min(0.78, (e === 0 ? 0.20 : (e === 1 ? 0.30 : 0.42)) + lift);
    const b2: number = Math.min(0.74, (e === 0 ? 0.12 : (e === 1 ? 0.20 : 0.30)) + lift);
    return [['rgba(255,255,255,' + b0.toFixed(3) + ')', 0.0],
      ['rgba(255,255,255,' + b1.toFixed(3) + ')', 0.46],
      ['rgba(255,255,255,' + b2.toFixed(3) + ')', 1.0]];
  }

  /** 运行日志卡：嵌入面板时透明无玻璃 */
  private cardTintOr(fill: boolean): Array<[ResourceColor, number]> {
    if (fill) {
      return [[Color.Transparent, 0.0], [Color.Transparent, 1.0]];
    }
    return this.cardTint();
  }

  private cardBorderColor(): string {
    if (this.effLevel() < 0) {
      return this.dark ? 'rgba(255,255,255,0.07)' : 'rgba(15,23,42,0.09)';
    }
    return this.dark ? 'rgba(255,255,255,0.18)' : 'rgba(255,255,255,0.92)';
  }

  private cardShadowColor(): string {
    if (this.effLevel() < 0) {
      return this.dark ? 'rgba(0,0,0,0.30)' : 'rgba(15,23,42,0.08)';
    }
    return this.dark ? 'rgba(0,0,0,0.58)' : 'rgba(15,23,42,0.18)';
  }

  private cardShadowY(): number {
    const e: number = this.effLevel();
    if (e < 0) {
      return 3;
    }
    if (e === 0) {
      return 12;
    }
    if (e === 1) {
      return 8;
    }
    return 5;
  }

  /** 设备系统材质等级名称 */
  private deviceLevelName(): string {
    if (!this.matSupported()) {
      return this.t('不支持', 'Unsupported');
    }
    const lv: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
    if (lv === uiMaterial.MaterialLevel.EXQUISITE) {
      return this.t('精致', 'Exquisite');
    }
    if (lv === uiMaterial.MaterialLevel.GENTLE) {
      return this.t('柔和', 'Gentle');
    }
    return this.t('平滑', 'Smooth');
  }

  /** 卡片玻璃描述（设置页状态提示） */
  private glassDesc(): string {
    const e: number = this.effLevel();
    if (e < 0) {
      return this.t('（无材质）', 'No material');
    }
    if (e === 0) {
      return this.t('（厚玻璃）', 'Thick glass');
    }
    if (e === 1) {
      return this.t('（中玻璃）', 'Medium glass');
    }
    return this.t('（薄玻璃）', 'Thin glass');
  }

  /** 进度条配色：跟随主题色 */
  private progressTint(): Array<[ResourceColor, number]> {
    return [[this.accent(), 0.0], [this.accentPale(), 1.0]];
  }

  /** 导航胶囊左边界与宽度（vp，窗口坐标） */
  private navStackLeft(): number {
    const w: number = Math.min(360, this.winW - 48);
    return (this.winW - w) / 2;
  }

  private navStackWidth(): number {
    return Math.min(360, this.winW - 48);
  }

  /** 主题色 + 透明度 → rgba 字符串 */
  private accentRgba(alpha: number): string {
    const c: string = this.accent();
    const r: number = Number.parseInt(c.substring(1, 3), 16);
    const g: number = Number.parseInt(c.substring(3, 5), 16);
    const b: number = Number.parseInt(c.substring(5, 7), 16);
    return 'rgba(' + r.toString() + ',' + g.toString() + ',' + b.toString() + ',' + alpha.toFixed(2) + ')';
  }

  /** 宽柔光带：中心为触摸位置（只在交互期间渲染，静止时不画） */
  private glowBand(): Array<[ResourceColor, number]> {
    const p: number = Math.max(0.06, Math.min(0.94, this.navGlowPct / 100));
    const spread: number = 0.10 + 0.04 * this.navStretch;
    const lo: number = Math.max(0.0, p - spread);
    const hi: number = Math.min(1.0, p + spread);
    return [[this.accentRgba(0.0), 0.0], [this.accentRgba(0.06), lo], [this.accentRgba(0.16), p],
      [this.accentRgba(0.06), hi], [this.accentRgba(0.0), 1.0]];
  }

  /** 窄亮芯 */
  private glowCore(): Array<[ResourceColor, number]> {
    const p: number = Math.max(0.04, Math.min(0.96, this.navGlowPct / 100));
    const spread: number = 0.035 + 0.02 * this.navStretch;
    const lo: number = Math.max(0.0, p - spread);
    const hi: number = Math.min(1.0, p + spread);
    return [[this.accentRgba(0.0), 0.0], [this.accentRgba(0.20), lo], [this.accentRgba(0.20), p],
      [this.accentRgba(0.12), hi], [this.accentRgba(0.0), 1.0]];
  }

  /** 跟手：拖拽过程中光斑位置由系统响应式弹簧跟随（不是逐帧手搓） */
  private navDragFollow(pct: number, stretch: number): void {
    animateTo({ curve: curves.responsiveSpringMotion(0.6, 0.84) }, () => {
      this.navGlowPct = pct;
      this.navStretch = stretch;
    });
  }

  /** 离手：弹回当前选中项，随后光效淡出（系统弹簧，无定时器） */
  private navDragRelease(): void {
    const anchor: number = (this.curTab + 0.5) / 4 * 100;
    animateTo({
      curve: curves.springMotion(0.36, 0.72),
      onFinish: () => {
        if (!this.navDrag) {
          animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
            this.navGlowOn = false;
            this.navStretch = 0;
          });
        }
      }
    }, () => {
      this.navGlowPct = anchor;
      this.navStretch = 0;
    });
  }

  // ===== 方案 A：悬浮导航高亮胶囊拖拽（参数逐字采用华为官方技术设计文档）=====
  /** 胶囊内可拖动区宽度（vp）：去掉左右各 6 的内边距 */
  private navInnerW(): number {
    const w: number = this.navStackWidth() - 12;
    return w < 120 ? 120 : w;
  }

  private navTabW(): number {
    return this.navInnerW() / 4;
  }

  /** 第 i 个页签中心 x（相对胶囊左边缘） */
  /** 平板三列：单列宽度（内容区宽 - 两个列间距后三等分） */
  /** 单列页（筛选/测速）在平板上居中限宽 900vp，避免内容铺到屏幕两端 */
  private pageSidePad(): number {
    if (this.winW >= 900) {
      const w: number = Math.min(this.winW, 1600);
      return Math.max(16, (w - 900) / 2);
    }
    return 16;
  }

  private tabColW(): number {
    const content: number = Math.min(this.winW, 1600) - 32;
    return Math.max(220, (content - 28) / 3);
  }

  /** 平板左区宽度 = 两列 + 一个间距 */
  private tabLeftZoneW(): number {
    return this.tabColW() * 2 + 14;
  }

  private navTabCenter(i: number): number {
    let k: number = i;
    if (k < 0) {
      k = 0;
    }
    if (k > 3) {
      k = 3;
    }
    return 6 + this.navTabW() * (k + 0.5);
  }

  /** 高亮胶囊宽度 */
  private navPillW(): number {
    return this.navTabW() * 0.82;
  }

  /** 拖动边界：首/末页签中心之间（不滑进圆角端帽） */
  private navClampPill(x: number): number {
    const lo: number = this.navTabCenter(0);
    const hi: number = this.navTabCenter(3);
    if (x < lo) {
      return lo;
    }
    if (x > hi) {
      return hi;
    }
    return x;
  }

  /** 越界阻力：溢出位移按 pow(overflow, 0.6) 压缩，越拉越难拉（官方区间 0.5–0.7） */
  private clampWithResistance(x: number, lo: number, hi: number): number {
    const exp: number = 0.6;
    if (x < lo) {
      return lo - Math.pow(lo - x, exp);
    }
    if (x > hi) {
      return hi + Math.pow(x - hi, exp);
    }
    return x;
  }

  /** 离手吸附到最近页签 */
  private navNearestTab(x: number): number {
    let best: number = 0;
    let bestD: number = 1000000;
    for (let i = 0; i < 4; i++) {
      const d: number = Math.abs(this.navTabCenter(i) - x);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  /** 单一数据源：所有形变只改这三个数，避免多个 animateTo 抢同一属性 */
  private setPillScale(s: number, flatness: number, yDeform: number): void {
    let ss: number = s;
    if (ss < 1.12) {
      ss = 1.12;
    }
    if (ss > 1.85) {
      ss = 1.85;
    }
    let f: number = flatness;
    if (f < 0) {
      f = 0;
    }
    if (f > 0.2) {
      f = 0.2;
    }
    let y: number = yDeform;
    if (y < -0.15) {
      y = -0.15;
    }
    if (y > 0.15) {
      y = 0.15;
    }
    this.navPillS = ss;
    this.navPillFlat = f;
    this.navPillY = y;
  }

  /** scaleX = s × (1 + flatness) */
  private navPillScaleX(): number {
    return this.navPillS * (1 + this.navPillFlat);
  }

  /** scaleY = s × (1 - flatness + yDeform) */
  private navPillScaleY(): number {
    return this.navPillS * (1 - this.navPillFlat + this.navPillY);
  }

  /** 光斑位置跟随胶囊中心 */
  private syncNavGlow(x: number): void {
    const p: number = x / this.navInnerW() * 100;
    this.navGlowPct = p < 2 ? 2 : (p > 98 ? 98 : p);
  }

  private navPanStart(e: GestureEvent): void {
    this.navPillDragging = true;
    this.navGlowOn = true;
    this.navStartX = this.navPillX;
    this.navLastWX = e.offsetX;
    this.navLastMs = Date.now();
    this.navVelMs = 0;
    this.syncNavGlow(this.navPillX);
  }

  private navPanUpdate(e: GestureEvent): void {
    const lo: number = this.navTabCenter(0);
    const hi: number = this.navTabCenter(3);
    const target: number = this.clampWithResistance(this.navStartX + e.offsetX, lo, hi);
    const now: number = Date.now();
    const dt: number = now - this.navLastMs;
    if (dt > 0) {
      this.navVelMs = Math.abs(e.offsetX - this.navLastWX) / dt;
    }
    this.navLastWX = e.offsetX;
    this.navLastMs = now;
    // 官方公式：s = max(1.12, 1 + min(0.85, dist/55))
    const dist: number = Math.abs(target - this.navStartX);
    const s: number = Math.max(1.12, 1 + Math.min(0.85, dist / 55));
    // flatness = 0.2 × min(1, vel/1.5)
    const flat: number = 0.2 * Math.min(1, this.navVelMs / 1.5);
    // yDeform = clamp(-offsetY/200, -0.15, 0.15)
    let yd: number = -e.offsetY / 200;
    if (yd < -0.15) {
      yd = -0.15;
    }
    if (yd > 0.15) {
      yd = 0.15;
    }
    // §1.7 位置直接赋值保证跟手；形变走 responsiveSpringMotion(0.32, 0.6) 平滑
    animateTo({ curve: curves.responsiveSpringMotion(0.32, 0.6) }, () => {
      this.setPillScale(s, flat, yd);
    });
    this.navPillX = target;
    this.syncNavGlow(target);
  }

  private navPanEnd(): void {
    const idx: number = this.navNearestTab(this.navClampPill(this.navPillX));
    const target: number = this.navTabCenter(idx);
    const fast: boolean = this.navVelMs > 0.6;
    const slow: boolean = this.navVelMs < 0.15;
    this.navPillDragging = false;
    // 光效：离手立即淡出，不挂在位置回弹的 onFinish 上
    animateTo({ duration: 130, curve: Curve.EaseOut }, () => {
      this.navGlowOn = false;
    });
    if (fast) {
      // 快速甩动：先挤压
      animateTo({ curve: curves.springMotion(0.25, 0.5) }, () => {
        this.setPillScale(1.34, 0.2, 0);
      });
      // 再回弹并吸附
      animateTo({ curve: curves.springMotion(1.0, 0.7), delay: 90 }, () => {
        this.navPillX = target;
        this.setPillScale(1.0, 0, 0);
      });
    } else if (slow) {
      animateTo({ curve: curves.springMotion(1.0, 0.7) }, () => {
        this.navPillX = target;
        this.setPillScale(1.0, 0, 0);
      });
    } else {
      animateTo({ curve: curves.springMotion(0.32, 0.6) }, () => {
        this.navPillX = target;
        this.setPillScale(1.0, 0, 0);
      });
    }
    if (idx !== this.curTab) {
      this.anyScrollY = 0;
      if (this.showBackTop) {
        this.showBackTop = false;
      }
      // 走统一入口，让 Tabs 真正切页（不要只改 curTab）
      this.curTab = idx;
    }
    this.syncNavGlow(target);
  }

  /** 底部悬浮导航：原生 Tabs（隐藏系统页签）作页面宿主，导航层只负责切页，不做拖动、不做柔光 */
  @Builder BottomNav() {
    Row() {
      Stack() {
        // ① 系统沉浸材质（对标 OA homeTabsFloatingStyle 的 systemMaterialEffect）
        // 玻璃背板：材质挂在胶囊本体上（官方 path A：Tabs.barFloatingStyle.systemMaterial），
        // 拖动中置 undefined + BlurStyle.NONE + 0.25 白，离手恢复 THIN + 0.15 白
        Column()
          .width('100%')
          .height('100%')
          // §1.5 材质动态切换：拖动关模糊保证跟手，静止恢复 Thin
          .backgroundBlurStyle(
            this.navPillDragging ? BlurStyle.NONE : BlurStyle.Thin,
            { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }
          )
          .backgroundColor(this.navPillDragging
            ? 'rgba(255,255,255,0.25)'
            : 'rgba(255,255,255,0.15)')
        // ② 光感：顶部受光高光 → 中段淡出 → 底边极轻的暗面，形成厚度与弧面感
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [
              [this.dark ? 'rgba(255,255,255,0.16)' : 'rgba(255,255,255,0.46)', 0.0],
              [this.dark ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.16)', 0.42],
              [this.dark ? 'rgba(0,0,0,0.12)' : 'rgba(15,23,42,0.06)', 1.0]
            ]
          })
        // ③ 光效并入高亮胶囊自身（外发光 + 内高光），天然跟手，不会溢出胶囊
        // ④ 高亮胶囊：位置与形变只由 navPillX / setPillScale 驱动
        Column()
          .width(this.navPillW())
          .height(46)
          .borderRadius(23)
          .backgroundColor(this.accentRgba(this.navGlowOn ? (this.dark ? 0.42 : 0.38) : (this.dark ? 0.30 : 0.26)))
          .border({ width: 1, color: this.accentRgba(this.navGlowOn ? (this.dark ? 0.55 : 0.50) : (this.dark ? 0.38 : 0.34)) })
          // 光效只在拖动期存在，静止态 radius 0 完全无光
          .shadow({
            radius: this.navGlowOn ? 26 : 0,
            color: this.accentRgba(this.navGlowOn ? 0.38 : 0),
            offsetX: 0,
            offsetY: 0
          })
          .scale({ x: this.navPillScaleX(), y: this.navPillScaleY() })
          .position({ x: this.navPillX - this.navPillW() / 2, y: 8 })
          .hitTestBehavior(HitTestMode.None)
        // 胶囊内高光：顶部亮 → 底部弱，读起来是凸起的高亮块
        Column()
          .width(this.navPillW())
          .height(46)
          .borderRadius(23)
          .linearGradient({
            angle: 180,
            colors: [[this.dark ? 'rgba(255,255,255,0.30)' : 'rgba(255,255,255,0.85)', 0.0],
              [this.dark ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.30)', 0.55],
              [this.dark ? 'rgba(255,255,255,0.02)' : 'rgba(255,255,255,0.05)', 1.0]]
          })
          .opacity(this.curTab >= 0 ? 0.55 : 0.55)
          .scale({ x: this.navPillScaleX(), y: this.navPillScaleY() })
          .position({ x: this.navPillX - this.navPillW() / 2, y: 8 })
          .hitTestBehavior(HitTestMode.None)
        // ⑤ 内容层
        Row() {
          this.NavItem(0)
          this.NavItem(1)
          this.NavItem(2)
          this.NavItem(3)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
      }
      .width('100%')
      .constraintSize({ maxWidth: 360 })
      .height(62)
      .borderRadius(31)
      .clip(true)
      .systemMaterial(this.navPillDragging ? undefined : this.navMaterial())
      .border({ width: 1, color: this.navGlassBorder() })
      .shadow({
        radius: this.dark ? 20 : 22,
        color: this.dark ? 'rgba(0,0,0,0.55)' : 'rgba(15,23,42,0.16)',
        offsetX: 0,
        offsetY: 8
      })
      .gesture(
        PanGesture({ distance: 1 })
          .onActionStart((e: GestureEvent) => {
            this.navPanStart(e);
          })
          .onActionUpdate((e: GestureEvent) => {
            this.navPanUpdate(e);
          })
          .onActionEnd(() => {
            this.navPanEnd();
          })
          .onActionCancel(() => {
            this.navPanEnd();
          })
      )
    }
    .width('100%')
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
    .margin({ bottom: px2vp(this.navBarPx) + 26 })
    .zIndex(10)
  }

  /** 导航胶囊玻璃：深色更薄、浅色更厚，保证两套主题都能读出层次 */
  /** 悬浮控件受光渐变：与 FloatingNav 的 ② 光感层同源 */
  private floatSheen(): Array<[ResourceColor, number]> {
    return [
      [this.dark ? 'rgba(255,255,255,0.16)' : 'rgba(255,255,255,0.46)', 0.0],
      [this.dark ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.16)', 0.42],
      [this.dark ? 'rgba(0,0,0,0.12)' : 'rgba(15,23,42,0.06)', 1.0]
    ];
  }

  private navGlassStyle(): BlurStyle {
    const e: number = this.effLevel();
    if (e < 0) {
      return BlurStyle.NONE;
    }
    if (e === 0) {
      return this.matType === 1 ? BlurStyle.COMPONENT_ULTRA_THICK : BlurStyle.COMPONENT_THICK;
    }
    if (e === 1) {
      return BlurStyle.COMPONENT_REGULAR;
    }
    return BlurStyle.COMPONENT_THIN;
  }
  /** 玻璃外缘：浅色用亮白高光描边，深色用低对比白线 */
  private navGlassBorder(): string {
    return this.dark ? 'rgba(255,255,255,0.18)' : 'rgba(255,255,255,0.85)';
  }
  /** 单个页签：选中时只加一层淡色圆角底 + 主题色图标/文字，不做发光 */
  /** 选中光：中心亮、四周完全渐隐的径向柔光（没有矩形边界） */
  private navSelGlow(): Array<[ResourceColor, number]> {
    const hi: number = this.dark ? 0.30 : 0.34;
    return [[this.accentRgba(hi), 0.0], [this.accentRgba(0.0), 1.0]];
  }

  @Builder NavItem(index: number) {
    Column() {
      Stack() {
        Column() {
          SymbolGlyph(this.tabIcon(index))
            .fontSize(20)
            .fontColor([this.navSel === index ? this.accentText() : this.txt3()])
          Text(this.tabLabel(index))
            .fontSize(10)
            .margin({ top: 2 })
            .fontWeight(this.navSel === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.navSel === index ? this.txt() : this.txt3())
        }
        .width('100%')
        .height(46)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.navSel === index ? this.soft() : Color.Transparent)
        .borderRadius(14)
        .animation({ duration: 180, curve: Curve.EaseOut })
      }
      .width('100%')
      .height(46)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchTab(index);
    })
  }

  /** 来源名称 */
  private srcLabel(): string {
    return [this.t('CF 官方 IP 段', 'CF official IP ranges'), this.t('社区 IPv6 段库', 'Community IPv6 ranges'), this.t('社区 IPv4 段库', 'Community IPv4 ranges'), this.t('自定义（文件 / 链接）', 'Custom (file / link)')][this.srcIdx];
  }

  /** 来源弹层：与卡片同族玻璃底，选项之间只有发丝分隔线、没有独立圆角 */
  @Builder SourceMenu() {
    Column() {
      ForEach([0, 1, 2, 3], (i: number) => {
        Column() {
          Row() {
            Text([this.t('CF 官方 IP 段', 'CF official IP ranges'), this.t('社区 IPv6 段库', 'Community IPv6 ranges'), this.t('社区 IPv4 段库', 'Community IPv4 ranges'), this.t('自定义（文件 / 链接）', 'Custom (file / link)')][i])
              .fontSize(13)
              .fontColor(i === this.srcIdx ? this.accent() : this.txt())
              .fontWeight(i === this.srcIdx ? FontWeight.Medium : FontWeight.Normal)
              .layoutWeight(1)
            if (i === this.srcIdx) {
              Text('✓')
                .fontSize(12)
                .fontColor(this.accentText())
            }
          }
          .width('100%')
          .height(40)
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            this.applySource(i);
          })

          if (i < 3) {
            Divider()
              .color(this.lineC())
              .strokeWidth(0.5)
              .margin({ left: 14, right: 14 })
          }
        }
        .width('100%')
      }, (i: number) => 'src' + i.toString())
    }
    .width(212)
    .backgroundColor(this.dark ? '#F21F1F26' : '#F2FFFFFF')
    .backgroundBlurStyle(this.cardBlurStyle(), {
      colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
    })
    .borderRadius(14)
    .border({ width: 0.5, color: this.cardBorderColor() })
    .clip(true)
  }

  /** 切页统一入口：只改 curTab，不重启扫描、不动业务状态 */
  private switchTab(index: number): void {
    if (index === this.curTab) {
      return;
    }
    this.anyScrollY = 0;
    if (this.showBackTop) {
      this.showBackTop = false;
    }
    // 点击切页不扫光：光带只在拖动交互时出现
    this.navGlowOn = false;
    this.navStretch = 0;
    this.navGlowPct = (index + 0.5) / 4 * 100;
    animateTo({ curve: curves.springMotion(0.55, 0.82) }, () => {
      this.curTab = index;
      this.navPillX = this.navTabCenter(index);
      this.setPillScale(1.0, 0, 0);
    });
  }

  /** 导航栏宽度：手机取屏宽 - 48，平板/2in1 上限 360vp */
  private navBarW(): number {
    const w: number = this.winW > 0 ? this.winW : 360;
    return Math.min(360, w - 48);
  }

  /** 页面底部避让：导航 62 + 悬浮 12 + 系统手势区 + 16 余量（只加一次，避免双重留白） */
  /**
   * 内容区顶部让位：状态栏 + 标题区实测高度取较大者。
   * 平板/折叠屏横屏状态栏≈0 时按标题区实测高让位，避免标题被首张卡片压住。
   */
  private contentTop(): number {
    if (this.winW >= 900) {
      return px2vp(this.statusBarPx) + 86;
    }
    const base: number = px2vp(this.statusBarPx) + 70;
    const need: number = this.headerH + 12;
    return need > base ? need : base;
  }
  /** 悬浮导航胶囊：底距与高度（与 navFloatStyle() 的取值保持同源） */
  private navBottomMargin(): number {
    return Math.max(px2vp(this.navBarPx) + 18, 28);
  }

  private navPillH(): number {
    return 56;
  }

  /** 回到顶部按钮：尺寸 / 与导航的间距 / 自底偏移 / 右侧偏移 / 内容区需要让出的高度 */
  private fabSize(): number {
    return 46;
  }

  private fabGap(): number {
    // 与导航胶囊之间的呼吸间距：按钮自成一条，不贴着导航
    return 24;
  }

  private fabBottom(): number {
    // 贴在导航胶囊上方，而不是贴屏幕底部：导航底距 + 胶囊高度 + 间距
    return this.navBottomMargin() + this.navPillH() + this.fabGap();
  }

  private fabRight(): number {
    // 宽屏时对齐到内容最大宽度（1600）的内边距，而不是永远贴窗口右边
    if (this.winW >= 900) {
      const side: number = Math.max(0, (this.winW - 1600) / 2);
      return side + 18;
    }
    return 18;
  }

  /** 内容区为悬浮按钮让出的高度：按钮本体 + 间距 + 余量 */
  private fabReserve(): number {
    return this.fabSize() + this.fabGap() + 12;
  }

  private pageBottomPad(): number {
    // 导航胶囊 + 悬浮按钮占位，保证滚到底时最后一张卡片停在按钮上方而不是被压住
    return 62 + 26 + px2vp(this.navBarPx) + 16 + this.fabReserve();
  }
  private tabLabel(index: number): string {
    if (index === 0) {
      return this.t('扫描', 'Scan');
    }
    if (index === 1) {
      return this.t('筛选', 'Filter');
    }
    if (index === 2) {
      return this.t('测速', 'Speed test');
    }
    return this.t('设置', 'Settings');
  }

  /** 浅光版主题色：向白混合约 60%，用于选中图标/文字，保证是淡光而不是浓色 */
  private accentPale(): string {
    const idx: number = this.themeColorIdx;
    if (idx === 0) { return '#EFE7A6'; }
    if (idx === 1) { return '#F5EAD4'; }
    if (idx === 2) { return '#D6E3D4'; }
    if (idx === 3) { return '#CDD9E8'; }
    if (idx === 4) { return '#E7D6D7'; }
    return this.dark ? '#8A8A92' : '#6E6E76';
  }
  /** 选中态底色：主题色的极淡版本 */
  private accentSoft(): string {
    if (this.dark) {
      return 'rgba(255,255,255,0.10)';
    }
    return 'rgba(0,0,0,0.045)';
  }

  /**
   * 胶囊的系统毛玻璃厚度：由「材质类型 / 材质等级」共同决定。
   * 关闭全局沉浸光感、或材质类型选「无材质」时退化为纯半透明底色。
   */
  private barBlurStyle(): BlurStyle {
    if (!this.globalImmersion || this.matType === 2) {
      return BlurStyle.NONE;
    }
    const s: uiMaterial.ImmersiveStyle = this.styleOfLevel();
    if (s === uiMaterial.ImmersiveStyle.ULTRA_THIN) {
      return BlurStyle.BACKGROUND_THIN;
    }
    if (s === uiMaterial.ImmersiveStyle.THIN) {
      return BlurStyle.BACKGROUND_THIN;
    }
    if (s === uiMaterial.ImmersiveStyle.REGULAR) {
      return BlurStyle.BACKGROUND_REGULAR;
    }
    return BlurStyle.COMPONENT_THICK;
  }
  /** 底部页签图标（系统 Symbol） */
  private tabIcon(index: number): Resource {
    if (index === 0) {
      return $r('sys.symbol.wifi');
    }
    if (index === 1) {
      return $r('sys.symbol.line_3_horizontal');
    }
    if (index === 2) {
      return $r('sys.symbol.bolt');
    }
    return $r('sys.symbol.gearshape');
  }

  /** 底部玻璃胶囊里的单个页签 */
  @Builder TabItem(label: string, index: number) {
    Column() {
      SymbolGlyph(this.tabIcon(index))
        .fontSize(19)
        .fontColor([this.navSel === index ? this.accentText() : this.txt3()])
        .margin({ bottom: 2 })
      Text(label)
        .fontSize(10)
        .maxLines(1)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontWeight(this.navSel === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.navSel === index ? this.accentText() : this.txt3())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      // HDS 的 onChange 要等页签切换动画结束才回调（实测滞后 1~2s），
      // 这里点击时先把选中态落下去，图标/文字颜色立即响应；后续 onChange 仍是权威值。
      if (this.navSel !== index) {
        this.navSel = index;
        this.navPillX = this.navTabCenter(index);
        this.setPillScale(1.0, 0, 0);
      }
    })
  }

  @Builder ScanPage() {
    Column() {
        // 顶部透明占位：约六行字符高度，纯透明，仅用于把下方卡片整体下移
      if (this.winW >= 900) {
        // 平板 / 电脑：左侧全是参数，右侧是「开始优选 + 进度条 + 运行日志」
        Scroll(this.scanScroller) {
          Row() {
            Column() {
              Row({ space: 14 }) {
                Column({ space: 14 }) {
                  this.CardSource()
                  this.CardParam()
                }
                .layoutWeight(1)
                .onAreaChange((_o: Area, a: Area) => {
                  const h: number = Number(a.height);
                  if (Math.abs(h - this.scanLeftColH) > 0.5) {
                    this.scanLeftColH = h;
                  }
                })
                Column({ space: 14 }) {
                  this.CardSpeed()
                }
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)


            }
            .width('100%')
            .padding({ left: 16, right: 16, top: this.contentTop(), bottom: this.pageBottomPad() })
            .constraintSize({ maxWidth: 1080 })
            .width(this.tabLeftZoneW())

            Column({ space: 14 }) {
              if (this.scanning || this.total > 0) {
                this.ActionBar()
              }
              Column() {
                Stack({ alignContent: Alignment.TopStart }) {
                  Column() {
                    this.CardLog(true, 240, false)
                  }
                  .onAreaChange((_o: Area, a: Area) => {
                    this.updateMeasuredCardHeight('tablog', a);
                  })
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .constraintSize({ minHeight: 240 })
                  .padding(16)
                }
                .width('100%')
                .backgroundBlurStyle(this.cardBlurStyle(),
                  { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
                .constraintSize({ maxHeight: 520 })
                .linearGradient({ angle: 145, colors: this.cardTintOr(false) })
                .borderRadius(20)
                .border({ width: 1, color: this.cardBorderColor() })
                .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
                .margin({ bottom: 16 })
              }
              .width('100%')
            }
            .width(this.tabColW())
            .padding({ left: 16, right: 16, top: this.contentTop(), bottom: this.pageBottomPad() })
    }
    .alignItems(VerticalAlign.Top)
    .justifyContent(FlexAlign.Center)
    .constraintSize({ maxWidth: 1600 })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .linearGradientBlur(LG_BLUR_MAX, {
    fractionStops: this.lgStops(this.scanVpH),
    direction: GradientDirection.Bottom
    })
    .onAreaChange((_o: Area, n: Area) => {
    const h: number = Number(n.height);
    if (h > 0 && Math.abs(h - this.scanVpH) > 0.5) {
    this.scanVpH = h;
    }
    })
    .onScroll(() => {
    this.onPageScroll(this.scanScroller);
    })
    } else {
    // 手机：单列，从上到下依次是 按钮 → 进度条 → 参数卡片 → 运行日志
    Scroll(this.scanScroller) {
    Column() {
    
    Column() {
    this.CardSource()
    if (this.scanning || this.total > 0) {
    this.ActionBar()
    }
    this.CardParam()
    this.CardSpeed()
    this.CardLog(false, 180, true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    

    }
    .width('100%')
    .padding({ left: 16, right: 16, top: this.contentTop(), bottom: this.pageBottomPad() })
    .constraintSize({ maxWidth: 1600 })
    }
    .width('100%')
    .layoutWeight(1)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .linearGradientBlur(LG_BLUR_MAX, {
    fractionStops: this.lgStops(this.scanVpH),
    direction: GradientDirection.Bottom
    })
    .onAreaChange((_o: Area, n: Area) => {
    const h: number = Number(n.height);
    if (h > 0 && Math.abs(h - this.scanVpH) > 0.5) {
    this.scanVpH = h;
    }
    })
    .onScroll(() => {
    this.onPageScroll(this.scanScroller);
    })
    }
  }
  }
    /** 运行 IPv6 网络诊断（设置页「网络诊断」卡片触发） */
    /** IPv4 自检 */
    async runIpv4Diag(): Promise<void> {
    if (this.diagBusy) {
    return;
    }
    this.diagGen++;
    const gen: number = this.diagGen;
    this.diagBusy = true;
    this.armDiagWatchdog();
    this.diagText = this.t('正在诊断 IPv4，请稍候…', 'Diagnosing IPv4, please wait…');
    try {
    const text: string = await Diag.runV4();
    if (gen !== this.diagGen) {
    return;
    }
    this.diagText = text;
    this.addLog(this.t('IPv4 网络诊断完成', 'IPv4 network diagnostics complete'));
    } catch (e) {
    if (gen !== this.diagGen) {
    return;
    }
    const err: BusinessError = e as BusinessError;
    this.diagText = this.t('诊断失败：', 'Diagnostics failed: ') + (err.message !== undefined ? err.message : this.t('未知错误', 'Unknown error'));
    } finally {
    if (gen === this.diagGen) {
    this.disarmDiagWatchdog();
    this.diagBusy = false;
    }
    }
    }
    
    /** 清空诊断：让进行中的旧诊断立刻失效，按钮恢复可点 */
    private clearDiag(): void {
    this.diagGen++;
    this.disarmDiagWatchdog();
    this.diagBusy = false;
    this.diagText = '';
    }
    
    /** 复制诊断结果到剪贴板 */
    copyDiag(): void {
    try {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.diagText);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
    this.toast(this.t('诊断结果已复制', 'Diagnostic results copied'));
    }).catch((e: BusinessError) => {
    this.toast(this.t('复制失败：', 'Copy failed: ') + e.message);
    });
    } catch (e) {
    const err: BusinessError = e as BusinessError;
    this.toast(this.t('复制失败：', 'Copy failed: ') + err.message);
    }
    }
    
    async runIpv6Diag(): Promise<void> {
    if (this.diagBusy) {
    return;
    }
    this.diagGen++;
    const gen: number = this.diagGen;
    this.diagBusy = true;
    this.armDiagWatchdog();
    this.diagText = this.t('正在诊断 IPv6，请稍候…', 'Diagnosing IPv6, please wait…');
    try {
    const text: string = await Diag.run();
    if (gen !== this.diagGen) {
    return;
    }
    this.diagText = text;
    this.addLog(this.t('IPv6 网络诊断完成，详情见「设置 → 网络诊断」', 'IPv6 network diagnostics complete; see Settings → Network diagnostics for details'));
    } catch (e) {
    if (gen !== this.diagGen) {
    return;
    }
    const err: BusinessError = e as BusinessError;
    this.diagText = this.t('诊断失败：', 'Diagnostics failed: ') + (err.message !== undefined ? err.message : this.t('未知错误', 'Unknown error'));
    } finally {
    if (gen === this.diagGen) {
    this.disarmDiagWatchdog();
    this.diagBusy = false;
    }
    }
    }
    
    private armDiagWatchdog(): void {
    this.disarmDiagWatchdog();
    const gen: number = this.diagGen;
    this.diagWatchdog = setTimeout(() => {
    if (gen === this.diagGen && this.diagBusy) {
    this.diagBusy = false;
    this.diagText = this.diagText + this.t('\n\n（诊断超时，按钮已恢复。请检查网络后重试）', '\n\n(Diagnostic timed out; the button has been restored. Check your network and try again.)');
    }
    }, 120000);
    }
    
    private disarmDiagWatchdog(): void {
    if (this.diagWatchdog >= 0) {
    clearTimeout(this.diagWatchdog);
    this.diagWatchdog = -1;
    }
    }
    
    @Builder CardTitle(title: string, icon: Resource) {
    Row() {
    SymbolGlyph(icon)
    .fontSize(16)
    .fontColor([this.txt2()])
    .margin({ right: 8 })
    Text(title)
    .fontSize(15)
    .fontWeight(FontWeight.Medium)
    .fontColor(this.txt())
    Blank()
    }
    .width('100%')
    }
    
    @Builder FieldRow(label: string, value: string, onChange: (v: string) => void) {
    Row() {
    Text(label)
    .fontSize(13)
    .fontColor(this.txt2())
    .width(110)
    TextInput({ text: value })
    .id('fr-' + label + '-' + this.cfgRev.toString())
    .layoutWeight(1)
    .height(40)
    .fontSize(13)
    .fontColor(this.txt())
    .backgroundColor(this.inputBg())
    .borderRadius(10)
    .onChange(onChange)
    }
    .width('100%')
    .margin({ top: 8 })
    }
    
    // ---- 统一控件尺寸 token（vp）：chip / 按钮 / 输入框内边距 ----
    private readonly CHIP_H: number = 34;
    private readonly CHIP_R: number = 9;
    private readonly CHIP_FS: number = 12;
    private readonly BTN_H: number = 38;
    
    @Builder SegRow(label: string, items: string[], current: number, onPick: (i: number) => void) {
    Row() {
    Text(label)
    .fontSize(13)
    .fontColor(this.txt2())
    .width(110)
    Row() {
    ForEach(items, (item: string, index: number) => {
    Text(item)
    .fontSize(this.CHIP_FS)
    .fontColor(current === index ? '#FFFFFF' : this.txt2())
    .textAlign(TextAlign.Center)
    .layoutWeight(1)
    .height(this.CHIP_H)
    .backgroundColor(current === index ? this.accentFill() : this.soft())
    .borderRadius(this.CHIP_R)
    .margin({ right: index === items.length - 1 ? 0 : 6 })
    .onClick(() => {
    onPick(index);
    })
    }, (item: string, index: number) => item + '#' + index.toString())
    }
    .layoutWeight(1)
    }
    .width('100%')
    .margin({ top: 8 })
    }
    
    @Builder SourceHint() {
    Text(this.srcIdx >= 1 ? this.sourceBrief() : this.t('内置官方段库，无需导入；选「自定义」后可自行导入', 'Built-in official ranges, no import needed; choose "Custom" to import your own'))
    .fontSize(11)
    .fontColor(this.txt3())
    .width('100%')
    .margin({ top: 8 })
    .maxLines(2)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    
  /** 候选来源：来源 / IP 版本 / 端口 三组参数合并为一张卡片，减少卡片数与纵向占用 */
  @Builder CardSource() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitle(this.t('候选来源', 'Candidate source'), $r('sys.symbol.wifi'))

        // 开始优选：主操作，视觉权重最高
        Text(this.scanning ? this.t('停止', 'Stop') : this.t('开始优选', 'Start selection'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .width('100%')
          .height(48)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.scanning ? BAD_C : this.accentFill())
          .borderRadius(14)
          .margin({ top: 14 })
          .onClick(() => {
            if (this.scanning) {
              this.stopScan();
            } else {
              this.startScan();
            }
          })

        Row() {
          Text(this.t('来源', 'Source'))
            .fontSize(13)
            .fontColor(this.txt2())
            .width(72)
          Row() {
            Text(this.srcLabel())
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.txt())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('▼')
              .fontSize(8)
              .fontColor(this.txt2())
              .margin({ left: 6 })
          }
          .height(36)
          .layoutWeight(1)
          .padding({ left: 12, right: 10 })
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .justifyContent(FlexAlign.SpaceBetween)
          .bindMenu(this.SourceMenu(), {
            backgroundColor: Color.Transparent
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 12 })

        // 官方来源无需按钮；社区库=更新来源；自定义=自定义导入
        if (this.srcIdx !== 0) {
          Text((this.srcIdx === 1 || this.srcIdx === 2) ? this.t('更新来源', 'Update source') : this.t('自定义导入', 'Custom import'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accentText())
            .textAlign(TextAlign.Center)
            .width('100%')
            .height(34)
            .backgroundColor(this.soft())
            .borderRadius(9)
            .margin({ top: 8 })
            .onClick(() => {
              if (this.srcIdx === 3 && this.customText.trim().length === 0) {
                this.toast(this.t('自定义为空，请添加来源', 'Custom source is empty; add a source'));
              }
              this.importDlg.open();
            })
        }

        Row() {
          Text(this.t('IP 版本', 'IP version'))
            .fontSize(13)
            .fontColor(this.txt2())
            .width(72)
          Row() {
            Text('IPv4')
              .fontSize(12)
              .fontColor(this.ipVersion === IpVersion.V4 ? '#FFFFFF' : this.txt2())
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(this.CHIP_H)
              .backgroundColor(this.ipVersion === IpVersion.V4 ? this.accentFill() : this.soft())
              .borderRadius(this.CHIP_R)
              .onClick(() => {
                this.ipVersion = IpVersion.V4;
                this.maybeAutoSuggest(false);
              })
            Text('IPv6')
              .fontSize(12)
              .fontColor(this.ipVersion === IpVersion.V6 ? '#FFFFFF' : this.txt2())
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(this.CHIP_H)
              .backgroundColor(this.ipVersion === IpVersion.V6 ? this.accentFill() : this.soft())
              .borderRadius(this.CHIP_R)
              .margin({ left: 6 })
              .onClick(() => {
                this.ipVersion = IpVersion.V6;
                this.maybeAutoSuggest(true);
              })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 8 })

        Row() {
          Text(this.t('端口', 'Port'))
            .fontSize(13)
            .fontColor(this.txt2())
            .width(72)
          Row() {
            ForEach(PORT_OPTIONS, (p: number, index: number) => {
              Text(p.toString())
                .fontSize(this.CHIP_FS)
                .fontColor(this.port === p ? '#FFFFFF' : this.txt2())
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height(this.CHIP_H)
                .backgroundColor(this.port === p ? this.accentFill() : this.soft())
                .borderRadius(this.CHIP_R)
                .margin({ right: index === PORT_OPTIONS.length - 1 ? 0 : 4 })
                .onClick(() => {
                  this.port = p;
                  this.scheduleScanSave();
                })
            }, (p: number, index: number) => p.toString())
          }
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 8 })

        Text(this.t('Cloudflare 只支持这几个 TLS 端口。', 'Cloudflare only supports these TLS ports.'))
          .fontSize(11)
          .fontColor(this.txt3())
          .width('100%')
          .margin({ top: 8 })

        this.SourceHint()
      }
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('src', a);
      })
      .width('100%')
      .padding(16)
      }
      .width('100%')
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
    { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }


  /** 紧凑参数格：标签压在输入框上方，多列并排，替代「一个参数一行 + 一段长说明」 */
  @Builder ParamCell(label: string, field: string, inputId: string, numeric: boolean, onChange: (v: string) => void) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(this.txt3())
        .maxLines(1)
        .margin({ bottom: 6 })
      TextInput({ text: this.paramValue(field) })
        .id(inputId)
        .width('100%')
        .height(38)
        .fontSize(14)
        .fontColor(this.txt())
        .backgroundColor(this.inputBg())
        .borderRadius(10)
        .type(numeric ? InputType.Number : InputType.Normal)
        .onChange(onChange)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 卡片内折叠条：默认收起，收起时只占一行，展开后露出低频参数与参数说明 */
  @Builder AdvRow(open: boolean, onTap: () => void) {
    Row() {
      Text(open ? this.t('收起高级选项', 'Hide advanced options') : this.t('高级选项', 'Advanced options'))
        .fontSize(12)
        .fontColor(this.txt2())
      Blank()
      Text(open ? this.t('收起', 'Collapse') : this.t('展开', 'Expand'))
        .fontSize(12)
        .fontColor(this.accentText())
    }
    .width('100%')
    .height(38)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.soft())
    .borderRadius(10)
    .margin({ top: 10 })
    .onClick(onTap)
  }

  /** 参数说明弹窗：轻量、居中、可关闭，不改动页面布局 */
  @Builder ParamNotesSheet() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.38)')
        .onClick(() => {
          this.showParamNotes = false;
        })
      Stack({ alignContent: Alignment.TopStart }) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(16)
              .fontColor([this.accentText()])
            Text(this.t('参数说明', 'Parameter notes'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.txt())
              .layoutWeight(1)
          }
          .width('100%')
          this.ParamNotesBody()
          Row() {
            Text(this.t('知道了', 'Got it'))
              .fontSize(13)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .height(36)
              .layoutWeight(1)
              .borderRadius(10)
              .backgroundColor(this.accentFill())
              .onClick(() => {
                this.showParamNotes = false;
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(18)
        .alignItems(HorizontalAlign.Start)
      }
      .width('86%')
      .constraintSize({ maxWidth: 460 })
      .backgroundBlurStyle(this.cardBlurStyle(),
        { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .linearGradient({ angle: 145, colors: this.cardTint() })
      .borderRadius(20)
      .border({ width: 1, color: this.cardBorderColor() })
      .shadow({ radius: 24, color: this.cardShadowColor(), offsetX: 0, offsetY: 10 })
    }
    .width('100%')
    .height('100%')
  }

  /** 参数说明正文（弹窗内使用） */
  @Builder ParamNotesBody() {
    Column() {
      Text(this.t('采样数：IPv4/IPv6 统一 3000；随机地址命中率偏低时可改用域名 AAAA 采样。', 'Samples: 3000 for both IPv4 and IPv6; if random addresses have a low hit rate, sample domain AAAA records instead.'))
        .fontSize(11)
        .fontColor(this.txt3())
        .width('100%')
      Text(this.t('并发上限：手机 120 / 平板 200 / 电脑 300（当前设备 ', 'Concurrency cap: 120 on phones / 200 on tablets / 300 on computers (this device: ') + maxScanConcurrency().toString() +
        this.t('），超过会自动改回上限。', '). Values above it are reset to the cap automatically.'))
        .fontSize(11)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 6 })
      Text(this.latencyHint)
        .fontSize(11)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 6 })
      Text(this.t('每个 IP 连 ', 'Each IP gets ') + this.pingText + this.t(' 次 TCP 取最小值；超过延迟上限直接淘汰，IPv4/IPv6 共用同一上限。', ' TCP samples, keeping the minimum; nodes above the latency cap are dropped. IPv4 and IPv6 share the same cap.'))
        .fontSize(11)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 6 })
      Text(this.t('合格速度：低于该值的节点在第一轮初筛后按延迟从低到高逐个淘汰，凑不满会提前中止（0 = 不淘汰）。', 'Min speed: after the round 1 pre-filter, nodes below this value are eliminated one by one in ascending latency order, and the process stops early if the target cannot be filled (0 = no elimination).'))
        .fontSize(11)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder CardParam() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.line_3_horizontal'))
            .fontSize(16)
            .fontColor([this.txt2()])
            .margin({ right: 8 })
          Text(this.t('快速筛选参数', 'Quick filter parameters'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 说明入口固定在卡片右上角，与「应用建议」不再重复
          Text('ⓘ')
            .fontSize(13)
            .fontColor(this.accentText())
            .textAlign(TextAlign.Center)
            .width(28)
            .height(28)
            .borderRadius(14)
            .backgroundColor(this.soft())
            .margin({ left: 8 })
            .accessibilityText(this.t('参数说明', 'Parameter notes'))
            .onClick(() => {
              this.showParamNotes = true;
            })
        }
        .width('100%')

        if (this.winW >= 900) {
          Row({ space: 10 }) {
            this.ParamCell(this.t('采样数', 'Samples'), 'sample', 'sample-' + this.cfgRev.toString(), true, (v: string) => {
              this.sampleText = v;
              this.scheduleScanSave();
            })
            this.ParamCell(this.t('并发线程', 'Threads'), 'conc', 'conc-' + this.cfgRev.toString(), true, (v: string) => {
              const lim: number = maxScanConcurrency();
              const n: number = parseInt(v);
              if (!isNaN(n) && n > lim) {
                this.concurrencyText = lim.toString();
                // TextInput 的 text 只作初值，必须换 id 触发重建才能把上限值回显到输入框
                this.cfgRev++;
                this.toast(this.t('并发上限为 ', 'Concurrency cap is ') + lim.toString() + this.t('，已按上限执行', '; the limit has been applied'));
              } else {
                this.concurrencyText = v;
              }
              this.scheduleScanSave();
            })
            this.ParamCell(this.t('延迟上限 ms', 'Latency cap ms'), 'lat', 'lat-' + this.cfgRev.toString(), true, (v: string) => {
              this.latencyText = v;
              this.scheduleScanSave();
            })
            this.ParamCell(this.t('Ping 次数', 'Ping count'), 'ping', 'ping-' + this.cfgRev.toString(), true, (v: string) => {
              this.pingText = v;
              this.scheduleScanSave();
            })
          }
          .width('100%')
          .margin({ top: 12 })
        } else {
          Row({ space: 10 }) {
            this.ParamCell(this.t('采样数', 'Samples'), 'sample', 'sample-' + this.cfgRev.toString(), true, (v: string) => {
              this.sampleText = v;
              this.scheduleScanSave();
            })
            this.ParamCell(this.t('并发线程', 'Threads'), 'conc', 'conc-' + this.cfgRev.toString(), true, (v: string) => {
              const lim: number = maxScanConcurrency();
              const n: number = parseInt(v);
              if (!isNaN(n) && n > lim) {
                this.concurrencyText = lim.toString();
                // TextInput 的 text 只作初值，必须换 id 触发重建才能把上限值回显到输入框
                this.cfgRev++;
                this.toast(this.t('并发上限为 ', 'Concurrency cap is ') + lim.toString() + this.t('，已按上限执行', '; the limit has been applied'));
              } else {
                this.concurrencyText = v;
              }
              this.scheduleScanSave();
            })
          }
          .width('100%')
          .margin({ top: 12 })
          Row({ space: 10 }) {
            this.ParamCell(this.t('延迟上限 ms', 'Latency cap ms'), 'lat', 'lat-' + this.cfgRev.toString(), true, (v: string) => {
              this.latencyText = v;
              this.scheduleScanSave();
            })
            this.ParamCell(this.t('Ping 次数', 'Ping count'), 'ping', 'ping-' + this.cfgRev.toString(), true, (v: string) => {
              this.pingText = v;
              this.scheduleScanSave();
            })
          }
          .width('100%')
          .margin({ top: 10 })
        }

        // 合格速度直接展示；右侧空位放「应用建议」，与输入框底边对齐
        Row({ space: 10 }) {
          this.ParamCell(this.t('合格速度 MB/s', 'Min speed MB/s'), 'minSpeed', 'speed-ms-' + this.cfgRev.toString(), false, (v: string) => {
            this.minSpeedText = v;
            this.scheduleScanSave();
          })
          Text(this.t('应用建议', 'Apply'))
            .fontSize(12)
            .fontColor(this.accentText())
            .textAlign(TextAlign.Center)
            .height(38)
            .padding({ left: 14, right: 14 })
            .backgroundColor(this.soft())
            .borderRadius(10)
            .constraintSize({ minWidth: 84 })
            .onClick(() => {
              this.applySuggestedParams();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 10 })
      }
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('param', a);
      })
      .width('100%')
      .padding(16)
      }
      .width('100%')
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
    { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder CardSpeed() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row() {
          Text(this.t('下载测速', 'Download speed test'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.enableSpeed })
            .selectedColor(this.accent())
            .onChange((on: boolean) => {
              this.enableSpeed = on;
              this.scheduleScanSave();
            })
        }
        .width('100%')

        if (this.enableSpeed) {
          Row() {
            Text(this.t('完全测速', 'Full speed test'))
              .fontSize(12)
              .fontColor(this.speedScope === SpeedScope.ALL ? '#FFFFFF' : this.txt2())
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(this.CHIP_H)
              .backgroundColor(this.speedScope === SpeedScope.ALL ? this.accentFill() : this.soft())
              .borderRadius(this.CHIP_R)
              .onClick(() => {
                this.speedScope = SpeedScope.ALL;
                this.scheduleScanSave();
              })
            Text(this.t('地区测速', 'Region speed test'))
              .fontSize(12)
              .fontColor(this.speedScope === SpeedScope.REGION ? '#FFFFFF' : this.txt2())
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(this.CHIP_H)
              .backgroundColor(this.speedScope === SpeedScope.REGION ? this.accentFill() : this.soft())
              .borderRadius(this.CHIP_R)
              .margin({ left: 6 })
              .onClick(() => {
                this.speedScope = SpeedScope.REGION;
                this.scheduleScanSave();
              })
            Text(this.t('全部地区', 'All regions'))
              .fontSize(12)
              .fontColor(this.speedScope === SpeedScope.PER_REGION ? '#FFFFFF' : this.txt2())
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(this.CHIP_H)
              .backgroundColor(this.speedScope === SpeedScope.PER_REGION ? this.accentFill() : this.soft())
              .borderRadius(this.CHIP_R)
              .margin({ left: 6 })
              .onClick(() => {
                this.speedScope = SpeedScope.PER_REGION;
                this.scheduleScanSave();
              })
          }
          .width('100%')
          .margin({ top: 12 })

          if (this.speedScope === SpeedScope.PER_REGION) {
            Row({ space: 10 }) {
              this.ParamCell(this.t('每地区数量', 'Per-region count'), this.speedPerRegionText, 'spd-per-' + this.cfgRev.toString(), true,
                (v: string) => {
                  this.speedPerRegionText = v;
                  this.scheduleScanSave();
                })
              Column()
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 10 })
          } else {
            Row({ space: 10 }) {
              this.ParamCell(this.t('测速地址数', 'Test addresses'), this.speedCountText, 'spd-count-' + this.cfgRev.toString(), true,
                (v: string) => {
                  this.speedCountText = v;
                  this.scheduleScanSave();
                })
              Column()
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 10 })
          }

          if (this.speedScope === SpeedScope.REGION) {
            Row({ space: 10 }) {
              this.ParamCell(this.t('地区码', 'Region code'), this.regionCode, 'spd-region-' + this.cfgRev.toString(), false,
                (v: string) => {
                  this.regionCode = v;
                  this.scheduleScanSave();
                })
              Column()
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 10 })
          }

          Text(this.speedScope === SpeedScope.PER_REGION
            ? this.t('按地区分组，每个地区各取延迟最低的前几个地址测速；覆盖所有地区。', 'Groups by region and speed-tests the few lowest-latency addresses in each region; covers all regions.')
            : this.t('第一轮通过的地址按延迟从低到高排序，只测前 N 个（默认 10，范围 1~99）；上传数量可在「设置 → 订阅上传」限制。', 'Round 1 addresses are sorted by latency, lowest first, and only the top N are tested (default 10, range 1–99); the upload count can be limited in Settings → Subscription upload.'))
            .fontSize(11)
            .fontColor(this.txt3())
            .width('100%')
            .margin({ top: 8 })

          // 平板/电脑端横向空间充足：去掉「高级选项」折叠，参数直接全部展示
          if (this.winW < 900) {
            this.AdvRow(this.advSpeedOpen, () => {
              animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, () => {
                this.advSpeedOpen = !this.advSpeedOpen;
              });
            })
          }

          if (this.winW >= 900 || this.advSpeedOpen) {
            Row({ space: 10 }) {
              this.ParamCell(this.t('每地址次数', 'Rounds per address'), this.speedRoundsText, 'spd-rounds-' + this.cfgRev.toString(), true,
                (v: string) => {
                  this.speedRoundsText = v;
                  this.scheduleScanSave();
                })
              this.ParamCell(this.t('窗口 ms', 'Window ms'), this.speedWindowText, 'spd-window-' + this.cfgRev.toString(), true,
                (v: string) => {
                  this.speedWindowText = v;
                  this.scheduleScanSave();
                })
            }
            .width('100%')
            .margin({ top: 10 })

            Row({ space: 10 }) {
              this.ParamCell(this.t('测速域名（可选）', 'Test domain (optional)'), this.domain, 'spd-domain-' + this.cfgRev.toString(), false,
                (v: string) => {
                  this.domain = v;
                  this.scheduleScanSave();
                })
              Column()
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 10 })

            Row() {
              Text(this.t('解析测试', 'Resolve test'))
                .fontSize(12)
                .fontColor(this.accentText())
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.soft())
                .borderRadius(9)
                .onClick(() => {
                  this.doResolve();
                })
              Text(this.domainInfoText)
                .fontSize(11)
                .fontColor(this.txt3())
                .margin({ left: 10 })
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 10 })

            Text(this.t('每个地址测 ', 'Each address is tested ') + this.speedRoundsText + this.t(' 次取平均，单次下载窗口 ', ' times and the results averaged; each download window is ') + this.speedWindowText +
              this.t('ms。建议次数不超过 10，否则总耗时很长。域名用于测速 Host/SNI 校验，并自动解析其 A（IPv4）/AAAA（IPv6）记录并入候选；留空则用 speed.cloudflare.com。', 'ms. Keep rounds at 10 or fewer, otherwise the total takes a long time. The domain is used for the test Host/SNI check and its A (IPv4)/AAAA (IPv6) records are resolved into candidates; if blank, speed.cloudflare.com is used.'))
              .fontSize(11)
              .fontColor(this.txt3())
              .width('100%')
              .margin({ top: 8 })
          }
        } else {
          Text(this.t('已关闭下载测速：只做连接可用性与延迟筛选，不测下载速度。', 'Download speed test is off: only connectivity and latency are filtered; download speed is not measured.'))
            .fontSize(11)
            .fontColor(this.txt3())
            .width('100%')
            .margin({ top: 8 })
        }
      }
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('speed', a);
      })
      .width('100%')
      .padding(16)
      }
      .width('100%')
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
    { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    // 宽屏时按左列高度撑满，保证左右两列卡片底部边界齐平。
    // 注意：这里直接读 @State（而不是用 Builder 形参），否则量测值变化不会触发重建。
    .constraintSize({ minHeight: this.speedCardMinH() })
    .margin({ bottom: 12 })
  }
  @Builder ThemeChip(label: string, idx: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.themeMode === idx ? '#FFFFFF' : this.txt2())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(this.BTN_H)
      .borderRadius(9)
      .backgroundColor(this.themeMode === idx ? this.accentFill() : this.soft())
      .onClick(() => {
        this.themeMode = idx;
        this.applyThemeMode();
        ConfigStore.saveTheme(idx).catch((e: BusinessError) => {
          this.addLog(this.t('保存主题失败：', 'Failed to save theme: ') + e.message);
        });
      })
  }

  /** 选项 chip 的选中判定：在 Builder 内部读取状态，保证点按后高亮即时刷新 */
  private chipSel(group: string, idx: number): boolean {
    if (group === 'matType') {
      return this.matType === idx;
    }
    if (group === 'matLevel') {
      return this.matLevel === idx;
    }
    return this.themeMode === idx;
  }

  /** 选项 chip（group + idx 由 Builder 内部换算选中态） */
  @Builder OptChip(label: string, group: string, idx: number, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(this.chipSel(group, idx) ? Color.White : this.txt2())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(this.BTN_H)
      .borderRadius(10)
      .backgroundColor(this.chipSel(group, idx) ? this.accentFill() : (this.dark ? '#1AFFFFFF' : '#10000000'))
      .onClick(() => {
        onTap();
      })
  }

  /** 滑块当前值：在 Builder 内部读取，拖动时百分比与位置即时刷新 */
  private pctVal(key: string): number {
    return key === 'blur' ? this.bgBlurPct : this.bgBrightPct;
  }

  /** 一行滑块（标题 + 百分比 + Slider），用于背景图模糊 / 明亮程度 */
  @Builder PctSliderRow(label: string, key: string) {
    Column({ space: 6 }) {
      Row() {
        Text(label)
          .fontSize(14)
          .fontColor(this.txt())
          .layoutWeight(1)
        Text(Math.round(this.pctVal(key)).toString() + '%')
          .fontSize(12)
          .fontColor(this.txt3())
      }
      .width('100%')

      Slider({ value: this.pctVal(key), min: 0, max: 100, step: 1 })
        .width('100%')
        .selectedColor(this.accent())
        .trackColor(this.dark ? '#22FFFFFF' : '#14000000')
        .blockColor(this.accent())
        .enabled(this.bgPath.length > 0)
        .opacity(this.bgPath.length > 0 ? 1 : 0.4)
        .onChange((v: number) => {
          if (key === 'blur') {
            this.bgBlurPct = v;
          } else {
            this.bgBrightPct = v;
          }
          this.saveUi();
        })
    }
    .width('100%')
    .margin({ top: 14 })
  }

  /** 外观 · 材质：全局沉浸光感 / 材质类型 / 材质等级 */
  @Builder CardAppearanceMaterial() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitle(this.t('材质', 'Material'), $r('sys.symbol.paintbrush'))

        Row() {
          Column() {
            Text(this.t('全局沉浸光感', 'Global immersive effect'))
              .fontSize(14)
              .fontColor(this.txt())
            Text(this.t('关闭后卡片与底部导航都不再使用沉浸光感', 'When off, cards and the bottom navigation no longer use the immersive material effect'))
              .fontSize(11)
              .fontColor(this.txt3())
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.globalImmersion })
            .selectedColor(this.accent())
            .onChange((on: boolean) => {
              this.globalImmersion = on;
              this.saveUi();
            })
        }
        .width('100%')
        .margin({ top: 12 })

        Row() {
          Text(this.t('类型', 'Type'))
            .fontSize(12)
            .fontColor(this.txt3())
            .width(56)
          Row({ space: 8 }) {
            this.OptChip(this.t('自适应', 'Adaptive'), 'matType', 0, () => {
              this.matType = 0;
              this.saveUi();
            })
            this.OptChip(this.t('沉浸', 'Immersive'), 'matType', 1, () => {
              this.matType = 1;
              this.saveUi();
            })
            this.OptChip(this.t('无材质', 'No material'), 'matType', 2, () => {
              this.matType = 2;
              this.saveUi();
            })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 12 })

        Row() {
          Text(this.t('等级', 'Level'))
            .fontSize(12)
            .fontColor(this.txt3())
            .width(56)
          Row({ space: 8 }) {
            this.OptChip(this.t('自适应', 'Adaptive'), 'matLevel', 0, () => {
              this.matLevel = 0;
              this.saveUi();
            })
            this.OptChip(this.t('精致', 'Exquisite'), 'matLevel', 1, () => {
              this.matLevel = 1;
              this.saveUi();
            })
            this.OptChip(this.t('柔和', 'Gentle'), 'matLevel', 2, () => {
              this.matLevel = 2;
              this.saveUi();
            })
            this.OptChip(this.t('平滑', 'Smooth'), 'matLevel', 3, () => {
              this.matLevel = 3;
              this.saveUi();
            })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 8 })

        Text(this.matSupported()
          ? (this.t('当前：', 'Current: ') + this.matTypeName() + ' · ' + this.matLevelName() + this.t('（设备等级 ', ' (device level ') + this.deviceLevelName() + this.t('，卡片', ', card: ') + this.glassDesc() + '）')
          : this.t('本机不支持系统沉浸材质，卡片与胶囊退回手绘玻璃。', 'This device does not support system immersive materials; cards and the capsule fall back to hand-drawn glass.'))
          .fontSize(11)
          .fontColor(this.txt3())
          .width('100%')
          .margin({ top: 12 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
    }
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .onAreaChange((_o: Area, a: Area) => {
      this.updateMeasuredCardHeight('mat', a);
    })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  /** 预设背景缩略图（Android 端 rawfile 直读，避免额外解码文件） */
  /** 背景图块可见内容宽度：宽屏要扣掉左侧分类栏 */
  private bgContentW(): number {
    const w: number = Math.min(this.winW, 1600);
    const side: number = w >= 900 ? 336 : 0;
    return Math.max(240, w - side - 32);
  }

  /** 一行放几个图块：内容窄时 4 个（两行），内容宽时 8 个（一行），避免被拉成细长条 */
  private bgCols(): number {
    return this.bgContentW() >= 760 ? 8 : 4;
  }

  /** 图块高度：列数越少、单个越宽，相应加高以保持接近 3:2 的预览比例 */
  private bgTileH(): number {
    const cols: number = this.bgCols();
    if (cols === 8) {
      return 76;
    }
    return this.bgContentW() >= 560 ? 72 : 56;
  }

  @Builder BgPresetTile(idx: number) {
    Stack({ alignContent: Alignment.Center }) {
      if (idx === 0) { Image($rawfile('bg/preset1.jpg'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
      } else if (idx === 1) { Image($rawfile('bg/preset2.jpg'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
      } else if (idx === 2) { Image($rawfile('bg/preset3.jpg'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
      } else if (idx === 3) { Image($rawfile('bg/preset4.jpg'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
      } else if (idx === 4) { Image($rawfile('bg/preset5.jpg'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
      } else if (idx === 5) { Image($rawfile('bg/preset6.jpg'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
      } else if (idx === 6) { Image($rawfile('bg/preset7.jpg'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
      }
      if (this.presetBgIndex() === idx) {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(12)
          .border({ width: 2, color: this.accent() })
      }
    }
    .width('100%')
    .height(this.bgTileH())
    .borderRadius(12)
    .clip(true)
    .backgroundColor(this.soft())
    .onClick(() => {
      this.usePresetBackground(idx);
    })
  }

  /** 「无背景图」图块：与预设图块同尺寸同圆角，选中态与预设一致 */
  @Builder BgNoneTile() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.nosign'))
        .fontSize(18)
        .fontColor([this.txt3()])
      if (this.bgPath.length === 0) {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(12)
          .border({ width: 2, color: this.accent() })
      }
    }
    .width('100%')
    .height(this.bgTileH())
    .borderRadius(12)
    .clip(true)
    .backgroundColor(this.soft())
    .onClick(() => {
      this.clearBackground();
    })
  }

  /** 外观 · 背景：颜色模式 / 主题色 / 背景图 / 模糊 / 明亮 */
  @Builder CardAppearanceBackground() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitle(this.t('外观', 'Appearance'), $r('sys.symbol.paintbrush'))

        Text(this.t('颜色模式', 'Color mode'))
          .fontSize(12)
          .fontColor(this.txt3())
          .width('100%')
          .margin({ top: 12, bottom: 8 })
        Row({ space: 8 }) {
          this.OptChip(this.t('跟随系统', 'Follow system'), 'theme', 2, () => {
            this.setThemeMode(2);
          })
          this.OptChip(this.t('深色', 'Dark'), 'theme', 0, () => {
            this.setThemeMode(0);
          })
          this.OptChip(this.t('浅色', 'Light'), 'theme', 1, () => {
            this.setThemeMode(1);
          })
        }
        .width('100%')

        Text(this.t('主题色', 'Accent color'))
          .fontSize(12)
          .fontColor(this.txt3())
          .width('100%')
          .margin({ top: 16, bottom: 8 })
        Row({ space: 10 }) {
          this.ThemeColorDot(0)
          this.ThemeColorDot(1)
          this.ThemeColorDot(2)
          this.ThemeColorDot(3)
          this.ThemeColorDot(4)
          this.ThemeColorDot(5)
        }
        .width('100%')

        Row() {
          Column() {
            Text(this.t('背景图', 'Background image'))
              .fontSize(14)
              .fontColor(this.txt())
            Text(this.bgPathLabel())
              .fontSize(11)
              .fontColor(this.txt3())
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.t('图库选择', 'Choose from gallery'))
            .fontSize(12)
            .fontColor(this.accentText())
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.dark ? '#1AFFFFFF' : '#10000000')
            .borderRadius(10)
            .onClick(() => {
              this.pickBackground();
            })
        }
        .width('100%')
        .margin({ top: 18 })

        if (this.bgCols() === 8) {
          Row({ space: 8 }) {
            Column() {
              this.BgNoneTile()
            }
            .layoutWeight(1)
            Column() {
              this.BgPresetTile(0)
            }
            .layoutWeight(1)
            Column() {
              this.BgPresetTile(1)
            }
            .layoutWeight(1)
            Column() {
              this.BgPresetTile(2)
            }
            .layoutWeight(1)
            Column() {
              this.BgPresetTile(3)
            }
            .layoutWeight(1)
            Column() {
              this.BgPresetTile(4)
            }
            .layoutWeight(1)
            Column() {
              this.BgPresetTile(5)
            }
            .layoutWeight(1)
            Column() {
              this.BgPresetTile(6)
            }
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 10 })
        } else {
        Row({ space: 8 }) {
          Column() {
            this.BgNoneTile()
          }
          .layoutWeight(1)
          Column() {
            this.BgPresetTile(0)
          }
          .layoutWeight(1)
          Column() {
            this.BgPresetTile(1)
          }
          .layoutWeight(1)
          Column() {
            this.BgPresetTile(2)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 10 })

        Row({ space: 8 }) {
          Column() {
            this.BgPresetTile(3)
          }
          .layoutWeight(1)
          Column() {
            this.BgPresetTile(4)
          }
          .layoutWeight(1)
          Column() {
            this.BgPresetTile(5)
          }
          .layoutWeight(1)
          Column() {
            this.BgPresetTile(6)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        }


        // 两个滑杆属于常用外观调节，直接展示，不再折叠
        this.PctSliderRow(this.t('背景图模糊程度', 'Background blur'), 'blur')
        this.PctSliderRow(this.t('背景图明亮程度', 'Background brightness'), 'bright')
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .onAreaChange((_o: Area, a: Area) => {
      this.updateMeasuredCardHeight('appbg', a);
    })
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
    }

  /** 主题色色块 */
  @Builder ThemeColorDot(idx: number) {
    Column() {
      Row()
        .width(30)
        .height(30)
        .borderRadius(15)
        .backgroundColor(this.themeColorAt(idx))
        .border({ width: this.themeColorIdx === idx ? 2 : 1, color: this.themeColorIdx === idx ? this.txt() : (this.dark ? '#33FFFFFF' : '#33000000') })
      Text(this.themeColorName(idx))
        .fontSize(10)
        .fontColor(this.themeColorIdx === idx ? this.txt() : this.txt3())
        .margin({ top: 5 })
    }
    .layoutWeight(1)
    .onClick(() => {
      this.themeColorIdx = idx;
      this.saveUi();
    })
  }
  /** 打开外部链接：优先用系统 openLink，失败则退回隐式 Want */
  private openExternal(url: string): void {
    const ctx: common.UIAbilityContext = this.ctx as common.UIAbilityContext;
    try {
      ctx.openLink(url).catch((err: BusinessError) => {
        this.addLog(this.t('打开浏览器失败（', 'Failed to open browser (') + err.code + this.t('），改用系统浏览器', '), falling back to the system browser'));
        this.startBrowser(url);
      });
    } catch (e) {
      this.startBrowser(url);
    }
  }

  private startBrowser(url: string): void {
    const ctx: common.UIAbilityContext = this.ctx as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    ctx.startAbility(want).catch((err: BusinessError) => {
      this.addLog(this.t('无法打开链接：', 'Cannot open link: ') + err.message);
    });
  }

  @Builder AboutLink(label: string, sub: string, url: string) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(12)
          .fontColor(this.txt())
        Text(sub)
          .fontSize(10)
          .fontColor(this.txt3())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('↗')
        .fontSize(13)
        .fontColor(this.accentText())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .borderRadius(12)
    .backgroundColor(this.accentSoft())
    .margin({ top: 8 })
    .onClick(() => {
      this.openExternal(url);
    })
  }
  @Builder CardRuntime() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitle(this.t('运行', 'Runtime'), $r('sys.symbol.gearshape'))
        Row() {
          Column({ space: 3 }) {
            Text(this.t('后台保持运行', 'Keep running in background'))
              .fontSize(14)
              .fontColor(this.txt())
            Text(this.t('开启后扫描/测速/上传期间切到后台不中断：手机/平板使用数据传输连续任务，PC 优先计算任务；关闭则使用系统默认行为', 'When on, scans, speed tests and uploads keep running after switching to the background: DATA_TRANSFER continuous task on phones/tablets, compute task preferred on PC. When off, the system default applies.'))
              .fontSize(11)
              .fontColor(this.txt3())
              .lineHeight(16)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.keepAlive })
            .selectedColor(this.accent())
            .onChange((v: boolean) => {
              this.keepAlive = v;
              AppBackground.enabled = v;
              ConfigStore.saveKeepAlive(v);
              if (v) {
                this.addLog(this.t('后台保活已开启：扫描/测速/自动上传期间保持运行（手机/平板 DATA_TRANSFER，PC 优先 TASK_KEEPING）', 'Background keep-alive on: stays running during scans, speed tests and auto uploads (DATA_TRANSFER on phones/tablets; TASK_KEEPING preferred on PC)'));
              } else {
                this.addLog(this.t('后台保活已关闭：使用系统默认后台策略', 'Background keep-alive off: using the system default background policy'));
              }
            })
        }
        .width('100%')
        .margin({ top: 14 })
        .alignItems(VerticalAlign.Center)
      }
      .padding(16)
      .width('100%')
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('rt', a);
      })
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder CardAbout() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitle(this.t('关于', 'About'), $r('sys.symbol.info_circle'))
        Row() {
          Text('CFLark')
            .fontSize(14)
            .fontColor(this.txt())
          Blank()
          Text('v' + this.appVersion)
            .fontSize(13)
            .fontColor(this.txt3())
        }
        .width('100%')
        .margin({ top: 12 })
        Text(this.t('Cloudflare 节点优选 · 鸿蒙原生应用', 'Cloudflare node selection · native HarmonyOS app'))
          .fontSize(11)
          .fontColor(this.txt3())
          .margin({ top: 6 })
        Text(this.t('TCP 筛选 → 数据中心 → 下载测速 → 加权排序，支持域名端到端校验与 edgetunnel 订阅上传。', 'TCP filter → data center → download speed test → weighted ranking, with end-to-end domain validation and edgetunnel subscription uploads.'))
          .fontSize(11)
          .fontColor(this.txt3())
          .lineHeight(17)
          .margin({ top: 8 })
        this.AboutLink(this.t('GitHub 项目主页', 'GitHub project page'), this.t('源码、Issue 与更新记录', 'Source code, issues and changelog'), 'https://github.com/Bailin-Love/CFLark-Harmony')

        // 检查更新：并入「关于」卡片，紧跟项目主页，不另起一张卡
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.t('检查更新', 'Check for updates'))
              .fontSize(13)
              .fontColor(this.txt())
            Text(this.updStatusText())
              .fontSize(11)
              .fontColor(this.updStatusColor())
              .lineHeight(16)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.updStatus === UpdateStatus.CHECKING ? this.t('检查中…', 'Checking…')
            : (this.updFailed() ? this.t('重试', 'Retry') : this.t('检查', 'Check')))
            .fontSize(12)
            .fontColor(this.updStatus === UpdateStatus.CHECKING ? this.txt3() : Color.White)
            .textAlign(TextAlign.Center)
            .height(34)
            .padding({ left: 16, right: 16 })
            .borderRadius(9)
            .backgroundColor(this.updStatus === UpdateStatus.CHECKING ? this.soft() : this.accentFill())
            .onClick(() => {
              this.checkUpdate();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 12 })

        if (this.updStatus === UpdateStatus.UPDATE_AVAILABLE) {
          Row({ space: 8 }) {
            Text('v' + this.updLatestVersion)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.accentText())
            Text(this.updLatestDate.length >= 10 ? this.updLatestDate.substring(0, 10) : this.updLatestDate)
              .fontSize(11)
              .fontColor(this.txt3())
          }
          .width('100%')
          .margin({ top: 10 })
          if (this.updLatestNotes.length > 0) {
            Text(this.updLatestNotes.length > 260 ? this.updLatestNotes.substring(0, 260) + '…' : this.updLatestNotes)
              .fontSize(11)
              .fontColor(this.txt3())
              .lineHeight(17)
              .maxLines(6)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 6 })
          }
          Text(this.updHasPackage
            ? this.t('该版本的 Releases 提供安装包，请在发布页按需下载；应用不会自动安装。', 'This release provides an install package; download it from the release page if needed. The app never installs it automatically.')
            : this.t('该版本的 Releases 未附带鸿蒙安装包，本应用不会自动下载或覆盖安装。', 'This release has no HarmonyOS package attached; this app never downloads or installs automatically.'))
            .fontSize(10)
            .fontColor(this.txt3())
            .lineHeight(15)
            .width('100%')
            .margin({ top: 6 })
          Row({ space: 8 }) {
            Text(this.t('前往下载', 'Go to download'))
              .fontSize(12)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .height(32)
              .padding({ left: 14, right: 14 })
              .borderRadius(9)
              .backgroundColor(this.accentFill())
              .onClick(() => {
                this.openExternal(this.updLatestUrl.length > 0 ? this.updLatestUrl : AppMeta.RELEASES_URL);
              })
            Text(this.t('更新日志', 'Changelog'))
              .fontSize(12)
              .fontColor(this.accentText())
              .height(32)
              .padding({ left: 12, right: 12 })
              .borderRadius(9)
              .backgroundColor(this.soft())
              .onClick(() => {
                this.openChangelog();
              })
            Blank()
          }
          .width('100%')
          .margin({ top: 10 })
        }

        if (this.updFromFallback && this.updStatus === UpdateStatus.UPDATE_AVAILABLE) {
          Text(this.t('（接口受限，版本号由官方 Releases 页面读取，更新说明可能缺失）',
            ' (API limited: version read from the official Releases page; notes may be missing)'))
            .fontSize(10)
            .fontColor(this.txt3())
            .lineHeight(14)
            .margin({ top: 6 })
        }

        Divider()
          .color(this.cardBorderColor())
          .margin({ top: 12, bottom: 8 })
        Text(this.t('免责条款', 'Disclaimer'))
          .fontSize(11)
          .fontColor(this.txt2())
          .margin({ top: 2 })
        Text(this.t('本应用仅供学习与个人研究使用，与 Cloudflare 官方无关。请遵守所在地区法律法规及 Cloudflare 服务条款；因使用本应用（含节点测速、订阅上传等）产生的任何后果由使用者自行承担。', 'This app is for learning and personal research only and is not affiliated with Cloudflare. Please comply with the laws of your region and the Cloudflare Terms of Service; you are solely responsible for any consequences of using this app (including node speed tests and subscription uploads).'))
          .fontSize(10)
          .fontColor(this.txt3())
          .lineHeight(16)
          .margin({ top: 6 })
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('about', a);
      })
      .width('100%')
      .padding(16)
    }
    .padding(16)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
    }
  }

  @Builder DiagOutput() {
    if (this.diagText.length > 0) {
      Scroll() {
        Text(this.diagText)
          .fontSize(10)
          .fontColor(this.txt2())
          .lineHeight(15)
          .width('100%')
          .textAlign(TextAlign.Start)
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .height(230)
      .margin({ top: 10 })
      .padding(10)
      .backgroundColor(this.soft())
      .borderRadius(10)
      .scrollBar(BarState.Auto)
    }
  }

  @Builder CardDiag() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitle(this.t('网络诊断', 'Network diagnostics'), $r('sys.symbol.info_circle'))
        Text(this.t('用于区分「应用 Socket 问题 / 运营商路由问题 / 随机地址不可达 / 超时过短 / 延迟门槛过严」。自检固定使用 3000ms 超时、顺序执行，不会修改扫描配置。', 'Helps distinguish app socket issues / carrier routing issues / unreachable random addresses / timeouts that are too short / an overly strict latency threshold. The self-test always uses a 3000ms timeout and runs sequentially; it does not change scan settings.'))
          .fontSize(11)
          .fontColor(this.txt3())
          .lineHeight(16)
          .margin({ top: 8 })
        Row({ space: 10 }) {
          Text(this.diagBusy ? this.t('诊断中…', 'Diagnosing…') : this.t('运行 IPv4 自检', 'Run IPv4 self-test'))
            .fontSize(13)
            .fontColor(this.diagBusy ? this.txt3() : this.accent())
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.soft())
            .borderRadius(9)
            .onClick(() => {
              if (!this.diagBusy) {
                this.runIpv4Diag();
              }
            })
          Text(this.diagBusy ? this.t('诊断中…', 'Diagnosing…') : this.t('运行 IPv6 自检', 'Run IPv6 self-test'))
            .fontSize(13)
            .fontColor(this.diagBusy ? this.txt3() : this.accent())
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.soft())
            .borderRadius(9)
            .onClick(() => {
              if (!this.diagBusy) {
                this.runIpv6Diag();
              }
            })
          Blank()
        }
        .width('100%')
        .margin({ top: 12 })

        if (this.diagText.length > 0) {
          Row({ space: 10 }) {
            Text(this.t('复制结果', 'Copy results'))
              .fontSize(12)
              .fontColor(this.accentText())
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.soft())
              .borderRadius(8)
              .onClick(() => {
                this.copyDiag();
              })
            Text(this.t('清空', 'Clear'))
              .fontSize(12)
              .fontColor(this.txt3())
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.soft())
              .borderRadius(8)
              .onClick(() => {
                this.clearDiag();
              })
            Blank()
          }
          .width('100%')
          .margin({ top: 8 })
        }

        this.DiagOutput()
      }
      .padding(16)
      .width('100%')
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('diag', a);
      })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
    { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  /**
   * 标签页主体（抽出为 @Builder，便于语言切换时整棵重建）。
   * 说明：ArkUI 中 @Builder 的按值参数不会随状态变化刷新，
   * 因此在 build() 里用 if/else 两个等价分支包住本 Builder，
   * 语言切换时销毁并重建，保证所有已渲染文案立即切换。
   */
  @Builder TabsCore() {
    HdsTabs({ index: this.curTab, barPosition: BarPosition.End }) {
      TabContent() {
        Column() {
          this.ScanPage()
        }
        .width('100%')
        .height('100%')
      }.tabBar(this.TabItem(this.t('扫描', 'Scan'), 0))

      TabContent() {
        Column() {
          this.PingPage()
        }
        .width('100%')
        .height('100%')
      }.tabBar(this.TabItem(this.t('筛选', 'Filter'), 1))

      TabContent() {
        Column() {
          this.SpeedPage()
        }
        .width('100%')
        .height('100%')
      }.tabBar(this.TabItem(this.t('测速', 'Speed test'), 2))
TabContent() {
  Column() {

    this.SettingsPage()
  }
  .width('100%')
  .height('100%')
}.tabBar(this.TabItem(this.t('设置', 'Settings'), 3))
    }
    .width('100%')
    .height('100%')
    // 官方「沉浸光感」：HdsTabs 悬浮页签 + barFloatingStyle.systemMaterialEffect
    // （见《鸿蒙沉浸光感》文档：barOverlap(true)/vertical(false)/barPosition(End)）
    .vertical(false)
    .barOverlap(true)
    .barBackgroundColor(this.dark ? '#A61C1C22' : '#00FFFFFF')
.barFloatingStyle(this.navFloatStyle())
    .backgroundColor(Color.Transparent)
    .scrollable(true)
    // 切页动画时长：默认偏长（300ms），缩短到 200ms 让滑动/点击更跟手；
    // 不改变切换判定，选中态仍以 onChange（真实生效的页面）为准
    .animationDuration(200)
    // 说明：这里只做「允许切换」的判断，不修改选中态。
    // 手势未达阈值 / 被取消并回弹时不会触发 onChange，选中态因此保持在真实页面；
    // 只有 onChange（切换真正生效）才会同步 navSel。
    .onContentWillChange((cur: number, coming: number) => {
      return true;
    })
    .onChange((index: number) => {
      if (index !== this.curTab) {
        this.anyScrollY = 0;
        if (this.showBackTop) {
          this.showBackTop = false;
        }
      }
      this.curTab = index;
      this.navSel = index;
      this.navPillX = this.navTabCenter(index);
      this.setPillScale(1.0, 0, 0);
    })
  }

  // ===== 更新检查 / 更新日志 / 升级说明 =====
  private updStatusText(): string {
    if (this.updStatus === UpdateStatus.CHECKING) {
      return this.t('正在检查…', 'Checking…');
    }
    if (this.updStatus === UpdateStatus.UP_TO_DATE) {
      return this.t('已是最新版本', 'You are on the latest version');
    }
    if (this.updStatus === UpdateStatus.UPDATE_AVAILABLE) {
      return this.t('发现新版本 v', 'New version available: v') + this.updLatestVersion;
    }
    if (this.updStatus === UpdateStatus.NO_RELEASE) {
      return this.t('暂无可发布的正式版本', 'No published release yet');
    }
    if (this.updStatus === UpdateStatus.RATE_LIMITED) {
      return this.t('请求被限流，请稍后再试', 'Requests are rate-limited; try again later');
    }
    if (this.updStatus === UpdateStatus.PARSE_ERROR) {
      return this.t('返回内容无法解析，请稍后重试', 'Unexpected response; try again later');
    }
    if (this.updStatus === UpdateStatus.NETWORK_ERROR) {
      return this.t('网络不可用，检查失败', 'Network unavailable; check failed');
    }
    return this.t('尚未检查', 'Not checked yet');
  }

  private updStatusColor(): string {
    if (this.updStatus === UpdateStatus.UPDATE_AVAILABLE) {
      return this.accentText();
    }
    if (this.updStatus === UpdateStatus.NETWORK_ERROR || this.updStatus === UpdateStatus.RATE_LIMITED ||
      this.updStatus === UpdateStatus.PARSE_ERROR) {
      return this.dark ? '#F0A0A0' : '#B3261E';
    }
    return this.txt3();
  }

  private updFailed(): boolean {
    return this.updStatus === UpdateStatus.NETWORK_ERROR || this.updStatus === UpdateStatus.RATE_LIMITED ||
      this.updStatus === UpdateStatus.PARSE_ERROR;
  }

  /** 手动检查更新（结果只展示，不自动下载、不覆盖安装） */
  async checkUpdate(): Promise<void> {
    if (this.updStatus === UpdateStatus.CHECKING) {
      return;
    }
    this.updStatus = UpdateStatus.CHECKING;
    this.updDetail = '';
    const res: UpdateCheckResult = await UpdateChecker.check(this.appVersion);
    this.updStatus = res.status;
    this.updDetail = res.detail;
    if (res.latest !== null) {
      this.updLatestVersion = res.latest.version;
      this.updLatestDate = res.latest.publishedAt;
      this.updLatestNotes = res.latest.notes;
      this.updLatestUrl = res.latest.htmlUrl;
      this.updHasPackage = res.latest.hasHarmonyPackage;
      this.updFromFallback = res.latest.fromFallback;
    }
  }

  /** 首次安装不弹；升级后仅在版本变化且本地有该版本真实记录时弹一次 */
  private maybeShowChangelog(): void {
    const current: string = this.appVersion;
    if (current.length === 0) {
      return;
    }
    let seen: string = '';
    try {
      seen = ConfigStore.changelogSeen();
    } catch (e) {
      seen = '';
    }
    const entry: ChangelogEntry | null = Changelog.forCurrent(current);
    if (seen.length === 0) {
      // 首次安装：直接记住当前版本，不打扰用户
      ConfigStore.saveChangelogSeen(current).catch(() => {
      });
      return;
    }
    if (seen === current) {
      return;
    }
    if (AppMeta.compareVersion(current, seen) < 0) {
      // 降级：不弹升级说明，只同步记录，避免反复打扰
      ConfigStore.saveChangelogSeen(current).catch(() => {
      });
      return;
    }
    if (entry === null) {
      ConfigStore.saveChangelogSeen(current).catch(() => {
      });
      return;
    }
    this.changelogVersion = current;
    this.showChangelogDialog = true;
  }

  private confirmChangelog(): void {
    this.showChangelogDialog = false;
    ConfigStore.saveChangelogSeen(this.changelogVersion).catch(() => {
    });
  }

  private openChangelog(): void {
    this.openSub(6);
  }

  /** 更新日志默认展开最新一个版本，其余折叠 */
  private changelogDefaultOpen(): string {
    const es: ChangelogEntry[] = Changelog.entries();
    return es.length > 0 ? es[0].version : '';
  }

  /** 参考项目与 AI 声明 */
  @Builder CardStatements() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 8 }) {
        this.CardTitle(this.t('声明', 'Statements'), $r('sys.symbol.doc_text'))
        Text(this.t('参考项目声明', 'Referenced projects'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txt2())
        Text(this.t(
          '本应用为独立实现的鸿蒙原生应用，不包含从其他仓库复制的源代码。界面与材质效果的实现思路参考了：HarmonyOS 官方设计规范与 HDS 组件文档（含沉浸光感 / 系统材质能力）；Cloudflare 公开的 IP 段列表与测速端点（仅作为网络请求目标）；社区公开的 Cloudflare 优选 IP 段列表（由内置来源在线拉取，不随应用打包）。',
          'This is an independent HarmonyOS app; it contains no source code copied from other repositories. Implementation ideas were informed by: the official HarmonyOS design guidelines and HDS component docs (including immersive material / system material); Cloudflare public IP ranges and speed-test endpoints (used only as network targets); community-maintained Cloudflare IP range lists (fetched online from built-in sources, not bundled).'))
          .fontSize(10)
          .fontColor(this.txt3())
          .lineHeight(16)
        Text(this.t('AI 辅助开发声明', 'AI-assisted development'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txt2())
          .margin({ top: 4 })
        Text(this.t(
          '部分界面代码、样式与中英文文案由 AI 编程助手辅助生成，随后由维护者审核、构建并在真机上验证；业务逻辑（节点扫描、质量筛选、TCPing 预检、下载测速与订阅上传）以项目自身实现为准，AI 不对其正确性负责。',
          'Parts of the UI code, styling and bilingual copy were drafted with the help of an AI programming assistant, then reviewed, built and verified on real devices by the maintainer. Business logic (scanning, quality filtering, TCPing pre-check, download speed test and subscription upload) follows the project\'s own implementation; the AI is not responsible for its correctness.'))
          .fontSize(10)
          .fontColor(this.txt3())
          .lineHeight(16)
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder ChangeItemRow(it: ChangeItem) {
    Row({ space: 8 }) {
      Text(Changelog.kindLabel(it.kind, this.langEn))
        .fontSize(10)
        .fontColor(this.accentText())
        .textAlign(TextAlign.Center)
        .height(18)
        .padding({ left: 6, right: 6 })
        .borderRadius(6)
        .backgroundColor(this.accentSoft())
      Text(this.langEn ? it.en : it.zh)
        .fontSize(11)
        .fontColor(this.txt2())
        .lineHeight(17)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: 6 })
  }

  /** 更新日志列表：按版本折叠，只展开一个，避免版本多了以后页面过长 */
  @Builder ChangelogList() {
    Column({ space: 12 }) {
      ForEach(Changelog.entries(), (e: ChangelogEntry, idx: number) => {
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            Row({ space: 8 }) {
              Text('v' + e.version)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.txt())
              Text(e.date)
                .fontSize(11)
                .fontColor(this.txt3())
              Blank()
              if (idx === 0) {
                Text(this.t('当前版本', 'Current'))
                  .fontSize(10)
                  .fontColor(this.accentText())
                  .textAlign(TextAlign.Center)
                  .height(18)
                  .padding({ left: 6, right: 6 })
                  .borderRadius(6)
                  .backgroundColor(this.accentSoft())
              }
              // 折叠状态：条目数 + 展开/收起箭头，点击整行切换
              Text(this.changelogOpen === e.version
                ? this.t('收起', 'Collapse')
                : e.items.length.toString() + this.t(' 条更新 · 展开', ' updates · Show'))
                .fontSize(11)
                .fontColor(this.txt3())
              Text(this.changelogOpen === e.version ? '▴' : '▾')
                .fontSize(11)
                .fontColor(this.txt3())
            }
            .width('100%')
            .height(24)
            .onClick(() => {
              this.changelogOpen = (this.changelogOpen === e.version ? '' : e.version);
            })
            if (this.changelogOpen === e.version) {
              ForEach(e.items, (it: ChangeItem) => {
                this.ChangeItemRow(it)
              }, (it: ChangeItem, i: number) => e.version + '-' + i.toString())
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: this.changelogOpen === e.version ? 16 : 12 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .backgroundBlurStyle(this.cardBlurStyle(),
          { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
        .linearGradient({ angle: 145, colors: this.cardTint() })
        .borderRadius(20)
        .border({ width: 1, color: this.cardBorderColor() })
        .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
      }, (e: ChangelogEntry) => e.version)
      Text(this.t('更早版本的更新说明见 GitHub Releases。', 'Notes for older versions are on GitHub Releases.'))
        .fontSize(11)
        .fontColor(this.accentText())
        .margin({ top: 2, bottom: 6 })
        .onClick(() => {
          this.openExternal(AppMeta.RELEASES_URL);
        })
    }
    .width('100%')
  }

  /** 升级后首次启动的说明弹层 */
  @Builder UpgradeCover() {
    Column() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.bolt'))
            .fontSize(18)
            .fontColor([this.accentText()])
          Text(this.t('已更新到 v', 'Updated to v') + this.changelogVersion)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
          Blank()
        }
        .width('100%')
        Text(this.t('本次更新的主要变化', 'What changed in this version'))
          .fontSize(11)
          .fontColor(this.txt3())
          .width('100%')
        Scroll() {
          Column() {
            if (Changelog.forVersion(this.changelogVersion) !== null) {
              ForEach((Changelog.forVersion(this.changelogVersion) as ChangelogEntry).items, (it: ChangeItem) => {
                this.ChangeItemRow(it)
              }, (it: ChangeItem, i: number) => 'dlg-' + i.toString())
            }
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
        Row({ space: 10 }) {
          Text(this.t('查看完整日志', 'Full changelog'))
            .fontSize(12)
            .fontColor(this.accentText())
            .textAlign(TextAlign.Center)
            .height(this.BTN_H)
            .layoutWeight(1)
            .borderRadius(10)
            .backgroundColor(this.soft())
            .onClick(() => {
              this.showChangelogDialog = false;
              this.curTab = 3;
              this.navSel = 3;
              this.navPillX = this.navTabCenter(3);
              setTimeout(() => {
                this.openChangelog();
              }, 60);
            })
          Text(this.t('知道了', 'Got it'))
            .fontSize(13)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .height(this.BTN_H)
            .layoutWeight(1)
            .borderRadius(10)
            .backgroundColor(this.accentFill())
            .onClick(() => {
              this.confirmChangelog();
            })
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('100%')
      .padding(18)
      .alignItems(HorizontalAlign.Start)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK,
        { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .linearGradient({ angle: 145, colors: this.cardTint() })
      .borderRadius(22)
      .border({ width: 1, color: this.cardBorderColor() })
      .shadow({ radius: 28, color: 'rgba(0,0,0,0.35)', offsetX: 0, offsetY: 10 })
      .margin({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.32)')
  }

  // ===== 设置：二级分类 =====
  private subTitle(id: number): string {
    if (id === 0) {
      return this.t('外观与主题', 'Appearance');
    }
    if (id === 1) {
      return this.t('沉浸材质与光感', 'Immersive material');
    }
    if (id === 2) {
      return this.t('订阅与上传', 'Subscription upload');
    }
    if (id === 3) {
      return this.t('运行与网络', 'Runtime & network');
    }
    if (id === 7) {
      return this.t('语言 / Language', 'Language');
    }
    if (id === 4) {
      return this.t('关于与更新', 'About & updates');
    }
    return this.t('更新日志', 'Changelog');
  }

  private openSub(id: number): void {
    try {
      this.settingsScrollCache = this.settingsScroller.currentOffset().yOffset;
    } catch (e) {
      this.settingsScrollCache = 0;
    }
    this.settingsSub = id;
    if (id === 6 && this.changelogOpen === '') {
      this.changelogOpen = this.changelogDefaultOpen();
    }
    setTimeout(() => {
      try {
        this.settingsScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      } catch (e) {
      }
    }, 0);
  }

  private closeSub(): void {
    this.settingsSub = -1;
    const y: number = this.settingsScrollCache;
    // 首页内容比二级页高，首帧可能还没完成布局（此时 scrollTo 会被夹到较小的可滚动范围），
    // 因此在 0 / 90 / 220ms 各校正一次，保证回到原来的滚动位置。
    const tries: number[] = [0, 90, 220];
    for (let i = 0; i < tries.length; i++) {
      setTimeout(() => {
        try {
          if (Math.abs(this.settingsScroller.currentOffset().yOffset - y) > 1) {
            this.settingsScroller.scrollTo({ xOffset: 0, yOffset: y });
          }
        } catch (e) {
        }
      }, tries[i]);
    }
  }

  /** 分类入口行 */
  @Builder SettingsRow(id: number, icon: Resource, title: string, sub: string) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([this.accentText()])
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14)
          .fontColor(this.txt())
        Text(sub)
          .fontSize(11)
          .fontColor(this.txt3())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.rowTrailing(id))
        .fontSize(14)
        .fontColor(this.txt3())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .borderRadius(14)
    .backgroundColor(this.soft())
    .margin({ top: 8 })
    .onClick(() => {
      if (this.winW >= 900) {
        // 宽屏：左侧菜单 + 右侧内容，原地切换
        this.settingsPane = id;
        this.settingsSub = -1;
        this.settingsScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      } else {
        // 手机：进入分类详情页（返回回到菜单），不再在页面底部内嵌展开
        this.openSub(id);
      }
    })
  }

  /** 二级页顶部：返回 + 标题 */
  @Builder SubHeader() {
    Row({ space: 10 }) {
      Text(this.settingsSub === 6 ? '‹' : '‹')
        .fontSize(22)
        .fontColor(this.accentText())
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .borderRadius(15)
        .backgroundColor(this.soft())
        .onClick(() => {
          this.closeSub();
        })
      Text(this.subTitle(this.settingsSub))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.txt())
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 10 })
  }

  /** 语言 chip */
  @Builder LangChip(label: string, idx: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.langMode === idx ? Color.White : this.txt2())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .borderRadius(9)
      .backgroundColor(this.langMode === idx ? this.accentFill() : this.soft())
      .onClick(() => {
        this.applyLangMode(idx);
        this.saveUi();
      })
  }

  /** 语言（设置首页直接可见） */
  @Builder CardLanguage() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.doc_text'))
            .fontSize(15)
            .fontColor([this.accentText()])
          Text(this.t('语言 / Language', 'Language'))
            .fontSize(14)
            .fontColor(this.txt())
        }
        .width('100%')
        Row({ space: 8 }) {
          this.LangChip(this.t('跟随系统', 'System'), LangMode.SYSTEM)
          this.LangChip('简体中文', LangMode.ZH)
          this.LangChip('English', LangMode.EN)
        }
        .width('100%')
        Text(this.t('默认跟随系统：系统为英文时用英文，其他语言回退简体中文。切换后立即生效。',
          'Follows the system by default: English for English systems, Simplified Chinese otherwise. Applies immediately.'))
          .fontSize(11)
          .fontColor(this.txt3())
          .lineHeight(16)
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  /** 当前显示的分类：宽屏用 settingsPane（右栏），手机用 settingsSub（详情页） */
  private bodyIdx(): number {
    return this.winW >= 900 ? this.settingsPane : this.settingsSub;
  }

  /** 分类行右侧提示符：两种布局都是「进入」，统一用 › */
  private rowTrailing(id: number): string {
    return '›';
  }

  /** 设置首页：分类入口 */
  @Builder SettingsHome() {
    Column({ space: 12 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.CardTitle(this.t('设置', 'Settings'), $r('sys.symbol.gearshape'))
          this.SettingsRow(0, $r('sys.symbol.paintbrush'),
            this.t('外观与主题', 'Appearance'),
            this.t('颜色模式 · 主题色 · 背景图', 'Color mode · accent · background'))
          this.SettingsRow(1, $r('sys.symbol.line_3_horizontal'),
            this.t('沉浸材质与光感', 'Immersive material'),
            this.globalImmersion
              ? this.t('已开启 · ', 'On · ') + this.matTypeName() + ' · ' + this.matLevelName()
              : this.t('已关闭（卡片与导航不使用沉浸光感）', 'Off (cards and navigation use solid style)'))
          this.SettingsRow(2, $r('sys.symbol.icloud'),
            this.t('订阅与上传', 'Subscription upload'),
            this.etEnabled ? this.t('自动上传已开启', 'Auto upload on') : this.t('自动上传已关闭', 'Auto upload off'))
          this.SettingsRow(3, $r('sys.symbol.gearshape'),
            this.t('运行与网络', 'Runtime & network'),
            this.keepAlive ? this.t('后台保活已开启', 'Background keep-alive on') : this.t('后台保活已关闭', 'Background keep-alive off') +
              this.t(' · 网络诊断与导出', ' · diagnostics & export'))
          this.SettingsRow(4, $r('sys.symbol.info_circle'),
            this.t('关于与更新', 'About & updates'),
            'v' + this.appVersion + this.t(' · 检查更新 · 更新日志', ' · Updates · Changelog'))
          this.SettingsRow(6, $r('sys.symbol.doc_text'),
            this.t('更新日志', 'Changelog'),
            this.t('查看各版本的新增、优化与修复', 'New, improved and fixed items per version'))
          this.SettingsRow(7, $r('sys.symbol.doc_text'),
            this.t('语言 / Language', 'Language'),
            this.langMode === LangMode.EN ? 'English'
              : (this.langMode === LangMode.ZH ? '简体中文' : this.t('跟随系统', 'System')))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .backgroundBlurStyle(this.cardBlurStyle(),
        { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .linearGradient({ angle: 145, colors: this.cardTint() })
      .borderRadius(20)
      .border({ width: 1, color: this.cardBorderColor() })
      .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    }
    .width('100%')
  }

  /** 平板/电脑：左侧分类菜单 */
  @Builder SettingsMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitle(this.t('设置', 'Settings'), $r('sys.symbol.gearshape'))
        this.SettingsRow(0, $r('sys.symbol.paintbrush'),
          this.t('外观与主题', 'Appearance'),
          this.t('颜色模式 · 主题色 · 背景图', 'Color mode · accent · background'))
        this.SettingsRow(1, $r('sys.symbol.line_3_horizontal'),
          this.t('沉浸材质与光感', 'Immersive material'),
          this.globalImmersion
            ? this.t('已开启 · ', 'On · ') + this.matTypeName() + ' · ' + this.matLevelName()
            : this.t('已关闭（卡片与导航不使用沉浸光感）', 'Off (cards and navigation use solid style)'))
        this.SettingsRow(2, $r('sys.symbol.icloud'),
          this.t('订阅与上传', 'Subscription upload'),
          this.etEnabled ? this.t('自动上传已开启', 'Auto upload on') : this.t('自动上传已关闭', 'Auto upload off'))
        this.SettingsRow(3, $r('sys.symbol.gearshape'),
          this.t('运行与网络', 'Runtime & network'),
          this.keepAlive ? this.t('后台保活已开启', 'Background keep-alive on') : this.t('后台保活已关闭', 'Background keep-alive off') +
              this.t(' · 网络诊断与导出', ' · diagnostics & export'))
        this.SettingsRow(4, $r('sys.symbol.info_circle'),
          this.t('关于与更新', 'About & updates'),
          'v' + this.appVersion + this.t(' · 检查更新 · 更新日志', ' · Updates · Changelog'))
          this.SettingsRow(6, $r('sys.symbol.doc_text'),
            this.t('更新日志', 'Changelog'),
            this.t('查看各版本的新增、优化与修复', 'New, improved and fixed items per version'))
        this.SettingsRow(7, $r('sys.symbol.doc_text'),
          this.t('语言 / Language', 'Language'),
          this.langMode === LangMode.EN ? 'English'
            : (this.langMode === LangMode.ZH ? '简体中文' : this.t('跟随系统', 'System')))
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
  }

  /** 分类内容：手机详情页与宽屏右栏共用同一份实现（读 bodyIdx() 保证响应式） */
  @Builder CatBody() {
    if (this.bodyIdx() === 0) {
      this.CardAppearanceBackground()
    } else if (this.bodyIdx() === 1) {
      this.CardAppearanceMaterial()
    } else if (this.bodyIdx() === 2) {
      this.CardUpload()
    } else if (this.bodyIdx() === 3) {
      // 合并后的「运行与网络」：设置项 + 诊断工具
      this.CardRuntime()
      this.CardDiag()
    } else if (this.bodyIdx() === 4) {
      this.CardAbout()
      this.CardStatements()
    } else if (this.bodyIdx() === 6) {
      this.ChangelogList()
    } else if (this.bodyIdx() === 7) {
      this.CardLanguage()
    }
  }

  @Builder SettingsPage() {
    Column() {
      if (this.winW >= 900) {
        // 平板/电脑：左侧菜单 + 右侧内容（右侧限宽、独立滚动）
        Row({ space: 16 }) {
          Scroll() {
            Column() {
              this.SettingsMenu()
            }
            .width('100%')
            .padding({ top: this.contentTop(), bottom: this.pageBottomPad() })
          }
          .width(320)
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.TopStart)

          Scroll(this.settingsScroller) {
            Column({ space: 12 }) {
              this.CatBody()
            }
            .width('100%')
            .padding({ top: this.contentTop(), bottom: this.pageBottomPad() })
            .constraintSize({ maxWidth: 900 })
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.TopStart)
          .onScroll(() => {
            this.onPageScroll(this.settingsScroller);
          })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Top)
        .constraintSize({ maxWidth: 1600 })
      } else {
        Scroll(this.settingsScroller) {
          Column() {
            if (this.settingsSub >= 0) {
              this.SubHeader()
              Column({ space: 12 }) {
                this.CatBody()
              }
              .width('100%')
            } else {
              this.SettingsHome()
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.contentTop(), bottom: this.pageBottomPad() })
          .constraintSize({ maxWidth: 1600 })
        }
        .width('100%')
        .layoutWeight(1)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .linearGradientBlur(LG_BLUR_MAX, {
          fractionStops: this.lgStops(this.settingsVpH),
          direction: GradientDirection.Bottom
        })
        .onAreaChange((_o: Area, n: Area) => {
          const h: number = Number(n.height);
          if (h > 0 && Math.abs(h - this.settingsVpH) > 0.5) {
            this.settingsVpH = h;
          }
        })
        .onScroll(() => {
          this.onPageScroll(this.settingsScroller);
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
  @Builder EtFieldRow(label: string, value: string, hint: string, isPwd: boolean, onChange: (v: string) => void) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.txt2())
        .width(90)
      TextInput({ text: value, placeholder: hint })
        .type(isPwd ? InputType.Password : InputType.Normal)
        .fontSize(13)
        .fontColor(this.txt())
        .placeholderColor(this.txt3())
        .backgroundColor(this.soft())
        .borderRadius(10)
        .height(40)
        .layoutWeight(1)
        .onChange(onChange)
    }
    .width('100%')
    .margin({ top: 10 })
  }

  @Builder EtModeChip(label: string, idx: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.etMode === idx ? '#FFFFFF' : this.txt2())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(this.BTN_H)
      .borderRadius(9)
      .backgroundColor(this.etMode === idx ? this.accentFill() : this.soft())
      .onClick(() => {
        this.etMode = idx;
        this.saveEtConfig();
      })
  }

  @Builder EtPosChip(label: string, idx: number) {
    Text(label)
      .fontSize(this.CHIP_FS)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(this.CHIP_H)
      .borderRadius(9)
      .backgroundColor(this.etPos === idx ? this.accentFill() : this.soft())
      .fontColor(this.etPos === idx ? '#FFFFFF' : this.txt2())
      .onClick(() => {
        this.etPos = idx;
        this.saveEtConfig();
      })
  }

  @Builder EtTopChip(label: string, value: number) {
    Text(label)
      .fontSize(this.CHIP_FS)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(this.CHIP_H)
      .borderRadius(9)
      .backgroundColor(this.etTopN === value ? this.accentFill() : this.soft())
      .fontColor(this.etTopN === value ? '#FFFFFF' : this.txt2())
      .onClick(() => {
        this.etTopN = value;
        this.saveEtConfig();
      })
  }

  @Builder EtWayChip(label: string, idx: number) {
    Text(label)
      .fontSize(13)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(this.BTN_H)
      .borderRadius(9)
      .backgroundColor(this.etWay === idx ? this.accentFill() : this.soft())
      .fontColor(this.etWay === idx ? '#FFFFFF' : this.txt2())
      .onClick(() => {
        this.etWay = idx;
        this.saveEtConfig();
      })
  }

  @Builder CardUpload() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitle(this.t('订阅上传', 'Subscription upload'), $r('sys.symbol.icloud'))

        Row() {
          Column() {
            Text(this.t('扫描完成后自动上传', 'Auto-upload after scanning'))
              .fontSize(13)
              .fontColor(this.txt())
            Text(this.t('把优选结果写入 edgetunnel 的 ADD.txt 订阅', 'Write the selection results to the edgetunnel ADD.txt subscription'))
              .fontSize(11)
              .fontColor(this.txt3())
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.etEnabled })
            .selectedColor(this.accent())
            .onChange((on: boolean) => {
              this.etEnabled = on;
              this.saveEtConfig();
            })
        }
        .width('100%')
        .margin({ top: 12 })

        Row() {
          Text(this.t('上传方式', 'Upload method'))
            .fontSize(13)
            .fontColor(this.txt2())
            .width(90)
          Row({ space: 8 }) {
            this.EtWayChip(this.t('登录上传', 'Login upload'), 0)
            this.EtWayChip(this.t('API 直传', 'API direct upload'), 1)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 10 })

        if (this.etWay === 0) {
          this.EtFieldRow(this.t('域名', 'Domain'), this.etHost, 'edgetunnel.example.com', false, (v: string) => {
            this.etHost = v;
            this.saveEtConfig();
          })
          this.EtFieldRow(this.t('密码', 'Password'), this.etPassword, this.t('后台登录密码', 'Dashboard login password'), true, (v: string) => {
            this.etPassword = v;
            this.saveEtConfig();
          })
        } else {
          this.EtFieldRow('Account ID', this.etCfAccount, this.t('Cloudflare 账户 ID（32 位）', 'Cloudflare Account ID (32 characters)'), false, (v: string) => {
            this.etCfAccount = v;
            this.saveEtConfig();
          })
          this.EtFieldRow(this.t('命名空间 ID', 'Namespace ID'), this.etCfNamespace, this.t('Workers KV 命名空间 ID（32 位）', 'Workers KV namespace ID (32 characters)'), false, (v: string) => {
            this.etCfNamespace = v;
            this.saveEtConfig();
          })
          this.EtFieldRow('API Token', this.etCfToken, this.t('需要 Workers KV 读写权限', 'Requires Workers KV read/write permission'), true, (v: string) => {
            this.etCfToken = v;
            this.saveEtConfig();
          })
        }

        Row() {
          Text(this.t('上传模式', 'Upload mode'))
            .fontSize(13)
            .fontColor(this.txt2())
            .width(90)
          Row({ space: 8 }) {
            this.EtModeChip(this.t('覆盖', 'Overwrite'), 0)
            this.EtModeChip(this.t('追加', 'Append'), 1)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 10 })
          Row() {
            Text(this.etStatus.length > 0 ? this.etStatus : this.t('未上传', 'Not uploaded'))
              .fontSize(11)
              .fontColor(this.txt3())
              .layoutWeight(1)
            Text(this.etBusy ? this.t('上传中…', 'Uploading…') : this.t('立即上传', 'Upload now'))
              .fontSize(13)
              .fontColor(this.etBusy ? this.txt3() : this.accent())
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(this.soft())
              .borderRadius(9)
              .onClick(() => {
                if (!this.etBusy) {
                  this.uploadEdgeTunnel(false);
                }
              })
          }
          .width('100%')
          .margin({ top: 12 })

        // 订阅上传的高级项直接展开，避免多一层折叠
        if (true) {
          Row() {
            Text(this.t('自定义保留', 'Custom retained lines'))
              .fontSize(13)
              .fontColor(this.txt2())
              .width(90)
            Text(this.etCustom.trim().length > 0 ? (this.t('已填 ', 'Filled: ') + this.etCustom.trim().split('\n').length.toString() + this.t(' 行，每次上传都会带上', ' lines; included in every upload')) : this.t('可选：每行一个域名或节点', 'Optional: one domain or node per line'))
              .fontSize(11)
              .fontColor(this.txt3())
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 10 })
  
          TextArea({ text: this.etCustom, placeholder: this.t('每行一个：cdn.example.com 或 1.2.3.4:443', 'One per line: cdn.example.com or 1.2.3.4:443') })
            .height(84)
            .fontSize(12)
            .borderRadius(9)
            .backgroundColor(this.soft())
            .padding(10)
            .margin({ top: 6 })
            .onChange((v: string) => {
              this.etCustom = v;
              this.saveEtConfig();
            })
  
          Row() {
            Text(this.t('写入位置', 'Write position'))
              .fontSize(13)
              .fontColor(this.txt2())
              .width(90)
            Row({ space: 8 }) {
              this.EtPosChip(this.t('最前', 'Top'), 0)
              this.EtPosChip(this.t('最后', 'Bottom'), 1)
            }
            .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 10 })
  
          Row() {
            Text(this.t('上传数量', 'Upload count'))
              .fontSize(13)
              .fontColor(this.txt2())
              .width(90)
            TextInput({ text: this.etTopNText, placeholder: '3' })
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .fontColor(this.txt())
              .backgroundColor(this.soft())
              .borderRadius(10)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.etTopNText = v;
                const n: number = this.intOf(v, 0);
                this.etTopN = Math.max(0, Math.min(999, n));
                this.saveEtConfig();
              })
          }
          .width('100%')
          .margin({ top: 10 })
  
          Text(this.uploadLimitHint())
            .fontSize(11)
            .fontColor(this.txt3())
            .lineHeight(16)
            .margin({ top: 6 })
  
          Row() {
            Text(this.t('上传代理', 'Upload proxy'))
              .fontSize(13)
              .fontColor(this.txt2())
              .width(90)
            Column() {
              Text(this.t('仅订阅上传走代理（仅支持 HTTP 代理）', 'Proxy only for subscription uploads (HTTP proxy only)'))
                .fontSize(12)
                .fontColor(this.txt())
              Text(this.t('不影响测速与优选（请求级代理）', 'Does not affect speed tests or selection (per-request proxy)'))
                .fontSize(11)
                .fontColor(this.txt3())
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
  
            Toggle({ type: ToggleType.Switch, isOn: this.etProxyOn })
              .selectedColor(this.accent())
              .onChange((on: boolean) => {
                this.etProxyOn = on;
                this.saveEtConfig();
              })
          }
          .width('100%')
          .margin({ top: 10 })
  
          if (this.etProxyOn) {
            this.EtFieldRow(this.t('代理地址', 'Proxy address'), this.etProxyHost, '127.0.0.1', false, (v: string) => {
              this.etProxyHost = v;
              this.saveEtConfig();
            })
            this.EtFieldRow(this.t('代理端口', 'Proxy port'), this.etProxyPort, '7890', false, (v: string) => {
              this.etProxyPort = v;
              this.saveEtConfig();
            })
            this.EtFieldRow(this.t('代理用户', 'Proxy user'), this.etProxyUser, this.t('可选，留空为无认证', 'Optional; leave blank for no auth'), false, (v: string) => {
              this.etProxyUser = v;
              this.saveEtConfig();
            })
            this.EtFieldRow(this.t('代理密码', 'Proxy password'), this.etProxyPass, this.t('可选', 'Optional'), true, (v: string) => {
              this.etProxyPass = v;
              this.saveEtConfig();
            })
          }
  
          Text(this.etWay === 1
            ? this.t('提示：上传格式为「IP:端口#地区 V4/V6中文名序号」，例如 162.159.9.26:443#SG V4新加坡1；API 直传直接读写 Worker 绑定的 KV（键 ADD.txt），Token 只保存在本机，需要该 Account 的 Workers KV 读写权限。', 'Note: the upload format is "IP:port#region V4/V6ChineseNameIndex", e.g. 162.159.9.26:443#SG V4Singapore1. API direct upload reads and writes the Worker-bound KV (key ADD.txt); the token is stored only on this device and needs Workers KV read/write permission for that account.')
            : this.t('提示：上传格式为「IP:端口#地区 V4/V6中文名序号」，例如 162.159.9.26:443#SG V4新加坡1；edgetunnel 需把「优选订阅模式」设为自定义订阅，节点不是越多越好。', 'Note: the upload format is "IP:port#region V4/V6ChineseNameIndex", e.g. 162.159.9.26:443#SG V4Singapore1. In edgetunnel, set "Preferred subscription mode" to custom subscription; more nodes is not always better.'))
            .fontSize(11)
            .fontColor(this.txt3())
            .lineHeight(16)
            .margin({ top: 8 })
        }
      }
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('upload', a);
      })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .padding(16)
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }
  @Builder LogContent(bodyH: number) {
    if (this.logs.length === 0) {
      Text(this.t('暂无日志', 'No logs yet'))
        .fontSize(12)
        .fontColor(this.txt3())
        .margin({ top: 8 })
    } else {
      // 定高 + 滚动条：日志再多也只在本区域内滚动，不再把整张卡片拉长
      Scroll(this.logScroller) {
        Column() {
          ForEach(this.logs, (line: string, index: number) => {
            Text(line)
              .fontSize(11)
              .lineHeight(17)
              .fontColor(this.txt3())
              .width('100%')
              .margin({ top: 4 })
          }, (line: string, index: number) => index.toString() + '#' + line)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(bodyH)
      .margin({ top: 6 })
      .align(Alignment.TopStart)
      .scrollBar(BarState.On)
      .scrollBarWidth(3)
      .scrollBarColor(this.dark ? 'rgba(255,255,255,0.35)' : 'rgba(15,23,42,0.28)')
      .edgeEffect(EdgeEffect.None)
    }
  }

  @Builder CardLog(fill: boolean, bodyH: number, withMat: boolean) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (withMat) {
        this.MeasuredImmersionCard('log', 20)
      }
      Column() {
        this.CardTitle(this.t('运行日志', 'Logs'), $r('sys.symbol.doc_text'))
        this.LogContent(bodyH)
      }
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('log', a);
      })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(fill ? 0 : 16)
    .width('100%')
    .backgroundBlurStyle(fill ? BlurStyle.NONE : this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTintOr(fill) })
    .borderRadius(fill ? 0 : 16)
    .border({ width: fill ? 0 : 1, color: this.lineC() })
    .margin({ bottom: fill ? 0 : 12 })
    }
  }
    
    @Builder ToolBar() {
    Row() {
    Text(this.t('补测速前 5', 'Re-test top 5'))
    .fontSize(12)
    .fontColor('#FFFFFF')
    .textAlign(TextAlign.Center)
    .layoutWeight(1)
    .height(40)
    .backgroundColor(this.accentFill())
    .borderRadius(10)
    .onClick(() => {
    this.runSpeedTop();
    })
    Text(this.t('导出 TXT', 'Export TXT'))
    .fontSize(12)
    .fontWeight(FontWeight.Medium)
    .fontColor(this.accentText())
    .textAlign(TextAlign.Center)
    .width(88)
    .height(40)
    .backgroundColor(this.accentRgba(0.12))
    .borderRadius(10)
    .margin({ left: 8 })
    .onClick(() => {
    this.doExport(ExportFormat.PLAIN_COLO_DELAY);
    })
    Text(this.t('导出 CSV', 'Export CSV'))
    .fontSize(12)
    .fontWeight(FontWeight.Medium)
    .fontColor(this.accentText())
    .textAlign(TextAlign.Center)
    .width(88)
    .height(40)
    .backgroundColor(this.accentRgba(0.12))
    .borderRadius(10)
    .margin({ left: 8 })
    .onClick(() => {
    this.doExport(ExportFormat.CSV);
    })
    }
    .width('100%')
    .margin({ bottom: 10 })
    }
    
    // ---------- 第一轮：筛选结果（按地区分组，可展开看延迟） ----------
    @Builder PingPage() {
    Scroll(this.pingScroller) {
    Column() {
    Row().width('100%').height(px2vp(this.statusBarPx) + 66).hitTestBehavior(HitTestMode.None)
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row({ space: 6 }) {
        Text(this.t('第一轮通过 ', 'Round 1 passed: ') + this.pingList.length.toString() + this.t(' 个', ' nodes'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.txt())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(' · ' + this.groups.length.toString() + this.t(' 个地区', ' regions'))
        .fontSize(12)
        .fontColor(this.txt3())
        .maxLines(1)
        Text(this.precheckActive ? this.t('预检中…', 'Pre-checking…') : this.t('开始测速', 'Start speed test'))
        .fontSize(12)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .padding({ left: 12, right: 12 })
        .constraintSize({ minWidth: 74 })
        .height(34)
        .backgroundColor(this.precheckActive ? this.soft() : this.accentFill())
        .borderRadius(9)
        .onClick(() => {
        this.onStartSpeedClick();
        })
        }
        .width('100%')
        .margin({ bottom: 10 })
    
        if (this.precheckActive || (this.precheckDone && this.pcMsg.length > 0)) {
        Row() {
        Text(this.precheckActive ? this.t('质量预检中', 'Quality pre-check in progress') : this.t('质量预检', 'Quality pre-check'))
        .fontSize(12)
        .fontColor(this.accentText())
        Blank()
        Text(this.t('检测 ', 'Checked ') + this.pcChecked.toString() + this.t(' · 合格 ', ' · Qualified ') +
        (this.pcTarget > 0 && this.pcQualified > this.pcTarget ? this.pcTarget : this.pcQualified).toString() +
        this.t(' / 目标 ', ' / Target ') + this.pcTarget.toString())
        .fontSize(11)
        .fontColor(this.txt3())
        }
        .width('100%')
        .margin({ bottom: 6 })
    
        // 质量预检进度条：与扫描页同一套视觉（底槽 + 渐变填充）
        Stack({ alignContent: Alignment.Start }) {
        Row()
        .width('100%')
        .height(6)
        .backgroundColor(this.soft())
        .borderRadius(3)
        Row()
        .width(this.pcBarPct().toFixed(1) + '%')
        .height(6)
        .linearGradient({
        angle: 90,
        colors: this.progressTint()
        })
        .borderRadius(3)
        }
        .width('100%')
        .height(6)
        .margin({ bottom: 6 })
    
        if (this.pcMsg.length > 0) {
        Text(this.pcMsg)
        .fontSize(10)
        .fontColor(this.txt3())
        .margin({ bottom: 10 })
        }
        }
    
        Row() {
        Text(this.t('地区码', 'Region code'))
        .fontSize(12)
        .fontColor(this.txt2())
        .width(52)
        TextInput({ text: this.regionCode, placeholder: this.t('可留空；如 HKG / LAX', 'Optional; e.g. HKG / LAX') })
        .layoutWeight(1)
        .height(36)
        .fontSize(12)
        .fontColor(this.txt())
        .backgroundColor(this.inputBg())
        .borderRadius(9)
        .onChange((v: string) => {
        this.regionCode = v.toUpperCase();
        // 地区码变了：上一轮的预检结论作废，点「开始测速」会先重新预检
        this.precheckDone = false;
        })
        }
        .width('100%')
        .margin({ bottom: 10 })
    
        Text(this.t('先看下面各地区的最快延迟，挑延迟低的地区填码，再点右上「开始测速」；留空则测全部地区。', 'Check the fastest latency for each region below, pick a low-latency region and enter its code, then tap "Start speed test" at the top right; leave blank to test all regions.'))
        .fontSize(11)
        .fontColor(this.txt3())
        .margin({ bottom: 12 })

            if (this.pingList.length === 0) {
              Column() {
                Text(this.t('还没有筛选结果', 'No filter results yet'))
                  .fontSize(15)
                  .fontColor(this.txt2())
                Text(this.t('回到「扫描」页开始优选', 'Go to the "Scan" tab to start selection'))
                  .fontSize(12)
                  .fontColor(this.txt3())
                  .margin({ top: 6 })
              }
              .width('100%')
              .padding({ top: 60, bottom: 30 })
            }
      }
      .onAreaChange((_o: Area, a: Area) => {
        this.updateMeasuredCardHeight('ping', a);
      })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
    }
    .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })

        GridRow({
          columns: { sm: 12, md: 12, lg: 12 },
          gutter: { x: 14, y: 0 },
          breakpoints: { value: ['600vp', '900vp'], reference: BreakpointsReference.WindowSize }
        }) {
          ForEach(this.groups, (g: RegionGroup) => {
            GridCol({ span: { sm: 12, md: 6, lg: 4 } }) {
              this.GroupRow(g)
            }
          }, (g: RegionGroup) => g.colo + '#' + g.count.toString() + '#' +
            (this.expandedColos.indexOf(g.colo) >= 0 ? '1' : '0'))
        }
        .width('100%')


      }
      .width('100%')
      .padding({ left: this.pageSidePad(), right: this.pageSidePad(), top: 12, bottom: this.pageBottomPad() })
      .constraintSize({ maxWidth: 1600 })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .linearGradientBlur(LG_BLUR_MAX, {
      fractionStops: this.lgStops(this.pingVpH),
      direction: GradientDirection.Bottom
    })
    .onAreaChange((_o: Area, n: Area) => {
      const h: number = Number(n.height);
      if (h > 0 && Math.abs(h - this.pingVpH) > 0.5) {
        this.pingVpH = h;
      }
    })
    .onScroll(() => {
      this.onPageScroll(this.pingScroller);
    })
  }

  @Builder GroupRow(g: RegionGroup) {
    Column() {
      Row() {
        Column() {
          Text(g.colo === 'UNK' ? this.t('UNK 未知地区', 'UNK Unknown region') : (Geo.flag(g.colo) + ' ' + Geo.placeZh(g.colo)))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
          Text(g.count.toString() + this.t(' 个 · 最快 ', ' nodes · fastest ') + (g.minLatency > 0 ? Math.round(g.minLatency).toString() : '—') +
            this.t('ms · 平均 ', 'ms · Avg ') + (g.avgLatency > 0 ? Math.round(g.avgLatency).toString() : '—') + 'ms')
            .fontSize(11)
            .fontColor(this.txt3())
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.expandedColos.indexOf(g.colo) >= 0 ? this.t('收起', 'Collapse') : this.t('展开', 'Expand'))
          .fontSize(12)
          .fontColor(this.accentText())
      }
      .width('100%')
      .onClick(() => {
        this.toggleGroup(g.colo);
      })

      if (this.expandedColos.indexOf(g.colo) >= 0) {
        Column() {
          ForEach(g.items, (c: Candidate) => {
            Row() {
              Text(Exporter.endpoint(c, true))
                .fontSize(12)
                .fontColor(this.txt2())
                .layoutWeight(1)
              Text(this.delayText(c))
                .fontSize(12)
                .fontColor(OK_C)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              this.copyIp(c.ip);
            })
          }, (c: Candidate) => 'p#' + c.ip + ':' + c.port.toString())
        }
        .width('100%')
        .margin({ top: 6 })
        .padding({ left: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 10 })
  }

  // ---------- 第二轮：测速结果（只显示参与测速的 N 个） ----------
  @Builder SpeedPage() {
    Scroll(this.speedScroller) {
      Column() {
            Row().width('100%').height(px2vp(this.statusBarPx) + 66).hitTestBehavior(HitTestMode.None)
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
        Row() {
          Text(this.t('测速 ', 'Speed test: ') + this.speedList.length.toString() + this.t(' 个', ' nodes'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
          Blank()
          Text(this.t('导出 TXT', 'Export TXT'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accentText())
            .textAlign(TextAlign.Center)
            .width(84)
            .height(34)
            .backgroundColor(this.accentRgba(0.12))
            .borderRadius(9)
            .onClick(() => {
              this.doExport(ExportFormat.PLAIN_SPEED);
            })
          Text(this.t('导出 CSV', 'Export CSV'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accentText())
            .textAlign(TextAlign.Center)
            .width(84)
            .height(34)
            .backgroundColor(this.accentRgba(0.12))
            .borderRadius(9)
            .margin({ left: 8 })
            .onClick(() => {
              this.doExport(ExportFormat.CSV);
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        if (this.etEnabled) {
          Text(this.t('自动上传：', 'Auto-upload: ') + this.uploadLimitShort() + this.t('（设置 → 订阅上传 可修改）', ' (editable in Settings → Subscription upload)'))
            .fontSize(11)
            .fontColor(this.txt3())
            .margin({ bottom: 8 })
        }

        if (this.scanning) {
          Column() {
            Row() {
              Text(this.phaseText)
                .fontSize(12)
                .fontColor(this.txt2())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(this.progressLabel())
                .fontSize(12)
                .fontColor(this.txt3())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .flexShrink(1)
                .margin({ left: 8 })
            }
            .width('100%')

            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(9)
                .backgroundColor(this.soft())
                .borderRadius(3)
              Row()
                .width(((this.total > 0 ? this.done / this.total : 0) * 100).toFixed(1) + '%')
                .height(9)
                .linearGradient({
                  angle: 90,
                  colors: this.progressTint()
                })
                .borderRadius(4)
            }
            .width('100%')
            .height(9)
            .margin({ top: 8 })
          }
          .width('100%')
          .margin({ bottom: 10 })
        }

        Row() {
          Text(this.scanning ? this.t('测速进行中…', 'Speed test in progress…') : this.t('重新测速', 'Re-run speed test'))
            .fontSize(12)
            .fontColor(this.accentText())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.soft())
            .borderRadius(9)
            .onClick(() => {
              this.onStartSpeedClick();
            })
        }
        .width('100%')
        .margin({ bottom: 10 })

        if (this.speedList.length === 0) {
          Column() {
            Text(this.enableSpeed ? this.t('还没有测速结果', 'No speed test results yet') : this.t('下载测速已关闭', 'Download speed test is off'))
              .fontSize(15)
              .fontColor(this.txt2())
            Text(this.enableSpeed ? this.t('回到「扫描」页开始优选', 'Go to the "Scan" tab to start selection') : this.t('在扫描页打开「下载测速」开关', 'Turn on "Download speed test" on the Scan tab'))
              .fontSize(12)
              .fontColor(this.txt3())
              .margin({ top: 6 })
          }
          .width('100%')
          .padding({ top: 26, bottom: 16 })
        }

          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        }
        .width('100%')
        .backgroundBlurStyle(this.cardBlurStyle(), {
          colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
        })
        .linearGradient({ angle: 145, colors: this.cardTint() })
        .borderRadius(20)
        .border({ width: 1, color: this.cardBorderColor() })
        .shadow({
          radius: this.cardShadowR(),
          color: this.cardShadowColor(),
          offsetY: this.cardShadowY()
        })
        .margin({ bottom: 12 })
        GridRow({
          columns: { sm: 12, md: 12, lg: 12 },
          gutter: { x: 14, y: 0 },
          breakpoints: { value: ['600vp', '900vp'], reference: BreakpointsReference.WindowSize }
        }) {
          ForEach(this.speedList, (c: Candidate, index: number) => {
            GridCol({ span: { sm: 12, md: 6, lg: 4 } }) {
              this.SpeedRow(c, index)
            }
          }, (c: Candidate, index: number) => 's#' + index.toString() + '#' + c.ip + ':' + c.port.toString())
        }
        .width('100%')


      }
      .width('100%')
      .padding({ left: this.pageSidePad(), right: this.pageSidePad(), top: 12, bottom: this.pageBottomPad() })
      .constraintSize({ maxWidth: 1600 })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .linearGradientBlur(LG_BLUR_MAX, {
      fractionStops: this.lgStops(this.speedVpH),
      direction: GradientDirection.Bottom
    })
    .onAreaChange((_o: Area, n: Area) => {
      const h: number = Number(n.height);
      if (h > 0 && Math.abs(h - this.speedVpH) > 0.5) {
        this.speedVpH = h;
      }
    })
    .onScroll(() => {
      this.onPageScroll(this.speedScroller);
    })
  }

  /** 把扫描结果拆成「第一轮筛选」与「第二轮测速」两份，并构建地区分组 */
  /** 从测速结果里挑出要上传的节点与「自定义保留行」 */
  /** 单个节点的订阅行：IP:端口#地区 V4/V6中文名序号（IPv6 地址加方括号） */
  nodeLine(c: Candidate, regionCode: string, family: number, index: number): string {
    const addr: string = family === 6 ? '[' + c.ip + ']' : c.ip;
    const country: string = Geo.countryZh(regionCode);
    let label: string = country;
    if (label.length === 0) {
      label = Geo.cityZh(c.colo);
    }
    if (label.length === 0) {
      label = this.t('未知', 'Unknown');
    } else {
      // 同一国家/地区下有多个城市时补上城市名：既保证同地区连成一块，也让序号含义更清楚
      const city: string = Geo.cityZh(c.colo);
      if (city.length > 0 && city !== label && label.indexOf(city) < 0) {
        label = label + '·' + city;
      }
    }
    return addr + ':' + c.port.toString() + '#' + regionCode + ' V' + family.toString() + label + index.toString();
  }

  /** 「上传数量」规则的完整说明：规则随当前测速范围变化（完全/地区=合计，全部地区=每地区） */
  uploadLimitHint(): string {
    const n: number = this.etTopN;
    if (this.speedScope === SpeedScope.PER_REGION) {
      return n > 0
        ? this.t('当前「全部地区」测速：每个地区最多上传排序最靠前的 ', 'Current "All regions" speed test: uploads at most the top ') + n.toString()
          + this.t(' 个（默认 3，0=全部）。只影响上传，不影响测速和结果列表。', ' (default 3, 0 = all). Upload only; speed test and results are unaffected.')
        : this.t('当前「全部地区」测速：不限制上传数量（「全部」）。只影响上传，不影响测速和结果列表。', 'Current "All regions" speed test: no upload limit ("All"). Upload only; speed test and results are unaffected.');
    }
    const scopeName: string = this.speedScope === SpeedScope.REGION ? this.t('地区测速', 'Region speed test') : this.t('完全测速', 'Full speed test');
    return n > 0
      ? this.t('当前「', 'Current "') + scopeName + this.t('」：所有地区合计最多上传排序最靠前的 ', '": uploads at most the top ') + n.toString()
        + this.t(' 个（默认 3，0=全部）。只影响上传，不影响测速和结果列表。', ' (default 3, 0 = all). Upload only; speed test and results are unaffected.')
      : this.t('当前「', 'Current "') + scopeName + this.t('」：不限制上传数量（「全部」）。只影响上传，不影响测速和结果列表。', '": no upload limit ("All"). Upload only; speed test and results are unaffected.');
  }

  /** 测速完成页的简短提示 */
  uploadLimitShort(): string {
    if (this.etTopN <= 0) {
      return this.t('全部', 'All');
    }
    if (this.speedScope === SpeedScope.PER_REGION) {
      return this.t('每地区前 ', 'Per region, top ') + this.etTopN.toString() + this.t(' 个', ' nodes');
    }
    return this.t('合计前 ', 'Overall, top ') + this.etTopN.toString() + this.t(' 个', ' nodes');
  }

  /**
   * 上传内容：按「地区（国家/地区代码）」分组，组内先 IPv4 后 IPv6，
   * 分别从 1 开始编号；组顺序按该地区最好成绩的排名先后。
   * 例：162.159.9.26:443#SG V4新加坡1 / [2606:4700:...]:443#HK V6香港1
   */
  buildUploadPayload(): UploadPayload {
    // 只上传「真正测出速度」的节点：测速失败的（speedMbps 约为 0）不上传，
    // 否则订阅里会混进连不通的地址。speedList 已按得分从高到低排序。
    const filtered: Candidate[] = [];
    for (let i = 0; i < this.speedList.length; i++) {
      const c: Candidate = this.speedList[i];
      if (c.verdict !== Verdict.SPEEDED || c.speedMbps < 0.01) {
        continue;
      }
      filtered.push(c);
    }
    // 上传数量：全部地区=每地区前 N；完全测速/地区测速=所有地区合计前 N
    let picked: Candidate[] = filtered;
    if (this.speedScope !== SpeedScope.PER_REGION && this.etTopN > 0 && filtered.length > this.etTopN) {
      picked = filtered.slice(0, this.etTopN);
    }
    const groups: Map<string, Candidate[]> = new Map<string, Candidate[]>();
    const order: string[] = [];
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      const cc: string = Geo.countryCode(c.colo);
      const code: string = cc.length > 0 ? cc : (c.colo.length > 0 ? c.colo.toUpperCase() : 'XX');
      let arr: Candidate[] | undefined = groups.get(code);
      if (arr === undefined) {
        const fresh: Candidate[] = [];
        groups.set(code, fresh);
        order.push(code);
        arr = fresh;
      }
      (arr as Candidate[]).push(c);
    }
    // 组内整理：先按城市（colo）聚拢，同城再按综合成绩从高到低。
    // 只按成绩排会让同一国家的不同城市交替出现，订阅里看起来很乱。
    for (let g = 0; g < order.length; g++) {
      const row: Candidate[] | undefined = groups.get(order[g]);
      if (row === undefined) {
        continue;
      }
      (row as Candidate[]).sort((a: Candidate, b: Candidate): number => {
        if (a.colo !== b.colo) {
          return a.colo < b.colo ? -1 : 1;
        }
        return b.finalScore - a.finalScore;
      });
    }
    const nodes: string[] = [];
    for (let g = 0; g < order.length; g++) {
      const code: string = order[g];
      const all: Candidate[] | undefined = groups.get(code);
      if (all === undefined) {
        continue;
      }
      // 「全部地区」模式：每个地区最多上传 topN 个（0=全部），组内保持当前结果排序；
      // 「完全测速 / 地区测速」已经做过整体 topN，不再按地区截断。
      const perRegion: boolean = this.speedScope === SpeedScope.PER_REGION;
      const allArr: Candidate[] = all as Candidate[];
      const arr: Candidate[] = perRegion && this.etTopN > 0 && allArr.length > this.etTopN
        ? allArr.slice(0, this.etTopN) : allArr;
      for (let f = 0; f < 2; f++) {
        const family: number = f === 0 ? 4 : 6;
        let num: number = 0;
        for (let i = 0; i < arr.length; i++) {
          const c: Candidate = arr[i];
          const v: number = c.version === 6 ? 6 : 4;
          if (v !== family) {
            continue;
          }
          num++;
          nodes.push(this.nodeLine(c, code, family, num));
        }
      }
    }
    const custom: string[] = [];
    const raw: string[] = this.etCustom.split('\n');
    for (let i = 0; i < raw.length; i++) {
      const t: string = raw[i].trim();
      if (t.length > 0) {
        custom.push(t);
      }
    }
    const payload: UploadPayload = {
      nodes: nodes,
      custom: custom,
      customPos: this.etPos === 1 ? 'bottom' : 'top'
    };
    return payload;
  }

  currentEtConfig(): EdgeTunnelConfig {
    const cfg: EdgeTunnelConfig = defaultEdgeTunnelConfig();
    cfg.enabled = this.etEnabled;
    cfg.host = this.etHost;
    cfg.password = this.etPassword;
    cfg.mode = this.etMode === 1 ? 'append' : 'overwrite';
    cfg.customHead = this.etCustom;
    cfg.customPos = this.etPos === 1 ? 'bottom' : 'top';
    cfg.proxyType = this.etProxyOn ? 'http' : 'none';
    cfg.proxyHost = this.etProxyHost;
    const pt: number = parseInt(this.etProxyPort, 10);
    cfg.proxyPort = isNaN(pt) ? 7890 : pt;
    cfg.proxyUser = this.etProxyUser;
    cfg.proxyPass = this.etProxyPass;
    cfg.uploadWay = this.etWay === 1 ? 'api' : 'login';
    cfg.cfAccountId = this.etCfAccount;
    cfg.cfNamespaceId = this.etCfNamespace;
    cfg.cfApiToken = this.etCfToken;
    cfg.topN = this.etTopN;
    return cfg;
  }

  /** 改动即落盘，下次启动不用重填 */
  saveEtConfig(): void {
    ConfigStore.saveEdgeTunnel(this.currentEtConfig()).catch((e: BusinessError) => {
      this.addLog(this.t('保存订阅上传配置失败：', 'Failed to save subscription upload settings: ') + e.message);
    });
  }

  initEtConfig(): void {
    const cfg: EdgeTunnelConfig = ConfigStore.edgeTunnel();
    this.etEnabled = cfg.enabled;
    this.etHost = cfg.host;
    this.etPassword = cfg.password;
    this.etMode = cfg.mode === 'append' ? 1 : 0;
    this.etCustom = cfg.customHead;
    this.etPos = cfg.customPos === 'bottom' ? 1 : 0;
    this.etProxyOn = cfg.proxyType === 'http';
    this.etProxyHost = cfg.proxyHost;
    this.etProxyPort = cfg.proxyPort.toString();
    this.etProxyUser = cfg.proxyUser;
    this.etProxyPass = cfg.proxyPass;
    this.etWay = cfg.uploadWay === 'api' ? 1 : 0;
    this.etCfAccount = cfg.cfAccountId;
    this.etCfNamespace = cfg.cfNamespaceId;
    this.etCfToken = cfg.cfApiToken;
    this.etTopN = cfg.topN;
    this.etTopNText = cfg.topN.toString();
  }

  /**
   * 上传到 edgetunnel 订阅。
   * 真正登录 / 读取 / 追加 / 写入都由 EdgeTunnel.upload 完成，这里只负责：
   * 收集本次节点与自定义行、做为空校验、把阶段文案和最终结果展示到 UI 与日志。
   * @param auto true=扫描完成后自动触发（配置不完整时只记日志，不弹 toast 打扰）
   */
  /** 上传参数是否齐全（按上传方式判断），自动上传与「立即上传」共用 */
  etReady(): boolean {
    if (this.etWay === 1) {
      return this.etCfAccount.trim().length > 0 && this.etCfNamespace.trim().length > 0
        && this.etCfToken.trim().length > 0;
    }
    return this.etHost.trim().length > 0 && this.etPassword.length > 0;
  }

  uploadEdgeTunnel(auto: boolean): void {
    if (this.etBusy) {
      return;
    }
    const cfg: EdgeTunnelConfig = this.currentEtConfig();
    if (cfg.uploadWay === 'api') {
      if (cfg.cfAccountId.trim().length === 0) {
        if (!auto) {
          this.toast(this.t('请先填 Cloudflare Account ID', 'Enter the Cloudflare Account ID first'));
        }
        return;
      }
      if (cfg.cfNamespaceId.trim().length === 0) {
        if (!auto) {
          this.toast(this.t('请先填 KV 命名空间 ID', 'Enter the KV namespace ID first'));
        }
        return;
      }
      if (cfg.cfApiToken.trim().length === 0) {
        if (!auto) {
          this.toast(this.t('请先填 API Token', 'Enter the API Token first'));
        }
        return;
      }
    } else {
      if (cfg.host.trim().length === 0) {
        if (!auto) {
          this.toast(this.t('请先填 edgetunnel 域名', 'Enter the edgetunnel domain first'));
        }
        return;
      }
      if (cfg.password.length === 0) {
        if (!auto) {
          this.toast(this.t('请先填 edgetunnel 密码', 'Enter the edgetunnel password first'));
        }
        return;
      }
    }
    const payload: UploadPayload = this.buildUploadPayload();
    if (payload.nodes.length === 0 && payload.custom.length === 0) {
      if (!auto) {
        this.toast(this.t('没有可上传的节点，请先完成测速', 'No nodes to upload. Run a speed test first.'));
      }
      return;
    }
    this.etBusy = true;
    AppBackground.hold('upload');
    this.etStatus = this.t('准备上传…', 'Preparing upload…');
    const how: string = auto ? this.t('自动', 'Auto') : this.t('手动', 'Manual');
    const modeText: string = cfg.mode === 'append' ? this.t('追加', 'Append') : this.t('覆盖', 'Overwrite');
    const posText: string = cfg.customPos === 'bottom' ? this.t('最后', 'Bottom') : this.t('最前', 'Top');
    const wayText: string = cfg.uploadWay === 'api' ? this.t('API 直传', 'API direct upload') : this.t('登录上传', 'Login upload');
    this.addLog('edgetunnel ' + how + this.t('上传开始（', 'Upload started (') + wayText + this.t('）：节点 ', '): nodes: ') + payload.nodes.length.toString()
      + this.t(' 个，自定义 ', ', custom ') + payload.custom.length.toString() + this.t(' 行，模式 ', ' lines, mode ') + modeText + this.t('，自定义位置 ', ', custom position ') + posText);
    this.toast(this.t('订阅', 'Subscription') + how + this.t('上传中…', 'Uploading…'));
    EdgeTunnel.upload(cfg, payload, (msg: string) => {
      this.etStatus = msg;
    }).then((res: UploadResult) => {
      this.etBusy = false;
      AppBackground.release('upload');
      this.etStatus = this.t('上传成功（', 'Upload succeeded (') + res.totalLines.toString() + this.t(' 行）', ' lines)');
      const costText: string = res.way === 'api'
        ? (this.t('读取 ', 'Read ') + res.readMs.toString() + this.t('ms，写入 ', 'ms, write ') + res.writeMs.toString() + 'ms')
        : (this.t('登录 ', 'Login ') + res.loginMs.toString() + 'ms'
          + (res.mode === 'append' ? this.t('，读取 ', ', read ') + res.readMs.toString() + 'ms' : '')
          + this.t('，写入 ', ', write ') + res.writeMs.toString() + 'ms');
      this.addLog(this.t('edgetunnel 订阅上传成功（', 'edgetunnel subscription upload succeeded (') + (res.way === 'api' ? this.t('API 直传', 'API direct upload') : this.t('登录上传', 'Login upload')) + this.t('）：模式 ', '): mode ')
        + (res.mode === 'append' ? this.t('追加', 'Append') : this.t('覆盖', 'Overwrite')) + this.t('，节点 ', ', nodes: ') + res.nodeCount.toString() + this.t(' 个，共 ', ', ')
        + res.totalLines.toString() + this.t(' 行 / ', ' lines / ') + res.bytes.toString() + this.t(' 字节，耗时 ', ' bytes, took ') + costText);
      // 自动上传也弹 toast：用户这时多半停在测速页，看不到设置页的状态行
      this.toast(this.t('订阅上传成功，共 ', 'Subscription upload succeeded: ') + res.totalLines.toString() + this.t(' 行', ' lines'));
    }).catch((e: BusinessError) => {
      this.etBusy = false;
      AppBackground.release('upload');
      const msg: string = this.etErrText(e);
      this.etStatus = this.t('上传失败：', 'Upload failed: ') + msg;
      this.addLog(this.t('edgetunnel 上传失败：', 'edgetunnel upload failed: ') + msg);
      this.toast(this.t('订阅上传失败：', 'Subscription upload failed: ') + msg);
    });
  }
  /** 把网络层错误码翻译成中文提示；EdgeTunnel 自己抛的中文错误已带阶段，直接展示 */
  etErrText(e: BusinessError): string {
    const raw: string = e.message === undefined ? '' : e.message;
    const code: number = e.code === undefined ? 0 : e.code;
    if (code === 2300005) {
      return this.t('代理服务器域名解析失败，请检查「上传代理」地址', 'Failed to resolve the proxy domain; check the "Upload proxy" address');
    }
    if (code === 2300006) {
      return this.t('无法解析 edgetunnel 域名，请检查域名拼写', 'Cannot resolve the edgetunnel domain; check the spelling');
    }
    if (code === 2300007) {
      return this.t('无法连接 edgetunnel 服务器，请检查网络或改用「上传代理」', 'Cannot connect to the edgetunnel server; check your network or use the "Upload proxy"');
    }
    if (code === 2300028) {
      return this.t('请求超时，请检查网络后重试', 'Request timed out. Check your network and try again.');
    }
    if (code === 2300047) {
      return this.t('重定向次数超过上限，请确认「域名」只填站点根地址', 'Too many redirects; make sure "Domain" contains only the site root address');
    }
    if (code === 2300094) {
      return this.t('TLS 认证失败，请检查域名或上传代理', 'TLS authentication failed; check the domain or upload proxy');
    }
    if (code === 2300997) {
      return this.t('系统禁止明文 HTTP，请使用 https 地址', 'The system blocks plain HTTP; use an https address');
    }
    if (code === 2300999) {
      return this.t('网络内部错误：', 'Internal network error: ') + raw;
    }
    if (raw.length > 0) {
      return raw;
    }
    return this.t('未知错误（错误码 ', 'Unknown error (code ') + code.toString() + '）';
  }
  splitResults(list: Candidate[]): void {
    const ping: Candidate[] = [];
    const speed: Candidate[] = [];
    for (let i = 0; i < list.length; i++) {
      const c: Candidate = list[i];
      if ((c.verdict === Verdict.PASS || c.verdict === Verdict.SPEEDED) && c.colo.length > 0) {
        ping.push(c);
      }
      if (c.stage === Stage.SPEED) {
        // 合格速度：低于门槛的测速结果直接剔除（失败的仍保留以说明原因）
        if (c.verdict === Verdict.SPEEDED && c.speedMbps < this.minSpeedValue()) {
          // 淘汰，不进入结果列表
        } else {
          speed.push(c);
        }
      }
    }
    ping.sort((a: Candidate, b: Candidate) => Ranker.delayOf(a) - Ranker.delayOf(b));
    speed.sort((a: Candidate, b: Candidate) => {
      const sa: number = a.verdict === Verdict.SPEEDED ? a.speedMbps : -1;
      const sb: number = b.verdict === Verdict.SPEEDED ? b.speedMbps : -1;
      if (sb !== sa) {
        return sb - sa;
      }
      return Ranker.delayOf(a) - Ranker.delayOf(b);
    });
    this.pingList = ping;
    this.speedList = speed;
    this.speedStates = [];
    this.buildGroups(ping);
    let regionLog: string = this.t('第一轮地区分布：', 'Round 1 region distribution: ');
    const colos: string[] = [];
    const counts: number[] = [];
    for (let i = 0; i < ping.length; i++) {
      const co: string = ping[i].colo;
      const idx: number = colos.indexOf(co);
      if (idx < 0) {
        colos.push(co);
        counts.push(1);
      } else {
        counts[idx] = counts[idx] + 1;
      }
    }
    for (let i = 0; i < colos.length; i++) {
      regionLog += (i > 0 ? '、' : '') + colos[i] + ' ' + counts[i].toString() + this.t(' 个', ' nodes');
    }
    this.addLog(regionLog);
  }

  buildGroups(list: Candidate[]): void {
    const colos: string[] = [];
    const groups: RegionGroup[] = [];
    const sums: number[] = [];
    for (let i = 0; i < list.length; i++) {
      const c: Candidate = list[i];
      // 没有 colo 的节点在第一阶段就被淘汰了，这里再兜一道，不让它进分组
      if (c.colo.length === 0) {
        continue;
      }
      const co: string = c.colo;
      let idx: number = colos.indexOf(co);
      if (idx < 0) {
        colos.push(co);
        const g: RegionGroup = {
          colo: co,
          city: co === 'UNK' ? '' : Geo.cityZh(co),
          count: 0,
          minLatency: -1,
          avgLatency: -1,
          items: []
        };
        groups.push(g);
        sums.push(0);
        idx = groups.length - 1;
      }
      const g: RegionGroup = groups[idx];
      g.count = g.count + 1;
      g.items.push(c);
      const d: number = Ranker.delayOf(c);
      if (d > 0) {
        sums[idx] = sums[idx] + d;
        if (g.minLatency < 0 || d < g.minLatency) {
          g.minLatency = d;
        }
      }
    }
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].minLatency > 0) {
        groups[i].avgLatency = sums[i] / groups[i].count;
      }
    }
    groups.sort((a: RegionGroup, b: RegionGroup) => {
      if (a.minLatency < 0) {
        return 1;
      }
      if (b.minLatency < 0) {
        return -1;
      }
      return a.minLatency - b.minLatency;
    });
    this.groups = groups;
  }

  toggleGroup(colo: string): void {
    const arr: string[] = this.expandedColos.slice();
    const idx: number = arr.indexOf(colo);
    if (idx >= 0) {
      arr.splice(idx, 1);
    } else {
      arr.push(colo);
    }
    this.expandedColos = arr;
  }

  copyIp(ip: string): void {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, ip);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast(this.t('已复制 ', 'Copied ') + ip);
    }).catch((err: BusinessError) => {
      this.toast(this.t('复制失败：', 'Copy failed: ') + err.message);
    });
  }

  /** 从文件导入自定义 IP 列表 */
  importIpFile(): void {
    if (this.ctx === undefined || this.ctx === null) {
      return;
    }
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    const dp = new picker.DocumentViewPicker(this.ctx);
    dp.select(opts).then((uris: string[]) => {
      if (uris === undefined || uris === null || uris.length === 0) {
        return;
      }
      try {
        const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(f.fd);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(f.fd, buf);
        fileIo.closeSync(f);
        const decoder = util.TextDecoder.create('utf-8');
        const text: string = decoder.decodeToString(new Uint8Array(buf));
        const merged: string = this.customText.length > 0 ? (this.customText + '\n' + text) : text;
        this.customText = merged;
        this.mode = ScanMode.CUSTOM;
        let lines: number = 0;
        const parts: string[] = text.split('\n');
        for (let i = 0; i < parts.length; i++) {
          if (parts[i].trim().length > 0) {
            lines++;
          }
        }
        this.toast(this.t('已导入 ', 'Imported ') + lines.toString() + this.t(' 行', ' lines'));
        this.addLog(this.t('从文件导入 ', 'Imported from file: ') + lines.toString() + this.t(' 行候选地址', ' candidate addresses'));
      } catch (err) {
        const e2: BusinessError = err as BusinessError;
        this.toast(this.t('读取失败：', 'Read failed: ') + e2.message);
      }
    }).catch((err: BusinessError) => {
      this.toast(this.t('选择文件失败：', 'Failed to select file: ') + err.message);
    });
  }
  sourceBrief(): string {
    if (this.srcIdx === 0) {
      return this.t('内置官方段库', 'Built-in official ranges');
    }
    if (this.srcIdx === 3) {
      const n: number = this.customText.split('\n').filter((l: string) => l.trim().length > 0).length;
      return n > 0 ? (this.t('自定义：', 'Custom: ') + n.toString() + this.t(' 行', ' lines')) : this.t('自定义：未添加来源', 'Custom: no sources added');
    }
    const n2: number = this.customText.split('\n').filter((l: string) => l.trim().length > 0).length;
    return (this.srcIdx === 1 ? this.t('社区 IPv6 段库', 'Community IPv6 ranges') : this.t('社区 IPv4 段库', 'Community IPv4 ranges')) + (n2 > 0 ? ('：' + n2.toString() + this.t(' 行', ' lines')) : '');
  }

  /** 从链接导入自定义 IP 列表（优选库） */
  applySource(idx: number): void {
    this.srcIdx = idx;
    if (idx === 0) {
      this.mode = ScanMode.OFFICIAL;
      this.scheduleScanSave();
      return;
    }
    this.mode = ScanMode.CUSTOM;
    if (idx === 1) {
      this.ipVersion = IpVersion.V6;
      this.importUrl = LIB_SOURCES[2].url;
      if (this.customText.trim().length === 0) {
        this.importIpUrl();
      }
    } else if (idx === 2) {
      this.ipVersion = IpVersion.V4;
      this.importUrl = LIB_SOURCES[3].url;
      if (this.customText.trim().length === 0) {
        this.importIpUrl();
      }
    } else if (idx === 3) {
      this.ipVersion = this.ipVersion;
      if (this.customText.trim().length === 0) {
        this.toast(this.t('自定义为空，请添加来源', 'Custom source is empty; add a source'));
        this.importDlg.open();
      }
    }
    this.scheduleScanSave();
  }

  importIpUrl(): void {
    const url: string = this.importUrl.trim();
    if (url.length === 0) {
      this.toast(this.t('请先填写链接', 'Enter a link first'));
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.toast(this.t('链接需以 http(s):// 开头', 'The link must start with http(s)://'));
      return;
    }
    this.toast(this.t('正在拉取优选库…', 'Fetching the selection library…'));
    const req = http.createHttp();
    req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      readTimeout: 20000,
      usingCache: false
    }).then((resp: http.HttpResponse) => {
      req.destroy();
      if (resp.responseCode !== 200) {
        this.toast(this.t('拉取失败：HTTP ', 'Fetch failed: HTTP ') + resp.responseCode.toString());
        return;
      }
      const text: string = typeof resp.result === 'string' ? resp.result as string : '';
      if (text.length === 0) {
        this.toast(this.t('链接内容为空', 'The link returned no content'));
        return;
      }
      const lines: string[] = text.split('\n');
      let valid: number = 0;
      const add: string[] = [];
      for (let i = 0; i < lines.length; i++) {
        let ln: string = lines[i].trim();
        if (ln.length === 0 || ln.startsWith('#') || ln.startsWith('//')) {
          continue;
        }
        const sp: number = ln.indexOf(' ');
        if (sp > 0) {
          ln = ln.substring(0, sp);
        }
        add.push(ln);
        valid++;
      }
      const merged: string = this.customText.length > 0 ? (this.customText + '\n' + add.join('\n')) : add.join('\n');
      this.customText = merged;
      this.mode = ScanMode.CUSTOM;
      this.scheduleScanSave();
      this.toast(this.t('已从链接导入 ', 'Imported ') + valid.toString() + this.t(' 行', ' lines'));
      this.addLog(this.t('从链接导入 ', 'Imported ') + valid.toString() + this.t(' 行优选地址：', ' preferred addresses from link: ') + url);
    }).catch((err: BusinessError) => {
      try { req.destroy(); } catch (e) { }
      this.toast(this.t('拉取失败：', 'Fetch failed: ') + err.message);
    });
  }

  /** 测速是否还没出结果（0=待测 / 1=测速中） */
  isSpeedPending(index: number): boolean {
    if (index < 0 || index >= this.speedStates.length) {
      return false;
    }
    return this.speedStates[index] === 0 || this.speedStates[index] === 1;
  }

  /**
   * 测速页单行：先把全部待测节点铺出来（灰「待测」），
   * 轮到它时变「测速中…」（主色），测完换成速度结果（绿/红）。
   */
  @Builder SpeedRow(c: Candidate, index: number) {
    Column() {
      Row() {
        Text(Exporter.endpoint(c, true))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txt())
          .maxLines(1)
        Blank()
        if (this.isSpeedPending(index)) {
          Text(index < this.speedStates.length && this.speedStates[index] === 1 ? this.t('测速中…', 'Testing…') : this.t('待测', 'Pending'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(index < this.speedStates.length && this.speedStates[index] === 1 ? this.accent() : this.txt3())
        } else {
          Text(Ranker.info(c).text)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Ranker.info(c).color)
        }
      }
      .width('100%')

      Row() {
        Text(this.coloText(c))
          .fontSize(11)
          .fontColor(this.txt3())
          .maxLines(1)
        Blank()
        Text(this.isSpeedPending(index) ? '' : this.delayText(c))
          .fontSize(11)
          .fontColor(Ranker.delayOf(c) >= 0 ? OK_C : this.txt3())
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    // 与全站卡片同源：材质 / 背景模糊 / tint 渐变 / 描边全部复用同一套取色
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTintOr(false) })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 10 })
    .onClick(() => {
      this.copyIp(c.ip);
    })
  }

  @Builder ResultRow(c: Candidate) {
    Column() {
      Row() {
        Text(Exporter.endpoint(c, true))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txt())
          .maxLines(1)
        Blank()
        Text(this.delayText(c))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Ranker.delayOf(c) >= 0 ? OK_C : this.txt3())
      }
      .width('100%')

      Row() {
        Text(this.coloText(c))
          .fontSize(11)
          .fontColor(this.txt3())
          .maxLines(1)
        Blank()
        Text(Ranker.info(c).text)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(Ranker.info(c).color)
      }
      .width('100%')
      .margin({ top: 4 })

      if (Ranker.detail(c).length > 0) {
        Text(Ranker.detail(c))
          .fontSize(10)
          .fontColor(this.txt3())
          .width('100%')
          .margin({ top: 3 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    // 与全站卡片同源：材质 / 背景模糊 / tint 渐变 / 描边全部复用同一套取色
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTintOr(false) })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 10 })
    .onClick(() => {
      this.copyIp(c.ip);
    })
  }

  /** 对当前结果前 5 条手动补测速（可选操作） */
  runSpeedTop(): void {
    if (this.results.length === 0 || this.testing) {
      return;
    }
    const list: Candidate[] = this.results.slice(0, 5);
    if (list.length === 0) {
      return;
    }
    this.testing = true;
    this.testInfo = this.t('测速中 0/', 'Testing 0/') + list.length.toString();
    const c: ScanConfig = this.buildConfig();
    const token: CancellationToken = new CancellationToken();
    Scanner.stageSpeed(c, list, new ScanHooks(), token).then(() => {
      Ranker.apply(this.results, c);
      this.results = this.results.slice();
      this.testing = false;
      this.testInfo = '';
      this.toast(this.t('补测速完成', 'Re-test complete'));
    }).catch((e: BusinessError) => {
      this.testing = false;
      this.testInfo = '';
      this.toast(this.t('补测速失败：', 'Re-test failed: ') + e.message);
    });
  }
}


/** ===== 滚动边缘渐变模糊（linearGradientBlur）参数 ===== */
/** 顶部模糊带高度（vp）：沿用改造前顶部条带覆盖到标题区的 118vp */
const LG_TOP_BAND: number = 118;
/** 底部模糊带高度（vp）：沿用改造前底部条带覆盖到导航区的 106.7vp */
const LG_BOTTOM_BAND: number = 106.7;
/** 最大模糊半径（vp）：与原顶部条带峰值 22vp 对齐，保证观感不突增 */
const LG_BLUR_MAX: number = 22;
/** 底部峰值折算比例：原底部条带峰值 16vp / 顶部 22vp，使一次调用同时还原两端强度 */
const LG_BOTTOM_RATIO: number = 16 / 22;

