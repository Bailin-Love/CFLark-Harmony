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
import {
  ConfigStore,
  ThemeMode,
  UiConfig,
  defaultUiConfig,
  defaultScanConfig,
  PORT_OPTIONS,
  LIB_SOURCES,
  LibSource,
  maxScanConcurrency,
  defaultScanConcurrency,
  REC_LATENCY_MS,
  REC_MIN_SPEED_MBPS,
  REC_PING_TIMES,
  REC_SAMPLE_COUNT,
  REC_SPEED_COUNT,
  REC_SPEED_PER_REGION,
  REC_SPEED_ROUNDS,
  REC_SPEED_WINDOW_MS
} from '../core/ConfigStore';
import { I18n, LangMode } from '../core/I18n';
import { UpdateChecker, UpdateStatus, UpdateCheckResult, ReleaseInfo } from '../core/UpdateChecker';
import { Changelog, ChangelogEntry, ChangeItem, ChangeKind } from '../core/Changelog';
import { AppMeta } from '../core/AppMeta';
import { AppBackground } from '../core/AppBackground';
import { Scanner, ScanHooks, CancellationToken, PrecheckResult } from '../core/Scanner';
import {
  Sources, SourceGroup, SourceItem, SourceChoice, GroupStats, CompileResult, ImportOutcome,
  AddSourceResult, OpResult, LineClass, QuarantineItem, SourceReject,
  SRC_FAM_V4, SRC_FAM_V6, SRC_ID_OFFICIAL, SRC_ID_COMMUNITY,
  SRC_KIND_LINK, SRC_KIND_FILE, SRC_KIND_TEXT, SRC_STATUS_OK, SRC_STATUS_PARTIAL, SRC_STATUS_FAILED
} from '../core/Sources';
import { HelpText, HELP_FILTER, HELP_SOURCE, HELP_SPEED, HELP_UPLOAD, HELP_MATERIAL, HELP_DIAG, HELP_RUNTIME } from '../core/HelpText';
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
import { hilog } from '@kit.PerformanceAnalysisKit';

interface RegionGroup {
  colo: string;
  city: string;
  count: number;
  minLatency: number;
  avgLatency: number;
  items: Candidate[];
}

/** 手机设置二级页的一层浏览记录：分类 id + 离开该层时的滚动位置 */
interface SettingsFrame {
  id: number;
  scrollY: number;
}

const OK_C: string = '#10B981';
const WARN_C: string = '#F59E0B';
const BAD_C: string = '#F43F5E';
const PRIMARY: string = '#4F46E5';
// 内置预设背景素材版本：换图后 +1，旧的沙箱缓存会自动重拷，避免用户仍看到旧图
const PRESET_CACHE_VER: number = 2;

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

