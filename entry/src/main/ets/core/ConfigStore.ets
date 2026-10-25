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
}

export function defaultUiConfig(): UiConfig {
  const c: UiConfig = {
    globalImmersion: true,
    matType: 0,
    matLevel: 0,
    themeColor: 4,
    bgBlur: 25,
    bgBright: 40
  };
  return c;
}

export const DEFAULT_TRACE_HOST: string = 'speed.cloudflare.com';
export const DEFAULT_TRACE_PATH: string = '/cdn-cgi/trace';
export const PORT_OPTIONS: number[] = [443, 2053, 2083, 2087, 2096, 8443];
const STORE_NAME: string = 'cflark_store';

/** 主题模式：深色 / 浅色 / 跟随系统 */
export enum ThemeMode {
  DARK = 0,
  LIGHT = 1,
  SYSTEM = 2
}

/** 第一轮并发上限：按设备形态分档，避免低端机开太猛反而更慢 */
export function maxScanConcurrency(): number {
  // 移动设备（手机 / 平板）并发上限统一 200；电脑（2in1）同样 200。
  // 超过这个值只会在弱网下制造大量超时并让设备发热，收益为负。
  return 200;
}

/** 默认并发 = 上限的 80% */
export function defaultScanConcurrency(): number {
  // 默认并发 16：实测在移动网络下 16 路已经能把 2000 个候选压在 1~2 分钟内，
  // 再高只会让延迟测量被排队放大、设备发热，用户可手动上调到上限 200。
  return 16;
}
export function defaultScanConfig(): ScanConfig {
  const c: ScanConfig = {
    mode: ScanMode.OFFICIAL,
    ipVersion: IpVersion.V4,
    port: 443,
    sampleCount: 2000,
    customText: '',
    pingTimes: 2,
    pingIntervalMs: 50,
    pingTimeoutMs: 1000,
    latencyLimitMs: 220,
    scanConcurrency: defaultScanConcurrency(),
    traceHost: DEFAULT_TRACE_HOST,
    tracePath: DEFAULT_TRACE_PATH,
    traceConcurrency: 30,
    traceTimeoutMs: 3000,
    enableSpeed: true,
    speedScope: SpeedScope.ALL,
    speedCount: 3,
    speedPerRegion: 3,
    speedRounds: 1,
    speedUrl: 'https://speed.cloudflare.com/__down?bytes=50000000',
    speedWindowMs: 3000,
    speedConcurrency: 1,
    speedGapMs: 300,
    domain: '',
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

  static load(): ScanConfig {
    const d: ScanConfig = defaultScanConfig();
    d.domain = ConfigStore.str('domain', '');
    return d;
  }

  /** 保存配置：只持久化测速域名，其余参数每次启动走默认值 */
  static async save(c: ScanConfig): Promise<void> {
    const st = ConfigStore.store;
    if (st === undefined) {
      return;
    }
    st.putSync('domain', c.domain);
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
  /** 读取主题模式，默认「跟随系统」 */
static ui(): UiConfig {
    const d: UiConfig = defaultUiConfig();
    const c: UiConfig = {
      globalImmersion: ConfigStore.str('ui_imm', d.globalImmersion ? '1' : '0') === '1',
      matType: ConfigStore.num('ui_mat_type', d.matType),
      matLevel: ConfigStore.num('ui_mat_level', d.matLevel),
      themeColor: ConfigStore.num('ui_theme_color', d.themeColor),
      bgBlur: ConfigStore.num('ui_bg_blur', d.bgBlur),
      bgBright: ConfigStore.num('ui_bg_bright', d.bgBright)
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
