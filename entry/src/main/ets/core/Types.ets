/**
 * CFLark 数据模型
 *
 * 优选流程（当前实现）：
 *  阶段一「快速筛选」：每个 IP 连 pingTimes 次 TCP（默认 3 次，间隔 50ms），取其中最小延迟；
 *      首包已明显低于门槛或首次超时会提前结束，未发出的探测不算丢包。
 *      最小延迟低于 latencyLimitMs（默认 320ms）才算通过；通过后再请求 /cdn-cgi/trace 取 colo。
 *  阶段二「质量预检 + 测速」：先按延迟升序取候选做短窗口预检；达标节点再取延迟最低的
 *      前 speedCount 个（默认 10，范围 1~99）逐个测速；每个地址测 speedRounds 次取平均，
 *      下载窗口默认 6 秒，URL /__down?bytes=50000000。
 *  排名：finalScore = delayScore*delayWeight + speedScore*speedWeight，
 *      两个分数都用「相对最优」归一化（delayScore=minDelay/delay，speedScore=speed/maxSpeed），
 *      速度权重默认 0.9（高于延迟）；界面、CSV 导出与实际上传共用这一顺序。
 *  域名（可选）：解析其 A/AAAA 记录并入候选；开启「域名端到端检测」后，还会在正式测速前
 *      对入选节点各发一次 HTTPS 请求。下载测速始终使用 speed.cloudflare.com。
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
  /**
   * 参与评分与排名的速度（方案 A 的「有效速度」）：
   *   有效速度 = 成功轮速度的中位数 ×（成功轮数 ÷ 设定轮数）
   * 失败轮通过这个比例参与惩罚，因此它不等于「成功轮的平均速度」；
   * 全失败节点固定为 0。界面上展示的实测均值见 speedAvgMbps。
   */
  speedMbps: number;
  /** 成功轮里的最高速度（MB/s）；只统计成功轮，0 表示没有成功轮 */
  speedMaxMbps: number;
  /** 成功轮里的最低速度（MB/s）；0 表示没有成功轮 */
  speedMinMbps: number;
  /** 成功轮的算术平均速度（MB/s）；只描述「实际测出多少」，不参与评分 */
  speedAvgMbps: number;
  /** 成功轮数（不是设定轮数；设定轮数见 speedCfgRounds） */
  speedRounds: number;
  /** 本轮配置的设定轮数；与 speedRounds 对比即可看出失败了几轮 */
  speedCfgRounds: number;
  speedOk: boolean;
  /**
   * 每一轮的实测速度（MB/s），用 `/` 分隔，失败轮写 `—`。仅用于导出与排查，
   * 不参与任何评分或排名；长度等于本轮实际执行到的轮数，不是配置次数。
   */
  speedSamples: string;
  /**
   * 每一轮的结果（`成功` 或失败原因，如 `HTTP 429`），用 `/` 分隔。仅用于导出与排查。
   */
  speedStates: string;
  /**
   * 每一轮的握手延迟（ms），用 `/` 分隔，未测到写 `—`。
   * 这是第十三轮之后新增的「逐轮延迟」采集，仅用于展开详情展示，不参与任何筛选或评分。
   */
  speedLatSamples: string;
  /**
   * 每一轮的丢包率（%），用 `/` 分隔，未测到写 `—`。仅用于展示，不参与评分。
   */
  speedLossSamples: string;
  /** 第三阶段逐轮 TCP 握手成功次数（排除用户取消与无效轮） */
  linkOk: number;
  /** 第三阶段逐轮 TCP 握手尝试次数（排除用户取消与无效轮） */
  linkTries: number;
  /** 第三阶段有效握手的平均 RTT（ms）；<=0 表示没有有效握手样本 */
  speedDelayMs: number;
  /** 稳定性得分 0–100（拉普拉斯平滑）；-1 表示没有有效握手样本 */
  stabilityScore: number;

  // ---- 评分 ----
  delayScore: number;
  speedScore: number;
  finalScore: number;

  verdict: Verdict;
  remark: string;
  /** 失败原因分类（timeout/refused/quality/colo 等，用于日志与调试） */
  failReason: string;
}

/** 测速结果 */
export interface SpeedResult {
  ok: boolean;
  avgMbps: number;
  maxMbps: number;
  bytes: number;
  costMs: number;
  error: string;
  /** 下载响应的 HTTP 状态码；0 表示没拿到（被统计窗口提前截断或连接失败）。仅诊断用。 */
  statusCode: number;
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
  /** 延迟上限（ms），超过就淘汰，默认 320 */
  latencyLimitMs: number;
  /** 丢包率上限（%）：0~100，超过就淘汰；0 = 不允许丢包（默认），100 = 不按丢包筛选 */
  maxLossPct: number;
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

  /**
   * 自定义域名：① 解析采样时并入候选池；② 开启 domainCheck 后用于端到端检测。
   * 注意：下载测速始终走 CF 官方地址，不会使用该域名作为 Host/SNI。
   */
  domain: string;
  /**
   * 是否启用「自定义域名端到端检测」。
   * 必须同时满足：开关打开 + domain 有效；只在正式测速阶段对入选节点各做一次
   * HTTPS 请求（Host/SNI = domain，DNS 指到候选 IP），失败节点不进入结果与上传。
   * 默认关闭，保持原有「域名只做解析采样」的行为。
   */
  domainCheck: boolean;
  /** 地区码（如 HKG / LAX）；留空 = 完全测速 */
  regionCode: string;

  // 排名
  delayWeight: number;
  speedWeight: number;
  resultLimit: number;
}

