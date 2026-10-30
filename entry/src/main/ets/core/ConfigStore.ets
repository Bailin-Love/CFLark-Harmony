/**
 * CFLark 配置持久化（preferences）
 *
 * 默认值按 CloudFlareScan 的推荐：
 *  - 每 IP ping 2 次（间隔 50ms）取最小值，超时 1 秒
 *  - 延迟上限 220ms（ScanWorker 的默认值，不取更高的，高了没意义）
 *  - TCP 并发 120（CloudFlareScan 用 150，模拟器上 120 更稳）
 *  - 测速 3 秒窗口，取延迟最低的前 10 个，每个测 1 次，串行、间隔 300ms
 *  - 排名权重：延迟 0.3 / 速度 0.7
 */
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { EdgeTunnelConfig, defaultEdgeTunnelConfig } from './EdgeTunnel';
import { common } from '@kit.AbilityKit';
import { ScanConfig, ScanMode, IpVersion, SpeedScope } from './Types';

/** 外观设置：材质（全局沉浸光感 / 材质类型 / 材质等级）+ 主题色 + 背景图（模糊 / 明亮） */
export interface UiConfig {
  globalImmersion: boolean;
  matType: number;
  matLevel: number;
  themeColor: number;
  bgBlur: number;
  bgBright: number;
  /** 背景图遮罩程度 0~100（0 = 完全通透，100 = 最实）；只在有背景图时生效 */
  bgScrim: number;
  /** 卡片通透度 0=更实 50=默认 100=最透 */
  cardClear: number;
  /** 语言模式：0 跟随系统 / 1 简体中文 / 2 English */
  langMode: number;
}

export function defaultUiConfig(): UiConfig {
  const c: UiConfig = {
    globalImmersion: true,
    matType: 0,
    matLevel: 0,
    themeColor: 4,
    bgBlur: 25,
    bgBright: 40,
    bgScrim: 55,
    cardClear: 50,
    langMode: 0
  };
  return c;
}

export const DEFAULT_TRACE_HOST: string = 'speed.cloudflare.com';
export const DEFAULT_TRACE_PATH: string = '/cdn-cgi/trace';
export const PORT_OPTIONS: number[] = [443, 2053, 2083, 2087, 2096, 8443];

/** 内置优选库（均由第三方持续维护、可直接拉取的纯文本 CIDR 列表） */
export interface LibSource {
  label: string;
  url: string;
  note: string;
}

export const LIB_SOURCES: LibSource[] = [
  { label: 'CF官方 IPv6', url: 'https://www.cloudflare.com/ips-v6', note: 'Cloudflare 官方发布的 IPv6 段，随官方更新' },
  { label: 'CF官方 IPv4', url: 'https://www.cloudflare.com/ips-v4', note: 'Cloudflare 官方发布的 IPv4 段，随官方更新' },
  { label: '社区 IPv6库', url: 'https://www.baipiao.eu.org/cloudflare/ips-v6', note: '社区维护的 Cloudflare IPv6 段列表' },
  { label: '社区 IPv4库', url: 'https://www.baipiao.eu.org/cloudflare/ips-v4', note: '社区维护的 Cloudflare IPv4 段列表' }
];
const STORE_NAME: string = 'cflark_store';

/** 主题模式：深色 / 浅色 / 跟随系统 */
export enum ThemeMode {
  DARK = 0,
  LIGHT = 1,
  SYSTEM = 2
}

/** 两套背景图快照（启动预读用） */
export interface BgSnapshot {
  light: string;
  dark: string;
}

/** 第一轮并发上限：按设备形态分档，避免低端机开太猛反而更慢 */
export function maxScanConcurrency(): number {
  // 按设备形态分档：手机 120、平板 200、电脑(2in1) 300。
  // 超过上限只会在弱网下制造大量超时并让设备发热，收益为负。
  const t: string = deviceInfo.deviceType;
  if (t === '2in1' || t === 'pc') {
    return 300;
  }
  if (t === 'tablet') {
    return 200;
  }
  return 120;
}

/** 默认并发 = 上限的 80% */
export function defaultScanConcurrency(): number {
  // 默认并发 30：3000 个候选大约 1 分钟内跑完，同时避免排队放大延迟与过度发热。
  return 30;
}
/** 推荐参数（默认值与「应用建议」共用的唯一来源，避免 UI / 配置 / 测速三处各写一份） */
export const REC_SAMPLE_COUNT: number = 3000;
export const REC_PING_TIMES: number = 1;
export const REC_LATENCY_MS: number = 300;
export const REC_SPEED_COUNT: number = 10;
export const REC_SPEED_PER_REGION: number = 3;
export const REC_SPEED_ROUNDS: number = 1;
export const REC_SPEED_WINDOW_MS: number = 6000;
export const REC_MIN_SPEED_MBPS: number = 0.1;

