/**
 * CFLark 数据模型
 *
 * 优选策略对齐 CloudFlareScan（用户指定）：
 *  阶段一「快速筛选」：每个 IP 连 pingTimes 次 TCP（默认 2 次，间隔 50ms），取其中最小延迟；
 *      最小延迟低于 latencyLimitMs（默认 220ms）才算通过；通过后再请求 /cdn-cgi/trace 取 colo。
 *  阶段二「测速」：把通过的候选按延迟从低到高排序（可选按地区码只保留该地区的 colo），
 *      取延迟最低的前 speedCount 个（默认 10，用户可改，范围 1~99）逐个测速；
 *      每个地址测 speedRounds 次取平均；下载窗口 3 秒，URL /__down?bytes=50000000。
 *  排名：finalScore = delayScore*delayWeight + speedScore*speedWeight，
 *      两个分数都在结果集内做 min-max 归一化；速度权重默认 0.7（高于延迟），
 *      因为测到的真实带宽比握手延迟更能代表使用体验。
 *  域名（可选）：填了就在测速阶段用它当 Host / SNI，没填就用 speed.cloudflare.com。
 */

/** 候选来源 */
export enum ScanMode {
  OFFICIAL = 0,
  CUSTOM = 1
}

/** IP 版本 */
export enum IpVersion {
  V4 = 4,
  V6 = 6
}

/** 候选走到哪个阶段 */
/** 测速范围：ALL = 第一轮通过的全部节点；REGION = 只测指定地区码；PER_REGION = 每个地区各取前 N 个 */
export enum SpeedScope {
  ALL = 0,
  REGION = 1,
  PER_REGION = 2
}

export enum Stage {
  NONE = 0,
  PING = 1,
  COLO = 2,
  SPEED = 3
}

/** 结果判定（简单直接，对齐 CloudFlareScan 的双阶段语义） */
export enum Verdict {
  UNKNOWN = 0,
  /** 延迟达标且有 colo，但没测速 */
  PASS = 1,
  /** 测速完成 */
  SPEEDED = 2,
  /** TCP 通但延迟超过上限 */
  SLOW = 3,
  /** ping 不通 */
  FAILED = 4
}

/** 文本展示（ArkUI 层不要直接用枚举拼字符串） */
export class VerdictText {
  static label(v: Verdict): string {
    if (v === Verdict.SPEEDED) {
      return '已测速';
    }
    if (v === Verdict.PASS) {
      return '延迟达标';
    }
    if (v === Verdict.SLOW) {
      return '延迟超限';
    }
    if (v === Verdict.FAILED) {
      return '无法连通';
    }
    return '未测试';
  }

  static color(v: Verdict): string {
    if (v === Verdict.SPEEDED) {
      return '#10B981';
    }
    if (v === Verdict.PASS) {
      return '#10B981';
    }
    if (v === Verdict.SLOW) {
      return '#F59E0B';
    }
    if (v === Verdict.FAILED) {
      return '#F43F5E';
    }
    return '#A1A1AA';
  }
}

/** 单个候选 IP 的全部测量数据 */
export interface Candidate {
  ip: string;
  port: number;
  version: number;
  stage: Stage;

  // ---- 阶段一：TCP 延迟 ----
  pingSent: number;
  pingRecv: number;
  /** 多次 ping 里的最小值，CloudFlareScan 用这个做筛选 */
  minLatencyMs: number;
  avgLatencyMs: number;
  maxLatencyMs: number;
  lossRate: number;

  // ---- colo 探测 ----
  colo: string;
  traceOk: boolean;
  traceDelayMs: number;
  httpCode: number;

  // ---- 阶段二：下载测速 ----
  speedMbps: number;
  speedMaxMbps: number;
  speedRounds: number;
  speedOk: boolean;

  // ---- 评分 ----
  delayScore: number;
  speedScore: number;
  finalScore: number;

  verdict: Verdict;
  remark: string;
  /** 失败原因分类（timeout/refused/quality/colo 等，用于日志与调试） */
  failReason: string;
}

/** trace 探测的原始结果 */
export interface ProbeOutcome {
  ok: boolean;
  tcpMs: number;
  tlsMs: number;
  ttfbMs: number;
  totalMs: number;
  httpCode: number;
  colo: string;
  errorCode: number;
  errorMsg: string;
}

/** 单次 TCP ping 结果 */
export interface TcpPingResult {
  ok: boolean;
  rttMs: number;
  errorCode: number;
}

/** 测速结果 */
export interface SpeedResult {
  ok: boolean;
  avgMbps: number;
  maxMbps: number;
  bytes: number;
  costMs: number;
  error: string;
}

/** 进度回调 */
export class ScanProgress {
  phase: number = 0;
  phaseText: string = '';
  done: number = 0;
  total: number = 0;
  passed: number = 0;
  failed: number = 0;
  currentLatency: number = 0;
  finished: boolean = false;
}

/** 域名解析结果 */
export interface DomainInfo {
  domain: string;
  ok: boolean;
  ips: string[];
  isCloudflare: boolean;
  error: string;
}

/** 完整扫描配置 */
export interface ScanConfig {
  // 候选
  mode: ScanMode;
  ipVersion: IpVersion;
  port: number;
  sampleCount: number;
  customText: string;
  /**
   * 当前选中的候选来源分组（只在运行期使用，持久化由 Sources 按 IP 族独立维护）：
   * builtin.official / builtin.community / 自定义分组 id。
   * 扫描日志用它说明"这次用的是哪个分组的候选数据"。
   */
  sourceGroupId: string;
  /** 选中分组的显示名（日志/提示用） */
  sourceGroupName: string;
  /** 是否用测速域名做 A/AAAA 解析采样并并入候选 */
  domainSampling: boolean;

  // 阶段一：TCP 快速筛选
  pingTimes: number;
  pingIntervalMs: number;
  pingTimeoutMs: number;
  /** 延迟上限（ms），超过就淘汰，CloudFlareScan 默认 220 */
  latencyLimitMs: number;
  /** TCP 并发 */
  scanConcurrency: number;

  // colo 探测
  traceHost: string;
  tracePath: string;
  traceConcurrency: number;
  traceTimeoutMs: number;

  // 阶段二：测速
  enableSpeed: boolean;
  /** 测速范围：ALL = 第一轮通过的全部节点；REGION = 只测指定地区；PER_REGION = 每个地区各取前 N 个 */
  speedScope: SpeedScope;
  /** ALL 模式下的数量上限，0 = 不限（全测） */
  speedCount: number;
  /** PER_REGION 模式下每个地区取延迟最低的前几个 */
  speedPerRegion: number;
  /** 每个地址测几次取平均，CloudFlareScan 默认 1，用户可调到 10 */
  speedRounds: number;
  speedUrl: string;
  /** 下载窗口（ms） */
  speedWindowMs: number;
  /** 测速并发（串行=1，对齐 CloudFlareScan） */
  speedConcurrency: number;
  /** 测速间隔（ms） */
  speedGapMs: number;
  /** 合格速度（MB/s）：测速结果低于该值会被淘汰，0 = 不淘汰 */
  minSpeedMbps: number;

  /** 测速阶段使用的域名（Host / SNI）；留空则用 traceHost */
  domain: string;
  /** 地区码（如 HKG / LAX）；留空 = 完全测速 */
  regionCode: string;

  // 排名
  delayWeight: number;
  speedWeight: number;
  resultLimit: number;
}

/** 应用设置（跨页共享） */
export interface AppSettings {
  darkTheme: boolean;
  autoTheme: boolean;
}