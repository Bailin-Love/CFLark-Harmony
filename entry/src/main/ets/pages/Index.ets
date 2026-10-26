/**
 * CFLark 主页面（单页 + 底部两个页签）
 *
 * 壳层：Stack(渐变背景 + Tabs 撑满 + 顶部覆盖层 Header/ActionBar)
 *  - Tabs 用 barPosition End + barOverlap + barFloatingStyle 拿到系统「沉浸光感」的悬浮胶囊
 *  - 顶部覆盖层用 onAreaChange 测高，内容区按 headerH 让位
 *  - 结果列表必须用 Scroll + Column + ForEach（List 的 layoutWeight 在 TabContent 里撑不满）
 */
import { common, ConfigurationConstant, bundleManager, Want } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { BarStyle } from '../entryability/EntryAbility';
import { Candidate, ScanConfig, ScanMode, IpVersion, Verdict, Stage, DomainInfo, SpeedScope } from '../core/Types';
import { ConfigStore, ThemeMode, UiConfig, defaultUiConfig, defaultScanConfig, PORT_OPTIONS, maxScanConcurrency, defaultScanConcurrency } from '../core/ConfigStore';
import { AppBackground } from '../core/AppBackground';
import { Scanner, ScanHooks, CancellationToken } from '../core/Scanner';
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

@Entry
@Component
struct Index {
  @State dark: boolean = AppStorage.get<boolean>('initialDark') ?? true;
  // 导航光感：控制中心按钮式的跟随柔光 + 拖拽弹簧（q 弹）
  @State navGlowPct: number = 50;
  @State navGlowOn: boolean = false;
  @State navStretch: number = 0;
  private navPosPct: number = 50;
  private navVelPct: number = 0;
  private navTargetPct: number = 50;
  private navDrag: boolean = false;
  private navDownX: number = -1;
  private navMoved: boolean = false;
  private navTimer: number = -1;
  /** 0=深色 1=浅色 2=跟随系统 */
  @State themeMode: number = ThemeMode.SYSTEM;
  @State curTab: number = 0;
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
  @State pageOpacity: number = 0;
  /** 启动页：背景色按应用主题走，展示 650ms */
  @State pageScale: number = 0.94;
  /** 出口 IP（启动时探测，用来判断是否处于代理环境） */
  @State egressIp: string = '';
  /** 全屏模式下系统状态栏占用的高度（px），由 EntryAbility 写入 */
  @StorageProp('statusBarPx') statusBarPx: number = 0;
  @StorageProp('navBarPx') navBarPx: number = 0;
  private scanScroller: Scroller = new Scroller();
  private pingScroller: Scroller = new Scroller();
  private speedScroller: Scroller = new Scroller();
  private settingsScroller: Scroller = new Scroller();


  // 扫描状态
  @State scanning: boolean = false;
  @State phaseText: string = '就绪';
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
  @State sampleText: string = '2000';
  @State cfgRev: number = 0;
  @State concurrencyText: string = defaultScanConcurrency().toString();
  @State latencyText: string = '300';
  /** 延迟上限建议提示（随 IPv4/IPv6 变化） */
  @State latencyHint: string = '建议：延迟上限建议 260~320ms（默认 300ms；两次 ping 下 220ms 偏低，容易误杀可用节点）';
  @State bgPath: string = '';
  /** 底部胶囊拖动时的指尖 x（-1 表示未触摸） */
  @State pingText: string = '2';
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
  @State domainInfoText: string = '';
  @State resolving: boolean = false;
  @State testing: boolean = false;
  @State testInfo: string = '';
  /** 应用版本号，Header 上展示 */
  @State appVersion: string = '1.3.8';
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