export function defaultScanConfig(): ScanConfig {
  const c: ScanConfig = {
    mode: ScanMode.OFFICIAL,
    ipVersion: IpVersion.V4,
    port: 443,
    sampleCount: REC_SAMPLE_COUNT,
    customText: '',
    sourceGroupId: '',
    sourceGroupName: '',
    pingTimes: REC_PING_TIMES,
    pingIntervalMs: 50,
    pingTimeoutMs: 1000,
    latencyLimitMs: REC_LATENCY_MS,
    scanConcurrency: defaultScanConcurrency(),
    traceHost: DEFAULT_TRACE_HOST,
    tracePath: DEFAULT_TRACE_PATH,
    traceConcurrency: 30,
    traceTimeoutMs: 3000,
    enableSpeed: true,
    speedScope: SpeedScope.ALL,
    speedCount: REC_SPEED_COUNT,
    speedPerRegion: REC_SPEED_PER_REGION,
    speedRounds: REC_SPEED_ROUNDS,
    speedUrl: 'https://speed.cloudflare.com/__down?bytes=50000000',
    speedWindowMs: REC_SPEED_WINDOW_MS,
    speedConcurrency: 1,
    speedGapMs: 300,
    minSpeedMbps: REC_MIN_SPEED_MBPS,
    domain: '',
    domainSampling: true,
    regionCode: '',
    delayWeight: 0.1,
    speedWeight: 0.9,
    resultLimit: 0
  };
  return c;
}

export class ConfigStore {
  private static store: preferences.Preferences | undefined = undefined;

  static async init(ctx: common.Context): Promise<void> {
    if (ConfigStore.store !== undefined) {
      return;
    }
    const opt: preferences.Options = { name: STORE_NAME };
    ConfigStore.store = await preferences.getPreferences(ctx, opt);
  }

  private static num(key: string, def: number): number {
    if (ConfigStore.store === undefined) {
      return def;
    }
    const v = ConfigStore.store.getSync(key, def);
    if (typeof v === 'number') {
      return v;
    }
    return def;
  }

  private static str(key: string, def: string): string {
    if (ConfigStore.store === undefined) {
      return def;
    }
    const v = ConfigStore.store.getSync(key, def);
    if (typeof v === 'string') {
      return v;
    }
    return def;
  }

  /**
   * 供 Sources 等模块复用的原始字符串读写：
   * 这些键不参与 ScanConfig 字段映射（单独维护自己的序列化格式与版本），
   * 但仍然落在同一个 preferences 里，避免额外存储依赖。
   */
  static rawStr(key: string, def: string): string {
    return ConfigStore.str(key, def);
  }