interface ProgressInfo {
  pct: number;
  stage: string;
  counter: string;
  running: boolean;
  finished: boolean;
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
  /** 背景图遮罩程度 0~100（0 = 完全通透看得见图，100 = 最实）；用户自选，默认偏薄 */
  @State bgScrimPct: number = 55;
  /** 卡片通透度：0=更实，50=默认，100=最透 */
  @State cardClearPct: number = 50;
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
  // 当前任务类型：0=空闲 1=第一轮扫描 2=质量预检 3=正式测速
  // 三页进度条与「停止」按钮按它区分归属，避免扫描页显示测速进度、停止误杀别的阶段
  @State taskKind: number = 0;
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
  // ===== 候选来源分组管理 =====
  // V4 / V6 的选择、分组、来源分别在 Sources 里独立保存（selV4/selV6、按 family 分组），
  // 这里所有界面都只读当前 IP 族的数据，切换 V4/V6 = 换一整套来源。
  /** 来源模型版本号：Sources 变更后 +1，用来强制刷新依赖它的只读数据 */
  @State srcRev: number = 0;
  /** 分组管理页是否打开 */
  @State srcMgr: boolean = false;
  /** 0=分组列表 1=分组详情 2=添加链接 3=粘贴文本 4=编辑来源内容 */
  @State srcMgrView: number = 0;
  /** 当前管理的分组 id（仅自定义分组） */
  @State srcMgrGid: string = '';
  @State srcMgrBusy: boolean = false;
  /** 管理页内的结果提示（成功/拒绝数量、错误原因） */
  @State srcMgrMsg: string = '';
  @State srcNewName: string = '';
  @State srcNameDraft: string = '';
  @State srcRename: boolean = false;
  @State srcLinkDraft: string = '';
  @State srcPasteDraft: string = '';
  /** 删除分组的内联二次确认 */
  @State srcConfirmGroup: boolean = false;
  /** 待删除来源 id（'' = 没有待确认的删除） */
  @State srcConfirmSrc: string = '';
  @State srcShowQuarantine: boolean = false;
  /** 正在编辑内容的来源 id（'' = 未进入编辑） */
  @State srcEditSid: string = '';
  /** 来源内容编辑草稿（按行；保存时按当前 IP 版本重新校验） */
  @State srcEditDraft: string = '';
  @State sampleText: string = '2000';
  @State cfgRev: number = 0;
  /** 扫描页「高级选项」是否展开（默认收起，压缩页面长度） */
  @State advParamOpen: boolean = false;
  /** 当前打开的功能说明：空字符串表示关闭（title/正文统一由 HelpText 提供） */
  @State helpKey: string = '';
  /** 冷启动时的应用内启动页：用应用主题渲染，覆盖系统启动窗口与首帧之间的空档 */
  /** 更新日志中当前展开的版本号，空串表示全部折叠 */
  @State changelogOpen: string = '';
  /** 测速页「高级选项」是否展开 */
  @State advUploadOpen: boolean = false;
  @State bgAdvancedOpen: boolean = false;
  @State concurrencyText: string = defaultScanConcurrency().toString();
  @State latencyText: string = REC_LATENCY_MS.toString();
  /** 延迟上限建议提示（随 IPv4/IPv6 变化） */
  @State latencyHint: string = '';
  /** 当前实际生效的背景图（渲染用：跟随实际深浅色自动取 bgLight / bgDark） */
  @State bgPath: string = '';
  @State customPathLight: string = '';
  @State customPathDark: string = '';
  /** 本次运行内背景图加载失败（只临时回落渐变，不改用户配置） */
  @State bgLoadFailed: boolean = false;
  /** 浅色模式背景图（空串=该模式使用默认背景） */
  @State bgLight: string = '';
  /** 深色模式背景图（空串=该模式使用默认背景） */
  @State bgDark: string = '';
  /** 背景图编辑目标：false=正在设置浅色背景，true=正在设置深色背景 */
  /** 系统深浅色变化计数（EntryAbility 在「跟随系统」时递增） */
  @StorageLink('sysThemeTick') @Watch('onSysThemeTick') sysThemeTick: number = 0;
  /** 系统深浅色（EntryAbility 里 Environment.envProp 订阅，跟随系统时用它重算） */
  @StorageProp('colorMode') @Watch('onSysColorMode') colorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  /** 底部胶囊拖动时的指尖 x（-1 表示未触摸） */
  @State pingText: string = REC_PING_TIMES.toString();
  @State speedCountText: string = REC_SPEED_COUNT.toString();
  @State speedRoundsText: string = REC_SPEED_ROUNDS.toString();
  @State speedWindowText: string = REC_SPEED_WINDOW_MS.toString();
  /** 合格速度（MB/s），低于该值的测速结果会被淘汰，默认 0.1 */
  @State minSpeedText: string = REC_MIN_SPEED_MBPS.toString();
  @State enableSpeed: boolean = true;
  @State speedScope: number = SpeedScope.ALL;
  @State speedPerRegionText: string = REC_SPEED_PER_REGION.toString();
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
  /** 平板/电脑右侧默认展示「订阅与上传」（2），手机默认不展开任何分类 */
  @State settingsPane: number = 2;
  private settingsScrollCache: number = 0;
  /** 手机设置二级页的浏览历史（首页不压栈），用于系统返回与返回按钮逐级回退 */
  private settingsStack: SettingsFrame[] = [];
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
    // 背景图同样用进程启动时的预读值，首帧就是用户上次选的那张，不会先画渐变再跳图
    const gl: string | undefined = AppStorage.get<string>('initialBgLight');
    const gd: string | undefined = AppStorage.get<string>('initialBgDark');
    this.bgLight = gl !== undefined ? gl : '';
    this.bgDark = gd !== undefined ? gd : '';
    this.applyEffectiveBg();
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
    // 退出前把还压在防抖队列里的参数落盘，避免「改完立刻退出」丢掉最后一次输入
    if (this.scanSaveTimer >= 0) {
      clearTimeout(this.scanSaveTimer);
      this.scanSaveTimer = -1;
      ConfigStore.save(this.buildConfig()).then(() => {
        return;
      }).catch(() => {
      });
    }
    this.clearScanTimers();
    this.stopHeartbeat();
    this.token.cancel();
  }
  /** 系统当前是否深色 */
  private systemDark(): boolean {
    // 能力侧（EntryAbility.onCreate / onForeground / onConfigurationUpdate）会刷新这个值，
    // 它比页面自己的缓存更早拿到系统变更，因此优先用它。
    const sd: boolean | undefined = AppStorage.get<boolean>('sysDark');
    if (sd !== undefined) {
      return sd;
    }
    const cm: number | undefined = AppStorage.get<number>('colorMode');
    if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      return true;
    }
    if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      return false;
    }
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
    // 主题变了就切换到同一模式的背景图（浅色图/深色图互不覆盖）
    this.applyEffectiveBg();
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
    // 下载测速开关已移除：始终开启（旧配置里被关闭的也一律恢复）
    this.enableSpeed = true;
    this.speedScope = c.speedScope;
    this.speedPerRegionText = c.speedPerRegion.toString();
    this.domain = c.domain;
    this.domainSampling = c.domainSampling;
    this.keepAlive = ConfigStore.keepAlive();
    AppBackground.enabled = this.keepAlive;
    this.regionCode = c.regionCode;
    this.latencyHint = this.t('建议：延迟上限建议 260~320ms（默认 300ms；两次 ping 下 220ms 偏低，容易误杀可用节点）', 'Tip: a latency cap of 260–320 ms is recommended (default 300 ms; 220 ms with two pings is too low and may discard usable nodes).');
    // v1→v2：旧版单一背景图复制进浅色/深色两套（同步完成，避免读到半迁移状态）
    ConfigStore.migrateBgPathsSync();
    this.refreshCustomPaths();
    this.migratePresetCache();
    this.bgLight = ConfigStore.bgPathFor(false);
    this.bgDark = ConfigStore.bgPathFor(true);
    this.applyEffectiveBg();
    // 来源分组模型：读取（首次启动时迁移旧版 scan_custom），迁移提示与当前选中项异常都进日志。
    // 注意这里是异步的：Sources 未就绪前页面不生成候选文本，startScan 里还会按当前族重编译一次兜底。
    Sources.load(c).then((note: string) => {
      this.srcRev++;
      const err: string = this.applySelection(false);
      if (note.length > 0) {
        this.addLog(note);
        this.toast(note);
      }
      if (err.length > 0) {
        this.addLog(this.t('候选来源：', 'Candidate source: ') + err);
      }
    }).catch((e: BusinessError) => {
      this.addLog(this.t('读取候选来源失败：', 'Failed to load sources: ') + e.message);
    });
  }

  /** 当前生效的背景图：跟随实际深浅色取对应那一套 */
  private applyEffectiveBg(): void {
    this.bgPath = this.dark ? this.bgDark : this.bgLight;
    this.bgLoadFailed = false;
  }

  /** 指定模式的背景图路径（空串 = 该模式默认渐变背景） */
  private bgFor(dark: boolean): string {
    return dark ? this.bgDark : this.bgLight;
  }

  /** 写入某一模式的背景图并持久化；另一套保持不变 */
  private async setModeBg(dark: boolean, path: string): Promise<void> {
    if (dark) {
      this.bgDark = path;
    } else {
      this.bgLight = path;
    }
    this.applyEffectiveBg();
    await ConfigStore.saveBgPathFor(dark, path);
  }

  /** 当前模式最新的自定义图片路径（文件名带时间戳，换图后路径必变，避免命中图片缓存） */
  private customPathFor(dark: boolean): string {
    return dark ? this.customPathDark : this.customPathLight;
  }

  /** 扫描 filesDir，找出浅色/深色各自最新的一张自定义背景 */
  private refreshCustomPaths(): void {
    const ctx = this.ctx;
    if (ctx === undefined) {
      return;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(ctx.filesDir);
    } catch (e) {
      names = [];
    }
    let bestLight: string = '';
    let lightTs: number = -1;
    let bestDark: string = '';
    let darkTs: number = -1;
    for (let i = 0; i < names.length; i++) {
      const n: string = names[i];
      const isLight: boolean = n.indexOf('bg_custom_light') === 0;
      const isDark: boolean = n.indexOf('bg_custom_dark') === 0;
      if (!isLight && !isDark) {
        continue;
      }
      const ts: number = this.timestampOfName(n);
      if (isLight) {
        if (ts > lightTs) {
          lightTs = ts;
          bestLight = ctx.filesDir + '/' + n;
        }
      } else if (ts > darkTs) {
        darkTs = ts;
        bestDark = ctx.filesDir + '/' + n;
      }
    }
    this.customPathLight = bestLight;
    this.customPathDark = bestDark;
  }

  private timestampOfName(name: string): number {
    const base: string = name.indexOf('.jpg') >= 0 ? name.substring(0, name.indexOf('.jpg')) : name;
    const cut: number = base.lastIndexOf('_');
    if (cut < 0) {
      return 0;
    }
    const v: number = Number(base.substring(cut + 1));
    return isNaN(v) ? 0 : v;
  }

  /** 当前模式是否已经有自定义图片（文件真的存在才算） */
  private hasCustomImage(): boolean {
    if (this.ctx === undefined) {
      return false;
    }
    const p: string = this.customPathFor(this.dark);
    if (p.length === 0) {
      return false;
    }
    try {
      // accessSync 直接返回 boolean（文件不存在不抛异常）
      return fileIo.accessSync(p);
    } catch (e) {
      return false;
    }
  }

  /** 当前背景是否就是当前模式的自定义图片（自定义格子选中态） */
  private isCustomSelected(): boolean {
    return this.bgPath.length > 0 && this.bgPath === this.customPathFor(this.dark);
  }

  /** 系统深浅色变化（AppStorage sysThemeTick，仅「跟随系统」时生效） */
  private onSysThemeTick(): void {
    if (this.themeMode !== ThemeMode.SYSTEM) {
      return;
    }
    this.applyThemeMode();
  }

  /** 系统深浅色变化（AppStorage colorMode，Environment.envProp 订阅） */
  private onSysColorMode(): void {
    if (this.themeMode !== ThemeMode.SYSTEM) {
      return;
    }
    this.applyThemeMode();
  }

  /**
   * 从图库选一张图片：它成为**当前模式**的专属背景（另一个模式不受影响）。
   * 用户取消选择或读取失败时不改动已有背景。
   */
  private async pickBackground(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === undefined) {
      this.toast(this.t('应用上下文未就绪', 'App context not ready'));
      return;
    }
    const dark: boolean = this.dark;
    try {
      const ph: picker.PhotoViewPicker = new picker.PhotoViewPicker();
      const opt: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
      opt.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 1;
      const res: picker.PhotoSelectResult = await ph.select(opt);
      if (res.photoUris.length === 0) {
        return;
      }
      const dir: string = ctx.filesDir;
      const oldPath: string = this.customPathFor(dark);
      const stamp: string = new Date().getTime().toString();
      const dst: string = dir + (dark ? '/bg_custom_dark_' : '/bg_custom_light_') + stamp + '.jpg';
      const f = fileIo.openSync(res.photoUris[0], fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(f.fd, dst);
      fileIo.closeSync(f);
      this.refreshCustomPaths();
      await this.setModeBg(dark, dst);
      // 换图成功后清掉同一模式的旧文件，避免沙箱里越堆越多
      if (oldPath.length > 0 && oldPath !== dst) {
        try {
          fileIo.unlinkSync(oldPath);
        } catch (e) {
          // 旧文件已被删除/占用时忽略
        }
      }
      this.refreshCustomPaths();
      const which: string = dark ? this.t('深色', 'dark') : this.t('浅色', 'light');
      this.addLog(which + this.t('模式已设置自定义背景图', ' mode custom background set'));
      this.toast(which + this.t('模式背景已更新', ' background updated'));
    } catch (e) {
      const err = e as BusinessError;
      this.toast(this.t('选择背景失败：', 'Failed to select background: ') + err.message);
    }
  }

  /** 「无」格子：清掉**当前模式**的背景选择（只回落到该模式的默认渐变） */
  private async clearBackground(): Promise<void> {
    const dark: boolean = this.dark;
    await this.setModeBg(dark, '');
    const which: string = dark ? this.t('深色', 'dark') : this.t('浅色', 'light');
    this.addLog(which + this.t('模式已恢复默认背景', ' mode default background restored'));
    this.toast(which + this.t('模式已恢复默认背景', ' mode default background restored'));
  }

  /** 当前模式正在使用的内置预设序号，-1 表示不是预设背景 */
  private presetBgIndex(): number {
    const p: string = this.bgPath;
    if (p.length === 0) {
      return -1;
    }
    for (let i = 1; i <= 7; i++) {
      if (p.indexOf('bg_preset_' + i + '.jpg') >= 0 || p.indexOf('bg_preset_' + i + '_') >= 0) {
        return i - 1;
      }
    }
    return -1;
  }

  /** 当前模式的背景状态文案 */
  private bgPathLabel(): string {
    if (this.bgPath.length === 0) {
      return this.dark
        ? this.t('当前：默认深色渐变背景', 'Current: default dark gradient')
        : this.t('当前：默认浅色渐变背景', 'Current: default light gradient');
    }
    const p: number = this.presetBgIndex();
    if (p >= 0) {
      return this.t('当前：预设背景 ', 'Current: preset background ') + (p + 1);
    }
    return this.t('当前：图库自定义图片', 'Current: custom image from gallery');
  }

  /** 当前模式是否已有背景（「无」格子的选中态） */
  private hasBg(): boolean {
    return this.bgPath.length > 0;
  }

  /** 从任意背景路径解析预设序号（-1 表示不是预设） */
  private presetIndexFromPath(p: string): number {
    if (p.length === 0) {
      return -1;
    }
    for (let i = 1; i <= 7; i++) {
      if (p.indexOf('bg_preset_' + i + '.jpg') >= 0 || p.indexOf('bg_preset_' + i + '_') >= 0) {
        return i - 1;
      }
    }
    return -1;
  }

  /** 预设素材换图后的缓存迁移：把当前选中项重拷成带版本号的新文件，并清掉旧缓存 */
  private migratePresetCache(): void {
    const ctx = this.ctx;
    if (ctx === undefined) {
      return;
    }
    const suffix: string = '_v' + PRESET_CACHE_VER + '.jpg';
    try {
      for (let k = 0; k < 2; k++) {
        const m: boolean = k === 1;
        const cur: string = ConfigStore.bgPathFor(m);
        if (cur.indexOf('/bg_preset_') < 0 || cur.endsWith(suffix)) {
          continue;
        }
        const idx: number = this.presetIndexFromPath(cur);
        if (idx < 0) {
          continue;
        }
        const raw: string = 'bg/preset' + (idx + 1) + '.jpg';
        const buf: Uint8Array = ctx.resourceManager.getRawFileContentSync(raw);
        const dst: string = ctx.filesDir + '/bg_preset_' + (idx + 1) +
          (m ? '_dark' : '_light') + suffix;
        const f = fileIo.openSync(dst,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, buf.buffer as ArrayBuffer);
        fileIo.closeSync(f);
        ConfigStore.saveBgPathFor(m, dst);
      }
      const files: string[] = fileIo.listFileSync(ctx.filesDir);
      for (let i = 0; i < files.length; i++) {
        const name: string = files[i];
        if (name.indexOf('bg_preset_') !== 0 || name.endsWith(suffix)) {
          continue;
        }
        try {
          fileIo.unlinkSync(ctx.filesDir + '/' + name);
        } catch (e) {
          const err = e as BusinessError;
          this.addLog(this.t('清理旧预设缓存失败：', 'Failed to clean old preset cache: ') + err.message);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      this.addLog(this.t('预设背景缓存迁移失败：', 'Preset cache migration failed: ') + err.message);
    }
  }

  /** 应用内置预设背景：复制进沙箱，文件按深浅色分开，和自定义图片共用同一条渲染/持久化路径 */
  private async usePresetBackground(index: number): Promise<void> {
    const ctx = this.ctx;
    if (ctx === undefined) {
      this.toast(this.t('应用上下文未就绪', 'App context not ready'));
      return;
    }
    const dark: boolean = this.dark;
    try {
      const raw: string = 'bg/preset' + (index + 1) + '.jpg';
      const buf: Uint8Array = ctx.resourceManager.getRawFileContentSync(raw);
      const dst: string = ctx.filesDir + '/bg_preset_' + (index + 1) +
        (dark ? '_dark' : '_light') + '_v' + PRESET_CACHE_VER + '.jpg';
      const f = fileIo.openSync(dst,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, buf.buffer as ArrayBuffer);
      fileIo.closeSync(f);
      await this.setModeBg(dark, dst);
      const which: string = dark ? this.t('深色', 'dark') : this.t('浅色', 'light');
      this.addLog(which + this.t('模式已应用预设背景 ', ' mode preset applied: ') + (index + 1));
      this.toast(which + this.t('模式背景已更新', ' background updated'));
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
      // 0 = 不抽样，直接把全部段各取 1 个地址（社区段库 / 官方段库全量候选）
      sampleCount: Math.min(50000, Math.max(0, this.intOf(this.sampleText, d.sampleCount))),
      customText: this.customText,
      // 记录当前分组，仅用于扫描日志/诊断；真正的候选文本是 customText（由 Sources.compile 生成）
      sourceGroupId: this.curSel(),
      sourceGroupName: Sources.selectionLabel(this.curFam(), this.curSel()),
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
    if (field === 'perRegion') {
      return this.speedPerRegionText;
    }
    if (field === 'speedCount') {
      return this.speedCountText;
    }
    if (field === 'rounds') {
      return this.speedRoundsText;
    }
    if (field === 'window') {
      return this.speedWindowText;
    }
    if (field === 'domain') {
      return this.domain;
    }
    return '';
  }

  private async applySuggestedParams(): Promise<void> {
    this.sampleText = REC_SAMPLE_COUNT.toString();
    this.concurrencyText = defaultScanConcurrency().toString();
    this.latencyText = REC_LATENCY_MS.toString();
    this.pingText = REC_PING_TIMES.toString();
    this.minSpeedText = REC_MIN_SPEED_MBPS.toString();
    // 全部写完再换一次 id：TextInput 的 text 只作初值，需重建才能回显被裁截/规范化后的值
    this.cfgRev++;
    try {
      await ConfigStore.save(this.buildConfig());
      this.toast(this.t('已应用建议参数：采样 3000、并发 30、延迟上限 300ms、Ping 1 次、合格速度 0.1MB/s（IPv4/IPv6 统一）', 'Applied recommended settings: 3000 samples, 30 threads, 300ms latency cap, 1 ping, 0.1MB/s min speed (same for IPv4/IPv6)'));
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      this.toast(this.t('应用建议失败：保存参数出错（', 'Failed to apply: saving settings failed (') + be.message + ')');
    }
  }

  /** 「下载测速」卡的应用建议：只改测速相关参数，扫描参数不动 */
  private async applySpeedSuggestions(): Promise<void> {
    this.speedCountText = REC_SPEED_COUNT.toString();
    this.speedPerRegionText = REC_SPEED_PER_REGION.toString();
    this.speedRoundsText = REC_SPEED_ROUNDS.toString();
    this.speedWindowText = REC_SPEED_WINDOW_MS.toString();
    this.cfgRev++;
    try {
      await ConfigStore.save(this.buildConfig());
      this.toast(this.t('已应用建议：每地址 1 次、窗口 6000ms、地址数 10（地区测速每地区 3 个）', 'Applied recommendations: 1 round per address, 6000ms window, 10 addresses (3 per region for region mode)'));
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      this.toast(this.t('应用建议失败：保存参数出错（', 'Failed to apply: saving settings failed (') + be.message + ')');
    }
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
    // 扫描前按当前 IP 族重新编译一次来源：历史数据、缓存、异常配置都会在这里再过一遍严格校验。
    // 当前族没有可用来源时明确报错并中止，绝不自动回退到另一族来源。
    const sel: string = this.curSel();
    this.mode = sel === SRC_ID_OFFICIAL ? ScanMode.OFFICIAL : ScanMode.CUSTOM;
    if (sel !== SRC_ID_OFFICIAL) {
      const cr: CompileResult = Sources.compile(this.curFam(), sel);
      if (!cr.ok || cr.lineCount === 0) {
        const why: string = cr.error.length > 0 ? cr.error : this.t('当前来源没有可用候选数据', 'The selected source has no usable candidates');
        this.toast(why);
        this.addLog(this.t('无法开始扫描：', 'Cannot start scanning: ') + why);
        return;
      }
      this.customText = cr.text;
      this.hlog('[SRC] scan fam=' + this.curFam().toString() + ' group=' + cr.label +
        ' sources=' + cr.sourceCount.toString() + '/' + cr.enabledCount.toString() +
        ' lines=' + cr.lineCount.toString() + ' wrong=' + cr.wrongFamily.toString());
      if (cr.wrongFamily > 0) {
        this.addLog(this.t('类型校验：来源中剔除了 ', 'Type check: dropped ') + cr.wrongFamily.toString() + this.t(' 行不属于当前 IP 版本的地址', ' lines not belonging to the current IP version'));
      }
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
    this.taskKind = 1;
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
    this.taskKind = 2;
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
        // 被停止或被新一轮顶掉：必须复位预检态，否则按钮会永远卡在「预检中…」
        this.precheckActive = false;
        return;
      }
      this.precheckActive = false;
      this.precheckDone = true;
      this.scanning = false;
      if (res.cancelled) {
        // 取消不算「预检完成」，否则下次点开始测速会直接跳过质量预检
        this.precheckDone = false;
        this.taskKind = 0;
        this.phaseText = this.t('已停止', 'Stopped');
        this.pcMsg = this.t('预检已取消', 'Pre-check cancelled');
        this.addLog(this.t('已停止：质量预检未完成', 'Stopped: quality pre-check not finished'));
        AppBackground.release('scan');
        return;
      }
      if (res.list.length === 0) {
        // 0 个达标同样不算完成：保留 0 达标提示，但不给「已预检」资格
        this.precheckDone = false;
        this.taskKind = 0;
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
      // 不许静默失败：告诉用户为什么点不动、去哪看当前进度
      this.toast(this.taskKind === 3
        ? this.t('测速进行中，可先停止当前测速', 'A speed test is running; stop it first')
        : (this.taskKind === 2
          ? this.t('质量预检进行中，请稍候', 'Quality pre-check is running, please wait')
          : this.t('扫描进行中，等第一轮筛选完成后再测速', 'Scanning is running; wait for round 1 to finish')));
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
    this.taskKind = 3;
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
    const kind: number = this.taskKind;
    this.scanGen++;
    this.token.cancel();
    this.scanning = false;
    this.taskKind = 0;
    this.clearScanTimers();
    this.stopHeartbeat();
    this.phaseText = this.t('已停止', 'Stopped');
    this.addLog(kind === 2
      ? this.t('用户停止了质量预检', 'User stopped the quality pre-check')
      : (kind === 3 ? this.t('用户停止了测速', 'User stopped the speed test') : this.t('用户停止了扫描', 'User stopped the scan')));
    AppBackground.release('scan');
    AppBackground.release('speed');
  }

  /** 扫描页主按钮文案：按当前任务类型区分「停止什么」，空闲时是开始入口 */
  private scanButtonLabel(): string {
    if (!this.scanning) {
      return this.t('开始优选', 'Start selection');
    }
    if (this.taskKind === 3) {
      return this.t('停止测速', 'Stop speed test');
    }
    if (this.taskKind === 2) {
      return this.t('停止预检', 'Stop pre-check');
    }
    return this.t('停止', 'Stop');
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
    // 跟随系统：回到前台时按最新系统深浅色重算一次（后台期间用户可能在系统里切过主题）
    if (this.themeMode === ThemeMode.SYSTEM) {
      this.applyThemeMode();
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
      if (this.bgPath.length > 0 && !this.bgLoadFailed) {
        Image('file://' + this.bgPath)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(this.bgBlurPx())
          .brightness(this.bgBrightFactor())
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .onError(() => {
            // 背景文件被删/损坏：本次运行先回落到渐变，但不动用户已保存的背景设置
            this.bgLoadFailed = true;
            this.toast(this.t('背景图读取失败，已临时使用默认背景', 'Failed to load the background; using the default for now'));
          })
        // 可读性薄纱：浅色压白、深色压黑，保留模糊与图片层次
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.bgScrim())
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .hitTestBehavior(HitTestMode.None)
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
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.txt())
                  .textAlign(TextAlign.Center)
                  .height(this.CHIP_H)
                  .padding({ left: 14, right: 14 })
                  .borderRadius(this.CHIP_H / 2)
                  .backgroundColor(this.shouldUseCardMaterial() ? Color.Transparent : this.floatFallbackBg())
                  .linearGradient({ angle: 145, colors: this.floatTint() })
                  .backgroundBlurStyle(this.floatBlur())
                  .border({ width: 1, color: this.floatBorder() })
                .shadow({
                  radius: this.floatShadowR(),
                  color: this.floatShadowColor(),
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
        .backgroundColor(this.shouldUseCardMaterial() ? Color.Transparent : this.floatFallbackBg())
        .linearGradient({ angle: 145, colors: this.floatTint() })
        .backgroundBlurStyle(this.floatBlur())
        .border({ width: 1, color: this.floatBorder() })
        .shadow({
          radius: this.floatShadowR(),
          color: this.floatShadowColor(),
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

      // 来源分组管理：整屏面板（在参数说明弹窗之下，保证参数说明仍可盖住它）
      if (this.srcMgr) {
        this.SourceManager()
      }

      // 功能说明：统一入口，整屏轻量弹窗（点击遮罩或「知道了」关闭，输入内容不受影响）
      if (this.helpKey.length > 0) {
        this.HelpSheet()
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

  /** 全局进度区：扫描 / 筛选 / 测速三页共用同一套视觉（纤细、无卡片容器） */
  @Builder ProgressStrip(kind: number) {
    Column() {
      Row() {
        Text(this.progStage(kind))
          .fontSize(12)
          .lineHeight(16)
          .fontColor(this.progRunning(kind) ? this.accentText() : this.txt2())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.progCounter(kind))
          .fontSize(11)
          .fontColor(this.txt3())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })
      }
      .width('100%')

      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(8)
          .backgroundColor(this.soft())
          .borderRadius(4)
        Row()
          .width(this.progPct(kind).toFixed(1) + '%')
          .height(8)
          .linearGradient({ angle: 90, colors: this.progressTint() })
          .borderRadius(4)
      }
      .width('100%')
      .height(8)
      .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 扫描页进度：阶段 + 计数（含通过/未通过与可用数）+ 百分比 */
  /** 进度数据按 kind 分派：0=扫描 1=筛选预检 2=测速（供 ProgressStrip 在 builder 内读取，保证状态依赖成立） */
  private progInfo(kind: number): ProgressInfo {
    if (kind === 1) {
      return this.precheckProgress();
    }
    if (kind === 2) {
      return this.speedProgress();
    }
    return this.scanProgress();
  }

  private progStage(kind: number): string {
    return this.progInfo(kind).stage;
  }

  private progCounter(kind: number): string {
    return this.progInfo(kind).counter;
  }

  private progPct(kind: number): number {
    return this.progInfo(kind).pct;
  }

  private progRunning(kind: number): boolean {
    return this.progInfo(kind).running;
  }

  private scanProgress(): ProgressInfo {
    const pct: number = this.total > 0 ? Math.min(100, this.done * 100 / this.total) : 0;
    const running: boolean = this.scanning;
    const finished: boolean = !running && this.total > 0 && this.done >= this.total;
    let stage: string = this.t('待开始', 'Not started');
    if (running) {
      stage = this.phaseText.length > 0 ? this.phaseText : this.progressLabel();
    } else if (this.total > 0) {
      stage = finished ? this.t('已完成', 'Finished') : this.t('已停止', 'Stopped');
    }
    let counter: string = this.done.toString() + ' / ' + this.total.toString() + ' · ' + pct.toFixed(1) + '%';
    if (this.pingList.length > 0) {
      counter += this.t(' · 可用 ', ' · available ') + this.pingList.length.toString();
    }
    return { pct: pct, stage: stage, counter: counter, running: running, finished: finished };
  }

  /** 筛选页质量预检进度 */
  private precheckProgress(): ProgressInfo {
    const pct: number = this.pcBarPct();
    const running: boolean = this.precheckActive;
    const finished: boolean = !running && this.precheckDone;
    const stage: string = running ? this.t('质量预检中', 'Quality pre-check in progress') : this.t('质量预检', 'Quality pre-check');
    const qual: number = (this.pcTarget > 0 && this.pcQualified > this.pcTarget ? this.pcTarget : this.pcQualified);
    const counter: string = this.t('检测 ', 'Checked ') + this.pcChecked.toString() +
      this.t(' · 合格 ', ' · Qualified ') + qual.toString() +
      this.t(' / 目标 ', ' / Target ') + this.pcTarget.toString() + ' · ' + pct.toFixed(1) + '%';
    return { pct: pct, stage: stage, counter: counter, running: running, finished: finished };
  }

  /** 测速页进度 */
  private speedProgress(): ProgressInfo {
    const pct: number = this.total > 0 ? Math.min(100, this.done * 100 / this.total) : 0;
    const running: boolean = this.scanning;
    const finished: boolean = !running && this.total > 0 && this.done >= this.total;
    const stage: string = this.phaseText.length > 0 ? this.phaseText : this.t('测速进行中…', 'Speed test in progress…');
    return { pct: pct, stage: stage, counter: this.progressLabel() + ' · ' + pct.toFixed(1) + '%', running: running, finished: finished };
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



  /**
   * 卡片玻璃底：用 Toggle(ToggleType.Button) 承载系统材质。
   * Toggle 是官方「全页面可渲染 systemMaterial」的白名单组件之一，
   * 普通容器（Stack/Column/Row）在内容区设置材质不会渲染。
   * 放在 background 层：不参与布局，不会把卡片撑高，也不拦截交互。
   */

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

  /**
   * 背景图之上的可读性蒙版。
   *
   * 底图是用户自选的（内置预设多数本身偏暗），浅色主题却仍用深色文字，
   * 没有蒙版时标题/返回/卡片辅助文字会完全糊在图上。
   * 这里只叠一层薄纱：模糊、亮度、图片层次全部保留，换来的是一致的最低对比度。
   */
  private bgScrim(): ResourceColor {
    // 0% 就是完全不加纱（与 1.4.1 观感一致），100% 上限 0.8
    const a: number = Math.max(0, Math.min(100, this.bgScrimPct)) / 100 * 0.8;
    return this.dark ? 'rgba(6,8,14,' + a.toFixed(3) + ')' : 'rgba(248,250,253,' + a.toFixed(3) + ')';
  }

  /**
   * 模态面（来源管理 / 功能说明 / 更新说明）统一的半透明底。
   *
   * 三个弹层此前各用一套「近不透明底 + 模糊 + 渐变」的组合，互相稀释，
   * 看起来比卡片更厚重。这里只保留一层固定薄纱，其余材质交给
   * cardBlurStyle / cardTint / cardBorderColor / cardShadow*，与卡片同源。
   */
  private modalVeil(): ResourceColor {
    return this.dark ? 'rgba(18,21,29,0.72)' : 'rgba(250,251,254,0.84)';
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
    this.bgScrimPct = c.bgScrim;
    this.cardClearPct = c.cardClear;
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
      bgScrim: this.bgScrimPct,
      cardClear: this.cardClearPct,
      langMode: this.langMode
    };
    ConfigStore.saveUi(c).catch((e: BusinessError) => {
      this.addLog(this.t('保存外观设置失败：', 'Failed to save appearance settings: ') + e.message);
    });
  }

  setThemeMode(m: number): void {
    this.themeMode = m;
    if (m === ThemeMode.SYSTEM) {
      // 从手动模式切回「跟随系统」时，AppStorage.sysDark 可能还是上一次强制
      // setColorMode 的结果（例如强制深色把 sysDark 覆成了 true）。先用系统真实
      // 配置校正一次，否则当帧会按旧值渲染出错误主题，看起来像闪屏。
      try {
        const c: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        AppStorage.setOrCreate<boolean>('sysDark',
          c.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } catch (e) {
      }
    }
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
  /** 卡片通透度 → 白纱强度与照片提亮系数：50=默认，0=更实，100=最透 */
  private cardClearK(): CardClearK {
    const p: number = Math.max(0, Math.min(100, this.cardClearPct));
    const d: number = (p - 50) / 50;
    // 按用户要求把可调幅度翻倍：最透 ≈0.56 倍（纯玻璃）、最实 ≈1.30 倍（厚白纱）
    const alpha: number = d >= 0 ? (1 - 0.44 * d) : (1 - 0.30 * d);
    // 照片提亮同步放大：最实时 1.6 倍，最透时归零
    const lift: number = d >= 0 ? (1 - d) : (1 - d * 0.6);
    const out: CardClearK = { alpha: alpha, lift: lift };
    return out;
  }

  private cardTint(): Array<[ResourceColor, number]> {
    const e: number = this.effLevel();
    const photo: number = this.bgPath.length > 0 ? 1 : 0;
    if (this.dark) {
      if (e < 0) {
        return [['rgba(36,39,49,0.97)', 0.0], ['rgba(32,35,44,0.97)', 0.55], ['rgba(29,32,40,0.97)', 1.0]];
      }
      const ck: CardClearK = this.cardClearK();
      const lift: number = photo * 0.05 * ck.lift;
      const a0: number = Math.max(0.03, Math.min(0.99, ((e === 0 ? 0.12 : (e === 1 ? 0.10 : 0.08)) + lift) * ck.alpha));
      const a1: number = Math.max(0.02, Math.min(0.97, ((e === 0 ? 0.05 : (e === 1 ? 0.045 : 0.04)) + lift * 0.5) * ck.alpha));
      const a2: number = Math.max(0.06, Math.min(0.99, (e === 0 ? 0.22 : (e === 1 ? 0.18 : 0.14)) * ck.alpha));
      return [['rgba(255,255,255,' + a0.toFixed(3) + ')', 0.0],
        ['rgba(255,255,255,' + a1.toFixed(3) + ')', 0.46],
        ['rgba(8,10,16,' + a2.toFixed(3) + ')', 1.0]];
    }
    if (e < 0) {
      return [['rgba(255,255,255,0.99)', 0.0], ['rgba(252,253,255,0.99)', 0.55], ['rgba(248,250,253,0.99)', 1.0]];
    }
    const ck: CardClearK = this.cardClearK();
    const lift: number = photo * 0.06 * ck.lift;
    const b0: number = Math.max(0.10, Math.min(0.99, ((e === 0 ? 0.30 : (e === 1 ? 0.40 : 0.52)) + lift) * ck.alpha));
    const b1: number = Math.max(0.07, Math.min(0.97, ((e === 0 ? 0.20 : (e === 1 ? 0.30 : 0.42)) + lift) * ck.alpha));
    const b2: number = Math.max(0.04, Math.min(0.95, ((e === 0 ? 0.12 : (e === 1 ? 0.20 : 0.30)) + lift) * ck.alpha));
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
  /** 悬浮小控件的底色：不做白纱，改成贴近底部导航的「微暗玻璃」，并跟随卡片通透度 */
  private floatTint(): Array<[ResourceColor, number]> {
    // 与卡片板块完全同源：cardTint 已内置「卡片通透度」系数，滑杆会同时影响卡片与悬浮件
    return this.cardTint();
  }

  /** 悬浮小控件的描边：与卡片同一套描边色 */
  private floatBorder(): string {
    return this.cardBorderColor();
  }
  /** 悬浮小控件（顶部主题胶囊 / 回到顶部按钮）：与底部悬浮导航同一套「浮起玻璃」配方 */
  private floatBlur(): BlurStyle {
    // 与卡片同一档玻璃，跟随材质等级（自适应/沉浸/无材质）一起变化
    return this.cardBlurStyle();
  }
  private floatFallbackBg(): ResourceColor {
    return this.dark ? 'rgba(39,39,46,0.92)' : 'rgba(255,255,255,0.94)';
  }
  private floatShadowR(): number {
    return this.cardShadowR();
  }
  private floatShadowColor(): string {
    return this.cardShadowColor();
  }
  /** 单个页签：选中时只加一层淡色圆角底 + 主题色图标/文字，不做发光 */
  /** 选中光：中心亮、四周完全渐隐的径向柔光（没有矩形边界） */
  private navSelGlow(): Array<[ResourceColor, number]> {
    const hi: number = this.dark ? 0.30 : 0.34;
    return [[this.accentRgba(hi), 0.0], [this.accentRgba(0.0), 1.0]];
  }


  // ——————————————————— 候选来源：分组模型接线 ———————————————————
  // 页面上只保留「当前 IP 版本 → 选中来源 → 编译后的候选文本」这一条链路，
  // 真正的来源数据（分组 / 每条来源 / 启用状态 / 隔离区）都在 Sources 里按 IP 族独立维护。

  /** 当前 IP 版本对应的来源族 */
  private curFam(): number {
    return this.ipVersion === IpVersion.V6 ? SRC_FAM_V6 : SRC_FAM_V4;
  }

  private famText(fam: number): string {
    return fam === SRC_FAM_V6 ? 'IPv6' : 'IPv4';
  }

  /** 当前族选中的来源 id（V4 / V6 各存一份，互不影响） */
  private curSel(): string {
    return Sources.selected(this.curFam());
  }

  /**
   * 建立 @State 依赖：来源数据存在 Sources 的静态表里，改完后靠 srcRev 通知页面刷新。
   * 任何在 build 路径里读取 Sources 的方法都应该先调一次，否则数据变了界面不会重绘。
   */
  private srcTick(): void {
    if (this.srcRev < 0) {
      return;
    }
  }

  /**
   * 来源链路的命令行可观测日志：分组/来源/编译/启停的关键决策都走这里，
   * 便于 `devecocli log` 或 hdc hilog 验证「V4 只读 V4 来源」是否真的成立。
   */
  private hlog(msg: string): void {
    hilog.info(0x0001, 'cflark', '%{public}s', msg);
  }

  /** 来源名称（下拉按钮上的文案） */
  private srcLabel(): string {
    this.srcTick();
    return Sources.selectionLabel(this.curFam(), this.curSel());
  }

  private menuChoices(): SourceChoice[] {
    this.srcTick();
    return Sources.choices(this.curFam());
  }

  /** 选中项变了：重新编译候选文本、同步扫描模式；返回错误提示（空串=成功） */
  private applySelection(persist: boolean): string {
    const fam: number = this.curFam();
    const sel: string = Sources.selected(fam);
    const cr: CompileResult = Sources.compile(fam, sel);
    this.mode = sel === SRC_ID_OFFICIAL ? ScanMode.OFFICIAL : ScanMode.CUSTOM;
    this.customText = cr.text;
    this.srcRev++;
    this.cfgRev++;
    this.hlog('[SRC] select fam=' + fam.toString() + ' id=' + sel + ' mode=' + this.mode.toString() +
      ' ok=' + (cr.ok ? '1' : '0') + ' lines=' + cr.lineCount.toString() + ' wrong=' + cr.wrongFamily.toString());
    if (persist) {
      this.scheduleScanSave();
    }
    return cr.error;
  }

  /** 切换选中来源；社区段库为空时按当前族自动拉一次（失败就明确报错，不回退另一族） */
  private async onPickSource(id: string): Promise<void> {
    const fam: number = this.curFam();
    if (id === SRC_ID_COMMUNITY && Sources.communityLineCount(fam) === 0) {
      this.toast(this.t('社区段库为空，正在拉取…', 'Community ranges are empty; fetching…'));
      const got: boolean = await this.fetchCommunity(fam);
      if (!got) {
        return;
      }
    }
    const err: string = await Sources.setSelected(fam, id);
    if (err.length > 0) {
      this.toast(err);
      this.addLog(this.t('切换来源失败：', 'Failed to switch source: ') + err);
      return;
    }
    const cerr: string = this.applySelection(true);
    if (cerr.length > 0) {
      this.toast(cerr);
      this.addLog(this.t('候选来源：', 'Candidate source: ') + cerr);
    }
  }

  /** 切换 IP 版本 = 换一整套来源：回到列表根视图，并按新族的选择重新编译候选文本 */
  private onFamSwitch(ver: number): void {
    if (this.ipVersion === ver) {
      return;
    }
    this.ipVersion = ver;
    this.maybeAutoSuggest(ver === IpVersion.V6);
    this.srcMgrView = 0;
    this.srcMgrGid = '';
    this.srcRename = false;
    this.srcConfirmGroup = false;
    this.srcConfirmSrc = '';
    // 切族后上一族的候选、结果、预检资格全部作废：
    // 否则可能拿旧族的节点去做质量预检/正式测速，进度与结果都会串族
    this.results = [];
    this.pingList = [];
    this.speedList = [];
    this.groups = [];
    this.done = 0;
    this.total = 0;
    this.doneRaw = 0;
    this.totalRaw = 0;
    this.precheckActive = false;
    this.precheckDone = false;
    this.pcChecked = 0;
    this.pcQualified = 0;
    this.pcTarget = 0;
    this.pcMsg = '';
    const e: string = this.applySelection(true);
    this.srcMgrMsg = e;
  }

  /** 来源弹层：只列当前 IP 族的官方 / 社区 / 自定义分组，末尾是管理入口 */
  @Builder SourceMenu() {
    Column() {
      ForEach(this.menuChoices(), (ch: SourceChoice) => {
        Column() {
          Row() {
            Text(ch.label)
              .fontSize(13)
              .fontColor(ch.id === this.curSel() ? this.accent() : this.txt())
              .fontWeight(ch.id === this.curSel() ? FontWeight.Medium : FontWeight.Normal)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (ch.builtin) {
              Text(this.t('内置', 'Built-in'))
                .fontSize(10)
                .fontColor(this.txt3())
                .margin({ left: 6 })
            }
            if (ch.id === this.curSel()) {
              Text('✓')
                .fontSize(12)
                .fontColor(this.accentText())
                .margin({ left: 6 })
            }
          }
          .width('100%')
          .height(40)
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            this.onPickSource(ch.id);
          })
          Divider()
            .color(this.lineC())
            .strokeWidth(0.5)
            .margin({ left: 14, right: 14 })
        }
        .width('100%')
      }, (ch: SourceChoice) => ch.id + '|' + ch.label + '|' + ch.stats.lineCount.toString())
    }
    .width(240)
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
        // 平板 / 电脑：两列，左右各两张卡（左：候选来源 / 快速筛选参数，右：下载测速 / 运行日志）
        // 四张卡按阅读顺序两两分配到两列，避免出现「三卡挤一列 + 单卡占一列」的不对称
        Scroll(this.scanScroller) {
          Row() {
            Column({ space: 20 }) {
              Row({ space: 20 }) {
                Column({ space: 20 }) {
                  this.CardSource()
                  this.CardParam()
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Column({ space: 20 }) {
                  this.CardSpeed()
                  this.CardLog(false, 240, true)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: this.contentTop(), bottom: this.pageBottomPad() })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Top)
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
    
    Column({ space: 16 }) {
    this.CardSource()
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

    /** 带功能说明入口的卡片标题：标题左、感叹号右，与「快速筛选参数」一致 */
    @Builder CardTitleWithHelp(title: string, icon: Resource, key: string) {
    Row() {
    SymbolGlyph(icon)
    .fontSize(16)
    .fontColor([this.txt2()])
    .margin({ right: 8 })
    Text(title)
    .fontSize(15)
    .fontWeight(FontWeight.Medium)
    .fontColor(this.txt())
    .layoutWeight(1)
    .maxLines(1)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    this.InfoDot(key)
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
    Text(this.sourceHintText())
    .fontSize(11)
    .fontColor(this.txt3())
    .width('100%')
    .margin({ top: 8 })
    .maxLines(2)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    
  // ——————————————————— 来源分组管理页：视图栈（列表 → 分组详情 → 加链接/加文本） ———————————————————
  // 用整屏面板而不是把所有编辑控件堆在一张卡片里；V4/V6 切换在面板顶部，切换即换整套来源数据。

  @Builder SrcMgrHeaderBtn(label: string) {
    Text(label)
      .fontSize(16)
      .fontColor(this.txt2())
      .width(34)
      .height(34)
      .textAlign(TextAlign.Center)
      .borderRadius(17)
      .accessibilityText(this.srcMgrView === 0 ? this.t('关闭来源分组管理', 'Close source groups') :
        this.t('返回上一级', 'Back'))
      .onClick(() => {
        this.srcMgrBack();
      })
  }

  @Builder SrcFamChip(label: string, ver: number) {
    Text(label)
      .fontSize(11)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.ipVersion === ver ? '#FFFFFF' : this.txt2())
      .height(26)
      .padding({ left: 10, right: 10 })
      .backgroundColor(this.ipVersion === ver ? this.accentFill() : this.soft())
      .borderRadius(8)
      .margin({ left: 6 })
      .onClick(() => {
        this.onFamSwitch(ver);
      })
  }

  @Builder SrcMgrHeader() {
    Column() {
      Row() {
        this.SrcMgrHeaderBtn(this.srcMgrView === 0 ? '✕' : '‹')
        Column() {
          Text(this.srcMgrTitle())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.srcMgrSub())
            .fontSize(10)
            .fontColor(this.txt3())
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 6, right: 6 })
        Row() {
          this.SrcFamChip('IPv4', IpVersion.V4)
          this.SrcFamChip('IPv6', IpVersion.V6)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.srcMgrMsg.length > 0) {
        Text(this.srcMgrMsg)
          .fontSize(10)
          .fontColor(this.accentText())
          .width('100%')
          .padding({ top: 6, bottom: 6, left: 10, right: 10 })
          .backgroundColor(this.soft())
          .borderRadius(8)
          .margin({ top: 8 })
      }
      Divider()
        .color(this.lineC())
        .strokeWidth(0.5)
        .margin({ top: 8 })
    }
    .width('100%')
  }

  @Builder SrcSectionTitle(text: string) {
    Text(text)
      .fontSize(10)
      .fontColor(this.txt3())
      .width('100%')
      .margin({ top: 10, bottom: 6 })
  }

  @Builder SrcChoiceRow(ch: SourceChoice) {
    Row() {
      Column() {
        Row() {
          Text(ch.label)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (ch.builtin) {
            Text(this.t('只读', 'Read-only'))
              .fontSize(9)
              .fontColor(this.txt3())
              .margin({ left: 6 })
          }
        }
        Text(this.choiceStatText(ch))
          .fontSize(10)
          .fontColor(this.txt3())
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (ch.builtin && ch.id === SRC_ID_COMMUNITY) {
        Text(this.srcMgrBusy ? this.t('更新中', 'Updating') : this.t('更新', 'Update'))
          .fontSize(11)
          .fontColor(this.accentText())
          .height(26)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.soft())
          .borderRadius(8)
          .onClick(() => {
            this.fetchCommunity(this.curFam());
          })
      }
      Text(ch.id === this.curSel() ? this.t('使用中', 'In use') : this.t('使用', 'Use'))
        .fontSize(11)
        .fontColor(ch.id === this.curSel() ? this.txt3() : this.accentText())
        .height(26)
        .padding({ left: 10, right: 10 })
        .backgroundColor(this.soft())
        .borderRadius(8)
        .margin({ left: 6 })
        .onClick(() => {
          this.onPickSource(ch.id);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 14, bottom: 14, left: 16, right: 16 })
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
    .onClick(() => {
      if (ch.builtin) {
        this.onPickSource(ch.id);
      } else {
        this.openGroup(ch.id);
      }
    })
  }

  @Builder SrcMgrList() {
    Scroll() {
      Column() {
        this.SrcSectionTitle(this.t('内置来源（受保护，不可编辑或删除）', 'Built-in sources (protected, read-only)'))
        ForEach(this.builtinChoices(), (ch: SourceChoice) => {
          this.SrcChoiceRow(ch)
        }, (ch: SourceChoice) => 'b|' + ch.id + '|' + ch.label + '|' + this.srcRev.toString())

        this.SrcSectionTitle(this.t('自定义分组（点一行进入管理）', 'Custom groups (tap a row to manage)'))
        if (this.customChoices().length === 0) {
          Text(this.t('还没有自定义分组', 'No custom groups yet'))
            .fontSize(11)
            .fontColor(this.txt3())
            .width('100%')
            .padding({ top: 2, bottom: 8 })
        }
        ForEach(this.customChoices(), (ch: SourceChoice) => {
          this.SrcChoiceRow(ch)
        }, (ch: SourceChoice) => 'c|' + ch.id + '|' + ch.label + '|' + this.srcRev.toString())

        Row() {
          TextInput({ text: this.srcNewName, placeholder: this.t('新分组名称', 'New group name') })
            .fontSize(12)
            .fontColor(this.txt())
            .placeholderColor(this.txt3())
            .height(36)
            .layoutWeight(1)
            .backgroundColor(this.inputBg())
            .borderRadius(10)
            .onChange((v: string) => {
              this.srcNewName = v;
            })
          Text(this.t('新建', 'Create'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accentText())
            .height(36)
            .padding({ left: 14, right: 14 })
            .backgroundColor(this.soft())
            .borderRadius(10)
            .margin({ left: 8 })
            .onClick(() => {
              this.createGroupNow();
            })
        }
        .width('100%')
        .margin({ top: 4 })

        if (Sources.quarantines.length > 0) {
          Row() {
            Text(this.t('隔离区：', 'Quarantine: ') + Sources.quarantines.length.toString() + this.t(' 行无法识别的旧数据（保留不丢弃，不参与扫描）', ' unrecognised legacy lines (kept, not used for scanning)'))
              .fontSize(10)
              .fontColor(this.txt3())
              .layoutWeight(1)
            Text(this.srcShowQuarantine ? this.t('收起', 'Hide') : this.t('查看', 'View'))
              .fontSize(10)
              .fontColor(this.accentText())
              .padding({ left: 8, right: 8 })
              .onClick(() => {
                this.srcShowQuarantine = !this.srcShowQuarantine;
              })
          }
          .width('100%')
          .margin({ top: 10 })
          .alignItems(VerticalAlign.Center)
          if (this.srcShowQuarantine) {
            Text(Sources.quarantineSummary())
              .fontSize(9)
              .fontColor(this.txt3())
              .width('100%')
              .padding(8)
              .backgroundColor(this.soft())
              .borderRadius(8)
              .margin({ top: 6 })
            Text(this.t('清空隔离区', 'Clear quarantine'))
              .fontSize(10)
              .fontColor(BAD_C)
              .padding({ top: 6, bottom: 6 })
              .onClick(() => {
                this.clearQuarantineNow();
              })
          }
        }

        Row() {
          Text(this.t('逻辑自检（校验官方保护 / 类型隔离 / 去重 / 编译）', 'Logic self-check (protection, isolation, dedupe, compile)'))
            .fontSize(10)
            .fontColor(this.txt3())
            .layoutWeight(1)
          Text(this.t('运行', 'Run'))
            .fontSize(10)
            .fontColor(this.accentText())
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.runSelfCheck();
            })
        }
        .width('100%')
        .margin({ top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 2, right: 2 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .margin({ top: 4 })
  }

  @Builder SrcItemRow(s: SourceItem) {
    Column() {
      Row() {
        Text(Sources.kindLabel(s.kind))
          .fontSize(9)
          .fontColor(this.txt2())
          .height(18)
          .padding({ left: 6, right: 6 })
          .backgroundColor(this.inputBg())
          .borderRadius(5)
        Column() {
          Text(s.name)
            .fontSize(12)
            .fontColor(this.txt())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.sourceStatText(s))
            .fontSize(9)
            .fontColor(s.status === SRC_STATUS_FAILED ? BAD_C : this.txt3())
            .margin({ top: 2 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 8, right: 6 })
        .onClick(() => {
          this.openSourceEdit(s.id);
        })
        Text(this.t('编辑', 'Edit'))
          .fontSize(10)
          .fontColor(this.txt2())
          .height(24)
          .padding({ left: 8, right: 8 })
          .backgroundColor(this.inputBg())
          .borderRadius(6)
          .margin({ right: 6 })
          .onClick(() => {
            this.openSourceEdit(s.id);
          })
        if (s.kind === SRC_KIND_LINK) {
          Text(this.t('更新', 'Refresh'))
            .fontSize(10)
            .fontColor(this.accentText())
            .height(24)
            .padding({ left: 8, right: 8 })
            .backgroundColor(this.inputBg())
            .borderRadius(6)
            .margin({ right: 6 })
            .onClick(() => {
              this.refreshLink(s.id, false);
            })
        }
        if (s.status === SRC_STATUS_FAILED) {
          Text(this.t('失败', 'Failed'))
            .fontSize(10)
            .fontColor(BAD_C)
            .height(24)
            .padding({ left: 8, right: 8 })
            .backgroundColor(this.inputBg())
            .borderRadius(6)
        } else {
          Text(s.enabled ? this.t('已启用', 'On') : this.t('已停用', 'Off'))
            .fontSize(10)
            .fontColor(s.enabled ? this.accentText() : this.txt3())
            .height(24)
            .padding({ left: 8, right: 8 })
            .backgroundColor(this.inputBg())
            .borderRadius(6)
            .onClick(() => {
              this.toggleSource(s.id);
            })
        }
        Text(this.srcConfirmSrc === s.id ? this.t('确认', 'Sure') : '✕')
          .fontSize(10)
          .fontColor(BAD_C)
          .width(40)
          .height(24)
          .textAlign(TextAlign.Center)
          .borderRadius(6)
          .backgroundColor(this.srcConfirmSrc === s.id ? this.inputBg() : Color.Transparent)
          .onClick(() => {
            this.removeSource(s.id);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 14, bottom: 14, left: 14, right: 14 })
    .backgroundBlurStyle(this.cardBlurStyle(),
      { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder SrcAddBtn(label: string, target: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.accentText())
      .height(36)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.soft())
      .borderRadius(10)
      .margin({ left: 4, right: 4 })
      .onClick(() => {
        if (target === 0) {
          this.addFileSource();
        } else {
          this.openAddView(target);
        }
      })
  }

  @Builder SrcMgrDetail() {
    Scroll() {
      Column() {
        if (this.srcRename) {
          Row() {
            TextInput({ text: this.srcNameDraft, placeholder: this.t('分组名称', 'Group name') })
              .fontSize(12)
              .fontColor(this.txt())
              .height(36)
              .layoutWeight(1)
              .backgroundColor(this.inputBg())
              .borderRadius(10)
              .onChange((v: string) => {
                this.srcNameDraft = v;
              })
            Text(this.t('保存', 'Save'))
              .fontSize(12)
              .fontColor(this.accentText())
              .height(32)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.soft())
              .borderRadius(10)
              .margin({ left: 8 })
              .onClick(() => {
                this.commitRename();
              })
            Text(this.t('取消', 'Cancel'))
              .fontSize(12)
              .fontColor(this.txt2())
              .height(32)
              .padding({ left: 10, right: 10 })
              .onClick(() => {
                this.srcRename = false;
              })
          }
          .width('100%')
          .margin({ top: 10 })
          .alignItems(VerticalAlign.Center)
        } else {
          Row() {
            Text(this.groupNameOf(this.srcMgrGid))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.txt())
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.t('改名', 'Rename'))
              .fontSize(11)
              .fontColor(this.accentText())
              .height(32)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.soft())
              .borderRadius(10)
              .onClick(() => {
                this.srcNameDraft = this.groupNameOf(this.srcMgrGid);
                this.srcRename = true;
              })
          }
          .width('100%')
          .margin({ top: 10 })
          .alignItems(VerticalAlign.Center)
        }

        Text(this.groupStatText(this.srcMgrGid))
          .fontSize(10)
          .fontColor(this.txt3())
          .width('100%')
          .margin({ top: 6 })

        this.SrcSectionTitle(this.t('来源列表（点来源可编辑内容，点状态切换启用，✕ 删除）',
          'Sources (tap to edit content, tap state to toggle, ✕ to delete)'))
        if (this.curGroupSources().length === 0) {
          Text(this.t('这个分组还没有来源，用下面三个按钮添加', 'No sources yet; add one with the buttons below'))
            .fontSize(11)
            .fontColor(this.txt3())
            .width('100%')
            .padding({ top: 2, bottom: 8 })
        }
        ForEach(this.curGroupSources(), (s: SourceItem) => {
          this.SrcItemRow(s)
        }, (s: SourceItem) => s.id + '|' + this.srcRev.toString())

        Row() {
          this.SrcAddBtn(this.t('+ 链接', '+ Link'), 2)
          this.SrcAddBtn(this.t('+ 文件', '+ File'), 0)
          this.SrcAddBtn(this.t('+ 文本', '+ Text'), 3)
        }
        .width('100%')
        .margin({ top: 10 })

        if (this.groupLinkCount() > 0) {
          Row() {
            Text(this.t('链接来源可一键更新：重新拉取并按当前 IP 版本校验，成功才替换内容', 'Link sources can be refreshed: refetch, revalidate for the current IP version, replace only on success'))
              .fontSize(9)
              .fontColor(this.txt3())
              .layoutWeight(1)
              .maxLines(2)
            Text(this.t('更新全部链接', 'Refresh all'))
              .fontSize(11)
              .fontColor(this.accentText())
              .height(32)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.soft())
              .borderRadius(10)
              .margin({ left: 8 })
              .onClick(() => {
                this.refreshAllLinks();
              })
          }
          .width('100%')
          .margin({ top: 8 })
          .alignItems(VerticalAlign.Center)
        }

        Divider()
          .color(this.lineC())
          .strokeWidth(0.5)
          .margin({ top: 16, bottom: 10 })

        if (this.srcConfirmGroup) {
          Row() {
            Text(this.t('确认删除整个分组？此操作不影响官方 IP 段', 'Delete this whole group? Official ranges are unaffected'))
              .fontSize(11)
              .fontColor(BAD_C)
              .layoutWeight(1)
            Text(this.t('删除分组', 'Delete'))
              .fontSize(11)
              .fontColor('#FFFFFF')
              .height(32)
              .padding({ left: 12, right: 12 })
              .backgroundColor(BAD_C)
              .borderRadius(10)
              .onClick(() => {
                this.deleteGroupNow();
              })
            Text(this.t('取消', 'Cancel'))
              .fontSize(11)
              .fontColor(this.txt2())
              .height(32)
              .padding({ left: 10, right: 10 })
              .onClick(() => {
                this.srcConfirmGroup = false;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        } else {
          Text(this.t('删除分组', 'Delete group'))
            .fontSize(11)
            .fontColor(BAD_C)
            .height(32)
            .padding({ left: 12, right: 12 })
            .borderRadius(10)
            .border({ width: 0.5, color: BAD_C })
            .onClick(() => {
              this.srcConfirmGroup = true;
            })
        }
      }
      .width('100%')
      .padding({ bottom: 16 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .margin({ top: 4 })
  }

  @Builder SrcMgrAddLink() {
    Scroll() {
      Column() {
        Text(this.t('填写一个 http(s) 链接，拉取成功后按当前 IP 版本校验并加入分组。解析失败会作为失败来源留在列表里，不会当成有效数据。', 'Enter an http(s) link. The content is validated against the current IP version. Failed imports are kept as failed sources, never as valid data.'))
          .fontSize(10)
          .fontColor(this.txt3())
          .width('100%')
          .margin({ top: 12, bottom: 10 })
        TextInput({ text: this.srcLinkDraft, placeholder: 'https://example.com/ips-v4.txt' })
          .fontSize(12)
          .fontColor(this.txt())
          .placeholderColor(this.txt3())
          .height(38)
          .width('100%')
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .onChange((v: string) => {
            this.srcLinkDraft = v;
          })
        Row() {
          Text(this.srcMgrBusy ? this.t('拉取中…', 'Fetching…') : this.t('添加链接', 'Add link'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.srcMgrBusy ? this.txt3() : '#FFFFFF')
            .height(36)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.srcMgrBusy ? this.soft() : this.accentFill())
            .borderRadius(10)
            .onClick(() => {
              if (!this.srcMgrBusy) {
                this.addLinkSource();
              }
            })
        }
        .width('100%')
        .margin({ top: 12 })
        Text(this.t('也可以直接在分组详情的「+ 文件」「+ 文本」里添加，三种方式可以混用。', 'You can also add files or pasted text from the group detail view; all three kinds can be mixed.'))
          .fontSize(10)
          .fontColor(this.txt3())
          .width('100%')
          .margin({ top: 12 })
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .margin({ top: 4 })
  }

  @Builder SrcMgrEditSource() {
    Column() {
      Text(this.t('来源', 'Source'))
        .fontSize(10)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 12 })
      Text(this.editSourceName())
        .fontSize(13)
        .fontColor(this.txt())
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
      Text(this.t('每行一条网段或地址：可直接改写，也可以删掉整行来移除该段。保存时按当前 IP 版本重新校验，无法识别的行会被拒绝并给出原因。',
        'One range or address per line: edit in place, or delete lines to drop them. Saving revalidates against the current IP version; invalid lines are rejected with a reason.'))
        .fontSize(10)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 8, bottom: 8 })
      TextArea({ text: this.srcEditDraft })
        .fontSize(11)
        .fontColor(this.txt())
        .width('100%')
        .height(220)
        .backgroundColor(this.inputBg())
        .borderRadius(10)
        .onChange((v: string) => {
          this.srcEditDraft = v;
        })
      Row() {
        Text(this.t('保存修改', 'Save'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .height(36)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.accentFill())
          .borderRadius(10)
          .onClick(() => {
            this.saveSourceEdit();
          })
        Text(this.t('取消', 'Cancel'))
          .fontSize(12)
          .fontColor(this.txt2())
          .height(36)
          .padding({ left: 14, right: 14 })
          .textAlign(TextAlign.Center)
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .margin({ left: 8 })
          .onClick(() => {
            this.srcMgrBack();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder SrcMgrAddText() {
    Column() {
      Text(this.t('粘贴 IP 段 / 地址文本；支持的写法与原有导入一致（# 注释、CIDR、IP:端口）。混合了另一种 IP 类型时，错误行会被拒绝并给出原因。', 'Paste ranges or addresses; same formats as before (# comments, CIDR, IP:port). Lines of the other IP version are rejected with a reason.'))
        .fontSize(10)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 12, bottom: 10 })
      TextArea({ text: this.srcPasteDraft, placeholder: '1.2.3.0/24\n2001:db8::/32' })
        .fontSize(11)
        .fontColor(this.txt())
        .placeholderColor(this.txt3())
        .width('100%')
        .height(200)
        .backgroundColor(this.inputBg())
        .borderRadius(10)
        .onChange((v: string) => {
          this.srcPasteDraft = v;
        })
      Text(this.t('添加文本来源', 'Add text source'))
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .height(36)
        .width('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor(this.accentFill())
        .borderRadius(10)
        .margin({ top: 12 })
        .onClick(() => {
          this.addTextSource();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 候选来源：整屏管理面板（遮罩点击关闭；平板/PC 居中定宽，手机全屏） */
  @Builder SourceManager() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.38)')
        .zIndex(0)
        .onClick(() => {
          this.closeSrcMgr();
        })
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.SrcMgrHeader()
          if (this.srcMgrView === 0) {
            this.SrcMgrList()
          } else if (this.srcMgrView === 1) {
            this.SrcMgrDetail()
          } else if (this.srcMgrView === 2) {
            this.SrcMgrAddLink()
          } else if (this.srcMgrView === 3) {
            this.SrcMgrAddText()
          } else if (this.srcMgrView === 4) {
            this.SrcMgrEditSource()
          } else {
            this.SrcMgrDetail()
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: px2vp(this.statusBarPx) + 10, bottom: 12 })
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
      }
      .width(this.winW >= 900 ? 720 : '100%')
      .height(this.winW >= 900 ? this.srcMgrPanelH() : '100%')
      .constraintSize({ maxHeight: this.winW >= 900 ? '86%' : '100%' })
      .zIndex(1)
      .backgroundBlurStyle(this.cardBlurStyle(), {
        colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
      })
      .backgroundColor(this.modalVeil())
      .linearGradient({ angle: 145, colors: this.cardTintOr(false) })
      .borderRadius(this.winW >= 900 ? 20 : 0)
      .border({ width: this.winW >= 900 ? 1 : 0, color: this.cardBorderColor() })
      .shadow({
        radius: this.winW >= 900 ? this.cardShadowR() : 0,
        color: this.cardShadowColor(),
        offsetX: 0,
        offsetY: this.cardShadowY()
      })
    }
    .width('100%')
    .height('100%')
    .zIndex(50)
  }

  /** 候选来源：来源 / IP 版本 / 端口 三组参数合并为一张卡片，减少卡片数与纵向占用 */
  /** 单个端口 chip（宽屏两行、手机一行共用） */
  @Builder PortChip(p: number) {
    Text(p.toString())
      .fontSize(this.CHIP_FS)
      .fontColor(this.port === p ? '#FFFFFF' : this.txt2())
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(this.CHIP_H)
      .backgroundColor(this.port === p ? this.accentFill() : this.soft())
      .borderRadius(this.CHIP_R)
      .onClick(() => {
        this.port = p;
        this.scheduleScanSave();
      })
  }

  @Builder CardSource() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitleWithHelp(this.t('候选来源', 'Candidate source'), $r('sys.symbol.wifi'), HELP_SOURCE)

        // 开始优选：主操作，视觉权重最高
        Text(this.scanButtonLabel())
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

        // 扫描进度：并入卡片内部；预检/测速阶段进度归属各自页面，这里只给一句指引
        if (this.scanning && this.taskKind !== 1) {
          Text(this.taskKind === 2
            ? this.t('质量预检进行中 · 进度见「筛选」页', 'Quality pre-check running · see the "Filter" tab')
            : this.t('测速进行中 · 进度见「测速」页', 'Speed test running · see the "Speed" tab'))
            .fontSize(11)
            .fontColor(this.txt3())
            .width('100%')
            .margin({ top: 10, bottom: 2 })
        } else {
          Column() {
            this.ProgressStrip(0)
          }
          .width('100%')
          .margin({ top: 12, bottom: 2 })
        }

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
          Text(this.t('编辑分组', 'Groups'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accentText())
            .textAlign(TextAlign.Center)
            .height(36)
            .padding({ left: 12, right: 12 })
            .backgroundColor(this.soft())
            .borderRadius(10)
            .margin({ left: 8 })
            .accessibilityText(this.t('编辑来源分组', 'Edit source groups'))
            .onClick(() => {
              this.openSrcMgr();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 12 })

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
                this.onFamSwitch(IpVersion.V4);
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
                this.onFamSwitch(IpVersion.V6);
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
            .alignSelf(ItemAlign.Start)
            .margin({ top: 8 })
          Column({ space: 6 }) {
            if (this.winW >= 900) {
              // 宽屏：端口排两行（3 + 3），与右侧卡片底部对齐
              Row({ space: 4 }) {
                ForEach(PORT_OPTIONS.slice(0, 3), (p: number, index: number) => {
                  this.PortChip(p)
                }, (p: number, index: number) => p.toString())
              }
              .width('100%')

              Row({ space: 4 }) {
                ForEach(PORT_OPTIONS.slice(3), (p: number, index: number) => {
                  this.PortChip(p)
                }, (p: number, index: number) => p.toString())
              }
              .width('100%')
            } else {
              Row({ space: 4 }) {
                ForEach(PORT_OPTIONS, (p: number, index: number) => {
                  this.PortChip(p)
                }, (p: number, index: number) => p.toString())
              }
              .width('100%')
            }
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
    .margin({ bottom: 0 })
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

  /** 功能说明入口：与「快速筛选参数」原有样式一致（28×28 胶囊底 + 强调色感叹号） */
  @Builder InfoDot(key: string) {
    Text('ⓘ')
      .fontSize(13)
      .fontColor(this.accentText())
      .textAlign(TextAlign.Center)
      .width(28)
      .height(28)
      .borderRadius(14)
      .backgroundColor(this.soft())
      .margin({ left: 8 })
      .accessibilityText(HelpText.title(key, this.langEn))
      .onClick(() => {
        this.openHelp(key);
      })
  }

  private openHelp(key: string): void {
    this.helpKey = key;
  }

  private closeHelp(): void {
    this.helpKey = '';
  }

  /** 说明正文：把占位符替换成当前真实状态，保证说明与实际配置一致 */
  private helpParagraphs(): string[] {
    const raw: string[] = HelpText.body(this.helpKey, this.langEn);
    const out: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      let line: string = raw[i];
      if (line === '{latency}') {
        line = this.latencyHint;
      }
      line = line.replace('{cap}', maxScanConcurrency().toString());
      line = line.replace('{ping}', this.pingText);
      line = line.replace('{rounds}', this.speedRoundsText);
      line = line.replace('{window}', this.speedWindowText);
      out.push(line);
    }
    return out;
  }

  /** 功能说明弹窗：沿用原「参数说明」的视觉与关闭行为，长文本在弹窗内滚动 */
  @Builder HelpSheet() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.38)')
        .onClick(() => {
          this.closeHelp();
        })
      Stack({ alignContent: Alignment.TopStart }) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(16)
              .fontColor([this.accentText()])
            Text(HelpText.title(this.helpKey, this.langEn))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.txt())
              .layoutWeight(1)
          }
          .width('100%')

          Scroll() {
            Column({ space: 8 }) {
              ForEach(this.helpParagraphs(), (line: string, index: number) => {
                Text(line)
                  .fontSize(12)
                  .lineHeight(19)
                  .fontColor(this.txt2())
                  .width('100%')
              }, (line: string, index: number) => index.toString() + '#' + line)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          // 短屏（横屏/分屏）时正文让位给标题与「知道了」按钮，避免整卡被裁掉底部按钮
          .constraintSize({
            maxHeight: Math.max(120,
              (this.winH > 0 ? this.winH : 780) * 0.80 - 210)
          })
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)

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
                this.closeHelp();
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
      .backgroundColor(this.modalVeil())
      .backgroundBlurStyle(this.cardBlurStyle(),
        { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .linearGradient({ angle: 145, colors: this.cardTint() })
      .borderRadius(20)
      .border({ width: 1, color: this.cardBorderColor() })
      .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    }
    .width('100%')
    .height('100%')
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
          this.InfoDot(HELP_FILTER)
        }
        .width('100%')

        // 两列两组：左列「采样数 / 并发线程」，右列「延迟上限 / Ping 次数」；
        // 宽屏与手机同一结构（宽屏靠这两行把左列拉高，与右列底部对齐）
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
    .margin({ bottom: 0 })
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
          this.InfoDot(HELP_SPEED)
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

          Row({ space: 10 }) {
            this.ParamCell(this.speedScope === SpeedScope.PER_REGION ? this.t('每地区数量', 'Per-region count') : this.t('测速地址数', 'Test addresses'),
              this.speedScope === SpeedScope.PER_REGION ? 'perRegion' : 'speedCount',
              (this.speedScope === SpeedScope.PER_REGION ? 'spd-per-' : 'spd-count-') + this.cfgRev.toString(), true,
              (v: string) => {
                if (this.speedScope === SpeedScope.PER_REGION) {
                  this.speedPerRegionText = v;
                } else {
                  this.speedCountText = v;
                }
                this.scheduleScanSave();
              })
            this.ParamCell(this.t('每地址次数', 'Rounds per address'), 'rounds', 'spd-rounds-' + this.cfgRev.toString(), true,
              (v: string) => {
                this.speedRoundsText = v;
                this.scheduleScanSave();
              })
          }
          .width('100%')
          .margin({ top: 10 })

          Row({ space: 10 }) {
            this.ParamCell(this.t('窗口 ms', 'Window ms'), 'window', 'spd-window-' + this.cfgRev.toString(), true,
              (v: string) => {
                this.speedWindowText = v;
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
                this.applySpeedSuggestions();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
          .margin({ top: 10 })

          Row({ space: 10 }) {
            this.ParamCell(this.t('测速域名（可选）', 'Test domain (optional)'), 'domain', 'spd-domain-' + this.cfgRev.toString(), false,
              (v: string) => {
                this.domain = v;
                this.scheduleScanSave();
              })
          }
          .width('100%')
          .margin({ top: 10 })

          if (this.speedScope === SpeedScope.REGION) {
            Text(this.t('地区码：', 'Region code: ') + (this.regionCode.length > 0 ? this.regionCode : this.t('未设置（在「筛选」页填写）', 'not set (fill it on the Filter page)')))
              .fontSize(11)
              .fontColor(this.txt3())
              .width('100%')
              .margin({ top: 10 })
          }

          Row({ space: 8 }) {
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
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 10 })

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
    .margin({ bottom: 0 })
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
    if (key === 'blur') {
      return this.bgBlurPct;
    }
    if (key === 'scrim') {
      return this.bgScrimPct;
    }
    if (key === 'card') {
      return this.cardClearPct;
    }
    return this.bgBrightPct;
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
        .enabled(key === 'card' || this.bgPath.length > 0)
        .opacity(key === 'card' || this.bgPath.length > 0 ? 1 : 0.4)
        .onChange((v: number) => {
          if (key === 'blur') {
            this.bgBlurPct = v;
          } else if (key === 'scrim') {
            this.bgScrimPct = v;
          } else if (key === 'card') {
            this.cardClearPct = v;
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
  /** 预设背景缩略图（Android 端 rawfile 直读，避免额外解码文件） */
  /** 背景图块可见内容宽度：宽屏要扣掉左侧分类栏 */
  private bgContentW(): number {
    const w: number = Math.min(this.winW, 1600);
    const side: number = w >= 900 ? 336 : 0;
    return Math.max(240, w - side - 32);
  }

  /** 一行放几个图块：内容窄时 4 个（两行），内容宽时 8 个（一行），避免被拉成细长条 */
  private bgCols(): number {
    const w: number = this.bgContentW();
    if (w >= 860) {
      return 9;
    }
    if (w >= 560) {
      return 5;
    }
    return 3;
  }

  /** 图块高度：列数越少、单个越宽，相应加高以保持接近 3:2 的预览比例 */
  private bgTileH(): number {
    // 9 格（无 + 7 预设 + 自定义）在宽屏排一行、窄屏排三行，统一 76 高保持接近 3:2
    return 76;
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

  /**
   * 「自定义」图块：当前模式已选自定义图就显示这张图，否则显示取图提示。
   * 点它 = 从图库选图，选完直接替换**当前模式**的自定义图片。
   */
  @Builder BgCustomTile() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.hasCustomImage()) {
        Image('file://' + this.customPathFor(this.dark))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.isCustomSelected() ? 1 : 0.55)
      } else {
        Column({ space: 2 }) {
          Text('+')
            .fontSize(18)
            .fontColor(this.txt3())
          Text(this.t('自定义', 'Custom'))
            .fontSize(9)
            .fontColor(this.txt3())
        }
      }
      if (this.hasCustomImage()) {
        // 自定义图独有的角标：一眼区分「自己上传的」与内置预设
        Stack({ alignContent: Alignment.BottomStart }) {
          Row({ space: 4 }) {
            Column()
              .width(5)
              .height(5)
              .borderRadius(3)
              .backgroundColor(Color.White)
            Text(this.t('自定义', 'Mine'))
              .fontSize(9)
              .fontColor(Color.White)
          }
          .height(18)
          .padding({ left: 5, right: 7 })
          .borderRadius(9)
          .backgroundColor(this.dark ? 'rgba(0,0,0,0.55)' : 'rgba(15,23,42,0.55)')
          .margin({ left: 5, bottom: 5 })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
      if (this.isCustomSelected()) {
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
      this.pickBackground();
    })
  }

  /** 材质卡片（原独立分类，现作为「外观与主题」里的第二张卡片，控件与字段完全不变） */
  @Builder CardAppearanceMaterial() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.CardTitleWithHelp(this.t('材质', 'Material'), $r('sys.symbol.paintbrush'), HELP_MATERIAL)

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

  /** 设置列表里「外观与主题」的摘要：当前主题 + 当前模式背景 + 材质 */
  private appearanceSummary(): string {
    const theme: string = this.themeMode === ThemeMode.SYSTEM
      ? this.t('跟随系统', 'Follow system')
      : (this.dark ? this.t('深色', 'Dark') : this.t('浅色', 'Light'));
    const bg: string = this.bgPath.length === 0
      ? this.t('默认背景', 'Default bg')
      : (this.presetBgIndex() >= 0 ? this.t('预设背景', 'Preset bg') : this.t('自定义背景', 'Custom bg'));
    return theme + ' · ' + bg + ' · ' + this.matTypeName() + ' · ' + this.matLevelName();
  }

  /** 外观 · 背景：颜色模式 / 主题色 / 背景图（9 格）/ 模糊 / 明亮 —— 结构沿用改造前版本 */
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
          Text(this.themeMode === ThemeMode.SYSTEM
            ? this.t('跟随系统：', 'Follows system: ')
              + (this.dark ? this.t('深色', 'dark') : this.t('浅色', 'light'))
            : (this.dark ? this.t('深色模式', 'Dark mode') : this.t('浅色模式', 'Light mode')))
            .fontSize(11)
            .fontColor(this.txt3())
        }
        .width('100%')
        .margin({ top: 18 })

        if (this.bgCols() === 9) {
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
            Column() {
              this.BgCustomTile()
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
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 10 })

          Row({ space: 8 }) {
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
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 8 })

          Row({ space: 8 }) {
            Column() {
              this.BgPresetTile(5)
            }
            .layoutWeight(1)
            Column() {
              this.BgPresetTile(6)
            }
            .layoutWeight(1)
            Column() {
              this.BgCustomTile()
            }
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 8 })
        }

        // 两个滑杆属于常用外观调节，直接展示，不再折叠
        this.PctSliderRow(this.t('背景图模糊程度', 'Background blur'), 'blur')
        this.PctSliderRow(this.t('背景图明亮程度', 'Background brightness'), 'bright')
        // 遮罩程度由用户决定：喜欢背景质感就调低，需要更清楚的文字就调高
        this.PctSliderRow(this.t('背景遮罩程度', 'Background scrim'), 'scrim')
        this.PctSliderRow(this.t('卡片通透度', 'Card clarity'), 'card')
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
        this.CardTitleWithHelp(this.t('运行', 'Runtime'), $r('sys.symbol.gearshape'), HELP_RUNTIME)
        Row() {
          Column({ space: 3 }) {
            Text(this.t('后台保持运行', 'Keep running in background'))
              .fontSize(14)
              .fontColor(this.txt())
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
        this.CardTitleWithHelp(this.t('网络诊断', 'Network diagnostics'), $r('sys.symbol.info_circle'), HELP_DIAG)
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
    if (this.winW >= 900) {
      // 宽屏没有「二级页」概念：直接切右栏，别走 openSub 留下脏 settingsSub
      if (this.changelogOpen.length === 0) {
        this.changelogOpen = this.changelogDefaultOpen();
      }
      this.settingsPane = 6;
      this.settingsSub = -1;
      this.settingsStack = [];
      this.settingsScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      return;
    }
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
        Text(this.t('致敬与致谢', 'Credits & thanks'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txt2())
          .margin({ top: 4 })
        Text(this.t(
          '本应用的外观设计采用「星蚀显影波源半模态沉浸光感方案」制作，并借鉴了开源项目 OpenAuthenticator（作者 mroble，https://atomgit.com/mroble/Authenticator ）的界面与玻璃材质思路；实现过程中也得到了原作者在设计思路上的指导。本项目代码为独立实现，未复制该仓库源码。在此郑重致谢。',
          'The visual design of this app follows the immersive-material scheme documented as "Stellar Eclipse Wave-Source Semi-Modal Immersive Light" (星蚀显影波源半模态沉浸光感方案), and drew on the interface and glass-material approach of the open-source project OpenAuthenticator by mroble (https://atomgit.com/mroble/Authenticator); its author also kindly advised on the design. All code here is independently written; no source was copied from that repository. Sincere thanks to the author.'))
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
      .backgroundColor(this.modalVeil())
      .backgroundBlurStyle(this.cardBlurStyle(),
        { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
      .linearGradient({ angle: 145, colors: this.cardTint() })
      .borderRadius(20)
      .border({ width: 1, color: this.cardBorderColor() })
      .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
      .constraintSize({ maxWidth: 460 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.38)')
  }

  // ===== 设置：二级分类 =====
  private subTitle(id: number): string {
    if (id === 0) {
      return this.t('外观与主题', 'Appearance');
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

  /**
   * 进入设置二级页（手机布局）。
   * 从设置首页进入：记录首页滚动位置、清空浏览历史；
   * 已在二级页时再跳转（如「关于与更新」→「更新日志」）：把当前页压栈，保证逐级返回。
   */
  private openSub(id: number): void {
    if (this.settingsSub < 0) {
      try {
        this.settingsScrollCache = this.settingsScroller.currentOffset().yOffset;
      } catch (e) {
        this.settingsScrollCache = 0;
      }
      this.settingsStack = [];
    } else if (this.settingsSub !== id) {
      const frame: SettingsFrame = { id: this.settingsSub, scrollY: this.currentSettingsY() };
      this.settingsStack.push(frame);
    }
    this.settingsSub = id;
    if (id === 6 && this.changelogOpen === '') {
      this.changelogOpen = this.changelogDefaultOpen();
    }
    this.scrollSettingsTo(0);
  }

  /** 返回上一级：有浏览历史先逐级回退，否则回到设置首页并恢复首页滚动位置 */
  private closeSub(): void {
    const frame: SettingsFrame | undefined = this.settingsStack.pop();
    if (frame !== undefined) {
      this.settingsSub = frame.id;
      this.scrollSettingsTo(frame.scrollY);
      return;
    }
    this.settingsSub = -1;
    this.scrollSettingsTo(this.settingsScrollCache);
  }

  /** 当前设置页滚动位置（取不到时按 0 处理） */
  private currentSettingsY(): number {
    try {
      return this.settingsScroller.currentOffset().yOffset;
    } catch (e) {
      return 0;
    }
  }

  /**
   * 恢复设置页滚动位置。
   * 页面内容高度变化后首帧可能还没完成布局（此时 scrollTo 会被夹到较小的可滚动范围），
   * 因此在 0 / 90 / 220ms 各校正一次，保证回到原来的滚动位置。
   */
  private scrollSettingsTo(y: number): void {
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

  /**
   * 系统返回事件（返回键 / 屏幕左右边缘侧滑）统一入口。
   * 覆盖「来源分组管理页」与「设置二级页」两处覆盖层/子页：
   * 都复用页面内返回按钮的同一套逐级返回逻辑（srcMgrBack / closeSub），
   * 手势与按钮行为一致；其他页面不拦截，保持原有退出行为。
   */
  onBackPress(): boolean {
    // 功能说明弹窗：返回键优先关闭弹窗（页面输入与滚动位置不变）
    if (this.helpKey.length > 0) {
      this.closeHelp();
      return true;
    }
    if (this.srcMgr) {
      this.srcMgrBack();
      return true;
    }
    if (this.winW < 900 && this.curTab === 3 && this.settingsSub >= 0) {
      this.closeSub();
      return true;
    }
    return false;
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
          .fontWeight(this.winW >= 900 && this.settingsPane === id ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.winW >= 900 && this.settingsPane === id ? this.accentText() : this.txt())
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
    // 宽屏才有「当前分类」概念：选中行给一点主题色底与主题色标题，避免左菜单看不出选中项
    .backgroundColor(this.winW >= 900 && this.settingsPane === id ? this.accentRgba(0.26) : this.soft())
    .margin({ top: 8 })
    .onClick(() => {
      if (this.winW >= 900) {
        // 宽屏：左侧菜单 + 右侧内容，原地切换
        this.settingsPane = id;
        this.settingsSub = -1;
        this.settingsStack = [];
        // 更新日志在宽屏没有二级页，进入时也要初始化展开项
        if (id === 6 && this.changelogOpen.length === 0) {
          this.changelogOpen = this.changelogDefaultOpen();
        }
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
      Text('‹')
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
          this.SettingsRow(2, $r('sys.symbol.icloud'),
            this.t('订阅与上传', 'Subscription upload'),
            this.etEnabled ? this.t('自动上传已开启', 'Auto upload on') : this.t('自动上传已关闭', 'Auto upload off'))
          this.SettingsRow(3, $r('sys.symbol.gearshape'),
            this.t('运行与网络', 'Runtime & network'),
            this.keepAlive ? this.t('后台保活已开启', 'Background keep-alive on') : this.t('后台保活已关闭', 'Background keep-alive off') +
              this.t(' · 网络诊断与导出', ' · diagnostics & export'))
          this.SettingsRow(0, $r('sys.symbol.paintbrush'),
            this.t('外观与主题', 'Appearance & theme'),
            this.appearanceSummary())
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
        this.SettingsRow(2, $r('sys.symbol.icloud'),
          this.t('订阅与上传', 'Subscription upload'),
          this.etEnabled ? this.t('自动上传已开启', 'Auto upload on') : this.t('自动上传已关闭', 'Auto upload off'))
        this.SettingsRow(3, $r('sys.symbol.gearshape'),
          this.t('运行与网络', 'Runtime & network'),
          this.keepAlive ? this.t('后台保活已开启', 'Background keep-alive on') : this.t('后台保活已关闭', 'Background keep-alive off') +
            this.t(' · 网络诊断与导出', ' · diagnostics & export'))
        this.SettingsRow(0, $r('sys.symbol.paintbrush'),
          this.t('外观与主题', 'Appearance & theme'),
          this.appearanceSummary())
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
      // 外观与主题：恢复成「外观」卡片 + 独立的「材质」卡片（材质不再单独占菜单项）
      this.CardAppearanceBackground()
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
        // 平板/电脑：左侧菜单 + 右侧内容；整体限宽居中，两侧与两栏之间都留出阴影空间
        Row({ space: 8 }) {
          Scroll() {
            Column() {
              this.SettingsMenu()
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: this.contentTop(), bottom: this.pageBottomPad() })
          }
          .width(300)
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.TopStart)

          Scroll(this.settingsScroller) {
            Column({ space: 12 }) {
              this.CatBody()
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: this.contentTop(), bottom: this.pageBottomPad() })
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
        .padding({ left: 24, right: 24 })
        .alignItems(VerticalAlign.Top)
        .constraintSize({ maxWidth: 1320 })
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
        // 与宽屏两个 Scroll 保持一致：内容不足一屏时顶部对齐。
        // 否则 Scroll 会把短内容（如「语言」详情页）整体垂直居中，
        // 导致返回按钮随页面内容高度上下浮动。
        .align(Alignment.TopStart)
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
        this.CardTitleWithHelp(this.t('订阅上传', 'Subscription upload'), $r('sys.symbol.icloud'), HELP_UPLOAD)

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
    .borderRadius(fill ? 0 : 20)
    .border({ width: fill ? 0 : 1, color: fill ? this.lineC() : this.cardBorderColor() })
    .shadow(fill ? { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 }
      : { radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 0 })
    .width('100%')
    }
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
        Column() {
        this.ProgressStrip(1)
        if (this.pcMsg.length > 0) {
        Text(this.pcMsg)
        .fontSize(10)
        .fontColor(this.txt3())
        .margin({ top: 6 })
        }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ bottom: 10 })
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
        // 与扫描页共用同一份状态：改完立即持久化，扫描页的地区测速会读到新值
        this.scheduleScanSave();
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

        Row({ space: 14 }) {
          ForEach(this.groupCols(), (col: RegionGroup[], ci: number) => {
            Column() {
              ForEach(col, (g: RegionGroup) => {
                this.GroupRow(g)
              }, (g: RegionGroup) => 'c' + ci.toString() + '#' + g.colo + '#' + g.count.toString() + '#' +
                (this.expandedColos.indexOf(g.colo) >= 0 ? '1' : '0'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Start)
          }, (col: RegionGroup[], ci: number) => 'gc' + ci.toString() + '#' + col.length.toString())
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)


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

        if (this.scanning && this.taskKind === 3) {
          Column() {
            this.ProgressStrip(2)
          }
          .width('100%')
          .margin({ bottom: 10 })
        } else if (this.scanning) {
          Text(this.t('第一轮扫描/预检进行中 · 测速在筛选完成后自动开始', 'Round 1 scanning/pre-check running · the speed test starts automatically afterwards'))
            .fontSize(11)
            .fontColor(this.txt3())
            .width('100%')
            .margin({ bottom: 10 })
        }

        Row() {
          Text(this.scanning && this.taskKind === 3
            ? this.t('测速进行中…', 'Speed test in progress…')
            : (this.scanning ? this.t('扫描进行中…', 'Scanning…') : this.t('重新测速', 'Re-run speed test')))
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
            Text(this.t('还没有测速结果', 'No speed test results yet'))
              .fontSize(15)
              .fontColor(this.txt2())
            Text(this.t('回到「扫描」页开始优选', 'Go to the "Scan" tab to start selection'))
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

  /** 地区分组按列独立流式：每列各自排布，展开某张卡只把本列下面的卡片推下去 */
  private groupCols(): RegionGroup[][] {
    const n: number = this.winW >= 900 ? 3 : (this.winW >= 600 ? 2 : 1);
    const out: RegionGroup[][] = [];
    for (let i = 0; i < n; i++) {
      out.push([]);
    }
    for (let k = 0; k < this.groups.length; k++) {
      out[k % n].push(this.groups[k]);
    }
    return out;
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

  // ——————————————————— 三种来源导入（链接 / 文件 / 文本） ———————————————————
  // 三种方式都只做「取得文本」这一件事，格式校验与 IP 类型判定统一交给 Sources.parseImport：
  // 它按内容实际格式分类，混合内容只收当前族并逐行给出拒绝原因。

  /** 从链接取回文本（沿用原有超时/错误处理，不扩大格式支持） */
  private async fetchUrlText(urlIn: string): Promise<string> {
    const url: string = urlIn.trim();
    if (url.length === 0) {
      throw new Error(this.t('请先填写链接', 'Enter a link first'));
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw new Error(this.t('链接需以 http(s):// 开头', 'The link must start with http(s)://'));
    }
    const req = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 20000,
        usingCache: false
      });
      req.destroy();
      if (resp.responseCode !== 200) {
        throw new Error(this.t('拉取失败：HTTP ', 'Fetch failed: HTTP ') + resp.responseCode.toString());
      }
      const text: string = typeof resp.result === 'string' ? resp.result as string : '';
      if (text.trim().length === 0) {
        throw new Error(this.t('链接内容为空', 'The link returned no content'));
      }
      return text;
    } catch (err) {
      try {
        req.destroy();
      } catch (e) {
      }
      const e2: BusinessError = err as BusinessError;
      throw new Error(e2.message.length > 0 ? e2.message : this.t('拉取失败', 'Fetch failed'));
    }
  }

  /** 拉取社区段库到指定 IP 族（沿用原有链接；段库按族独立保存，互不覆盖） */
  private async fetchCommunity(fam: number): Promise<boolean> {
    const url: string = fam === SRC_FAM_V6 ? LIB_SOURCES[2].url : LIB_SOURCES[3].url;
    this.srcMgrBusy = true;
    try {
      const text: string = await this.fetchUrlText(url);
      await Sources.setCommunityText(fam, text);
      this.srcRev++;
      const n: number = Sources.communityLineCount(fam);
      if (n === 0) {
        const msg: string = this.t('段库里没有符合 ', 'No valid ') + this.famText(fam) + this.t(' 的网段', ' ranges in the fetched content');
        this.toast(msg);
        this.addLog(msg + '：' + url);
        return false;
      }
      const ok: string = this.t('已更新社区段库：', 'Community ranges updated: ') + n.toString() + this.t(' 行（', ' lines (') + this.famText(fam) + '）';
      this.toast(ok);
      this.addLog(ok);
      return true;
    } catch (err) {
      const e2: BusinessError = err as BusinessError;
      this.toast(this.t('拉取失败：', 'Fetch failed: ') + e2.message);
      this.addLog(this.t('社区段库拉取失败：', 'Community fetch failed: ') + e2.message);
      return false;
    } finally {
      this.srcMgrBusy = false;
    }
  }

  /** 选文件并读成文本（沿用原有 DocumentViewPicker + fileIo + utf-8 解码） */
  private async pickFileText(): Promise<string> {
    if (this.ctx === undefined || this.ctx === null) {
      throw new Error(this.t('应用上下文未就绪', 'App context not ready'));
    }
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    const dp = new picker.DocumentViewPicker(this.ctx);
    const uris: string[] = await dp.select(opts);
    if (uris === undefined || uris === null || uris.length === 0) {
      return '';
    }
    const uri: string = uris[0];
    const idx: number = uri.lastIndexOf('/');
    this.lastPickName = idx >= 0 ? uri.substring(idx + 1) : uri;
    const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(f.fd);
      if (stat.size <= 0) {
        throw new Error(this.t('文件为空', 'The file is empty'));
      }
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      const decoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeToString(new Uint8Array(buf));
      if (text.trim().length === 0) {
        throw new Error(this.t('文件里没有内容', 'The file has no content'));
      }
      return text;
    } finally {
      fileIo.closeSync(f);
    }
  }

  // ——————————————————— 来源分组管理页：状态与取值 ———————————————————

  private lastPickName: string = '';

  private openSrcMgr(): void {
    this.srcMgr = true;
    this.srcMgrView = 0;
    this.srcMgrGid = '';
    this.srcMgrMsg = '';
    this.srcRename = false;
    this.srcConfirmGroup = false;
    this.srcConfirmSrc = '';
    this.srcLinkDraft = '';
    this.srcPasteDraft = '';
    this.srcShowQuarantine = false;
    this.srcEditSid = '';
    this.srcEditDraft = '';
  }

  /** 返回/关闭：在二级视图里先回列表，列表根视图才真正关闭 */
  private closeSrcMgr(): void {
    this.srcConfirmSrc = '';
    this.srcEditSid = '';
    this.srcEditDraft = '';
    if (this.srcMgrView !== 0) {
      this.srcMgrView = 0;
      this.srcMgrGid = '';
      this.srcRename = false;
      this.srcConfirmGroup = false;
      this.srcMgrMsg = '';
      return;
    }
    this.srcMgr = false;
  }

  /**
   * 逐级返回（与系统返回手势同一入口）：
   * 编辑来源 / 添加链接 / 添加文本 → 分组详情 → 分组列表 → 关闭面板。
   */
  private srcMgrBack(): void {
    this.srcConfirmSrc = '';
    if (this.srcMgrView === 4) {
      this.srcMgrView = 1;
      this.srcEditSid = '';
      this.srcEditDraft = '';
      this.srcMgrMsg = '';
      return;
    }
    if (this.srcMgrView === 2 || this.srcMgrView === 3) {
      this.srcMgrView = 1;
      this.srcMgrMsg = '';
      return;
    }
    if (this.srcMgrView === 1) {
      this.srcMgrView = 0;
      this.srcMgrGid = '';
      this.srcRename = false;
      this.srcConfirmGroup = false;
      this.srcMgrMsg = '';
      return;
    }
    this.srcMgr = false;
  }

  /** 宽屏面板高度：按当前视图取，列表页更矮，避免大面积留白 */
  private srcMgrPanelH(): number {
    if (this.srcMgrView === 0) {
      return 400;
    }
    if (this.srcMgrView === 1) {
      return 540;
    }
    return 470;
  }

  /** 进入来源内容编辑（官方段库 / 社区段库不在分组内，天然没有编辑入口） */
  private openSourceEdit(sid: string): void {
    const src: SourceItem | undefined = Sources.findSource(this.srcMgrGid, sid);
    if (src === undefined) {
      this.srcMgrMsg = this.t('来源不存在', 'Source not found');
      return;
    }
    this.srcEditSid = sid;
    this.srcEditDraft = src.lines.join('\n');
    this.srcMgrView = 4;
    this.srcMgrMsg = '';
    this.srcConfirmSrc = '';
    this.srcRename = false;
  }

  /** 编辑视图标题下的来源名称 */
  private editSourceName(): string {
    this.srcTick();
    const src: SourceItem | undefined = Sources.findSource(this.srcMgrGid, this.srcEditSid);
    if (src === undefined) {
      return '';
    }
    return Sources.kindLabel(src.kind) + ' · ' + src.name;
  }

  /** 保存来源内容：重新按当前 IP 版本校验，改/删段落都走同一条解析路径 */
  private async saveSourceEdit(): Promise<void> {
    if (this.srcEditSid.length === 0) {
      return;
    }
    const text: string = this.srcEditDraft.trim();
    if (text.length === 0) {
      this.srcMgrMsg = this.t('内容为空：至少保留一行有效网段；若要清空请直接删除该来源',
        'Empty content: keep at least one valid range, or delete this source instead');
      return;
    }
    const r: AddSourceResult = Sources.applyText(this.srcMgrGid, this.srcEditSid, text, '');
    await Sources.save();
    this.srcRev++;
    if (!r.ok) {
      let why: string = this.rejectHint(r.sampleRejects, 2);
      if (why.length === 0) {
        why = r.error;
      }
      this.srcMgrMsg = this.t('没有保存：', 'Not saved: ') + why;
      this.toast(this.t('没有保存：内容里没有符合当前 IP 版本的网段', 'Not saved: no ranges matching the current IP version'));
      this.hlog('[SRC] edit sid=' + this.srcEditSid + ' gid=' + this.srcMgrGid + ' ok=0 accepted=0 err=' + r.error);
      return;
    }
    let msg: string = this.t('已保存来源内容：', 'Source saved: ') + r.accepted.toString() + this.t(' 行有效地址', ' valid addresses');
    if (r.duplicates > 0) {
      msg += this.t('，跳过重复 ', ', skipped ') + r.duplicates.toString() + this.t(' 行', ' duplicates');
    }
    if (r.rejected > 0) {
      msg += this.t('，拒绝 ', ', rejected ') + r.rejected.toString() + this.t(' 行', ' lines');
    }
    this.srcMgrMsg = msg;
    this.addLog(msg);
    this.hlog('[SRC] edit sid=' + this.srcEditSid + ' gid=' + this.srcMgrGid + ' ok=1 accepted=' +
      r.accepted.toString() + ' rejected=' + r.rejected.toString() + ' dup=' + r.duplicates.toString());
    if (this.curSel() === this.srcMgrGid) {
      const e: string = this.applySelection(true);
      if (e.length > 0) {
        this.srcMgrMsg += '｜' + e;
      }
    }
    this.srcMgrView = 1;
    this.srcEditSid = '';
    this.srcEditDraft = '';
  }

  private openGroup(gid: string): void {
    this.srcMgrGid = gid;
    this.srcMgrView = 1;
    this.srcMgrMsg = '';
    this.srcRename = false;
    this.srcConfirmGroup = false;
    this.srcConfirmSrc = '';
    this.srcNameDraft = this.groupNameOf(gid);
  }

  private openAddView(view: number): void {
    this.srcMgrView = view;
    this.srcMgrMsg = '';
    this.srcConfirmSrc = '';
    this.srcEditSid = '';
    this.srcEditDraft = '';
    if (view === 2) {
      this.srcLinkDraft = '';
    } else if (view === 3) {
      this.srcPasteDraft = '';
    }
  }

  private groupNameOf(gid: string): string {
    const g: SourceGroup | undefined = Sources.findGroup(gid);
    if (g === undefined) {
      return '';
    }
    return g.name;
  }

  private groupStatText(gid: string): string {
    this.srcTick();
    const g: SourceGroup | undefined = Sources.findGroup(gid);
    if (g === undefined) {
      return '';
    }
    const st: GroupStats = Sources.stats(g);
    let out: string = st.sourceCount.toString() + this.t(' 个来源 · 启用 ', ' sources · enabled ');
    out += st.enabledCount.toString() + this.t(' · 共 ', ' · total ');
    out += st.lineCount.toString() + this.t(' 行', ' lines');
    if (st.failedCount > 0) {
      out += this.t(' · 失败 ', ' · failed ') + st.failedCount.toString();
    }
    return out;
  }

  private sourceStatText(s: SourceItem): string {
    this.srcTick();
    if (s.status === SRC_STATUS_FAILED) {
      return s.error.length > 0 ? s.error : this.t('导入失败', 'Import failed');
    }
    let out: string = s.lines.length.toString() + this.t(' 行有效地址', ' valid addresses');
    if (s.rejectedCount > 0) {
      out += this.t('；拒绝 ', '; rejected ') + s.rejectedCount.toString() + this.t(' 行（类型/格式不符）', ' lines (wrong type or format)');
    }
    if (s.ref.length > 0) {
      out = s.ref + ' · ' + out;
    }
    return out;
  }

  private choiceStatText(ch: SourceChoice): string {
    this.srcTick();
    if (ch.builtin) {
      if (ch.id === SRC_ID_OFFICIAL) {
        return this.t('内置段库 · 只读', 'Built-in list · read-only');
      }
      const n: number = ch.stats.lineCount;
      return n > 0 ? (n.toString() + this.t(' 行 · 只读', ' lines · read-only')) : this.t('尚未更新段库', 'Not updated yet');
    }
    if (ch.stats.sourceCount === 0 && ch.stats.lineCount === 0) {
      return this.t('未添加来源', 'No sources');
    }
    return ch.stats.sourceCount.toString() + this.t(' 个来源 · ', ' sources · ') + ch.stats.lineCount.toString() + this.t(' 行', ' lines');
  }

  private curGroupSources(): SourceItem[] {
    this.srcTick();
    const g: SourceGroup | undefined = Sources.findGroup(this.srcMgrGid);
    if (g === undefined) {
      return [];
    }
    return g.sources;
  }

  private builtinChoices(): SourceChoice[] {
    return Sources.choices(this.curFam()).filter((ch: SourceChoice) => ch.builtin);
  }

  private customChoices(): SourceChoice[] {
    return Sources.choices(this.curFam()).filter((ch: SourceChoice) => !ch.builtin);
  }

  /** 当前卡片下方的来源说明（随选中项与来源数量变化） */
  private sourceHintText(): string {
    this.srcTick();
    const fam: number = this.curFam();
    const sel: string = this.curSel();
    if (sel === SRC_ID_OFFICIAL) {
      return this.t('内置官方段库，受保护不可编辑；点「编辑」可管理自定义分组', 'Built-in official ranges are protected; tap "Edit" to manage custom groups');
    }
    if (sel === SRC_ID_COMMUNITY) {
      const n: number = Sources.communityLineCount(fam);
      if (n === 0) {
        return this.t('段库为空，切换时会自动拉取一次；也可点「编辑」手动更新', 'Empty; it is fetched when selected, or update it from "Edit"');
      }
      return this.famText(fam) + this.t(' 社区段库：', ' community ranges: ') + n.toString() + this.t(' 行', ' lines');
    }
    const g: SourceGroup | undefined = Sources.findGroup(sel);
    if (g === undefined) {
      return this.t('所选分组已删除，将回退到官方 IP 段', 'The selected group was deleted; falling back to official ranges');
    }
    const st: GroupStats = Sources.stats(g);
    let out: string = this.famText(fam) + this.t(' 分组「', ' group "') + g.name + this.t('」：', '": ');
    out += st.enabledCount.toString() + '/' + st.sourceCount.toString() + this.t(' 个来源启用 · ', ' sources enabled · ');
    out += st.lineCount.toString() + this.t(' 行', ' lines');
    return out;
  }

  private srcMgrTitle(): string {
    this.srcTick();
    if (this.srcMgrView === 1) {
      return this.groupNameOf(this.srcMgrGid);
    }
    if (this.srcMgrView === 2) {
      return this.t('添加链接来源', 'Add link source');
    }
    if (this.srcMgrView === 3) {
      return this.t('添加文本来源', 'Add text source');
    }
    if (this.srcMgrView === 4) {
      return this.t('编辑来源', 'Edit source');
    }
    return this.t('来源分组管理', 'Source groups');
  }

  private srcMgrSub(): string {
    this.srcTick();
    if (this.srcMgrView === 1) {
      return this.groupStatText(this.srcMgrGid);
    }
    if (this.srcMgrView === 2) {
      return this.t('只允许当前 IP 版本的网段', 'Only ranges of the current IP version');
    }
    if (this.srcMgrView === 3) {
      return this.t('支持 # 注释、CIDR、IP:端口，可混排', 'Comments, CIDR and IP:port are supported');
    }
    if (this.srcMgrView === 4) {
      return this.t('改完保存会按当前 IP 版本重新校验', 'Saving revalidates against the current IP version');
    }
    return this.famText(this.curFam()) + this.t(' 来源独立保存，V4 / V6 互不影响', ' sources are stored separately; V4/V6 never mix');
  }

  private linkNameOf(url: string): string {
    let out: string = url;
    const p: number = out.indexOf('://');
    if (p >= 0) {
      out = out.substring(p + 3);
    }
    const q: number = out.indexOf('?');
    if (q >= 0) {
      out = out.substring(0, q);
    }
    if (out.length > 48) {
      out = out.substring(0, 48) + '…';
    }
    return out;
  }

  private rejectHint(rejects: SourceReject[], max: number): string {
    if (rejects.length === 0) {
      return '';
    }
    let out: string = '';
    const n: number = rejects.length < max ? rejects.length : max;
    for (let i = 0; i < n; i++) {
      out += (out.length > 0 ? '\n' : '') + rejects[i].line + ' — ' + rejects[i].reason;
    }
    return out;
  }

  // ——————————————————— 来源分组管理页：业务动作（全部走 Sources 的业务层保护） ———————————————————

  private async createGroupNow(): Promise<void> {
    const name: string = this.srcNewName.trim();
    if (name.length === 0) {
      this.toast(this.t('请输入分组名称', 'Enter a group name'));
      return;
    }
    const r: OpResult = Sources.createGroup(name, this.curFam());
    if (!r.ok) {
      this.srcMgrMsg = r.error;
      this.toast(r.error);
      return;
    }
    await Sources.save();
    this.srcRev++;
    this.srcNewName = '';
    this.srcMgrGid = r.groupId;
    this.srcMgrView = 1;
    this.srcNameDraft = this.groupNameOf(r.groupId);
    this.srcMgrMsg = this.t('已创建分组「', 'Created group "') + this.srcNameDraft + '」';
  }

  private async commitRename(): Promise<void> {
    const name: string = this.srcNameDraft.trim();
    const old: string = this.groupNameOf(this.srcMgrGid);
    const r: OpResult = Sources.renameGroup(this.srcMgrGid, name);
    if (!r.ok) {
      this.srcMgrMsg = r.error;
      this.toast(r.error);
      return;
    }
    await Sources.save();
    this.srcRename = false;
    this.srcRev++;
    this.srcMgrMsg = this.t('已改名为「', 'Renamed to "') + name + this.t('」（原「', '" (was "') + old + '」）';
    this.addLog(this.srcMgrMsg);
  }

  private async deleteGroupNow(): Promise<void> {
    const gid: string = this.srcMgrGid;
    const fam: number = this.curFam();
    const label: string = this.groupNameOf(gid);
    const inUse: boolean = Sources.selected(fam) === gid;
    const r: OpResult = Sources.deleteGroup(gid);
    if (!r.ok) {
      this.srcMgrMsg = r.error;
      this.toast(r.error);
      return;
    }
    this.hlog('[SRC] deleteGroup id=' + gid + ' fam=' + fam.toString() + ' inUse=' + (inUse ? '1' : '0') +
      ' left=' + Sources.groupsOf(fam).length.toString());
    if (inUse) {
      await Sources.setSelected(fam, SRC_ID_OFFICIAL);
    }
    await Sources.save();
    this.srcMgrView = 0;
    this.srcMgrGid = '';
    this.srcConfirmGroup = false;
    this.srcRev++;
    let msg: string = this.t('已删除分组「', 'Deleted group "') + label + '」';
    if (inUse) {
      const e: string = this.applySelection(true);
      msg += this.t('，当前选择已切回官方 IP 段', '; the current selection fell back to official ranges');
      if (e.length > 0) {
        msg += '｜' + e;
      }
    }
    if (this.scanning) {
      msg += this.t('（正在进行的扫描仍使用删除前的快照，下次扫描生效）', ' (the running scan still uses the pre-delete snapshot; it applies from the next scan)');
    }
    this.srcMgrMsg = msg;
    this.toast(msg);
    this.addLog(msg);
  }

  private async toggleSource(sid: string): Promise<void> {
    const s: SourceItem | undefined = Sources.findSource(this.srcMgrGid, sid);
    if (s === undefined) {
      return;
    }
    const r: OpResult = Sources.setSourceEnabled(this.srcMgrGid, sid, !s.enabled);
    if (!r.ok) {
      this.toast(r.error);
      return;
    }
    await Sources.save();
    this.srcRev++;
    this.hlog('[SRC] toggle sid=' + sid + ' enabled=' + (s.enabled ? '0' : '1'));
    if (this.curSel() === this.srcMgrGid) {
      this.applySelection(true);
    }
  }

  /** 删除单条来源：两次点击确认（只删这条，不动整个分组） */
  private async removeSource(sid: string): Promise<void> {
    if (this.srcConfirmSrc !== sid) {
      this.srcConfirmSrc = sid;
      return;
    }
    const r: OpResult = Sources.deleteSource(this.srcMgrGid, sid);
    this.srcConfirmSrc = '';
    if (!r.ok) {
      this.toast(r.error);
      return;
    }
    await Sources.save();
    this.srcRev++;
    this.hlog('[SRC] removeSource sid=' + sid + ' gid=' + this.srcMgrGid);
    let msg: string = this.t('已删除该来源', 'Source removed');
    if (this.curSel() === this.srcMgrGid) {
      const e: string = this.applySelection(true);
      if (e.length > 0) {
        msg += '｜' + e;
      }
    }
    this.srcMgrMsg = msg;
  }

  /** 提交一条来源：成功/部分成功/失败都留痕，失败来源不会被当成有效数据 */
  private async commitSource(kind: string, ref: string, name: string, text: string, failure: string): Promise<boolean> {
    const r: AddSourceResult = Sources.addSource(this.srcMgrGid, kind, ref, name, text, failure);
    await Sources.save();
    this.srcRev++;
    let msg: string = '';
    if (failure.length > 0) {
      msg = this.t('已记录失败来源：', 'Recorded a failed source: ') + failure;
    } else {
      if (r.accepted > 0) {
        msg = this.t('已添加来源：', 'Added source: ') + r.accepted.toString() + this.t(' 行有效地址', ' valid addresses');
      } else {
        msg = this.t('没有添加有效地址', 'No valid addresses added');
      }
      if (r.duplicates > 0) {
        msg += this.t('，跳过重复 ', ', skipped ') + r.duplicates.toString() + this.t(' 行', ' duplicates');
      }
      if (r.rejected > 0) {
        msg += this.t('，拒绝 ', ', rejected ') + r.rejected.toString() + this.t(' 行', ' lines');
        const hint: string = this.rejectHint(r.sampleRejects, 3);
        if (hint.length > 0) {
          msg += '：\n' + hint;
        }
      }
    }
    if (!r.ok && r.error.length > 0) {
      msg += '\n' + r.error;
    }
    this.srcMgrMsg = msg;
    this.addLog(msg);
    if (r.ok) {
      this.toast(this.t('来源已添加', 'Source added'));
    } else {
      this.toast(failure.length > 0 ? this.t('导入失败，已记录到来源列表', 'Import failed; recorded in the source list') : this.t('没有可用数据，已记录到来源列表', 'No usable data; recorded in the source list'));
    }
    this.hlog('[SRC] add kind=' + kind + ' fam=' + this.curFam().toString() + ' ok=' + (r.ok ? '1' : '0') +
      ' accepted=' + r.accepted.toString() + ' rejected=' + r.rejected.toString() +
      ' dup=' + r.duplicates.toString() + ' err=' + r.error);
    if (this.curSel() === this.srcMgrGid) {
      this.applySelection(true);
    }
    return r.ok;
  }

  /** 当前分组里的链接来源 */
  private curGroupLinks(): SourceItem[] {
    this.srcTick();
    const out: SourceItem[] = [];
    const list: SourceItem[] = this.curGroupSources();
    for (let i = 0; i < list.length; i++) {
      if (list[i].kind === SRC_KIND_LINK) {
        out.push(list[i]);
      }
    }
    return out;
  }

  private groupLinkCount(): number {
    this.srcTick();
    return this.curGroupLinks().length;
  }

  /**
   * 一键更新单条链接来源：重新拉取 → 按当前 IP 版本解析 → 成功才替换内容；
   * 拉取失败时把该来源标为失败（保留在列表里，绝不把它当成有效数据）。
   */
  private async refreshLink(sid: string, silent: boolean): Promise<boolean> {
    const s: SourceItem | undefined = Sources.findSource(this.srcMgrGid, sid);
    if (s === undefined || s.kind !== SRC_KIND_LINK) {
      return false;
    }
    if (!silent) {
      this.srcMgrBusy = true;
      this.srcMgrMsg = this.t('正在更新链接…', 'Refreshing link…');
    }
    let text: string = '';
    let failure: string = '';
    try {
      text = await this.fetchUrlText(s.ref);
    } catch (err) {
      const e2: BusinessError = err as BusinessError;
      failure = e2.message.length > 0 ? e2.message : this.t('拉取失败', 'Fetch failed');
    }
    const r: AddSourceResult = Sources.applyText(this.srcMgrGid, sid, text, failure);
    await Sources.save();
    this.srcRev++;
    if (!silent) {
      this.srcMgrBusy = false;
    }
    this.hlog('[SRC] refresh sid=' + sid + ' ok=' + (r.ok ? '1' : '0') + ' accepted=' + r.accepted.toString() +
      ' rejected=' + r.rejected.toString() + ' err=' + r.error);
    if (this.curSel() === this.srcMgrGid) {
      this.applySelection(true);
    }
    if (!silent) {
      const msg: string = r.ok ?
        (this.t('链接已更新：', 'Link refreshed: ') + r.accepted.toString() + this.t(' 行有效地址', ' valid addresses')) :
        (this.t('链接更新失败：', 'Link refresh failed: ') + (r.error.length > 0 ? r.error : this.t('没有可用数据', 'no usable data')));
      this.srcMgrMsg = msg;
      this.toast(msg);
      this.addLog(msg);
    }
    return r.ok;
  }

  /** 一键更新分组内全部链接来源（逐条进行，最后汇总成功/失败） */
  private async refreshAllLinks(): Promise<void> {
    if (this.srcMgrBusy) {
      return;
    }
    const links: SourceItem[] = this.curGroupLinks();
    if (links.length === 0) {
      this.toast(this.t('这个分组没有链接来源', 'This group has no link sources'));
      return;
    }
    this.srcMgrBusy = true;
    let ok: number = 0;
    let bad: number = 0;
    let lines: number = 0;
    for (let i = 0; i < links.length; i++) {
      this.srcMgrMsg = this.t('正在更新链接 ', 'Refreshing links ') + (i + 1).toString() + '/' + links.length.toString();
      const good: boolean = await this.refreshLink(links[i].id, true);
      if (good) {
        ok++;
      } else {
        bad++;
      }
    }
    this.srcMgrBusy = false;
    const grp: SourceGroup | undefined = Sources.findGroup(this.srcMgrGid);
    if (grp !== undefined) {
      const st: GroupStats = Sources.stats(grp);
      lines = st.lineCount;
    }
    const msg: string = this.t('链接更新完成：成功 ', 'Refresh done: ') + ok.toString() +
      this.t(' 条 / 失败 ', ' ok / ') + bad.toString() + this.t(' 条，分组共 ', ' failed, group has ') +
      lines.toString() + this.t(' 行', ' lines');
    this.srcMgrMsg = msg;
    this.toast(msg);
    this.addLog(msg);
    this.srcRev++;
  }

  private async addLinkSource(): Promise<void> {
    const url: string = this.srcLinkDraft.trim();
    if (url.length === 0) {
      this.toast(this.t('请先填写链接', 'Enter a link first'));
      return;
    }
    this.srcMgrBusy = true;
    let text: string = '';
    let failure: string = '';
    try {
      text = await this.fetchUrlText(url);
    } catch (err) {
      const e2: BusinessError = err as BusinessError;
      failure = e2.message;
    }
    this.srcMgrBusy = false;
    const ok: boolean = await this.commitSource(SRC_KIND_LINK, url, this.linkNameOf(url), text, failure);
    if (ok) {
      this.srcLinkDraft = '';
      this.srcMgrView = 1;
    }
  }

  private async addTextSource(): Promise<void> {
    const text: string = this.srcPasteDraft;
    if (text.trim().length === 0) {
      this.toast(this.t('请先粘贴内容', 'Paste some content first'));
      return;
    }
    const lineCount: number = text.split('\n').filter((l: string) => l.trim().length > 0).length;
    const name: string = this.t('粘贴 ', 'Pasted ') + lineCount.toString() + this.t(' 行', ' lines');
    const ok: boolean = await this.commitSource(SRC_KIND_TEXT, '', name, text, '');
    if (ok) {
      this.srcPasteDraft = '';
      this.srcMgrView = 1;
    }
  }

  private async addFileSource(): Promise<void> {
    let text: string = '';
    let failure: string = '';
    let name: string = '';
    try {
      text = await this.pickFileText();
      name = this.lastPickName;
    } catch (err) {
      const e2: BusinessError = err as BusinessError;
      failure = e2.message;
      name = this.lastPickName.length > 0 ? this.lastPickName : this.t('文件', 'File');
    }
    if (failure.length === 0 && text.length === 0) {
      return;
    }
    const ok: boolean = await this.commitSource(SRC_KIND_FILE, name, name, text, failure);
    if (ok) {
      this.srcMgrView = 1;
    }
  }

  private async runSelfCheck(): Promise<void> {
    const lines: string[] = Sources.selfCheck();
    let pass: number = 0;
    let fail: number = 0;
    for (let i = 0; i < lines.length; i++) {
      this.addLog(lines[i]);
      this.hlog('[SRCCHECK] ' + lines[i]);
      if (lines[i].startsWith('PASS')) {
        pass++;
      } else {
        fail++;
      }
    }
    this.srcRev++;
    const msg: string = this.t('逻辑自检：通过 ', 'Logic self-check: passed ') + pass.toString() + this.t(' 项 / 失败 ', ' / failed ') + fail.toString() + this.t(' 项', ' items');
    this.hlog('[SRCCHECK] total pass=' + pass.toString() + ' fail=' + fail.toString());
    this.srcMgrMsg = msg;
    this.toast(msg);
  }

  private async clearQuarantineNow(): Promise<void> {
    await Sources.clearQuarantine();
    this.srcShowQuarantine = false;
    this.srcRev++;
    this.srcMgrMsg = this.t('已清空隔离区', 'Quarantine cleared');
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
}


/** ===== 滚动边缘渐变模糊（linearGradientBlur）参数 ===== */
/** 顶部模糊带高度（vp）：沿用改造前顶部条带覆盖到标题区的 118vp */
const LG_TOP_BAND: number = 118;
/** 底部模糊带高度（vp）：沿用改造前底部条带覆盖到导航区的 106.7vp */
const LG_BOTTOM_BAND: number = 106.7;
/** 最大模糊半径（vp）：与原顶部条带峰值 22vp 对齐，保证观感不突增 */
interface CardClearK {
  alpha: number;
  lift: number;
}

const LG_BLUR_MAX: number = 22;
/** 底部峰值折算比例：原底部条带峰值 16vp / 顶部 22vp，使一次调用同时还原两端强度 */
const LG_BOTTOM_RATIO: number = 16 / 22;