// ===== 测速历史快照 =====
//
// 历史记录只保存「当时算出来的数字」，读取时不再重算：
// 以后即使调整评分公式/权重，旧记录的评分与排名也必须保持原样。
// 列表只读 index.json 里的小摘要，完整记录点开详情才按需读文件。

/** 历史记录里的一轮下载测速（只保存实际执行到的轮次） */
export interface HistoryRound {
  /** 该轮实测速度（MB/s）；失败轮固定 0 */
  mbps: number;
  /** 该轮是否成功 */
  ok: boolean;
  /** 成功，或失败原因（HTTP 429 / 未读到数据 / 数据不足…） */
  state: string;
  /** 该轮握手延迟（ms）；-1 表示该轮未采集到（旧快照或失败轮） */
  latencyMs: number;
  /** 该轮丢包率（%）；-1 表示该轮未采集到（旧快照或失败轮） */
  lossRate: number;
}

/** 历史记录里的单个节点（统计值、评分、排名均为当时快照） */
export interface HistoryNode {
  ip: string;
  port: number;
  version: number;
  colo: string;
  minLatencyMs: number;
  avgLatencyMs: number;
  maxLatencyMs: number;
  lossRate: number;
  pingSent: number;
  pingRecv: number;
  /** 成功轮里的最低速度（MB/s） */
  speedMinMbps: number;
  /** 成功轮里的最高速度（MB/s） */
  speedMaxMbps: number;
  /** 成功轮算术平均速度（MB/s，展示用） */
  speedAvgMbps: number;
  /** 方案 A 有效速度（MB/s，评分与排名用） */
  speedEffMbps: number;
  successRounds: number;
  cfgRounds: number;
  /** 稳定性样本（旧快照没有这三个字段，读取时按 -1 兜底） */
  linkOk: number;
  linkTries: number;
  stabilityScore: number;
  delayScore: number;
  speedScore: number;
  finalScore: number;
  /** 当时的最终排名（1 起） */
  rank: number;
  /** 测速成功 / 未达标 / 测速失败（全失败节点也保留） */
  status: string;
  remark: string;
  rounds: HistoryRound[];
}

/** 一次测速任务的参数与概况（快照） */
export interface HistoryMeta {
  id: string;
  time: string;
  appVersion: string;
  nodeCount: number;
  okCount: number;
  failCount: number;
  cfgRounds: number;
  latencyLimitMs: number;
  maxLossPct: number;
  pingTimes: number;
  pingTimeoutMs: number;
  speedCount: number;
  speedWindowMs: number;
  minSpeedMbps: number;
  scoreBaseDelayMs: number;
  scoreBaseSpeedMbps: number;
  delayWeight: number;
  speedWeight: number;
}

/** 一条完整历史记录：详情页读取它，不复用当前测速结果 */
export interface HistoryRecord {
  meta: HistoryMeta;
  nodes: HistoryNode[];
}

/** 历史列表项：常驻内存的只有这份摘要 */
export interface HistorySummary {
  id: string;
  time: string;
  nodeCount: number;
  okCount: number;
  failCount: number;
  cfgRounds: number;
  /** 排名第一的节点地址（无节点时为空串） */
  topEndpoint: string;
  topScore: number;
}
// ===== 共享节点卡片视图模型 =====
//
// 当前测速结果（Candidate）与历史快照（HistoryNode）是两套数据，但展示必须是同一套卡片。
// 这里用一个只读视图模型做适配层：两种来源各自映射成 NodeVM，卡片组件只认 NodeVM，
// 以后改卡片样式只需要改一处，不会出现「当前页改了、历史页还是旧的」。

/** 逐轮表格的一行 */
export class RoundVM {
  /** 1 起 */
  index: number = 0;
  /** 该轮握手延迟（ms），-1 = 未采集 */
  latencyMs: number = -1;
  /** 该轮丢包率（%），-1 = 未采集 */
  lossRate: number = -1;
  /** 该轮速度（MB/s），失败轮为 0 */
  mbps: number = 0;
  ok: boolean = false;
  /** `成功` 或失败原因 */
  state: string = '';
}

/** 节点卡片 / 详情表格的视图模型 */
export class NodeVM {
  /** 展开状态用的唯一键：ip:port */
  key: string = '';
  ip: string = '';
  port: number = 0;
  version: number = 4;
  profile: string = '';
  place: string = '';
  /** true = 多轮展示（有评分/排名/逐轮）；false = 单轮简洁卡片 */
  multi: boolean = false;
  /** true = 来自历史快照（只读，复测结果不回写） */
  history: boolean = false;
  minDelay: number = -1;
  avgDelay: number = -1;
  maxDelay: number = -1;
  lossRate: number = -1;
  /** 稳定性 0–100；-1 = 无有效握手样本（N=1 或全部取消） */
  stability: number = -1;
  speedMin: number = 0;
  speedMax: number = 0;
  speedAvg: number = 0;
  speedEff: number = 0;
  okRounds: number = 0;
  cfgRounds: number = 0;
  rank: number = 0;
  delayScore: number = 0;
  speedScore: number = 0;
  finalScore: number = 0;
  /** 单轮卡片右侧的状态文案（成功显示速度，失败显示原因） */
  statusText: string = '';
  /** 失败轮摘要（`R2 HTTP 429 · R3 未读到数据`），空串 = 没有失败轮 */
  failText: string = '';
  /** 整批测速中：该节点尚未轮到 / 正在测速 */
  pending: boolean = false;
  pendingText: string = '';
  /** 单节点复测进行中 */
  retesting: boolean = false;
  rounds: RoundVM[] = [];
}