  static async rawPut(key: string, value: string): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    await st.put(key, value);
    await st.flush();
  }

  static load(): ScanConfig {
    const d: ScanConfig = defaultScanConfig();
    d.mode = ConfigStore.str('scan_mode', '0') === '1' ? ScanMode.CUSTOM : ScanMode.OFFICIAL;
    d.ipVersion = ConfigStore.str('scan_ipver', '4') === '6' ? IpVersion.V6 : IpVersion.V4;
    d.port = ConfigStore.num('scan_port', d.port);
    d.sampleCount = ConfigStore.num('scan_samples', d.sampleCount);
    d.customText = ConfigStore.str('scan_custom', d.customText);
    d.pingTimes = ConfigStore.num('scan_ping_times', d.pingTimes);
    d.latencyLimitMs = ConfigStore.num('scan_latency', d.latencyLimitMs);
    d.scanConcurrency = ConfigStore.num('scan_concurrency', d.scanConcurrency);
    d.enableSpeed = ConfigStore.str('scan_enable_speed', '1') === '1';
    const sc: number = ConfigStore.num('scan_speed_scope', d.speedScope);
    d.speedScope = sc === 1 ? SpeedScope.REGION : (sc === 2 ? SpeedScope.PER_REGION : SpeedScope.ALL);
    d.speedCount = ConfigStore.num('scan_speed_count', d.speedCount);
    d.speedPerRegion = ConfigStore.num('scan_speed_per', d.speedPerRegion);
    d.speedRounds = ConfigStore.num('scan_speed_rounds', d.speedRounds);
    d.speedWindowMs = ConfigStore.num('scan_speed_window', d.speedWindowMs);
    d.minSpeedMbps = ConfigStore.num('scan_min_speed', d.minSpeedMbps);
    d.domain = ConfigStore.str('domain', d.domain);
    d.domainSampling = ConfigStore.str('domain_sampling', '0') === '1';
    d.regionCode = ConfigStore.str('scan_region', d.regionCode);
    return d;
  }

  /**
   * 保存扫描参数：扫描参数、候选来源、端口、IP 版本、测速域名、地区码
   * 全部持久化，避免每次打开 App 都要重新填写。
   */
  static async save(c: ScanConfig): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    st.putSync('scan_mode', c.mode === ScanMode.CUSTOM ? '1' : '0');
    st.putSync('scan_ipver', c.ipVersion === IpVersion.V6 ? '6' : '4');
    st.putSync('scan_port', c.port);
    st.putSync('scan_samples', c.sampleCount);
    st.putSync('scan_custom', c.customText);
    st.putSync('scan_ping_times', c.pingTimes);
    st.putSync('scan_latency', c.latencyLimitMs);
    st.putSync('scan_concurrency', c.scanConcurrency);
    st.putSync('scan_enable_speed', c.enableSpeed ? '1' : '0');
    st.putSync('scan_speed_scope', c.speedScope);
    st.putSync('scan_speed_count', c.speedCount);
    st.putSync('scan_speed_per', c.speedPerRegion);
    st.putSync('scan_speed_rounds', c.speedRounds);
    st.putSync('scan_speed_window', c.speedWindowMs);
    st.putSync('scan_min_speed', c.minSpeedMbps);
    st.putSync('domain', c.domain);
    st.putSync('domain_sampling', c.domainSampling ? '1' : '0');
    st.putSync('scan_region', c.regionCode);
    await st.flush();
  }
  /**
   * 读取 edgetunnel 订阅上传配置。
   * 这四个值需要长期记住（每次都要重填域名密码不现实），
   * 与「测速域名」一样属于「连接另一侧服务」的配置，不属于扫描参数。
   */
  static edgeTunnel(): EdgeTunnelConfig {
    const d: EdgeTunnelConfig = defaultEdgeTunnelConfig();
    d.enabled = ConfigStore.str('et_enabled', '0') === '1';
    d.host = ConfigStore.str('et_host', d.host);
    d.password = ConfigStore.str('et_password', d.password);
    d.mode = ConfigStore.str('et_mode', d.mode);
    d.customHead = ConfigStore.str('et_custom', d.customHead);
    d.customPos = ConfigStore.str('et_pos', d.customPos);
    d.proxyType = ConfigStore.str('et_proxy_type', d.proxyType);
    d.proxyHost = ConfigStore.str('et_proxy_host', d.proxyHost);
    d.proxyPort = ConfigStore.num('et_proxy_port', d.proxyPort);
    d.proxyUser = ConfigStore.str('et_proxy_user', d.proxyUser);
    d.proxyPass = ConfigStore.str('et_proxy_pass', d.proxyPass);
    d.uploadWay = ConfigStore.str('et_way', d.uploadWay);
    d.cfAccountId = ConfigStore.str('et_cf_account', d.cfAccountId);
    d.cfNamespaceId = ConfigStore.str('et_cf_ns', d.cfNamespaceId);
    d.cfApiToken = ConfigStore.str('et_cf_token', d.cfApiToken);
    d.topN = ConfigStore.num('et_top_n', d.topN);
    return d;
  }

  /** 保存 edgetunnel 配置 */
  static async saveEdgeTunnel(c: EdgeTunnelConfig): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    st.putSync('et_enabled', c.enabled ? '1' : '0');
    st.putSync('et_host', c.host);
    st.putSync('et_password', c.password);
    st.putSync('et_mode', c.mode);
    st.putSync('et_custom', c.customHead);
    st.putSync('et_pos', c.customPos);
    st.putSync('et_proxy_type', c.proxyType);
    st.putSync('et_proxy_host', c.proxyHost);
    st.putSync('et_proxy_port', c.proxyPort);
    st.putSync('et_proxy_user', c.proxyUser);
    st.putSync('et_proxy_pass', c.proxyPass);
    st.putSync('et_way', c.uploadWay);
    st.putSync('et_cf_account', c.cfAccountId);
    st.putSync('et_cf_ns', c.cfNamespaceId);
    st.putSync('et_cf_token', c.cfApiToken);
    st.putSync('et_top_n', c.topN);
    await st.flush();
  }
  /** 已展示过升级说明的版本号（空串 = 从未展示，例如首次安装） */
  static changelogSeen(): string {
    return ConfigStore.str('changelog_seen_version', '');
  }

  static async saveChangelogSeen(version: string): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    st.putSync('changelog_seen_version', version);
    await st.flush();
  }
  /** 自定义背景图（应用沙箱内的绝对路径），空串表示用默认渐变 */
  static bgPath(): string {
    return ConfigStore.str('bg_path', '');
  }

  static async saveBgPath(path: string): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    st.putSync('bg_path', path);
    await st.flush();
  }

  /**
   * 按深浅色分别读取背景图（v2 数据结构）。
   * 空串表示该模式使用默认背景（深色为深色渐变、浅色为浅色渐变）。
   */
  static bgPathFor(dark: boolean): string {
    return ConfigStore.str(dark ? 'bg_path_dark' : 'bg_path_light', '');
  }

  /** 保存某一模式的背景图；同时把数据结构版本号写成 2 */
  static async saveBgPathFor(dark: boolean, path: string): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    st.putSync(dark ? 'bg_path_dark' : 'bg_path_light', path);
    st.putSync('bg_path_ver', 2);
    await st.flush();
  }

  /**
   * 旧版只有一份 `bg_path`（不分深浅色）。首次升级时把它**复制**到两套配置里，
   * 这样升级前后背景观感完全一致，也不会因为只归入一种模式而让另一种模式突然变样。
   * 已是 v2 或旧值为空则不做任何事；旧键保留不删，便于回滚。
   */
  static async migrateBgPaths(): Promise<void> {
    ConfigStore.migrateBgPathsSync();
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    await st.flush();
  }

  /** 迁移的同步部分：页面 loadConfig 里可以安全地同步调用，避免读到半迁移状态 */
  static migrateBgPathsSync(): void {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    const ver: number = ConfigStore.num('bg_path_ver', 0);
    if (ver >= 2) {
      return;
    }
    const legacy: string = ConfigStore.str('bg_path', '');
    if (legacy.length > 0) {
      st.putSync('bg_path_light', legacy);
      st.putSync('bg_path_dark', legacy);
    }
    st.putSync('bg_path_ver', 2);
  }

  /** 启动阶段同步取两套背景图（供进程创建时预读，避免首帧闪空白） */
  static bgPathSnapshot(): BgSnapshot {
    const st = ConfigStore.store;
    if (st === undefined) {
      return { light: '', dark: '' };
    }
    const ver: number = ConfigStore.num('bg_path_ver', 0);
    if (ver >= 2) {
      return {
        light: ConfigStore.str('bg_path_light', ''),
        dark: ConfigStore.str('bg_path_dark', '')
      };
    }
    const legacy: string = ConfigStore.str('bg_path', '');
    return { light: legacy, dark: legacy };
  }
  /** 读取主题模式，默认「跟随系统」 */