  private token: CancellationToken = new CancellationToken();
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
        this.addLog('未检测到可用网络，请先连接 Wi-Fi 或移动数据');
      } else {
        this.netOk = true;
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.addLog('网络状态检测失败：' + err.message);
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
        this.addLog('网络环境：出口 IP ' + ip + (warpOn ? '（WARP 已开启）' : '（私有地址）') +
          '，建议关闭代理后重新测速');
        setTimeout(() => {
          this.toast('检测到当前网络经过代理，测速结果会失真，建议先关闭代理');
        }, 700);
      } else {
        this.addLog('网络环境：出口 IP ' + ip);
      }
    }).catch((e: BusinessError) => {
      req.destroy();
      this.addLog('网络环境检测失败：' + e.message);
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
      this.addLog('读取版本号失败：' + be.message);
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
    }).catch((e: BusinessError) => {
      this.addLog('读取配置失败：' + e.message);
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
      animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
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
        this.toast('当前无网络连接，请先联网再开始优选');
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
    this.runEntrance(false);
  }

  /** 主题按钮文案 */
  private themeLabel(): string {
    if (this.themeMode === ThemeMode.DARK) {
      return '深色';
    }
    if (this.themeMode === ThemeMode.LIGHT) {
      return '浅色';
    }
    return '跟随系统';
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
    this.enableSpeed = c.enableSpeed;
    this.speedScope = c.speedScope;
    this.speedPerRegionText = c.speedPerRegion.toString();
    this.domain = c.domain;
    this.domainSampling = c.domainSampling;
    this.keepAlive = ConfigStore.keepAlive();
    AppBackground.enabled = this.keepAlive;
    this.regionCode = c.regionCode;
    this.latencyHint = '建议：延迟上限建议 260~320ms（默认 300ms；两次 ping 下 220ms 偏低，容易误杀可用节点）';
    this.bgPath = ConfigStore.bgPath();
  }

  /** 选择一张本地图片作为应用背景（复制进沙箱，卸载前一直可用） */
  private async pickBackground(): Promise<void> {
    const ctx = this.ctx;
    if (ctx === undefined) {
      this.toast('应用上下文未就绪');
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
      this.addLog('已设置自定义背景图');
      this.toast('背景已更新');
    } catch (e) {
      const err = e as BusinessError;
      this.toast('选择背景失败：' + err.message);
    }
  }

  /** 恢复默认渐变背景 */
  private async clearBackground(): Promise<void> {
    this.bgPath = '';
    await ConfigStore.saveBgPath('');
    this.addLog('已恢复默认渐变背景');
    this.toast('已恢复默认背景');
  }
  /** 进度条左侧文案：同时显示成功/失败数，避免「整数进度」看不出失败 */
  progressLabel(): string {
    if (this.total <= 0) {
      return '就绪';
    }
    let s: string = this.done.toString() + '/' + this.total.toString();
    if (this.passed + this.failed > 0) {
      s += ' · 通过 ' + this.passed.toString() + ' · 未通过 ' + this.failed.toString();
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
      domainSampling: this.domainSampling,
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
    this.latencyHint = '建议：延迟上限建议 260~320ms（默认 300ms；两次 ping 下 220ms 偏低，容易误杀可用节点）';
    if (v6) {
      this.latencyHint = this.latencyHint;
    }
    this.scheduleScanSave();
  }

  /** 一键应用当前 IP 版本的建议参数 */
  private applySuggestedParams(): void {
    const v6: boolean = this.ipVersion === IpVersion.V6;
    this.sampleText = v6 ? '5000' : '2000';
    this.cfgRev++;
    this.concurrencyText = defaultScanConcurrency().toString();
    this.latencyText = '300';
    this.scheduleScanSave();
    this.toast(v6
      ? '已应用建议参数：采样 5000、并发 20、延迟上限 300ms（IPv4/IPv6 同一上限）'
      : '已应用建议参数：采样 2000、并发 20、延迟上限 300ms（IPv4/IPv6 同一上限）');
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
    }, 100);
  }

  toast(msg: string): void {
    const opt: promptAction.ShowToastOptions = { message: msg, duration: 2200 };
    promptAction.showToast(opt);
  }

  doResolve(): void {
    const d: string = DnsService.normalize(this.domain);
    if (!DnsService.isValidDomain(d)) {
      this.domainInfoText = '请先填写有效域名，例如 cdn.example.com';
      return;
    }
    this.resolving = true;
    this.domainInfoText = '解析中…';
    DnsService.resolve(d).then((info: DomainInfo) => {
      this.resolving = false;
      if (info.ok) {
        let cf: number = 0;
        for (let i = 0; i < info.ips.length; i++) {
          this.addLog('解析到 ' + info.ips[i]);
        }
        this.domainInfoText = '解析到 ' + info.ips.length.toString() + ' 个地址';
      } else {
        this.domainInfoText = '解析失败：' + info.error;
      }
    }).catch((e: BusinessError) => {
      this.resolving = false;
      this.domainInfoText = '解析失败：' + e.message;
    });
  }

  startScan(): void {
    if (this.scanning) {
      return;
    }
    this.checkNetwork();
    if (!this.netOk) {
      this.toast('没有网络连接，无法开始扫描');
      return;
    }
    const c: ScanConfig = this.buildConfig();
    this.cfg = c;
    ConfigStore.save(c).then(() => {
      return;
    }).catch((e: BusinessError) => {
      this.addLog('保存配置失败：' + e.message);
    });
    this.token.reset();
    this.scanning = true;
    AppBackground.hold('scan');
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
    this.phaseText = '准备中';
    this.curTab = 0;

    const hooks: ScanHooks = new ScanHooks();
    hooks.onPhase = (phase: number, text: string) => {
      this.phaseText = text;
    };
    hooks.onProgress = (done: number, total: number, passed: number, failed: number) => {
      this.doneRaw = done;
      this.totalRaw = total;
      this.passedRaw = passed;
      this.failedRaw = failed;
      this.scheduleProgressSync();
    };
    hooks.onResult = (list: Candidate[]) => {
      this.resultsRaw = list;
      this.scheduleResultsSync();
    };
    hooks.onLog = (msg: string) => {
      this.addLog(msg);
    };

    Scanner.runPing(c, hooks, this.token).then((list: Candidate[]) => {
      // 用户中途点了「停止」：runPing 仍会正常返回已收集的结果，
      // 这里必须拦住，否则会继续走到「自动进入第二轮测速」。
      if (this.token.isCancelled()) {
        this.scanning = false;
        this.phaseText = '已停止';
        this.addLog('已停止：不再继续后续阶段');
        AppBackground.release('scan');
        return;
      }
      this.results = list;
      this.scanning = false;
      this.phaseText = '第一轮完成';
      this.splitResults(list);
      if (this.pingList.length === 0) {
        // 一个都没通过：明确告诉用户，而不是给一片空白
        const v6: boolean = c.ipVersion === IpVersion.V6;
        const lowCount: number = list.filter((x: Candidate) => x.remark === '合格速度不达标').length;
        this.phaseText = v6 ? 'IPv6 无可用节点' : '没有可用节点';
        this.addLog(v6
          ? (lowCount > 0
            ? '第一轮没有通过的节点：其中 ' + lowCount.toString() +
              ' 个因合格速度未达标被淘汰，可调低「合格速度」；若仍无结果，请检查网络是否支持 IPv6。'
            : '第一轮没有通过的节点。若当前网络不支持 IPv6，或该网段不可达，都会是这个结果。')
          : (lowCount > 0
            ? '第一轮没有通过的节点：其中 ' + lowCount.toString() +
              ' 个因合格速度未达标被淘汰，可调低「合格速度」或设为 0；其余请检查网络连接或调高「延迟上限」。'
            : '第一轮没有通过的节点。请检查网络连接，或调高「延迟上限」。'));
        this.toast(lowCount > 0
          ? ('没有可用节点：' + lowCount.toString() + ' 个低于合格速度门槛')
          : (v6 ? '当前网络可能不支持 IPv6，未发现可用节点' : '没有可用节点，请检查网络或调高延迟上限'));
        this.curTab = 1;
        AppBackground.release('scan');
        return;
      }
      const scope: number = c.speedScope;
      if (!c.enableSpeed) {
        this.addLog('第一轮筛选完成（测速已关闭），可在「筛选」页查看地区分布');
        this.curTab = 1;
        AppBackground.release('scan');
        return;
      }
      if (scope === SpeedScope.REGION) {
        // 地区测速需要用户先看地区码再决定，停在筛选页
        this.addLog('第一轮筛选完成，请填地区码后点「开始测速」，或在扫描页改选「完全测速 / 全部地区」');
        this.curTab = 1;
        AppBackground.release('scan');
        return;
      }
      // 完全测速 / 全部地区：一气呵成，直接进入第二轮
      this.addLog('第一轮筛选完成，自动继续测速…');
      this.curTab = 2;
      this.startSpeedTest();
      AppBackground.release('scan');
    }).catch((e: BusinessError) => {
      this.scanning = false;
      this.phaseText = '出错';
      AppBackground.release('scan');
      this.addLog('扫描异常：' + e.message);
    });
  }

  /** 第二轮：只对第一轮通过的节点测速（可先填地区码缩小范围） */
  startSpeedTest(): void {
    if (this.scanning) {
      return;
    }
    if (this.pingList.length === 0) {
      this.toast('请先在「扫描」页完成第一轮筛选');
      return;
    }
    const c: ScanConfig = this.buildConfig();
    this.cfg = c;
    ConfigStore.save(c).then(() => {
      return;
    }).catch((e: BusinessError) => {
      this.addLog('保存配置失败：' + e.message);
    });
    this.token.reset();
    this.scanning = true;
    this.done = 0;
    this.total = 0;
    this.doneRaw = 0;
    this.totalRaw = 0;
    AppBackground.hold('speed');
    // 换地区/换模式重测时，必须清空上一轮的速度结果，否则会残留别的地区的节点
    this.speedList = [];
    this.phaseText = '准备测速';
    this.curTab = 2;

    const hooks: ScanHooks = new ScanHooks();
    hooks.onPhase = (phase: number, text: string) => {
      this.phaseText = text;
    };
    hooks.onProgress = (done: number, total: number, passed: number, failed: number) => {
      this.doneRaw = done;
      this.totalRaw = total;
      this.scheduleProgressSync();
    };
    hooks.onResult = (list: Candidate[]) => {
      this.resultsRaw = list;
      this.scheduleResultsSync();
    };
    hooks.onLog = (msg: string) => {
      this.addLog(msg);
    };
    // 测速页先把「全部待测节点」铺出来，再逐个把状态刷成测速中/完成；
    // 排序留到全部结束再做，避免列表在测速过程中不断上蹿下跳。
    hooks.onSpeedInit = (targets: Candidate[]) => {
      this.speedList = targets.slice();
      const st: number[] = [];
      for (let i = 0; i < targets.length; i++) {
        st.push(0);
      }
      this.speedStates = st;
    };
    hooks.onSpeedTick = (index: number, cand: Candidate, done: boolean) => {
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

    Scanner.runSpeed(c, this.pingList, hooks, this.token).then(() => {
      if (this.token.isCancelled()) {
        // 被用户停止时也要复位 scanning，否则「重新测速」按钮会被
        // startSpeedTest 开头的 if (this.scanning) return 挡住，看起来像没反应。
        this.scanning = false;
        this.phaseText = '已停止';
        this.addLog('已停止测速');
        AppBackground.release('speed');
        return;
      }
      this.scanning = false;
      this.phaseText = '测速完成';
      Ranker.apply(this.results, c);
      this.splitResults(this.results);
      this.addLog('第二轮测速完成，共 ' + this.speedList.length.toString() + ' 个节点');
      // 开了自动上传就把这批结果推到 edgetunnel 订阅；配置不完整时记一条日志后台跳过，
      // 避免每次测速结束都弹失败提示。
      if (this.etEnabled) {
        if (!this.etReady()) {
          this.addLog('已开启订阅自动上传，但' + (this.etWay === 1 ? 'API 直传参数' : '域名或密码') + '未填，跳过本次上传');
        } else {
          this.uploadEdgeTunnel(true);
        }
      }
      AppBackground.release('speed');
    }).catch((e: BusinessError) => {
      this.scanning = false;
      this.phaseText = '测速出错';
      AppBackground.release('speed');
      this.addLog('测速异常：' + e.message);
    });
  }
  stopScan(): void {
    // 先取消令牌，再清状态：所有异步回调都会在入口处检查 isCancelled 并直接返回，
    // 避免「点了停止，页面却跳去测速页、后台还在跑」。
    this.token.cancel();
    this.scanning = false;
    this.phaseText = '已停止';
    this.addLog('用户停止了扫描');
    AppBackground.release('scan');
    AppBackground.release('speed');
  }

  async doExport(fmt: ExportFormat): Promise<void> {
    if (this.speedList.length === 0) {
      this.toast('还没有测速结果');
      return;
    }
    if (this.ctx === undefined || this.ctx === null) {
      this.toast('上下文未就绪');
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
        this.toast('已取消保存');
        this.addLog('导出已取消');
        return;
      }
      this.toast('已保存：' + saved);
      this.addLog('导出 ' + name + ' → ' + saved);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.toast('保存失败：' + err.message);
      this.addLog('导出失败：' + err.message);
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
    return this.dark ? '#8B8B95' : '#94A3B8';
  }

  soft(): string {
    return this.dark ? 'rgba(255,255,255,0.06)' : 'rgba(15,23,42,0.05)';
  }

  inputBg(): string {
    return this.dark ? 'rgba(255,255,255,0.06)' : 'rgba(15,23,42,0.04)';
  }

  coloText(c: Candidate): string {
    if (c.colo.length === 0) {
      return '未知地区';
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
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.dark ? 'rgba(9,9,11,0.62)' : 'rgba(238,242,249,0.84)')
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
      }

      // 正常流式布局：标题区在最顶上直接占位，不再用覆盖层遮罩
        // 顶层：标题层，与模糊条同一垂直位置，全程不做任何模糊
        Column() {
          Stack({ alignContent: Alignment.TopStart }) {

            // 标题文字画在模糊条之上，自身不模糊

            // 顶部渐变虚化：40 条 2.4vp 细条，半径 30→0.3 立方递减，无明显分界线
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
                  .backgroundColor(this.soft())
                  .onClick(() => {
                    this.setThemeMode((this.themeMode + 1) % 3);
                  })
                  .accessibilityText('切换外观模式，当前' + this.themeLabel())
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
        Tabs({ index: this.curTab, barPosition: BarPosition.End }) {
          TabContent() {
            Column() {
              this.ScanPage()
            }
            .width('100%')
            .height('100%')
          }.tabBar(this.TabItem('扫描', 0))

          TabContent() {
            Column() {
              this.PingPage()
            }
            .width('100%')
            .height('100%')
          }.tabBar(this.TabItem('筛选', 1))

          TabContent() {
            Column() {
              this.SpeedPage()
            }
            .width('100%')
            .height('100%')
          }.tabBar(this.TabItem('测速', 2))
    TabContent() {
      Column() {

        this.SettingsPage()
      }
      .width('100%')
      .height('100%')
    }.tabBar(this.TabItem('设置', 3))
        }
        .width('100%')
        .height('100%')
        // v1.3.2：Tabs 整体上移 1 个状态栏高度，让滚动内容能延伸到屏幕最顶端（contentTop 同步补偿）
        .barHeight(0)
        .barBackgroundColor(Color.Transparent)
        .barBackgroundBlurStyle(BlurStyle.NONE)
        .backgroundColor(Color.Transparent)
        .scrollable(true)
        .onChange((index: number) => {
          if (index !== this.curTab) {
            this.anyScrollY = 0;
            if (this.showBackTop) {
              this.showBackTop = false;
            }
          }
          this.curTab = index;
        })


        // 顶部渐变虚化：80 层细条（层高 2.5×步进、重叠 60%），指数衰减，过渡更细腻
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach(this.topBlurStrips(), (item: BlurStrip, i: number) => {
            Row()
              .width('100%')
              .height(item.h)
              .position({ x: 0, y: item.y })
              .backdropBlur(item.blur)
              .hitTestBehavior(HitTestMode.None)
          }, (item: BlurStrip, i: number) => 'top' + i.toString())
        }
        .width('100%')
        .height(118.0)
        .zIndex(2)
        .hitTestBehavior(HitTestMode.None)
        // 顶部柔和底色蒙版：与页面底色同色，盖住残余条带
        if (this.bgPath.length === 0) {
          Column()
            .width('100%')
            .height(118.0)
            .linearGradient({
              angle: 180,
              colors: [[this.blurScrim(0.90), 0.0], [this.blurScrim(0.62), 0.30],
                [this.blurScrim(0.30), 0.62], [this.blurScrim(0.0), 1.0]]
            })
            .zIndex(3)
            .hitTestBehavior(HitTestMode.None)
        }
          // （顶部渐变层暂时移除，先确认列表滑动是否恢复）

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
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.bottomBlurStrips(), (item: BlurStrip, i: number) => {
          Row()
            .width('100%')
            .height(item.h)
            .position({ x: 0, y: item.y })
            .backdropBlur(item.blur)
            .hitTestBehavior(HitTestMode.None)
        }, (item: BlurStrip, i: number) => 'bot' + i.toString())
      }
      .width('100%')
      .height(106.7)
      .zIndex(2)
      .hitTestBehavior(HitTestMode.None)
      // 底部柔和底色蒙版：与页面底色同色，向上渐隐
      if (this.bgPath.length === 0) {
        Column()
          .width('100%')
          .height(106.7)
          .linearGradient({
            angle: 180,
            colors: [[this.blurScrim(0.0), 0.0], [this.blurScrim(0.45), 0.50],
              [this.blurScrim(0.90), 0.90], [this.blurScrim(0.90), 1.0]]
          })
          .zIndex(3)
          .hitTestBehavior(HitTestMode.None)
      }
      this.BottomNav()
      // 右下角「回到顶部」悬浮按钮：扫描 / 筛选 / 测速 / 设置 四个页面通用，
      // 当前页向下滚动超过一屏（420vp）后出现。
      if (this.showBackTop) {
        Stack() {
          Text('↑')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accent())
        }
        .width(46)
        .height(46)
        .borderRadius(23)
        .backgroundColor(this.dark ? 'rgba(39,39,46,0.92)' : 'rgba(255,255,255,0.94)')
        .border({ width: 1, color: this.lineC() })
        .shadow({ radius: 12, color: 'rgba(0,0,0,0.28)', offsetX: 0, offsetY: 4 })
        .margin({ right: 18, bottom: this.pageBottomPad() + 8 })
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.dark ? '#0B0B12' : '#F3F5FA')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((oldV: Area, newV: Area) => {
      const w: number = newV.width as number;
      if (w > 0 && Math.abs(w - this.winW) > 1) {
        this.winW = w;
      }
    })
  }

  @Builder Header() {
    Column() {
      Text('CFLark')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.txt())
      Text('Cloudflare 智能优选 · v' + this.appVersion)
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

      // 状态文字 + 进度条放在按钮下方
      Row({ space: 10 }) {
        Text(this.progressLabel())
          .fontSize(12)
          .fontColor(this.txt3())
          .flexShrink(0)
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
        .layoutWeight(1)
        .height(9)
      }
      .width('100%')
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
      return '沉浸';
    }
    if (this.matType === 2) {
      return '无材质';
    }
    return '系统沉浸';
  }

  private matLevelName(): string {
    if (this.matLevel === 1) {
      return '精致';
    }
    if (this.matLevel === 2) {
      return '柔和';
    }
    if (this.matLevel === 3) {
      return '平滑';
    }
    return '自适应';
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
      return 6;
    }
    if (e === 0) {
      return 22;
    }
    if (e === 1) {
      return 16;
    }
    return 9;
  }

  /** 光感等级的名称，用于设置页状态提示 */
  private glassLevelName(): string {
    if (this.glassLevel === 0) {
      return '弱';
    }
    if (this.glassLevel === 1) {
      return '标准';
    }
    if (this.glassLevel === 2) {
      return '强';
    }
    return '极致';
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
      return '柠檬黄';
    }
    if (idx === 1) {
      return '奶油黄';
    }
    if (idx === 2) {
      return '鼠尾草绿';
    }
    if (idx === 3) {
      return '雾霾蓝';
    }
    if (idx === 4) {
      return '灰豆沙粉';
    }
    return '清透炭黑';
  }

  /** 当前主题色：主按钮、选中 chip、滑块都用它 */
  accent(): string {
    return this.themeColorAt(this.themeColorIdx);
  }

  /** 系统材质档位名称（设置页提示用） */
  private styleName(): string {
    const s: uiMaterial.ImmersiveStyle = this.styleOfLevel();
    if (s === uiMaterial.ImmersiveStyle.ULTRA_THIN || s === uiMaterial.ImmersiveStyle.THIN) {
      return '薄玻璃';
    }
    if (s === uiMaterial.ImmersiveStyle.REGULAR) {
      return '中玻璃';
    }
    return '厚玻璃';
  }

  /** 背景图模糊半径（0~50vp） */
  private bgBlurPx(): number {
    return this.bgBlurPct / 100 * 50;
  }

  /** 渐变虚化条带数据 */
  private topBlurStrips(): BlurStrip[] {
    if (!TOP_STRIPS_READY) {
      const n: number = 44;
      const area: number = 118;
      const step: number = area / n;
      const out: BlurStrip[] = [];
      for (let i = 0; i < n; i++) {
        const t: number = (i + 0.5) / n;
        const blur: number = 15 * Math.pow(1 - t, 1.25) + 0.2;
        const jy: number = ((i * 7919) % 7 - 3) * 0.05;
        const jh: number = ((i * 104729) % 5 - 2) * 0.04;
        out.push(new BlurStrip(i * step + jy, step * 2.0 + jh, blur));
      }
      TOP_STRIPS_CACHE = out;
      TOP_STRIPS_READY = true;
    }
    return TOP_STRIPS_CACHE;
  }

  private bottomBlurStrips(): BlurStrip[] {
    if (!BOTTOM_STRIPS_READY) {
      const n: number = 24;
      const area: number = 106.7;
      const step: number = area / n;
      const out: BlurStrip[] = [];
      for (let i = 0; i < n; i++) {
        const t: number = (i + 0.5) / n;
        const blur: number = 16 * Math.pow(t, 1.1) + 0.2;
        out.push(new BlurStrip(i * step, step * 1.6, blur));
      }
      BOTTOM_STRIPS_CACHE = out;
      BOTTOM_STRIPS_READY = true;
    }
    return BOTTOM_STRIPS_CACHE;
  }

  /** 顶部/底部虚化的柔和底色蒙版（与页面底色一致，隐藏条带接缝） */
  private blurScrim(alpha: number): string {
    const a: string = alpha.toFixed(2);
    return this.dark ? ('rgba(11,11,18,' + a + ')') : ('rgba(238,242,249,' + a + ')');
  }

  /** 背景图亮度系数：50% = 1.0 */
  private bgBrightFactor(): number {
    return this.bgBrightPct / 50;
  }

  loadUi(): void {
    const c: UiConfig = ConfigStore.ui();
    this.globalImmersion = c.globalImmersion;
    this.matType = c.matType;
    this.matLevel = c.matLevel;
    this.themeColorIdx = c.themeColor;
    this.bgBlurPct = c.bgBlur;
    this.bgBrightPct = c.bgBright;
  }

  saveUi(): void {
    const c: UiConfig = {
      globalImmersion: this.globalImmersion,
      matType: this.matType,
      matLevel: this.matLevel,
      themeColor: this.themeColorIdx,
      bgBlur: this.bgBlurPct,
      bgBright: this.bgBrightPct
    };
    ConfigStore.saveUi(c).catch((e: BusinessError) => {
      this.addLog('保存外观设置失败：' + e.message);
    });
  }

  setThemeMode(m: number): void {
    this.themeMode = m;
    this.applyThemeMode();
    ConfigStore.saveTheme(m).catch((e: BusinessError) => {
      this.addLog('保存主题失败：' + e.message);
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

  /** 卡片玻璃的系统模糊档位：精致更厚、平滑更薄；「沉浸」再升一档 */
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

  /** 卡片霜面 tint：精致更通透、平滑更实；深色模式用低透白叠出玻璃厚度 */
  private cardTint(): Array<[ResourceColor, number]> {
    const e: number = this.effLevel();
    const photo: number = this.bgPath.length > 0 ? 1 : 0;
    if (this.dark) {
      if (e < 0) {
        return [['rgba(48,52,64,0.94)', 0.0], ['rgba(48,52,64,0.88)', 0.55], ['rgba(48,52,64,0.82)', 1.0]];
      }
      const lift: number = photo * 0.06;
      const a0: number = (e === 0 ? 0.10 : (e === 1 ? 0.15 : 0.22)) + lift;
      const a1: number = (e === 0 ? 0.06 : (e === 1 ? 0.09 : 0.14)) + lift;
      const a2: number = (e === 0 ? 0.03 : (e === 1 ? 0.04 : 0.07)) + lift;
      return [['rgba(255,255,255,' + a0.toFixed(3) + ')', 0.0],
        ['rgba(255,255,255,' + a1.toFixed(3) + ')', 0.55],
        ['rgba(255,255,255,' + a2.toFixed(3) + ')', 1.0]];
    }
    if (e < 0) {
      return [['rgba(255,255,255,0.96)', 0.0], ['rgba(255,255,255,0.92)', 0.55], ['rgba(255,255,255,0.88)', 1.0]];
    }
    const lift: number = photo * 0.08;
    const b0: number = Math.min(0.9, (e === 0 ? 0.18 : (e === 1 ? 0.38 : 0.60)) + lift);
    const b1: number = Math.min(0.85, (e === 0 ? 0.11 : (e === 1 ? 0.26 : 0.46)) + lift);
    const b2: number = Math.min(0.8, (e === 0 ? 0.06 : (e === 1 ? 0.15 : 0.30)) + lift);
    return [['rgba(255,255,255,' + b0.toFixed(3) + ')', 0.0],
      ['rgba(255,255,255,' + b1.toFixed(3) + ')', 0.55],
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
      return this.dark ? 'rgba(255,255,255,0.08)' : 'rgba(15,23,42,0.08)';
    }
    return this.dark ? 'rgba(255,255,255,0.20)' : 'rgba(255,255,255,0.78)';
  }

  private cardShadowColor(): string {
    if (this.effLevel() < 0) {
      return '#14000000';
    }
    return this.dark ? 'rgba(0,0,0,0.52)' : 'rgba(15,23,42,0.16)';
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
      return '不支持';
    }
    const lv: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
    if (lv === uiMaterial.MaterialLevel.EXQUISITE) {
      return '精致';
    }
    if (lv === uiMaterial.MaterialLevel.GENTLE) {
      return '柔和';
    }
    return '平滑';
  }

  /** 卡片玻璃描述（设置页状态提示） */
  private glassDesc(): string {
    const e: number = this.effLevel();
    if (e < 0) {
      return '（无材质）';
    }
    if (e === 0) {
      return '（厚玻璃）';
    }
    if (e === 1) {
      return '（中玻璃）';
    }
    return '（薄玻璃）';
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

  /** 宽柔光带：中心为触摸位置 */
  private glowBand(): Array<[ResourceColor, number]> {
    const p: number = Math.max(0.06, Math.min(0.94, this.navGlowPct / 100));
    const spread: number = 0.24 + 0.09 * this.navStretch;
    const lo: number = Math.max(0.0, p - spread);
    const hi: number = Math.min(1.0, p + spread);
    return [[this.accentRgba(0.0), 0.0], [this.accentRgba(0.10), lo], [this.accentRgba(0.28), p],
      [this.accentRgba(0.10), hi], [this.accentRgba(0.0), 1.0]];
  }

  /** 窄亮芯 */
  private glowCore(): Array<[ResourceColor, number]> {
    const p: number = Math.max(0.04, Math.min(0.96, this.navGlowPct / 100));
    const spread: number = 0.075 + 0.05 * this.navStretch;
    const lo: number = Math.max(0.0, p - spread);
    const hi: number = Math.min(1.0, p + spread);
    return [[this.accentRgba(0.0), 0.0], [this.accentRgba(0.44), lo], [this.accentRgba(0.44), p],
      [this.accentRgba(0.44), hi], [this.accentRgba(0.0), 1.0]];
  }

  /** 弹簧步进：拖拽时柔光带一点滞后与回弹（q 弹感） */
  private navStep(): void {
    const dt: number = 0.016;
    const k: number = 120;
    const damp: number = 8;
    const diff: number = this.navTargetPct - this.navPosPct;
    const acc: number = diff * k - this.navVelPct * damp;
    this.navVelPct += acc * dt;
    this.navPosPct += this.navVelPct * dt;
    if (this.navPosPct < 2) {
      this.navPosPct = 2;
      this.navVelPct = 0;
    }
    if (this.navPosPct > 98) {
      this.navPosPct = 98;
      this.navVelPct = 0;
    }
    this.navStretch = Math.min(1, Math.abs(this.navVelPct) / 46);
    this.navGlowPct = this.navPosPct;
  }

  private ensureNavTimer(): void {
    if (this.navTimer < 0) {
      this.navTimer = setInterval(() => {
        this.navStep();
      }, 16);
    }
  }

  private stopNavTimer(): void {
    if (this.navTimer >= 0) {
      clearInterval(this.navTimer);
      this.navTimer = -1;
    }
    this.navStretch = 0;
  }

  /** 底部导航触摸：只有拖动才显示跟手扫光（轻点不触发） */
  private onNavTouch(e: TouchEvent): void {
    if (e.touches.length === 0) {
      return;
    }
    const t: TouchObject = e.touches[0];
    const lx: number = t.windowX - this.navStackLeft();
    const pct: number = Math.max(2, Math.min(98, lx / this.navStackWidth() * 100));
    if (e.type === TouchType.Down) {
      this.navDownX = lx;
      this.navMoved = false;
      this.navDrag = false;
      this.stopNavTimer();
      this.navStretch = 0;
    } else if (e.type === TouchType.Move) {
      if (!this.navMoved) {
        if (this.navDownX < 0 || Math.abs(lx - this.navDownX) < 8) {
          return;
        }
        this.navMoved = true;
        this.navDrag = true;
        this.navPosPct = (this.curTab + 0.5) / 4 * 100;
        this.navVelPct = 0;
        this.navGlowOn = true;
      }
      this.navTargetPct = pct;
      this.ensureNavTimer();
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      this.navDrag = false;
      this.navMoved = false;
      this.navDownX = -1;
      if (this.navGlowOn) {
        setTimeout(() => {
          if (!this.navDrag) {
            this.navGlowOn = false;
            this.stopNavTimer();
          }
        }, 120);
      } else {
        this.stopNavTimer();
      }
    }
  }

  /** 底部悬浮导航：原生 Tabs（隐藏系统页签）作页面宿主，导航层只负责切页，不做拖动、不做柔光 */
  @Builder BottomNav() {
    Row() {
      Stack() {
        // ① 系统沉浸材质：真实采样其后的内容并模糊，作为玻璃的“体”
        Column()
          .width('100%')
          .height('100%')
          .backgroundBlurStyle(this.navGlassStyle(), {
            colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
          })
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
        // ③ 光感：控制中心按钮式的扫光（宽柔光 + 窄亮芯，随触摸位置移动）
        if (this.navGlowOn && this.matType !== 2) {
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({ angle: 90, colors: this.glowBand() })
            .hitTestBehavior(HitTestMode.None)
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({ angle: 90, colors: this.glowCore() })
            .hitTestBehavior(HitTestMode.None)
        }
        // ④ 内容层
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
      .border({ width: 1, color: this.navGlassBorder() })
      .shadow({
        radius: this.dark ? 20 : 22,
        color: this.dark ? 'rgba(0,0,0,0.55)' : 'rgba(15,23,42,0.16)',
        offsetX: 0,
        offsetY: 8
      })
      .onTouch((e: TouchEvent) => {
        this.onNavTouch(e);
      })
      .scale({ x: 1 + 0.014 * this.navStretch, y: 1 - 0.009 * this.navStretch })
    }
    .width('100%')
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
    .margin({ bottom: px2vp(this.navBarPx) + 26 })
    .zIndex(10)
  }

  /** 导航胶囊玻璃：深色更薄、浅色更厚，保证两套主题都能读出层次 */
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
        if (this.curTab === index) {
          // 选中柔光：光斑比按钮更高，上下也完整渐隐（没有上下切边）
          Column()
            .width('100%')
            .height(72)
            .radialGradient({
              center: [43.5, 36],
              radius: 34,
              colors: this.navSelGlow()
            })
          Column()
            .width(72)
            .height(42)
            .radialGradient({
              center: [36, 21],
              radius: 21,
              colors: this.navSelGlow()
            })
        }
        Column() {
          SymbolGlyph(this.tabIcon(index))
            .fontSize(20)
            .fontColor([this.curTab === index ? this.accent() : this.txt3()])
          Text(this.tabLabel(index))
            .fontSize(10)
            .margin({ top: 2 })
            .fontWeight(this.curTab === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.curTab === index ? this.accent() : this.txt3())
        }
        .width('100%')
        .height(46)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(46)
      .animation({ duration: 180, curve: Curve.EaseOut })
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchTab(index);
    })
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
    // 点击切页不扫光：光带只在拖动时出现
    this.navGlowOn = false;
    this.stopNavTimer();
    this.navPosPct = (index + 0.5) / 4 * 100;
    this.navVelPct = 0;
    this.navTargetPct = this.navPosPct;
    this.navStretch = 0;
    animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.curTab = index;
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
  private pageBottomPad(): number {
    return 62 + 26 + px2vp(this.navBarPx) + 16;
  }
  private tabLabel(index: number): string {
    if (index === 0) {
      return '扫描';
    }
    if (index === 1) {
      return '筛选';
    }
    if (index === 2) {
      return '测速';
    }
    return '设置';
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
        .fontColor([this.curTab === index ? (this.dark ? this.accent() : this.accentPale()) : this.txt3()])
        .margin({ bottom: 2 })
      Text(label)
        .fontSize(10)
        .maxLines(1)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontWeight(this.curTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.curTab === index ? (this.dark ? this.accent() : this.accentPale()) : this.txt3())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
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
                Column({ space: 14 }) {
                  this.CardPort()
                  this.CardSpeed()
                }
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)

              Column().height(104)
            }
            .width('100%')
            .padding({ left: 20, right: 6, top: this.contentTop() })
            .constraintSize({ maxWidth: 1080 })
            .layoutWeight(1)

            Column() {
              if (this.scanning || this.total > 0) {
                this.ActionBar()
              }
              Column() {
                this.CardLog(true)
              }
              .width('100%')
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
              .constraintSize({ minHeight: 520 })
              .padding({ left: 16, right: 16, top: 16, bottom: 16 })
              .margin({ bottom: 16 })
            }
            .width(420)
            .padding({ left: 6, right: 16, top: this.contentTop() })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .justifyContent(FlexAlign.Center)
          .constraintSize({ maxWidth: 1600 })
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onScroll(() => {
          this.onPageScroll(this.scanScroller);
        })
      } else {
        // 手机：单列，从上到下依次是 按钮 → 进度条 → 参数卡片 → 运行日志
        Scroll(this.scanScroller) {
          Column() {

            GridRow({
              columns: { sm: 12, md: 12, lg: 12 },
              gutter: { x: 14, y: 14 },
              breakpoints: { value: ['600vp', '900vp'], reference: BreakpointsReference.WindowSize }
            }) {
              GridCol({ span: { sm: 12, md: 6, lg: 4 } }) {
                this.CardSource()
              }
              GridCol({ span: { sm: 12, md: 12, lg: 12 } }) {
                if (this.scanning || this.total > 0) {
                  this.ActionBar()
                }
              }
              GridCol({ span: { sm: 12, md: 6, lg: 4 } }) {
                this.CardPort()
              }
              GridCol({ span: { sm: 12, md: 6, lg: 4 } }) {
                this.CardParam()
              }
              GridCol({ span: { sm: 12, md: 6, lg: 4 } }) {
                this.CardSpeed()
              }

              GridCol({ span: { sm: 12, md: 6, lg: 4 } }) {
                this.CardLog(false)
              }
            }
            .width('100%')

            Column().height(104)
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
        .onScroll(() => {
          this.onPageScroll(this.scanScroller);
        })
      }
    }
    .width('100%')
    .height('100%')
  }
  /** 运行 IPv6 网络诊断（设置页「网络诊断」卡片触发） */
  /** IPv4 自检 */
  async runIpv4Diag(): Promise<void> {
    if (this.diagBusy) {
      return;
    }
    this.diagBusy = true;
    this.armDiagWatchdog();
    this.diagText = '正在诊断 IPv4，请稍候…';
    try {
      const text: string = await Diag.runV4();
      this.diagText = text;
      this.addLog('IPv4 网络诊断完成');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.diagText = '诊断失败：' + (err.message !== undefined ? err.message : '未知错误');
    } finally {
      this.disarmDiagWatchdog();
      this.diagBusy = false;
    }
  }

  /** 复制诊断结果到剪贴板 */
  copyDiag(): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.diagText);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('诊断结果已复制');
      }).catch((e: BusinessError) => {
        this.toast('复制失败：' + e.message);
      });
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.toast('复制失败：' + err.message);
    }
  }

  async runIpv6Diag(): Promise<void> {
    if (this.diagBusy) {
      return;
    }
    this.diagBusy = true;
    this.armDiagWatchdog();
    this.diagText = '正在诊断 IPv6，请稍候…';
    try {
      const text: string = await Diag.run();
      this.diagText = text;
      this.addLog('IPv6 网络诊断完成，详情见「设置 → 网络诊断」');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      this.diagText = '诊断失败：' + (err.message !== undefined ? err.message : '未知错误');
    } finally {
      this.disarmDiagWatchdog();
      this.diagBusy = false;
    }
  }

  private armDiagWatchdog(): void {
    this.disarmDiagWatchdog();
    this.diagWatchdog = setTimeout(() => {
      if (this.diagBusy) {
        this.diagBusy = false;
        this.diagText = this.diagText + '\n\n（诊断超时，按钮已恢复。请检查网络后重试）';
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
            .backgroundColor(current === index ? this.accent() : this.soft())
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

  @Builder CardSource() {
    Column() {
      this.CardTitle('候选来源', $r('sys.symbol.wifi'))
      // 开始优选：紧贴「候选来源」标题下方
      Row() {
        Text(this.scanning ? '停止' : '开始优选')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .width('100%')
          .height(48)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.scanning ? BAD_C : this.accent())
          .borderRadius(14)
          .onClick(() => {
            if (this.scanning) {
              this.stopScan();
            } else {
              this.startScan();
            }
          })
      }
      .width('100%')
      .margin({ top: 20, bottom: 2 })
      Row() {
        Text(this.mode === ScanMode.OFFICIAL ? '官方 IP 段' : '自定义')
          .fontSize(12)
          .fontColor(this.txt2())
          .width(110)
        Row() {
          Text('官方 IP 段')
            .fontSize(12)
            .fontColor(this.mode === ScanMode.OFFICIAL ? '#FFFFFF' : this.txt2())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.mode === ScanMode.OFFICIAL ? this.accent() : this.soft())
            .borderRadius(9)
            .onClick(() => {
              this.mode = ScanMode.OFFICIAL;
              this.scheduleScanSave();
            })
          Text('自定义')
            .fontSize(12)
            .fontColor(this.mode === ScanMode.CUSTOM ? '#FFFFFF' : this.txt2())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.mode === ScanMode.CUSTOM ? this.accent() : this.soft())
            .borderRadius(9)
            .margin({ left: 6 })
            .onClick(() => {
              this.mode = ScanMode.CUSTOM;
              this.scheduleScanSave();
            })
        }
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('IP 版本')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(110)
        Row() {
          Text('IPv4')
            .fontSize(12)
            .fontColor(this.ipVersion === IpVersion.V4 ? '#FFFFFF' : this.txt2())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.ipVersion === IpVersion.V4 ? this.accent() : this.soft())
            .borderRadius(9)
            .onClick(() => {
              this.ipVersion = IpVersion.V4;
              this.maybeAutoSuggest(false);
            })
          Text('IPv6')
            .fontSize(12)
            .fontColor(this.ipVersion === IpVersion.V6 ? '#FFFFFF' : this.txt2())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.ipVersion === IpVersion.V6 ? this.accent() : this.soft())
            .borderRadius(9)
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

      if (this.mode === ScanMode.CUSTOM) {
        Row() {
          Text('从文件导入（txt / csv，每行一个地址）')
            .fontSize(12)
            .fontColor(this.accent())
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(this.soft())
            .borderRadius(9)
            .onClick(() => {
              this.importIpFile();
            })
          Blank()
        }
        .width('100%')
        .margin({ top: 10 })

        TextArea({ text: this.customText, placeholder: '每行一个：1.2.3.4 / 1.2.3.4:8443 / [2001:db8::1]:443 / CIDR' })
          .width('100%')
          .height(90)
          .fontSize(12)
          .fontColor(this.txt())
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .margin({ top: 8 })
          .placeholderColor(this.txt3())
          .onChange((v: string) => {
            this.customText = v;
            this.scheduleScanSave();
          })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder CardPort() {
    Column() {
      this.CardTitle('端口', $r('sys.symbol.gearshape'))
      Row() {
        ForEach(PORT_OPTIONS, (p: number, index: number) => {
          Text(p.toString())
            .fontSize(this.CHIP_FS)
            .fontColor(this.port === p ? '#FFFFFF' : this.txt2())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(this.CHIP_H)
            .backgroundColor(this.port === p ? this.accent() : this.soft())
            .borderRadius(9)
            .margin({ right: index === PORT_OPTIONS.length - 1 ? 0 : 5 })
            .onClick(() => {
              this.port = p;
              this.scheduleScanSave();
            })
        }, (p: number, index: number) => p.toString())
      }
      .width('100%')
      .margin({ top: 10 })
      Text('Cloudflare 只支持这几个 TLS 端口')
        .fontSize(11)
        .fontColor(this.txt3())
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder CardParam() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(16)
          .fontColor([this.txt2()])
          .margin({ right: 8 })
        Text('快速筛选参数')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.txt())
        Blank()
        Text('应用建议')
          .fontSize(12)
          .fontColor(this.accent())
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.soft())
          .borderRadius(9)
          .onClick(() => { this.applySuggestedParams(); })
      }
      .width('100%')
      Row() {
        Text('采样数')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(110)
        TextInput({ text: this.sampleText })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(this.txt())
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .type(InputType.Number)
          .onChange((v: string) => {
            this.sampleText = v;
            this.scheduleScanSave();
          })
      }
      .width('100%')
      .margin({ top: 8 })
      Text('建议：IPv4 2000；IPv6 随机地址命中率低，建议 3000~5000，或改用域名 AAAA 采样。')
        .fontSize(11)
        .fontColor(this.txt3())
        .margin({ top: 6 })
      Row() {
        Text('并发线程')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(110)
        TextInput({ text: this.concurrencyText })
          .id('conc-' + this.cfgRev.toString())
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(this.txt())
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .type(InputType.Number)
          .onChange((v: string) => {
            const lim: number = maxScanConcurrency();
            const n: number = parseInt(v);
            if (!isNaN(n) && n > lim) {
              this.concurrencyText = lim.toString();
              this.toast('并发上限为 ' + lim.toString() + '，已按上限执行');
            } else {
              this.concurrencyText = v;
            }
            this.scheduleScanSave();
          })
      }
      .width('100%')
      .margin({ top: 8 })

      Text('并发上限：手机 120 / 平板 200 / 电脑 300（当前设备上限 ' + maxScanConcurrency().toString() +
        '）。超过会自动改回上限；过高会导致设备发热卡死。')
        .fontSize(11)
        .fontColor(this.txt3())
        .margin({ top: 6 })
      Row() {
        Text('延迟上限 ms')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(110)
        TextInput({ text: this.latencyText })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(this.txt())
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .type(InputType.Number)
          .onChange((v: string) => {
            this.latencyText = v;
            this.scheduleScanSave();
          })
      }
      .width('100%')
      .margin({ top: 8 })
      Text(this.latencyHint)
        .fontSize(11)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 6 })
      this.FieldRow('Ping 次数', this.pingText, (v: string) => {
        this.pingText = v;
        this.scheduleScanSave();
      })
      Text('每个 IP 连 ' + this.pingText + ' 次 TCP 取最小值；最小值超过 ' + this.latencyText +
        'ms 的直接淘汰。IPv4 与 IPv6 使用同一延迟上限（建议 260~320ms，默认 300ms；两次 ping 下 220ms 会明显偏严）。')
        .fontSize(11)
        .fontColor(this.txt3())
        .margin({ top: 8 })
        Row() {
          Text('合格速度 MB/s')
            .fontSize(13)
            .fontColor(this.txt2())
            .width(110)
          TextInput({ text: this.minSpeedText })
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .fontColor(this.txt())
            .backgroundColor(this.inputBg())
            .borderRadius(10)
            .onChange((v: string) => {
              this.minSpeedText = v;
              this.scheduleScanSave();
            })
        }
        .width('100%')
        .margin({ top: 8 })

        Text('低于该速度的节点会在第一轮 TCP 初筛后从延迟最低的开始逐个检测并淘汰，直到凑够「测速地址数」个达标节点；若大量节点都不达标会提前中止并提示检查网络（默认 0.1 MB/s，0 = 不淘汰）。')
          .fontSize(11)
          .fontColor(this.txt3())
          .margin({ top: 8 })

    }
    .width('100%')
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder CardSpeed() {
    Column() {
      Row() {
        Text('下载测速')
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
        Text('测速范围')
          .fontSize(13)
          .fontColor(this.txt2())
          .width('100%')
          .margin({ top: 10 })

        Row() {
          Text('完全测速')
            .fontSize(12)
            .fontColor(this.speedScope === SpeedScope.ALL ? '#FFFFFF' : this.txt2())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.speedScope === SpeedScope.ALL ? this.accent() : this.soft())
            .borderRadius(9)
            .onClick(() => {
              this.speedScope = SpeedScope.ALL;
              this.scheduleScanSave();
            })
          Text('地区测速')
            .fontSize(12)
            .fontColor(this.speedScope === SpeedScope.REGION ? '#FFFFFF' : this.txt2())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.speedScope === SpeedScope.REGION ? this.accent() : this.soft())
            .borderRadius(9)
            .margin({ left: 6 })
            .onClick(() => {
              this.speedScope = SpeedScope.REGION;
              this.scheduleScanSave();
            })
          Text('全部地区')
            .fontSize(12)
            .fontColor(this.speedScope === SpeedScope.PER_REGION ? '#FFFFFF' : this.txt2())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.speedScope === SpeedScope.PER_REGION ? this.accent() : this.soft())
            .borderRadius(9)
            .margin({ left: 6 })
            .onClick(() => {
              this.speedScope = SpeedScope.PER_REGION;
              this.scheduleScanSave();
            })
        }
        .width('100%')
        .margin({ top: 8 })

        if (this.speedScope === SpeedScope.ALL) {
          this.FieldRow('测速地址数', this.speedCountText, (v: string) => {
            this.speedCountText = v;
            this.scheduleScanSave();
          })
          Text('第一轮通过的地址按延迟从低到高排序，只测前 N 个（默认 10，范围 1~99）；上传数量可在「设置 → 订阅上传」里限制。')
            .fontSize(11)
            .fontColor(this.txt3())
            .margin({ top: 8 })
        }

        if (this.speedScope === SpeedScope.REGION) {
          this.FieldRow('测速地址数', this.speedCountText, (v: string) => {
            this.speedCountText = v;
            this.scheduleScanSave();
          })
          Row() {
            Text('地区码')
              .fontSize(13)
              .fontColor(this.txt2())
              .width(110)
            TextInput({ text: this.regionCode, placeholder: '例如 HKG / LAX / NRT' })
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .fontColor(this.txt())
              .backgroundColor(this.inputBg())
              .borderRadius(10)
              .placeholderColor(this.txt3())
              .onChange((v: string) => {
                this.regionCode = v;
                this.scheduleScanSave();
              })
          }
          .width('100%')
          .margin({ top: 8 })
          Text('只测这个地区，同样按延迟从低到高取前 N 个（默认 10；HKG / LAX / NRT 这类三字码）。')
            .fontSize(11)
            .fontColor(this.txt3())
            .margin({ top: 8 })
        }

        if (this.speedScope === SpeedScope.PER_REGION) {
          this.FieldRow('每地区数量', this.speedPerRegionText, (v: string) => {
            this.speedPerRegionText = v;
            this.scheduleScanSave();
          })
          Text('按 colo 分组，每个地区各取延迟最低的前几个测速，覆盖所有地区。')
            .fontSize(11)
            .fontColor(this.txt3())
            .margin({ top: 8 })
        }

        Row() {
          Text('每地址次数')
            .fontSize(13)
            .fontColor(this.txt2())
            .width(110)
          TextInput({ text: this.speedRoundsText })
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .fontColor(this.txt())
            .backgroundColor(this.inputBg())
            .borderRadius(10)
            .onChange((v: string) => {
              this.speedRoundsText = v;
              this.scheduleScanSave();
            })
        }
        .width('100%')
        .margin({ top: 8 })

        Row() {
          Text('窗口 ms')
            .fontSize(13)
            .fontColor(this.txt2())
            .width(110)
          TextInput({ text: this.speedWindowText })
            .layoutWeight(1)
            .height(40)
            .fontSize(13)
            .fontColor(this.txt())
            .backgroundColor(this.inputBg())
            .borderRadius(10)
            .onChange((v: string) => {
              this.speedWindowText = v;
              this.scheduleScanSave();
            })
        }
        .width('100%')
        .margin({ top: 8 })

        Text('每个地址测 ' + this.speedRoundsText + ' 次取平均，单次下载窗口 ' + this.speedWindowText +
          'ms（CloudFlareScan 用 3 秒）。建议次数不超过 10，否则总耗时很长。')
          .fontSize(11)
          .fontColor(this.txt3())
          .margin({ top: 8 })
      }

      Divider().color(this.lineC()).margin({ top: 12, bottom: 4 })

      Row() {
        Text('测速域名（可选）')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(110)
        TextInput({ text: this.domain, placeholder: 'cdn.example.com' })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontColor(this.txt())
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .placeholderColor(this.txt3())
          .onChange((v: string) => {
            this.domain = v;
            this.scheduleScanSave();
          })
      }
      .width('100%')
      .margin({ top: 8 })

      Row() {
        Text('解析测试')
          .fontSize(12)
          .fontColor(this.accent())
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

      Text('域名只在测速阶段作为 Host / SNI 使用；留空则用 speed.cloudflare.com。')
        .fontSize(11)
        .fontColor(this.txt3())
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
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
      .backgroundColor(this.themeMode === idx ? this.accent() : this.soft())
      .onClick(() => {
        this.themeMode = idx;
        this.applyThemeMode();
        ConfigStore.saveTheme(idx).catch((e: BusinessError) => {
          this.addLog('保存主题失败：' + e.message);
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
      .backgroundColor(this.chipSel(group, idx) ? this.accent() : (this.dark ? '#1AFFFFFF' : '#10000000'))
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
    Column() {
      this.CardTitle('材质', $r('sys.symbol.paintbrush'))
      Row() {
        Column() {
          Text('全局沉浸光感')
            .fontSize(14)
            .fontColor(this.txt())
          Text('关闭后卡片与底部导航都不再使用沉浸光感')
            .fontSize(11)
            .fontColor(this.txt3())
            .margin({ top: 4 })
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

      Text('材质类型')
        .fontSize(12)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 16, bottom: 8 })
      Row({ space: 8 }) {
        this.OptChip('系统沉浸', 'matType', 0, () => {
          this.matType = 0;
          this.saveUi();
        })
        this.OptChip('沉浸', 'matType', 1, () => {
          this.matType = 1;
          this.saveUi();
        })
        this.OptChip('无材质', 'matType', 2, () => {
          this.matType = 2;
          this.saveUi();
        })
      }
      .width('100%')

      Text('材质等级')
        .fontSize(12)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 16, bottom: 8 })
      Row({ space: 8 }) {
        this.OptChip('自适应', 'matLevel', 0, () => {
          this.matLevel = 0;
          this.saveUi();
        })
        this.OptChip('精致', 'matLevel', 1, () => {
          this.matLevel = 1;
          this.saveUi();
        })
        this.OptChip('柔和', 'matLevel', 2, () => {
          this.matLevel = 2;
          this.saveUi();
        })
        this.OptChip('平滑', 'matLevel', 3, () => {
          this.matLevel = 3;
          this.saveUi();
        })
      }
      .width('100%')

      Text(this.matSupported()
        ? ('当前：' + this.matTypeName() + ' · ' + this.matLevelName() + '（设备等级 ' + this.deviceLevelName() + '，卡片' + this.glassDesc() + '）')
        : '本机不支持系统沉浸材质，卡片与胶囊退回手绘玻璃。')
        .fontSize(11)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  /** 外观 · 背景：颜色模式 / 主题色 / 背景图 / 模糊 / 明亮 */
  @Builder CardAppearanceBackground() {
    Column() {
      this.CardTitle('外观', $r('sys.symbol.paintbrush'))

      Text('颜色模式')
        .fontSize(12)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 12, bottom: 8 })
      Row({ space: 8 }) {
        this.OptChip('跟随系统', 'theme', 2, () => {
          this.setThemeMode(2);
        })
        this.OptChip('深色', 'theme', 0, () => {
          this.setThemeMode(0);
        })
        this.OptChip('浅色', 'theme', 1, () => {
          this.setThemeMode(1);
        })
      }
      .width('100%')

      Text('主题色')
        .fontSize(12)
        .fontColor(this.txt3())
        .width('100%')
        .margin({ top: 16, bottom: 8 })
      Row({ space: 10 }) {
        this.ThemeColorDot(0)
        this.ThemeColorDot(1)
        this.ThemeColorDot(2)
      }
      .width('100%')
      Row({ space: 10 }) {
        this.ThemeColorDot(3)
        this.ThemeColorDot(4)
        this.ThemeColorDot(5)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Column() {
          Text('自定义背景图')
            .fontSize(14)
            .fontColor(this.txt())
          Text(this.bgPath.length > 0 ? '已选择，点右侧按钮可清除' : '默认使用渐变背景')
            .fontSize(11)
            .fontColor(this.txt3())
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.bgPath.length > 0 ? '清除' : '从图库选择')
          .fontSize(12)
          .fontColor(this.accent())
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(this.dark ? '#1AFFFFFF' : '#10000000')
          .borderRadius(10)
          .onClick(() => {
            if (this.bgPath.length > 0) {
              this.clearBackground();
            } else {
              this.pickBackground();
            }
          })
      }
      .width('100%')
      .margin({ top: 18 })

      this.PctSliderRow('背景图模糊程度', 'blur')
      this.PctSliderRow('背景图明亮程度', 'bright')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
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
        this.addLog('打开浏览器失败（' + err.code + '），改用系统浏览器');
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
      this.addLog('无法打开链接：' + err.message);
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
        .fontColor(this.accent())
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
    Column() {
      this.CardTitle('运行', $r('sys.symbol.gearshape'))
      Row() {
        Column({ space: 3 }) {
          Text('后台保持运行')
            .fontSize(14)
            .fontColor(this.txt())
          Text('开启后扫描/测速/上传期间切到后台不中断；关闭则使用系统默认行为')
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
          })
      }
      .width('100%')
      .margin({ top: 14 })
      .alignItems(VerticalAlign.Center)
      Row() {
        Column({ space: 3 }) {
          Text('域名解析采样')
            .fontSize(14)
            .fontColor(this.txt())
          Text('开启后按当前 IP 版本解析测速域名的 A/AAAA 记录并并入候选，提高命中率')
            .fontSize(11)
            .fontColor(this.txt3())
            .lineHeight(16)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.domainSampling })
          .selectedColor(this.accent())
          .onChange((v: boolean) => {
            this.domainSampling = v;
          })
      }
      .width('100%')
      .margin({ top: 14 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder CardAbout() {
    Column() {
      this.CardTitle('关于', $r('sys.symbol.info_circle'))
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
      Text('Cloudflare 节点优选 · 鸿蒙原生应用')
        .fontSize(11)
        .fontColor(this.txt3())
        .margin({ top: 6 })
      Text('TCP 筛选 → 数据中心 → 下载测速 → 加权排序，支持域名端到端校验与 edgetunnel 订阅上传。')
        .fontSize(11)
        .fontColor(this.txt3())
        .lineHeight(17)
        .margin({ top: 8 })
      this.AboutLink('GitHub 项目主页', '源码、Issue 与更新记录', 'https://github.com/Bailin-Love/CFLark-Harmony')
      this.AboutLink('下载最新版本', 'GitHub Releases · HAP / APP', 'https://github.com/Bailin-Love/CFLark-Harmony/releases/latest')
      Divider()
        .color(this.cardBorderColor())
        .margin({ top: 12, bottom: 8 })
      Text('免责条款')
        .fontSize(11)
        .fontColor(this.txt2())
        .margin({ top: 2 })
      Text('本应用仅供学习与个人研究使用，与 Cloudflare 官方无关。请遵守所在地区法律法规及 Cloudflare 服务条款；因使用本应用（含节点测速、订阅上传等）产生的任何后果由使用者自行承担。')
        .fontSize(10)
        .fontColor(this.txt3())
        .lineHeight(16)
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder CardDiag() {
    Column() {
      this.CardTitle('网络诊断', $r('sys.symbol.info_circle'))
      Text('用于区分「应用 Socket 问题 / 运营商路由问题 / 随机地址不可达 / 超时过短 / 延迟门槛过严」。自检固定使用 3000ms 超时、顺序执行，不会修改扫描配置。')
        .fontSize(11)
        .fontColor(this.txt3())
        .lineHeight(16)
        .margin({ top: 8 })
      Row({ space: 10 }) {
        Text(this.diagBusy ? '诊断中…' : '运行 IPv4 自检')
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
        Text(this.diagBusy ? '诊断中…' : '运行 IPv6 自检')
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
          Text('复制结果')
            .fontSize(12)
            .fontColor(this.accent())
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.soft())
            .borderRadius(8)
            .onClick(() => {
              this.copyDiag();
            })
          Text('清空')
            .fontSize(12)
            .fontColor(this.txt3())
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.soft())
            .borderRadius(8)
            .onClick(() => {
              this.diagText = '';
            })
          Blank()
        }
        .width('100%')
        .margin({ top: 8 })
      }

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
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }

  @Builder SettingsPage() {
    Column() {
      Scroll(this.settingsScroller) {
        Column() {
          if (this.winW >= 900) {
            Row({ space: 14 }) {
              Column({ space: 14 }) {
                this.CardUpload()
              }
              .layoutWeight(1)
              Column({ space: 14 }) {
                this.CardAppearanceBackground()
                this.CardAppearanceMaterial()
              }
              .layoutWeight(1)
              Column({ space: 14 }) {
                this.CardRuntime()
                this.CardAbout()
                this.CardDiag()
              }
              .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            Column({ space: 14 }) {
              this.CardUpload()
              this.CardAppearanceMaterial()
              this.CardAppearanceBackground()
              this.CardRuntime()
              this.CardAbout()
              this.CardDiag()
            }
            .width('100%')
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
      .onScroll(() => {
        this.onPageScroll(this.settingsScroller);
      })
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
      .backgroundColor(this.etMode === idx ? this.accent() : this.soft())
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
      .backgroundColor(this.etPos === idx ? this.accent() : this.soft())
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
      .backgroundColor(this.etTopN === value ? this.accent() : this.soft())
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
      .backgroundColor(this.etWay === idx ? this.accent() : this.soft())
      .fontColor(this.etWay === idx ? '#FFFFFF' : this.txt2())
      .onClick(() => {
        this.etWay = idx;
        this.saveEtConfig();
      })
  }

  @Builder CardUpload() {
    Column() {
      this.CardTitle('订阅上传', $r('sys.symbol.icloud'))

      Row() {
        Column() {
          Text('扫描完成后自动上传')
            .fontSize(13)
            .fontColor(this.txt())
          Text('把优选结果写入 edgetunnel 的 ADD.txt 订阅')
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
        Text('上传方式')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(90)
        Row({ space: 8 }) {
          this.EtWayChip('登录上传', 0)
          this.EtWayChip('API 直传', 1)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      if (this.etWay === 0) {
        this.EtFieldRow('域名', this.etHost, 'edgetunnel.example.com', false, (v: string) => {
          this.etHost = v;
          this.saveEtConfig();
        })
        this.EtFieldRow('密码', this.etPassword, '后台登录密码', true, (v: string) => {
          this.etPassword = v;
          this.saveEtConfig();
        })
      } else {
        this.EtFieldRow('Account ID', this.etCfAccount, 'Cloudflare 账户 ID（32 位）', false, (v: string) => {
          this.etCfAccount = v;
          this.saveEtConfig();
        })
        this.EtFieldRow('命名空间 ID', this.etCfNamespace, 'Workers KV 命名空间 ID（32 位）', false, (v: string) => {
          this.etCfNamespace = v;
          this.saveEtConfig();
        })
        this.EtFieldRow('API Token', this.etCfToken, '需要 Workers KV 读写权限', true, (v: string) => {
          this.etCfToken = v;
          this.saveEtConfig();
        })
      }

      Row() {
        Text('上传模式')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(90)
        Row({ space: 8 }) {
          this.EtModeChip('覆盖', 0)
          this.EtModeChip('追加', 1)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('自定义保留')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(90)
        Text(this.etCustom.trim().length > 0 ? ('已填 ' + this.etCustom.trim().split('\n').length.toString() + ' 行，每次上传都会带上') : '可选：每行一个域名或节点')
          .fontSize(11)
          .fontColor(this.txt3())
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      TextArea({ text: this.etCustom, placeholder: '每行一个：cdn.example.com 或 1.2.3.4:443' })
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
        Text('写入位置')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(90)
        Row({ space: 8 }) {
          this.EtPosChip('最前', 0)
          this.EtPosChip('最后', 1)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('上传数量')
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
        Text('上传代理')
          .fontSize(13)
          .fontColor(this.txt2())
          .width(90)
        Column() {
          Text('仅订阅上传走代理（仅支持 HTTP 代理）')
            .fontSize(12)
            .fontColor(this.txt())
          Text('不影响测速与优选（请求级代理）')
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
        this.EtFieldRow('代理地址', this.etProxyHost, '127.0.0.1', false, (v: string) => {
          this.etProxyHost = v;
          this.saveEtConfig();
        })
        this.EtFieldRow('代理端口', this.etProxyPort, '7890', false, (v: string) => {
          this.etProxyPort = v;
          this.saveEtConfig();
        })
        this.EtFieldRow('代理用户', this.etProxyUser, '可选，留空为无认证', false, (v: string) => {
          this.etProxyUser = v;
          this.saveEtConfig();
        })
        this.EtFieldRow('代理密码', this.etProxyPass, '可选', true, (v: string) => {
          this.etProxyPass = v;
          this.saveEtConfig();
        })
      }

      Row() {
        Text(this.etStatus.length > 0 ? this.etStatus : '未上传')
          .fontSize(11)
          .fontColor(this.txt3())
          .layoutWeight(1)
        Text(this.etBusy ? '上传中…' : '立即上传')
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

      Text(this.etWay === 1
        ? '提示：上传格式为「IP:端口#地区 V4/V6中文名序号」，例如 162.159.9.26:443#SG V4新加坡1；API 直传直接读写 Worker 绑定的 KV（键 ADD.txt），Token 只保存在本机，需要该 Account 的 Workers KV 读写权限。'
        : '提示：上传格式为「IP:端口#地区 V4/V6中文名序号」，例如 162.159.9.26:443#SG V4新加坡1；edgetunnel 需把「优选订阅模式」设为自定义订阅，节点不是越多越好。')
        .fontSize(11)
        .fontColor(this.txt3())
        .lineHeight(16)
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTint() })
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderColor() })
    .shadow({ radius: this.cardShadowR(), color: this.cardShadowColor(), offsetX: 0, offsetY: this.cardShadowY() })
    .margin({ bottom: 12 })
  }
  @Builder CardLog(fill: boolean) {
    Column() {
      this.CardTitle('运行日志', $r('sys.symbol.doc_text'))
      if (this.logs.length === 0) {
        Text('暂无日志')
          .fontSize(12)
          .fontColor(this.txt3())
          .margin({ top: 8 })
      } else {
        ForEach(this.logs, (line: string, index: number) => {
          Text(line)
            .fontSize(11)
            .fontColor(this.txt3())
            .width('100%')
            .margin({ top: 3 })
        }, (line: string, index: number) => index.toString() + '#' + line)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(fill ? 0 : 16)
    .backgroundBlurStyle(fill ? BlurStyle.NONE : this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .linearGradient({ angle: 145, colors: this.cardTintOr(fill) })
    .borderRadius(fill ? 0 : 16)
    .border({ width: fill ? 0 : 1, color: this.lineC() })
    .margin({ bottom: fill ? 0 : 12 })
  }

  @Builder ToolBar() {
    Row() {
      Text('补测速前 5')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .height(40)
        .backgroundColor(this.accent())
        .borderRadius(10)
        .onClick(() => {
          this.runSpeedTop();
        })
      Text('导出 TXT')
        .fontSize(12)
        .fontColor(this.txt2())
        .textAlign(TextAlign.Center)
        .width(88)
        .height(40)
        .backgroundColor(this.soft())
        .borderRadius(10)
        .margin({ left: 8 })
        .onClick(() => {
          this.doExport(ExportFormat.PLAIN_COLO_DELAY);
        })
      Text('导出 CSV')
        .fontSize(12)
        .fontColor(this.txt2())
        .textAlign(TextAlign.Center)
        .width(88)
        .height(40)
        .backgroundColor(this.soft())
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
        Row() {
          Text('第一轮通过 ' + this.pingList.length.toString() + ' 个')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
          Text(' · ' + this.groups.length.toString() + ' 个地区')
            .fontSize(12)
            .fontColor(this.txt3())
          Blank()
          Text('开始测速')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .width(88)
            .height(34)
            .backgroundColor(this.accent())
            .borderRadius(9)
            .onClick(() => {
              this.startSpeedTest();
            })
        }
        .width('100%')
        .margin({ bottom: 10 })

        Row() {
          Text('地区码')
            .fontSize(12)
            .fontColor(this.txt2())
            .width(52)
          TextInput({ text: this.regionCode, placeholder: '可留空；如 HKG / LAX' })
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .fontColor(this.txt())
            .backgroundColor(this.inputBg())
            .borderRadius(9)
            .onChange((v: string) => {
              this.regionCode = v.toUpperCase();
            })
        }
        .width('100%')
        .margin({ bottom: 10 })

        Text('先看下面各地区的最快延迟，挑延迟低的地区填码，再点右上「开始测速」；留空则测全部地区。')
          .fontSize(11)
          .fontColor(this.txt3())
          .margin({ bottom: 12 })

        if (this.pingList.length === 0) {
          Column() {
            Text('还没有筛选结果')
              .fontSize(15)
              .fontColor(this.txt2())
            Text('回到「扫描」页开始优选')
              .fontSize(12)
              .fontColor(this.txt3())
              .margin({ top: 6 })
          }
          .width('100%')
          .padding({ top: 60, bottom: 30 })
        }

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

        Column().height(112)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: this.pageBottomPad() })
      .constraintSize({ maxWidth: 1600 })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScroll(() => {
      this.onPageScroll(this.pingScroller);
    })
  }

  @Builder GroupRow(g: RegionGroup) {
    Column() {
      Row() {
        Column() {
          Text(g.colo === 'UNK' ? 'UNK 未知地区' : (Geo.flag(g.colo) + ' ' + Geo.placeZh(g.colo)))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
          Text(g.count.toString() + ' 个 · 最快 ' + (g.minLatency > 0 ? Math.round(g.minLatency).toString() : '—') +
            'ms · 平均 ' + (g.avgLatency > 0 ? Math.round(g.avgLatency).toString() : '—') + 'ms')
            .fontSize(11)
            .fontColor(this.txt3())
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.expandedColos.indexOf(g.colo) >= 0 ? '收起' : '展开')
          .fontSize(12)
          .fontColor(this.accent())
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
        .border({ width: { left: 2 }, color: this.lineC() })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundBlurStyle(this.cardBlurStyle(), { colorMode: this.dark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
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
        Row() {
          Text('测速 ' + this.speedList.length.toString() + ' 个')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.txt())
          Blank()
          Text('导出 TXT')
            .fontSize(12)
            .fontColor(this.txt2())
            .textAlign(TextAlign.Center)
            .width(84)
            .height(34)
            .backgroundColor(this.soft())
            .borderRadius(9)
            .onClick(() => {
              this.doExport(ExportFormat.PLAIN_SPEED);
            })
          Text('导出 CSV')
            .fontSize(12)
            .fontColor(this.txt2())
            .textAlign(TextAlign.Center)
            .width(84)
            .height(34)
            .backgroundColor(this.soft())
            .borderRadius(9)
            .margin({ left: 8 })
            .onClick(() => {
              this.doExport(ExportFormat.CSV);
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        if (this.etEnabled) {
          Text('自动上传：' + this.uploadLimitShort() + '（设置 → 订阅上传 可修改）')
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
          Text(this.scanning ? '测速进行中…' : '重新测速')
            .fontSize(12)
            .fontColor(this.accent())
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .backgroundColor(this.soft())
            .borderRadius(9)
            .onClick(() => {
              this.startSpeedTest();
            })
        }
        .width('100%')
        .margin({ bottom: 10 })

        if (this.speedList.length === 0) {
          Column() {
            Text(this.enableSpeed ? '还没有测速结果' : '下载测速已关闭')
              .fontSize(15)
              .fontColor(this.txt2())
            Text(this.enableSpeed ? '回到「扫描」页开始优选' : '在扫描页打开「下载测速」开关')
              .fontSize(12)
              .fontColor(this.txt3())
              .margin({ top: 6 })
          }
          .width('100%')
          .padding({ top: 60, bottom: 30 })
        }

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

        Column().height(112)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: this.pageBottomPad() })
      .constraintSize({ maxWidth: 1600 })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
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
      label = '未知';
    }
    return addr + ':' + c.port.toString() + '#' + regionCode + ' V' + family.toString() + label + index.toString();
  }

  /** 「上传数量」规则的完整说明：规则随当前测速范围变化（完全/地区=合计，全部地区=每地区） */
  uploadLimitHint(): string {
    const n: number = this.etTopN;
    if (this.speedScope === SpeedScope.PER_REGION) {
      return n > 0
        ? '当前「全部地区」测速：每个地区最多上传排序最靠前的 ' + n.toString()
          + ' 个（默认 3，0=全部）。只影响上传，不影响测速和结果列表。'
        : '当前「全部地区」测速：不限制上传数量（「全部」）。只影响上传，不影响测速和结果列表。';
    }
    const scopeName: string = this.speedScope === SpeedScope.REGION ? '地区测速' : '完全测速';
    return n > 0
      ? '当前「' + scopeName + '」：所有地区合计最多上传排序最靠前的 ' + n.toString()
        + ' 个（默认 3，0=全部）。只影响上传，不影响测速和结果列表。'
      : '当前「' + scopeName + '」：不限制上传数量（「全部」）。只影响上传，不影响测速和结果列表。';
  }

  /** 测速完成页的简短提示 */
  uploadLimitShort(): string {
    if (this.etTopN <= 0) {
      return '全部';
    }
    if (this.speedScope === SpeedScope.PER_REGION) {
      return '每地区前 ' + this.etTopN.toString() + ' 个';
    }
    return '合计前 ' + this.etTopN.toString() + ' 个';
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
        arr = [];
        groups.set(code, arr);
        order.push(code);
      }
      arr.push(c);
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
      const arr: Candidate[] = perRegion && this.etTopN > 0 && all.length > this.etTopN
        ? all.slice(0, this.etTopN) : all;
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
      this.addLog('保存订阅上传配置失败：' + e.message);
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
          this.toast('请先填 Cloudflare Account ID');
        }
        return;
      }
      if (cfg.cfNamespaceId.trim().length === 0) {
        if (!auto) {
          this.toast('请先填 KV 命名空间 ID');
        }
        return;
      }
      if (cfg.cfApiToken.trim().length === 0) {
        if (!auto) {
          this.toast('请先填 API Token');
        }
        return;
      }
    } else {
      if (cfg.host.trim().length === 0) {
        if (!auto) {
          this.toast('请先填 edgetunnel 域名');
        }
        return;
      }
      if (cfg.password.length === 0) {
        if (!auto) {
          this.toast('请先填 edgetunnel 密码');
        }
        return;
      }
    }
    const payload: UploadPayload = this.buildUploadPayload();
    if (payload.nodes.length === 0 && payload.custom.length === 0) {
      if (!auto) {
        this.toast('没有可上传的节点，请先完成测速');
      }
      return;
    }
    this.etBusy = true;
    AppBackground.hold('upload');
    this.etStatus = '准备上传…';
    const how: string = auto ? '自动' : '手动';
    const modeText: string = cfg.mode === 'append' ? '追加' : '覆盖';
    const posText: string = cfg.customPos === 'bottom' ? '最后' : '最前';
    const wayText: string = cfg.uploadWay === 'api' ? 'API 直传' : '登录上传';
    this.addLog('edgetunnel ' + how + '上传开始（' + wayText + '）：节点 ' + payload.nodes.length.toString()
      + ' 个，自定义 ' + payload.custom.length.toString() + ' 行，模式 ' + modeText + '，自定义位置 ' + posText);
    this.toast('订阅' + how + '上传中…');
    EdgeTunnel.upload(cfg, payload, (msg: string) => {
      this.etStatus = msg;
    }).then((res: UploadResult) => {
      this.etBusy = false;
      AppBackground.release('upload');
      this.etStatus = '上传成功（' + res.totalLines.toString() + ' 行）';
      const costText: string = res.way === 'api'
        ? ('读取 ' + res.readMs.toString() + 'ms，写入 ' + res.writeMs.toString() + 'ms')
        : ('登录 ' + res.loginMs.toString() + 'ms'
          + (res.mode === 'append' ? '，读取 ' + res.readMs.toString() + 'ms' : '')
          + '，写入 ' + res.writeMs.toString() + 'ms');
      this.addLog('edgetunnel 订阅上传成功（' + (res.way === 'api' ? 'API 直传' : '登录上传') + '）：模式 '
        + (res.mode === 'append' ? '追加' : '覆盖') + '，节点 ' + res.nodeCount.toString() + ' 个，共 '
        + res.totalLines.toString() + ' 行 / ' + res.bytes.toString() + ' 字节，耗时 ' + costText);
      // 自动上传也弹 toast：用户这时多半停在测速页，看不到设置页的状态行
      this.toast('订阅上传成功，共 ' + res.totalLines.toString() + ' 行');
    }).catch((e: BusinessError) => {
      this.etBusy = false;
      AppBackground.release('upload');
      const msg: string = this.etErrText(e);
      this.etStatus = '上传失败：' + msg;
      this.addLog('edgetunnel 上传失败：' + msg);
      this.toast('订阅上传失败：' + msg);
    });
  }
  /** 把网络层错误码翻译成中文提示；EdgeTunnel 自己抛的中文错误已带阶段，直接展示 */
  etErrText(e: BusinessError): string {
    const raw: string = e.message === undefined ? '' : e.message;
    const code: number = e.code === undefined ? 0 : e.code;
    if (code === 2300005) {
      return '代理服务器域名解析失败，请检查「上传代理」地址';
    }
    if (code === 2300006) {
      return '无法解析 edgetunnel 域名，请检查域名拼写';
    }
    if (code === 2300007) {
      return '无法连接 edgetunnel 服务器，请检查网络或改用「上传代理」';
    }
    if (code === 2300028) {
      return '请求超时，请检查网络后重试';
    }
    if (code === 2300047) {
      return '重定向次数超过上限，请确认「域名」只填站点根地址';
    }
    if (code === 2300094) {
      return 'TLS 认证失败，请检查域名或上传代理';
    }
    if (code === 2300997) {
      return '系统禁止明文 HTTP，请使用 https 地址';
    }
    if (code === 2300999) {
      return '网络内部错误：' + raw;
    }
    if (raw.length > 0) {
      return raw;
    }
    return '未知错误（错误码 ' + code.toString() + '）';
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
    let regionLog: string = '第一轮地区分布：';
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
      regionLog += (i > 0 ? '、' : '') + colos[i] + ' ' + counts[i].toString() + ' 个';
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
      this.toast('已复制 ' + ip);
    }).catch((err: BusinessError) => {
      this.toast('复制失败：' + err.message);
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
        this.toast('已导入 ' + lines.toString() + ' 行');
        this.addLog('从文件导入 ' + lines.toString() + ' 行候选地址');
      } catch (err) {
        const e2: BusinessError = err as BusinessError;
        this.toast('读取失败：' + e2.message);
      }
    }).catch((err: BusinessError) => {
      this.toast('选择文件失败：' + err.message);
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
          Text(index < this.speedStates.length && this.speedStates[index] === 1 ? '测速中…' : '待测')
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
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    // 玻璃质感：系统背景模糊 + 半透明叠加 + 细边框 + 柔和外阴影，
    // 让卡片能透出底层的页面渐变，而不是纯色填充。
    .backgroundColor(this.dark ? '#33FFFFFF' : '#66FFFFFF')
    .borderRadius(20)
    .border({ width: 1, color: '#66FFFFFF' })
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
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    // 玻璃质感：系统背景模糊 + 半透明叠加 + 细边框 + 柔和外阴影，
    // 让卡片能透出底层的页面渐变，而不是纯色填充。
    .backgroundColor(this.dark ? '#33FFFFFF' : '#66FFFFFF')
    .borderRadius(20)
    .border({ width: 1, color: '#66FFFFFF' })
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
    this.testInfo = '测速中 0/' + list.length.toString();
    const c: ScanConfig = this.buildConfig();
    const token: CancellationToken = new CancellationToken();
    Scanner.stageSpeed(c, list, new ScanHooks(), token).then(() => {
      Ranker.apply(this.results, c);
      this.results = this.results.slice();
      this.testing = false;
      this.testInfo = '';
      this.toast('补测速完成');
    }).catch((e: BusinessError) => {
      this.testing = false;
      this.testInfo = '';
      this.toast('补测速失败：' + e.message);
    });
  }
}


let TOP_STRIPS_CACHE: BlurStrip[] = [];
let TOP_STRIPS_READY: boolean = false;
let BOTTOM_STRIPS_CACHE: BlurStrip[] = [];
let BOTTOM_STRIPS_READY: boolean = false;

class BlurStrip {
  y: number = 0;
  h: number = 0;
  blur: number = 0;

  constructor(y: number, h: number, blur: number) {
    this.y = y;
    this.h = h;
    this.blur = blur;
  }
}