static ui(): UiConfig {
    const d: UiConfig = defaultUiConfig();
    const c: UiConfig = {
      globalImmersion: ConfigStore.str('ui_imm', d.globalImmersion ? '1' : '0') === '1',
      matType: ConfigStore.num('ui_mat_type', d.matType),
      matLevel: ConfigStore.num('ui_mat_level', d.matLevel),
      themeColor: ConfigStore.num('ui_theme_color', d.themeColor),
      bgBlur: ConfigStore.num('ui_bg_blur', d.bgBlur),
      bgBright: ConfigStore.num('ui_bg_bright', d.bgBright),
      bgScrim: ConfigStore.num('ui_bg_scrim', d.bgScrim),
      cardClear: ConfigStore.num('ui_card_clear', d.cardClear),
    langMode: ConfigStore.num('ui_lang', d.langMode)
    };
    return c;
  }

  static async saveUi(c: UiConfig): Promise<void> {
    const st: preferences.Preferences | undefined = ConfigStore.store;
    if (!st) {
      return;
    }
    await st.put('ui_imm', c.globalImmersion ? '1' : '0');
    await st.put('ui_mat_type', c.matType);
    await st.put('ui_mat_level', c.matLevel);
    await st.put('ui_theme_color', c.themeColor);
    await st.put('ui_bg_blur', c.bgBlur);
    await st.put('ui_bg_bright', c.bgBright);
    await st.put('ui_bg_scrim', c.bgScrim);
    await st.put('ui_card_clear', c.cardClear);
  await st.put('ui_lang', c.langMode);
    await st.flush();
  }

  static keepAlive(): boolean {
    const st: preferences.Preferences | undefined = ConfigStore.store;
    if (st === undefined) {
      return false;
    }
    return (st.getSync('keep_alive', '0') as string) === '1';
  }

  static async saveKeepAlive(v: boolean): Promise<void> {
    const st: preferences.Preferences | undefined = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    await st.put('keep_alive', v ? '1' : '0');
    await st.flush();
  }

  static theme(): number {
    return ConfigStore.num('themeMode', ThemeMode.SYSTEM);
  }

  /** 光感等级：0=弱 1=标准 2=强 3=极致（决定底部液态玻璃的模糊与折射强度） */
  static glassLevel(): number {
    const n = ConfigStore.num('glass_level', 1);
    return n < 0 ? 0 : (n > 3 ? 3 : n);
  }

  static async saveGlassLevel(v: number): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    st.putSync('glass_level', v < 0 ? 0 : (v > 3 ? 3 : v));
    await st.flush();
  }

  /** 保存主题模式（切换后立刻落盘，避免重启丢失） */
  static async saveTheme(mode: number): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    st.putSync('themeMode', mode);
    await st.flush();
  }
}
