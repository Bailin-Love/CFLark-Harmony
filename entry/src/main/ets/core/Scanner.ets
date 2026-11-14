/**
 * CFLark 扫描编排 —— 两阶段，对齐 CloudFlareScan
 *
 * 阶段一「快速筛选」（对应 CloudFlareScan 的 ScanWorker）：
 *   每个候选 IP 连 pingTimes 次 TCP（默认 1 次，间隔 pingIntervalMs），取最小延迟；
 *   最小延迟 >= latencyLimitMs（默认 320ms）或全部失败就淘汰；
 *   通过的再做一次 /cdn-cgi/trace 拿 colo（Host 固定 speed.cloudflare.com）。
 *   为省时间有两个提前结束：首包已低于门槛 60% 直接通过、首次超时直接放弃剩余重试；
 *   丢包率按「真实发出的次数」算分母，未执行的次数不算丢包。
 *
 * 阶段二「测速」（对应 CloudFlareScan 的 SpeedTestWorker）：
 *   把通过的候选按延迟升序排序（可选先按 regionCode 过滤 colo）；
 *   取延迟最低的前 speedCount 个（默认 10，范围 1~99），逐个测速；
 *   每个地址测 speedRounds 次，每个之间 sleep(speedGapMs)；
 *   评分速度用方案 A 的「有效速度」= 成功轮中位数 ×（成功轮数 ÷ 设定轮数），
 *   失败轮不消失、而是按比例扣减；平均/最低/最高只用于展示。
 *   测速的 Host / SNI 固定 speed.cloudflare.com（用户域名一般不提供 /__down 端点）。
 *
 * 可选「自定义域名端到端检测」：开关打开且域名有效时，在正式测速前对已入选的
 *   节点各做一次 https://<域名>/ 请求（DNS 指到候选 IP），失败的节点直接淘汰。
 *
 * 排名：Ranker 负责相对最优归一化 + 加权（延迟 0.1 / 速度 0.9）。
 */
import { Candidate, ScanConfig, ScanMode, IpVersion, Stage, Verdict, SpeedScope } from './Types';
import { IpUtil, CidrV4, CF_IPV4_RANGES, CF_IPV6_RANGES } from './IpUtil';
import { CF_IPV6_POOL_48 } from './V6Pool';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TcpProbe, TcpResult, TraceProbe, TraceResult, TraceTarget } from './Probe';
import { SpeedTest, SpeedTarget } from './SpeedTest';
import { DnsService } from './DnsService';
import { Ranker } from './Ranker';

export const DEFAULT_TRACE_HOST: string = 'speed.cloudflare.com';
export const DEFAULT_TRACE_PATH: string = '/cdn-cgi/trace';
export const SPEED_PATH: string = '/__down?bytes=50000000';

/** 进度与结果回调（必须是 class，ArkTS 不接受未标注类型的对象字面量） */
export class ScanHooks {
  onPhase: (phase: number, text: string) => void = (phase: number, text: string) => {
  };
  onProgress: (done: number, total: number, passed: number, failed: number) => void =
    (done: number, total: number, passed: number, failed: number) => {
    };
  onResult: (list: Candidate[]) => void = (list: Candidate[]) => {
  };
  onLog: (msg: string) => void = (msg: string) => {
  };
  /** 测速阶段开始：一次性把「全部待测目标」交给 UI，让列表先铺满再逐个刷新 */
  onSpeedInit: (targets: Candidate[]) => void = (targets: Candidate[]) => {
  };
  /** 单个地址测速状态变化：done=false 开始测，done=true 测完（结果已写回 c） */
  onSpeedTick: (index: number, c: Candidate, done: boolean) => void =
    (index: number, c: Candidate, done: boolean) => {
    };
  /** 质量预检开始：target=目标达标数，candidates=参与预检的候选数 */
  onPrecheckStart: (target: number, candidates: number) => void = (target: number, candidates: number) => {
  };
  /** 质量预检进度：checked=已检测，qualified=已达标，inflight=在测数，target=目标达标数 */
  onPrecheckTick: (checked: number, qualified: number, inflight: number, target: number) => void =
    (checked: number, qualified: number, inflight: number, target: number) => {
    };
  /** 质量预检结束：done=true 时结果已定，exhausted=候选不足/提前中止 */
  onPrecheckDone: (qualified: number, checked: number, exhausted: boolean, target: number) => void =
    (qualified: number, checked: number, exhausted: boolean, target: number) => {
    };
  /**
   * 单个节点的预检结果（诊断用）：把每个节点实际测到的速度、字节数、耗时、
   * HTTP 状态码和判定结果交给 UI 写进运行日志。
   *
   * 为什么需要它：合格速度 0.4 MB/s 却「全部不通过」时，只看一个「0 个达标」
   * 的数字分不清是「网络确实慢」「阈值没生效」还是「节点回了 429/错误页」。
   * 把每次探测的真实数字摊开，才能把配置问题、阈值问题和网络问题区分开。
   * 这条日志不参与任何评分或筛选，只用于排查。
   */
  onProbeResult: (text: string) => void = (text: string) => {
  };
  /**
   * 本轮在进入下载测速前被中止（目前只有「域名端到端检测全部失败」这一种）。
   * reason 是给用户看的中文原因；UI 据此显示失败阶段与后续动作建议，
   * 不能把它当成「测速完成」。
   */
  onAborted: (reason: string, suggestion: string) => void = (reason: string, suggestion: string) => {
  };
}

/** 取消令牌 */
export class CancellationToken {
  private cancelled: boolean = false;

  isCancelled(): boolean {
    return this.cancelled;
  }

  cancel(): void {
    this.cancelled = true;
  }

  reset(): void {
    this.cancelled = false;
  }
}

/** 质量预检结果：list=达标节点；quota/target 为目标数；checked 为实际检测数 */
export class PrecheckResult {
  list: Candidate[] = [];
  quota: number = 0;
  checked: number = 0;
  qualified: number = 0;
  exhausted: boolean = false;
  cancelled: boolean = false;
}

/**
 * 单节点预检的诊断报告。只用于把「每个节点实际测到了什么」写进运行日志，
 * 不参与评分、排名或任何筛选判定。
 */
export interface ProbeReport {
  /** 是否达到用户设置的合格速度（r.ok && avgMbps >= minSpeedMbps） */
  ok: boolean;
  /** 本窗口内的实测速度（MB/s），按「首字节→结束」的有效时长计算 */
  avgMbps: number;
  /** 实际收到的字节数，0 表示什么都没下到（不能当成「速度 0」） */
  bytes: number;
  /** 本次探测耗时（ms） */
  costMs: number;
  /** HTTP 状态码，0 表示没拿到响应（TLS/连接层就失败了） */
  statusCode: number;
  /** 失败原因（成功时为空） */
  error: string;
}

export class Scanner {
  /** 上一次 customCandidates 解析跳过的行数（用于日志提示） */
  static lastParseSkipped: number = 0;
  /** 上一次 runPing 里因 IP 版本不符被剔除的候选数（0 = 没有跨类型污染） */
  static lastDroppedByType: number = 0;

  static makeCandidate(ip: string, port: number, version: number): Candidate {
    const c: Candidate = {
      ip: ip,
      port: port,
      version: version,
      stage: Stage.NONE,
      pingSent: 0,
      pingRecv: 0,
      minLatencyMs: -1,
      avgLatencyMs: -1,
      maxLatencyMs: -1,
      lossRate: 0,
      colo: '',
      traceOk: false,
      traceDelayMs: -1,
      httpCode: 0,
      speedMbps: 0,
      speedMaxMbps: 0,
      speedMinMbps: 0,
      speedAvgMbps: 0,
      speedRounds: 0,
      speedCfgRounds: 0,
      speedOk: false,
      speedSamples: '',
      speedStates: '',
      speedLatSamples: '',
      speedLossSamples: '',
      linkOk: 0,
      linkTries: 0,
      speedDelayMs: 0,
      stabilityScore: -1,
      delayScore: 0,
      speedScore: 0,
      finalScore: 0,
      verdict: Verdict.UNKNOWN,
      remark: '',
      failReason: ''
    };
    return c;
  }

  static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 最近一次官方 IPv6 分层采样可用 /48 块总数（仅用于日志展示） */
  static lastLayeredBlock48: number = 0;

  /** 官方 IP 段候选：每个 /24 随机取 1 个，对齐 CFData-WEB 的 getRandomIPv4s */
  static officialCandidates(cfg: ScanConfig): Candidate[] {
    const out: Candidate[] = [];
    if (cfg.ipVersion === IpVersion.V6) {
      // 官方 IPv6：优先用社区维护的 /48 池（实测命中率远高于 /32 随机 /48），
      // 池为空时退回官方 /32 段分层采样。
      const usePool: boolean = CF_IPV6_POOL_48.length > 0;
      if (usePool) {
        Scanner.lastLayeredBlock48 = CF_IPV6_POOL_48.length;
        // 采样数 <= 0：全部 /48 池各取 1 个地址
        const per: number = cfg.sampleCount <= 0 ? 1
          : Math.max(1, Math.ceil(cfg.sampleCount / CF_IPV6_POOL_48.length));
        for (let i = 0; i < CF_IPV6_POOL_48.length; i++) {
          const ips: string[] = IpUtil.sampleV6Layered(CF_IPV6_POOL_48[i], per);
          for (let j = 0; j < ips.length; j++) {
            out.push(Scanner.makeCandidate(ips[j], cfg.port, 6));
          }
        }
        return out;
      }
      const per: number = cfg.sampleCount <= 0 ? 1
        : Math.max(1, Math.ceil(cfg.sampleCount / CF_IPV6_RANGES.length));
      for (let i = 0; i < CF_IPV6_RANGES.length; i++) {
        const ips: string[] = IpUtil.sampleV6Layered(CF_IPV6_RANGES[i], per);
        for (let j = 0; j < ips.length; j++) {
          out.push(Scanner.makeCandidate(ips[j], cfg.port, 6));
        }
      }
      return out;
    }
    const bases: number[] = [];
    for (let i = 0; i < CF_IPV4_RANGES.length; i++) {
      const cidr: string = CF_IPV4_RANGES[i];
      const r: CidrV4 = IpUtil.parseCidrV4(cidr);
      if (r.count <= 0) {
        continue;
      }
      const n24: number = r.count >= 256 ? Math.floor(r.count / 256) : 1;
      for (let k = 0; k < n24; k++) {
        bases.push((r.start + k * 256) >>> 0);
      }
    }
    const shuffled: number[] = IpUtil.shuffle<number>(bases);
    // 采样数 <= 0：全部 /24 各取 1 个
    const need: number = cfg.sampleCount <= 0 ? shuffled.length : Math.min(cfg.sampleCount, shuffled.length);
    for (let i = 0; i < need; i++) {
      const base: number = shuffled[i];
      const off: number = 1 + Math.floor(Math.random() * 254);
      out.push(Scanner.makeCandidate(IpUtil.intToIpv4((base + off) >>> 0), cfg.port, 4));
    }
    return out;
  }

  /** 自定义候选：支持 CIDR / ip:port / [v6]:port / 纯 IPv6，一行一个，# 开头是注释 */
  /**
   * 从多行文本里随机抽取 limit 条有效行（跳过空行与 # 注释）。
   * 用于「来源行数 > 采样数」时把候选量收敛到采样数。
   */
  private static pickLines(text: string, limit: number): string {
    const src: string[] = text.split(String.fromCharCode(10));
    const valid: string[] = [];
    for (let i = 0; i < src.length; i++) {
      const t: string = src[i].trim();
      if (t.length > 0 && !t.startsWith('#')) {
        valid.push(t);
      }
    }
    if (limit >= valid.length || limit <= 0) {
      return text;
    }
    // Fisher-Yates 洗牌后取前 limit 条，保证每次扫描抽样不同
    for (let i = valid.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: string = valid[i];
      valid[i] = valid[j];
      valid[j] = tmp;
    }
    return valid.slice(0, limit).join(String.fromCharCode(10));
  }

  static customCandidates(text: string, defaultPort: number, perCidr: number = 20): Candidate[] {
    const out: Candidate[] = [];
    let skipped: number = 0;
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      let raw: string = lines[i].trim();
      if (raw.length === 0 || raw.startsWith('#')) {
        continue;
      }
      const hash: number = raw.indexOf('#');
      if (hash > 0) {
        raw = raw.substring(0, hash).trim();
      }
      if (raw.indexOf('/') > 0) {
        if (raw.indexOf(':') > 0) {
          // IPv6 CIDR：/48 等分层列表（社区优选库就是这种格式）
          const prefix: number = IpUtil.cidrV6Prefix(raw);
          if (prefix < 0 || prefix > 128) {
            skipped++;
            continue;
          }
          const ips6: string[] = IpUtil.sampleV6(raw, perCidr);
          for (let k6 = 0; k6 < ips6.length; k6++) {
            out.push(Scanner.makeCandidate(ips6[k6], defaultPort, 6));
          }
          continue;
        }
        const r: CidrV4 = IpUtil.parseCidrV4(raw);
        if (r.count <= 0) {
          skipped++;
          continue;
        }
        const ips: string[] = IpUtil.sampleV4(raw, perCidr);
        for (let k = 0; k < ips.length; k++) {
          out.push(Scanner.makeCandidate(ips[k], defaultPort, 4));
        }
        continue;
      }
      let host: string = raw;
      let port: number = defaultPort;
      if (host.startsWith('[')) {
        const close: number = host.indexOf(']');
        if (close > 0) {
          const rest: string = host.substring(close + 1);
          host = host.substring(1, close);
          if (rest.startsWith(':')) {
            const pv: number = parseInt(rest.substring(1), 10);
            if (pv > 0 && pv < 65536) {
              port = pv;
            }
          }
        }
      } else {
        // 纯地址：v4 形如 1.2.3.4:443；v6 可能裸写 2606:4700::1 或 2606:4700::1:2053
        const colon: number = host.lastIndexOf(':');
        if (colon > 0) {
          const portText: string = host.substring(colon + 1);
          let digits: boolean = portText.length > 0;
          for (let d = 0; d < portText.length; d++) {
            const code: number = portText.charCodeAt(d);
            if (code < 48 || code > 57) {
              digits = false;
              break;
            }
          }
          if (digits) {
            const pv: number = parseInt(portText, 10);
            const head: string = host.substring(0, colon);
            if (pv > 0 && pv < 65536 && host.indexOf(':') === colon) {
              port = pv;
              host = head;
            } else if (pv > 0 && pv < 65536 && Scanner.strictV6(host) && Scanner.strictV6(head)) {
              // 纯 IPv6 带端口：整串与前缀都必须是合法 IPv6 才拆分端口。
              // 否则 2606:4700::1 这种「:: 前缩写 + 末段纯数字」会被误当成端口，
              // 拆出非法 host 后整条地址被静默丢弃。
              port = pv;
              host = head;
            }
          }
        }
      }
      if (!IpUtil.isV4(host) && !IpUtil.isV6(host)) {
        skipped++;
        continue;
      }
      out.push(Scanner.makeCandidate(host, port, IpUtil.isV6(host) ? 6 : 4));
    }
    Scanner.lastParseSkipped = skipped;
    return out;
  }

  static dedupe(list: Candidate[]): Candidate[] {
    const seen: Set<string> = new Set<string>();
    const out: Candidate[] = [];
    for (let i = 0; i < list.length; i++) {
      const c: Candidate = list[i];
      const key: string = c.ip + ':' + c.port.toString();
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      out.push(c);
    }
    return out;
  }

  /**
   * 严格按实际地址格式校验并只保留指定 IP 版本的候选。
   * 这是「V4 筛选流程只能产生 IPv4 节点」的最后一道闸门：
   * 不看 Candidate.version 字段（它可能来自历史/异常数据），而是直接解析 ip 文本。
   */
  static filterByVersion(list: Candidate[], ver: IpVersion): Candidate[] {
    const wantV6: boolean = ver === IpVersion.V6;
    const out: Candidate[] = [];
    for (let i = 0; i < list.length; i++) {
      const c: Candidate = list[i];
      const isV6: boolean = Scanner.strictV6(c.ip);
      const isV4: boolean = !isV6 && Scanner.strictV4(c.ip);
      if (wantV6 ? isV6 : isV4) {
        c.version = wantV6 ? 6 : 4;
        out.push(c);
      }
    }
    Scanner.lastDroppedByType = list.length - out.length;
    return out;
  }

  /** 严格 IPv4：四段十进制、每段 0-255 */
  private static strictV4(ip: string): boolean {
    const parts: string[] = ip.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < 4; i++) {
      const p: string = parts[i];
      if (p.length === 0 || p.length > 3) {
        return false;
      }
      for (let k = 0; k < p.length; k++) {
        const code: number = p.charCodeAt(k);
        if (code < 48 || code > 57) {
          return false;
        }
      }
      const v: number = Number(p);
      if (isNaN(v) || v < 0 || v > 255) {
        return false;
      }
    }
    return true;
  }

  /** 严格 IPv6：展开成 8 组再校验（不认内嵌 IPv4） */
  private static strictV6(ip: string): boolean {
    if (ip.indexOf(':') < 0 || ip.indexOf('.') >= 0) {
      return false;
    }
    return IpUtil.ipv6ToBytes(ip).length === 16;
  }

  /** 并发池：cursor + N 个 worker */
  static pool<T>(count: number, concurrency: number, token: CancellationToken,
    fn: (index: number) => Promise<T>): Promise<void> {
    const workers: number = Math.max(1, Math.min(concurrency, count));
    let cursor: number = 0;
    const runner = async (): Promise<void> => {
      while (true) {
        if (token.isCancelled()) {
          return;
        }
        const idx: number = cursor;
        if (idx >= count) {
          return;
        }
        cursor = idx + 1;
        await fn(idx);
      }
    };
    const tasks: Promise<void>[] = [];
    for (let i = 0; i < workers; i++) {
      tasks.push(runner());
    }
    return Promise.all(tasks).then(() => {
      return;
    });
  }

  /** 阶段一：TCP 快速筛选（按真实结果分类统计，不把超时/错误混成「TCP 不通」） */
  /**
   * IPv6 环境自检：真机/路由掉线时先给一条可区分的日志，
   * 避免把「环境没有 IPv6」误判成「代码故障」。
   */
  static async checkV6Env(): Promise<boolean> {
    try {
      const r: TcpResult = await TcpProbe.pingOnce('2606:4700:4700::1111', 443, 3000);
      return r.ok && r.rttMs > 0;
    } catch (e) {
      return false;
    }
  }

  /**
   * 质量预检单节点：小窗口快速估速（只用于判断能否达标，不参与最终统计）。
   * 返回带诊断字段的报告，不只是 boolean——「0 个达标」时必须能说清每个节点
   * 到底测到了多少、花了多久、服务端回了什么。
   */
  private static async probeQuality(c: Candidate, cfg: ScanConfig, windowMs: number): Promise<ProbeReport> {
    const t: SpeedTarget = {
      ip: c.ip,
      port: c.port,
      host: DEFAULT_TRACE_HOST,
      url: 'https://' + DEFAULT_TRACE_HOST + SPEED_PATH,
      timeoutMs: Math.min(cfg.traceTimeoutMs, 3000),
      windowMs: windowMs,
      maxBytes: 2 * 1024 * 1024
    };
    try {
      const r = await SpeedTest.run(t);
      const rep: ProbeReport = {
        ok: r.ok && r.avgMbps >= cfg.minSpeedMbps,
        avgMbps: r.avgMbps,
        bytes: r.bytes,
        costMs: r.costMs,
        statusCode: r.statusCode,
        error: r.error
      };
      return rep;
    } catch (e) {
      const rep: ProbeReport = { ok: false, avgMbps: 0, bytes: 0, costMs: 0, statusCode: 0, error: '探测异常' };
      return rep;
    }
  }

  /**
   * 质量预检：进入正式测速前，按延迟从低到高只挑出「测速地址数」个达标节点。
   * - 完全测速：所有地区合计目标 = speedCount；全部地区：每地区各 speedPerRegion 个；
   *   地区测速：只预检 regionCode 指定地区；三种都支持合格速度门槛。
   * - 有界并发 4、达标即停；不达标顺延；检测数/合格数/在途数实时上报；
   * - 候选耗尽或明显异常时提前结束，返回已经合格的节点，不把未检测节点误标失败。
   */
  static async stagePrecheck(cfg: ScanConfig, candidates: Candidate[], hooks: ScanHooks,
    token: CancellationToken): Promise<PrecheckResult> {
    const res: PrecheckResult = new PrecheckResult();
    const all: Candidate[] = candidates.slice();
    all.sort((a: Candidate, b: Candidate): number => {
      const la: number = a.minLatencyMs > 0 ? a.minLatencyMs : 1e9;
      const lb: number = b.minLatencyMs > 0 ? b.minLatencyMs : 1e9;
      return la - lb;
    });
    const oneRegion: boolean = cfg.speedScope === SpeedScope.REGION;
    const perRegion: boolean = cfg.speedScope === SpeedScope.PER_REGION;
    const wantRegion: string = cfg.regionCode.trim().length > 0 ? cfg.regionCode.trim().toUpperCase() : 'UNK';
    const need: Map<string, number> = new Map<string, number>();
    if (perRegion) {
      const per: number = Math.max(1, Math.min(20, cfg.speedPerRegion));
      for (let i = 0; i < all.length; i++) {
        const k: string = all[i].colo.length > 0 ? all[i].colo.toUpperCase() : 'UNK';
        if (need.get(k) === undefined) {
          need.set(k, per);
          res.quota += per;
        }
      }
    } else if (oneRegion) {
      let n: number = 0;
      for (let i = 0; i < all.length; i++) {
        const k: string = all[i].colo.length > 0 ? all[i].colo.toUpperCase() : 'UNK';
        if (k === wantRegion) {
          n++;
        }
      }
      res.quota = Math.min(Math.max(1, cfg.speedCount), Math.max(1, n));
    } else {
      res.quota = Math.min(Math.max(1, cfg.speedCount), Math.max(1, all.length));
    }
    hooks.onPrecheckStart(res.quota, all.length);
    const minSpeed: number = cfg.minSpeedMbps;
    if (minSpeed <= 0 || all.length === 0 || res.quota <= 0) {
      const taken: Candidate[] = [];
      for (let i = 0; i < all.length && taken.length < res.quota; i++) {
        const k: string = all[i].colo.length > 0 ? all[i].colo.toUpperCase() : 'UNK';
        if (oneRegion && k !== wantRegion) {
          continue;
        }
        taken.push(all[i]);
      }
      res.list = taken;
      res.qualified = taken.length;
      res.checked = 0;
      res.exhausted = res.qualified < res.quota;
      hooks.onPrecheckDone(res.qualified, res.checked, res.exhausted, res.quota);
      return res;
    }
    const gateWindow: number = Math.min(2500, Math.max(1600, Math.floor(cfg.speedWindowMs * 2 / 3)));
    const gateConc: number = 4;
    const maxChecked: number = Math.max(res.quota * 6, 40);
    const limitMs: number = Math.max(30000, res.quota * 12000);
    const startAt: number = Date.now();
    hooks.onPhase(2, '质量预检（目标 ' + res.quota.toString() + ' 个，窗口 ' + gateWindow.toString() +
      'ms，并发 ' + gateConc.toString() + '）');
    hooks.onLog('质量预检开始：参与 ' + all.length.toString() + ' 个，目标 ' + res.quota.toString() +
      ' 个，合格速度 ' + minSpeed.toString() + ' MB/s，单次窗口 ' + gateWindow.toString() + 'ms');

    let next: number = 0;
    const inflight: Set<string> = new Set<string>();
    let abortReason: string = '';
    const quotaOf = (c: Candidate): number => {
      const k: string = c.colo.length > 0 ? c.colo.toUpperCase() : 'UNK';
      const v: number | undefined = need.get(k);
      return v === undefined ? 0 : v;
    };
    const provider = async (): Promise<void> => {
      while (true) {
        if (token.isCancelled()) {
          abortReason = 'cancelled';
          return;
        }
        if (res.qualified >= res.quota) {
          return;
        }
        if ((Date.now() - startAt) > limitMs) {
          abortReason = 'timeout';
          return;
        }
        if (res.checked + inflight.size >= maxChecked) {
          abortReason = 'checked-limit';
          return;
        }
        let pick: number = -1;
        while (next < all.length) {
          const c: Candidate = all[next];
          next++;
          if (perRegion && quotaOf(c) <= 0) {
            continue;
          }
          if (oneRegion) {
            const k: string = c.colo.length > 0 ? c.colo.toUpperCase() : 'UNK';
            if (k !== wantRegion) {
              continue;
            }
          }
          pick = next - 1;
          break;
        }
        if (pick < 0) {
          abortReason = 'exhausted';
          return;
        }
        const c: Candidate = all[pick];
        const key: string = c.ip + ':' + c.port.toString();
        inflight.add(key);
        hooks.onPrecheckTick(res.checked, res.qualified, inflight.size, res.quota);
        const rep: ProbeReport = await Scanner.probeQuality(c, cfg, gateWindow);
        inflight.delete(key);
        if (token.isCancelled()) {
          abortReason = 'cancelled';
          return;
        }
        const ok: boolean = rep.ok;
        // 诊断：把每个节点真正测到的数字写进日志，便于区分「网络慢」「阈值没生效」「服务端拒绝」
        const head: string = '预检 ' + c.ip + ':' + c.port.toString();
        if (rep.bytes <= 0) {
          hooks.onProbeResult(head + ' 未下到数据（' +
            (rep.error.length > 0 ? rep.error : (rep.statusCode > 0 ? 'HTTP ' + rep.statusCode.toString() : '无响应')) +
            '）→ 不达标');
        } else {
          hooks.onProbeResult(head + ' ' + rep.avgMbps.toFixed(2) + ' MB/s（' +
            Math.round(rep.bytes / 1024).toString() + ' KB / ' + rep.costMs.toString() + 'ms，HTTP ' +
            rep.statusCode.toString() + '）→ ' +
            (ok ? '达标' : '不达标（门槛 ' + minSpeed.toString() + ' MB/s）'));
        }
        res.checked++;
        if (ok) {
          c.verdict = Verdict.PASS;
          c.remark = '预检达标';
          c.failReason = '';
          res.list.push(c);
          res.qualified = res.list.length;
          if (perRegion) {
            const k: string = c.colo.length > 0 ? c.colo.toUpperCase() : 'UNK';
            const left: number | undefined = need.get(k);
            need.set(k, (left === undefined ? 1 : left) - 1);
          }
        } else {
          c.verdict = Verdict.FAILED;
          c.remark = '合格速度不达标';
          c.failReason = 'quality';
        }
        hooks.onPrecheckTick(res.checked, res.qualified, inflight.size, res.quota);
        hooks.onProgress(res.checked, all.length, res.qualified,
          Math.max(0, res.checked - res.qualified));
      }
    };
    const workers: Promise<void>[] = [];
    const workerCount: number = Math.max(1, Math.min(gateConc, all.length));
    for (let i = 0; i < workerCount; i++) {
      workers.push(provider());
    }
    await Promise.all(workers);
    if (token.isCancelled()) {
      res.cancelled = true;
    }
    // 并发 4 时收尾那一刻可能同时合格多个，超出目标的裁掉：
    // 目标 10 就只保留 10 个，避免出现「合格 13 / 目标 10」这种越界显示与多测。
    if (res.list.length > res.quota) {
      res.list = res.list.slice(0, res.quota);
    }
    res.qualified = res.list.length;
    res.exhausted = res.qualified < res.quota;
    if (abortReason === 'cancelled') {
      hooks.onLog('质量预检已取消：已检测 ' + res.checked.toString() + ' 个，达标 ' + res.qualified.toString() + ' 个');
    } else if (res.qualified >= res.quota) {
      hooks.onLog('质量预检完成：已检测 ' + res.checked.toString() + ' 个，达标 ' + res.qualified.toString() +
        ' 个（目标 ' + res.quota.toString() + '）');
    } else if (abortReason === 'timeout') {
      hooks.onLog('质量预检超时结束：已用 ' + Math.round((Date.now() - startAt) / 1000).toString() +
        ' 秒，已检测 ' + res.checked.toString() + ' 个，仅达标 ' + res.qualified.toString() +
        ' 个（疑似网络异常或合格速度设置过高，请检查网络）');
    } else if (abortReason === 'checked-limit') {
      hooks.onLog('质量预检提前结束：已检测 ' + res.checked.toString() + ' 个仍不足目标，仅达标 ' +
        res.qualified.toString() + ' 个（达标率过低，请检查网络或调低合格速度）');
    } else {
      hooks.onLog('质量预检结束：候选耗尽，共检测 ' + res.checked.toString() + ' 个，达标 ' +
        res.qualified.toString() + ' 个（目标 ' + res.quota.toString() + '）');
    }
    hooks.onPrecheckDone(res.qualified, res.checked, res.exhausted, res.quota);
    return res;
  }

  /**
   * 有效延迟筛选上限。
   *
   * 2026-11-13 起 IPv4/IPv6 统一使用用户设置的 latencyLimitMs，不再对 IPv6 放大。
   * 原先对 IPv6 按 2.2 倍放大（320 → 704ms）的副作用是：那条「首包已明显快于门槛就
   * 不再重试」的提前结束判断也是用同一个上限算的，阈值一并从 192ms 放宽到 422ms，
   * 于是 IPv6 节点几乎全部只测 1 次 —— 三次延迟完全相同、丢包率只能落在 0% 或 100%。
   *
   * 实测依据（2026-11-13 19:50，移动网络）：优选的 4 个 IPv6 节点延迟 211–283ms，
   * 本来就落在 320ms 以内，不存在「320ms 误杀 IPv6」的证据。用户若要在特定运营商
   * 环境下放宽，直接改界面上的「延迟上限」即可，两族同时生效。
   */
  static effectiveLatencyLimit(cfg: ScanConfig): number {
    return cfg.latencyLimitMs;
  }

  static async stagePing(cfg: ScanConfig, list: Candidate[], hooks: ScanHooks,
    token: CancellationToken): Promise<Candidate[]> {
    const limitMsEff: number = Scanner.effectiveLatencyLimit(cfg);
    hooks.onPhase(1, '第一阶段 · TCP 筛选 + 数据中心（TCP ' + cfg.pingTimes.toString() + ' 次，上限 ' +
      limitMsEff.toString() + 'ms，并行取 colo）');
    if (limitMsEff > cfg.latencyLimitMs) {
      hooks.onLog('IPv6 自适应延迟上限：' + cfg.latencyLimitMs.toString() + 'ms → ' + limitMsEff.toString() +
        'ms（随机 IPv6 路由普遍较远，沿用 IPv4 阈值会误杀大量可达节点）');
    }
    if (cfg.maxLossPct < 100) {
      if (cfg.maxLossPct <= 0) {
        hooks.onLog('连接失败率筛选：已启用，不允许失败（探测失败 1 次即淘汰）');
      } else {
        hooks.onLog('连接失败率筛选：已启用，连接失败率超过 ' + cfg.maxLossPct.toString() + '% 的节点在第一轮直接淘汰');
      }
    }
    hooks.onLog('候选 IP 共 ' + list.length.toString() + ' 个，开始第一轮 TCP 延迟筛选');
    const statStartMs: number = Date.now();
    let done: number = 0;
    let passed: number = 0;
    let overLimit: number = 0;
    let lossFiltered: number = 0;
    let timeouts: number = 0;
    let otherErrors: number = 0;
    let skipped: number = 0;
    const errSamples: string[] = [];
    const keep: Candidate[] = [];
    // 延迟达标的 IP 立刻并行去要数据中心，最后统一收尾
    const coloTasks: Promise<void>[] = [];

    await Scanner.pool<void>(list.length, cfg.scanConcurrency, token, async (index: number): Promise<void> => {
      const c: Candidate = list[index];
      const pings: number[] = [];
      let recv: number = 0;
      let timeoutCount: number = 0;
      let errorCount: number = 0;
      let lastCode: number = -1;
      let lastMsg: string = '';
      let lastStage: string = '';
      let cancelled: boolean = false;
      for (let k = 0; k < cfg.pingTimes; k++) {
        if (token.isCancelled()) {
          cancelled = true;
          break;
        }
        const r: TcpResult = await TcpProbe.pingOnce(c.ip, c.port, cfg.pingTimeoutMs);
        lastStage = r.stage;
        lastCode = r.rawErrorCode;
        lastMsg = r.errorMessage;
        if (r.ok && r.rttMs > 0) {
          pings.push(r.rttMs);
          recv++;
        } else if (r.stage === 'timeout') {
          timeoutCount++;
        } else {
          errorCount++;
        }
        // 第一次就超时：对不可达地址再试没有意义，直接放弃剩余重试，
        // 第一轮耗时可近似减半（这是最常走的失败分支）。
        // 注意：这条只对「一次都没成功」成立，因此不会掩盖真实的多次采样。
        if (r.stage === 'timeout') {
          break;
        }
        // 2026-11-13：删除了「首包已明显快于门槛就不再重试」的提前结束。
        // 用户设置 Ping N 次就必须完成 N 次独立探测，否则 min/avg/max 三值相同、
        // 丢包率只能出现 0% 或 100%，多次采样失去意义。
        if (k < cfg.pingTimes - 1) {
          await Scanner.sleep(cfg.pingIntervalMs);
        }
      }
      if (cancelled) {
        skipped++;
        hooks.onSpeedTick(index, c, true);
        return;
      }
      c.stage = Stage.PING;
      c.pingSent = recv + timeoutCount + errorCount;
      c.pingRecv = recv;
      // 丢包率的分母必须是「真实发出的探测次数」：提前结束（首包够快 / 第一次超时
      // 就放弃剩余重试）时，没发出去的次数不是丢包，否则 pingTimes=3 的快节点
      // 会被算成 66.7% 丢包，后续丢包筛选与展示全部失真。
      c.lossRate = c.pingSent > 0 ? (c.pingSent - recv) / c.pingSent : 0;
      if (recv > 0) {
        let sum: number = 0;
        let mn: number = pings[0];
        let mx: number = pings[0];
        for (let i = 0; i < pings.length; i++) {
          const v: number = pings[i];
          sum += v;
          if (v < mn) {
            mn = v;
          }
          if (v > mx) {
            mx = v;
          }
        }
        c.minLatencyMs = mn;
        c.avgLatencyMs = sum / pings.length;
        c.maxLatencyMs = mx;
      }
      if (recv === 0) {
        c.verdict = Verdict.FAILED;
        if (timeoutCount > 0 && errorCount === 0) {
          c.remark = '连接超时';
          timeouts++;
        } else {
          const codeText: string = lastCode >= 0 ? (' code=' + lastCode.toString()) : '';
          const msgText: string = lastMsg.length > 0 ? (' ' + lastMsg) : '';
          c.remark = '连接失败（' + lastStage + codeText + '）';
          otherErrors++;
          if (errSamples.length < 3) {
            errSamples.push(c.ip + ' ' + lastStage + codeText + msgText);
          }
        }
      } else if (cfg.maxLossPct < 100 && c.lossRate * 100 > cfg.maxLossPct) {
        c.verdict = Verdict.FAILED;
        c.remark = '连接失败率超限';
        lossFiltered++;
      } else if (c.minLatencyMs >= limitMsEff) {
        c.verdict = Verdict.SLOW;
        c.remark = '延迟超限';
        overLimit++;
      } else {
        c.verdict = Verdict.PASS;
        passed++;
        coloTasks.push(Scanner.fetchColo(c, cfg));
      }
      hooks.onSpeedTick(index, c, true);
      done++;
      // 每完成一个真实探测就上报（UI 侧再做 80ms 节流），避免按批次跳跃
      hooks.onProgress(done, list.length, passed, timeouts + otherErrors + overLimit);
    });

    await Promise.all(coloTasks);
    // 必须等 colo 全部拿完再筛：拿不到 colo 的节点走不了 HTTPS，
    // 后面下载测速必然失败，效果未知，直接在第一阶段就排除，
    // 不让它进入「筛选」和「测速」两个界面。
    for (let i = 0; i < list.length; i++) {
      // 注意：fetchColo 成功后会把 stage 改成 COLO，所以这里不能再要求 stage === PING，
      // 否则所有拿到 colo 的节点都会被漏掉（表现为「拿到 colo 0 个」）。
      if (list[i].verdict === Verdict.PASS && list[i].colo.length > 0) {
        keep.push(list[i]);
      }
    }
    // 质量预检已抽到 Scanner.stagePrecheck：在第一轮结束、正式测速前单独执行，
    // 这样「凑满目标才进测速」「进度/在途数上报」「不误标未检测节点」都能单独控制。
    const coloOk: number = keep.length;
    const coloDropped: number = Math.max(0, passed - keep.length);
    hooks.onLog('第一阶段完成：候选 ' + list.length.toString() + ' 个；TCP 成功 ' + passed.toString() +
      ' 个（延迟达标）；延迟超限 ' + overLimit.toString() + ' 个；丢包超限 ' + lossFiltered.toString() +
      ' 个；连接超时 ' + timeouts.toString() +
      ' 个；其他错误 ' + otherErrors.toString() + ' 个；取消/未执行 ' + skipped.toString() +
      ' 个；最终通过 ' + keep.length.toString() + ' 个（拿到 colo ' + coloOk.toString() + ' 个）' +
      (coloDropped > 0 ? ('，另有 ' + coloDropped.toString() + ' 个无法完成 HTTPS 探测') : ''));
    if (errSamples.length > 0) {
      hooks.onLog('连接错误示例：' + errSamples.join('；'));
    }
    let statSent: number = 0;
    let statRecv: number = 0;
    let statLatSum: number = 0;
    let statLatCnt: number = 0;
    for (let i = 0; i < list.length; i++) {
      const sc: Candidate = list[i];
      statSent += sc.pingSent;
      statRecv += sc.pingRecv;
      if (sc.minLatencyMs >= 0 && sc.pingRecv > 0) {
        statLatSum += sc.minLatencyMs;
        statLatCnt++;
      }
    }
    const statDur: number = Math.max(1, Date.now() - statStartMs);
    const statSec: number = statDur / 1000;
    hooks.onLog('统计：版本 ' + (cfg.ipVersion === IpVersion.V6 ? 'IPv6' : 'IPv4') +
      '，候选 ' + list.length.toString() + '，探测 ' + statSent.toString() + ' 次，TCP 成功 ' + statRecv.toString() +
      '，超时 ' + timeouts.toString() + '，其他错误 ' + otherErrors.toString() +
      '，耗时 ' + statSec.toFixed(1) + 's，速率 ' + (statSent / statSec).toFixed(1) + ' 次/s，成功率 ' +
      (statSent > 0 ? (statRecv * 100 / statSent).toFixed(1) : '0') + '%，平均最小延迟 ' +
      (statLatCnt > 0 ? (statLatSum / statLatCnt).toFixed(0) : '-') + 'ms');
    return keep;
  }

  /**
   * 单个候选取数据中心（colo）。
   *
   * 抽出来是为了能在「TCP 延迟筛选」里一旦判定延迟达标就**立刻并行**发起，
   * 而不是等全部 IP ping 完再串行跑一整轮 trace —— 那会白白多花一个阶段的耗时。
   */
  private static async fetchColo(c: Candidate, cfg: ScanConfig): Promise<void> {
    const r: TraceResult = await TraceProbe.request({
      ip: c.ip,
      port: c.port,
      host: DEFAULT_TRACE_HOST,
      path: DEFAULT_TRACE_PATH,
      timeoutMs: cfg.traceTimeoutMs
    });
    c.traceOk = r.ok;
    c.traceDelayMs = r.ok ? r.totalMs : -1;
    c.httpCode = r.httpCode;
    c.colo = r.colo;
    if (r.ok && r.colo.length > 0) {
      c.stage = Stage.COLO;
    } else {
      // trace 走的是 HTTPS（TLS + HTTP），拿不到 colo 说明这条链路的 TLS/HTTP 层不通。
      // 这类节点 TCP 能连、但实际服务不可用，下载测速基本必然失败，
      // 先把原因记下来，结果行能看出「为什么它在未知地区且测速失败」。
      c.remark = r.httpCode > 0 ? ('HTTPS 探测失败（HTTP ' + r.httpCode.toString() + '）') : 'HTTPS 探测未响应';
      // 无法完成 HTTPS 探测 = 实际服务不可用，直接淘汰
      c.verdict = Verdict.FAILED;
    }
  }

  /**
   * 自定义域名端到端检测（可选）：对已经入选的节点逐个用用户域名发起一次
   * HTTPS 请求，DNS 解析强制指向候选 IP，因此同时验证「域名可用」和
   * 「该 IP 能承载这个域名」。拿到任意 HTTP 状态码都算可达（403/404/429/500
   * 也说明 TCP + TLS + Host 链路已经抵达 Cloudflare 边缘），只有网络错误或超时才淘汰。
   *
   * 唯一例外是 421 Misdirected Request：它的语义正是「这台服务器不为该 SNI 服务」，
   * 说明域名并没有挂到这个 Cloudflare 边缘上，必须判失败，否则会掩盖真实的配置问题。
   */
  private static async domainCheckTargets(cfg: ScanConfig, targets: Candidate[],
    hooks: ScanHooks, token: CancellationToken): Promise<Candidate[]> {
    const host: string = cfg.domain;
    const conc: number = 4;
    const passed: boolean[] = [];
    for (let i = 0; i < targets.length; i++) {
      passed.push(false);
    }
    let done: number = 0;
    let okCount: number = 0;
    hooks.onPhase(2, '第二阶段 · 域名端到端检测（' + host + '，' + targets.length.toString() + ' 个地址）');
    hooks.onLog('域名端到端检测：' + host + '，只检查已入选的 ' + targets.length.toString() + ' 个地址');
    await Scanner.pool<void>(targets.length, conc, token, async (index: number): Promise<void> => {
      const c: Candidate = targets[index];
      const t: TraceTarget = {
        ip: c.ip,
        port: c.port,
        host: host,
        path: '/',
        timeoutMs: Math.max(3000, cfg.traceTimeoutMs)
      };
      const r: TraceResult = await TraceProbe.request(t);
      // 421 例外：它表示「这台边缘不为该 SNI 服务」，等于域名没挂上来。
      const ok: boolean = r.httpCode > 0 && r.httpCode !== 421;
      if (ok) {
        passed[index] = true;
        okCount++;
      } else {
        c.verdict = Verdict.FAILED;
        c.remark = r.httpCode === 421 ? '域名未被该节点承载（HTTP 421）' : '域名端到端不通';
        c.failReason = 'domain';
      }
      done++;
      if (done % 1 === 0 || done === targets.length) {
        hooks.onProgress(done, targets.length, okCount, targets.length - okCount);
      }
    });
    const out: Candidate[] = [];
    for (let i = 0; i < targets.length; i++) {
      if (passed[i]) {
        out.push(targets[i]);
      }
    }
    hooks.onLog('域名端到端检测完成：' + targets.length.toString() + ' 个中 ' + okCount.toString() + ' 个可达');
    return out;
  }

  /** 阶段二：测速（按延迟升序取前 N） */
  static async stageSpeed(cfg: ScanConfig, list: Candidate[], hooks: ScanHooks,
    token: CancellationToken): Promise<void> {
    const sorted: Candidate[] = list.slice();
    sorted.sort((a: Candidate, b: Candidate): number => {
      const la: number = a.minLatencyMs > 0 ? a.minLatencyMs : 1e9;
      const lb: number = b.minLatencyMs > 0 ? b.minLatencyMs : 1e9;
      return la - lb;
    });

    let pool: Candidate[] = sorted;
    const scope: number = cfg.speedScope;
    if (scope === SpeedScope.REGION) {
      const region: string = cfg.regionCode.trim().toUpperCase();
      const filtered: Candidate[] = [];
      for (let i = 0; i < sorted.length; i++) {
        // 空 colo 归一成 UNK，这样在筛选页填 UNK 就能只测这批没识别出数据中心的节点
        const co: string = sorted[i].colo.length > 0 ? sorted[i].colo.toUpperCase() : 'UNK';
        if (co === region) {
          filtered.push(sorted[i]);
        }
      }
      pool = filtered;
      hooks.onLog('地区测速 ' + region + '：命中 ' + pool.length.toString() + ' 个');
    } else if (scope === SpeedScope.PER_REGION) {
      const per: number = Math.max(1, Math.min(20, cfg.speedPerRegion));
      const cnt: Map<string, number> = new Map<string, number>();
      const picked: Candidate[] = [];
      for (let i = 0; i < sorted.length; i++) {
        const key: string = sorted[i].colo.length > 0 ? sorted[i].colo.toUpperCase() : '???';
        const n0: number | undefined = cnt.get(key);
        const n: number = n0 === undefined ? 0 : n0;
        if (n < per) {
          picked.push(sorted[i]);
          cnt.set(key, n + 1);
        }
      }
      pool = picked;
      hooks.onLog('全部地区测速：每个地区各取延迟最低的前 ' + per.toString() + ' 个，共 ' +
        pool.length.toString() + ' 个地址');
    } else {
      hooks.onLog('完全测速：第一轮通过的 ' + pool.length.toString() + ' 个地址全部测速');
    }

    // 三种范围都是从「延迟最低」开始取前 N 个（对齐 CloudFlareScan 的 max_test_count）
    // 测速地址数对所有范围都生效：完全测速 = 从全部候选里按延迟取前 N，
    // 地区测速 = 只从该地区的候选里取前 N，全部地区 = 每个地区各取 per 个。
    let cap: number = pool.length;
    if (scope === SpeedScope.PER_REGION) {
      cap = pool.length;
    } else {
      cap = Math.min(Math.max(1, cfg.speedCount), pool.length);
      hooks.onLog('按延迟从低到高，只测前 ' + cap.toString() + ' 个地址');
    }
    let targets: Candidate[] = pool.slice(0, cap);
    // 域名端到端检测只对「已经入选」的节点各做一次：不提前检查全部候选，
    // 也不在后续阶段重复请求。开关与有效域名必须同时满足。
    if (cfg.domainCheck && !DnsService.isValidDomain(cfg.domain)) {
      hooks.onLog('已开启域名端到端检测，但未填写有效域名：本次不执行（CF 官方测速不受影响）');
    }
    if (cfg.domainCheck && DnsService.isValidDomain(cfg.domain) && targets.length > 0) {
      targets = await Scanner.domainCheckTargets(cfg, targets, hooks, token);
      if (targets.length === 0) {
        hooks.onLog('域名端到端检测：' + cfg.domain + ' 在入选节点上全部失败，本轮没有可测速的地址');
        // 明确告诉 UI「这是检测失败，不是测速完成」，并给出下一步能做什么。
        // workers.dev 单独给一条说明：这类域名在部分网络下会被 DNS 污染 + SNI 阻断，
        // 而「解析测试」只做 DNS（不走 TCP/TLS），所以能解析出地址并不代表连得上。
        const isWorkers: boolean = cfg.domain.toLowerCase().indexOf('.workers.dev') >= 0;
        hooks.onAborted(
          '域名端到端检测失败：' + cfg.domain + ' 在第一阶段入选的节点上全部不可达，下载测速没有开始',
          isWorkers
            ? '当前测速域名无法完成端到端连接。若使用 workers.dev 域名，可能受到当前网络环境限制（解析能拿到地址，但 TLS 握手被中断），' +
              '建议更换为 speed.cloudflare.com 或留空后重试；也可以关闭「域名端到端检测」直接测速。'
            : '可关闭「域名端到端检测」开关，再到「筛选」页点「开始测速」——第一阶段结果已保留，不会再跑一遍延迟筛选；' +
              '或检查该域名是否已正确托管在 Cloudflare');
        return;
      }
    }
    hooks.onSpeedInit(targets);
    // 下载测速固定走 speed.cloudflare.com 的 /__down 端点：用户自己的域名一般没有这个路径，
    // 绑上去只会 404，表现就是「只显示延迟、没有 MB/s」。域名只用于可用性校验，不参与测速下载。
    const host: string = DEFAULT_TRACE_HOST;
    hooks.onPhase(3, '第三阶段 · 下载测速（' + targets.length.toString() + ' 个地址，Host=' + host + '）');
    const conc: number = Math.max(1, cfg.speedConcurrency);
    const estSec: number = Math.round(targets.length * cfg.speedRounds * cfg.speedWindowMs / conc / 1000);
    hooks.onLog('开始测速：共 ' + targets.length.toString() + ' 个地址，每个测 ' +
      cfg.speedRounds.toString() + ' 次，窗口 ' + cfg.speedWindowMs.toString() + 'ms，并发 ' +
      conc.toString() + '，预计约 ' + estSec.toString() + ' 秒');

    let done: number = 0;
    let okCount: number = 0;
    const gap: number = Math.max(0, cfg.speedGapMs);
    // 设定轮数：方案 A 的分母。配置被写成 0 时按 1 轮兜底，避免除零得到 Infinity/NaN。
    const cfgRounds: number = cfg.speedRounds > 0 ? cfg.speedRounds : 1;

    await Scanner.pool<void>(targets.length, cfg.speedConcurrency, token, async (index: number): Promise<void> => {
      const c: Candidate = targets[index];
      hooks.onSpeedTick(index, c, false);
      let total: number = 0;
      let best: number = 0;
      let rounds: number = 0;
      let lastErr: string = '';
      // 成功轮的速度样本：中位数、最低/最高/平均都从这份真实样本算，
      // 不再用「累计和 ÷ 成功轮数」直接当评分速度（方案 A 要按设定轮数惩罚失败轮）。
      const okSpeeds: number[] = [];
      // 逐轮记录：只记录真正执行到的轮次，不补空位、不按配置次数反推
      const sampleParts: string[] = [];
      const stateParts: string[] = [];
      // 逐轮延迟/丢包：只用于展开详情的表格展示，不参与筛选、评分与排名。
      // 每轮 2 次 TCP 握手（复用第一阶段同一探针），取最小 RTT，按真实发出次数算丢包。
      const latParts: string[] = [];
      const lossParts: string[] = [];
      // 34 号方案：稳定性只取第三阶段每轮的 TCP 握手结果，下载失败不计入。
      let linkOk: number = 0;
      let linkTries: number = 0;
      const linkRtts: number[] = [];
      for (let k = 0; k < cfgRounds; k++) {
        if (token.isCancelled()) {
          sampleParts.push('—');
          stateParts.push('已取消');
          break;
        }
        // 每轮只做 1 次 TCP 握手：既作为稳定性样本，也用于逐轮延迟展示。
        // 下载失败（HTTP 429 / 未读到数据 / 数据不足）只影响速度维度，不算连接失败。
        const pr: TcpResult = await TcpProbe.pingOnce(c.ip, c.port, cfg.pingTimeoutMs);
        const linkOkRound: boolean = pr.ok && pr.rttMs > 0;
        linkTries++;
        let roundLat: number = -1;
        if (linkOkRound) {
          linkOk++;
          roundLat = pr.rttMs;
          linkRtts.push(pr.rttMs);
        }
        latParts.push(roundLat > 0 ? Math.round(roundLat).toString() : '—');
        lossParts.push(linkOkRound ? '0' : '100');
        const t: SpeedTarget = {
          ip: c.ip,
          port: c.port,
          host: host,
          url: 'https://' + host + SPEED_PATH,
          timeoutMs: cfg.traceTimeoutMs,
          windowMs: cfg.speedWindowMs,
          maxBytes: 200 * 1024 * 1024
        };
        const r = await SpeedTest.run(t);
        if (r.ok && r.avgMbps > 0) {
          total += r.avgMbps;
          okSpeeds.push(r.avgMbps);
          if (r.avgMbps > best) {
            best = r.avgMbps;
          }
          rounds++;
          sampleParts.push(r.avgMbps.toFixed(2));
          stateParts.push('成功');
        } else {
          lastErr = r.error;
          // 失败轮速度留空（不写 0，避免被当成「测出 0 MB/s」）
          sampleParts.push('—');
          stateParts.push(r.error.length > 0 ? r.error : '失败');
        }
        if (k < cfgRounds - 1) {
          await Scanner.sleep(gap);
        }
      }
      c.stage = Stage.SPEED;
      c.speedSamples = sampleParts.join('/');
      c.speedStates = stateParts.join('/');
      c.speedLatSamples = latParts.join('/');
      c.speedLossSamples = lossParts.join('/');
      c.speedCfgRounds = cfgRounds;
      c.linkOk = linkOk;
      c.linkTries = linkTries;
      let linkSum: number = 0;
      for (let li = 0; li < linkRtts.length; li++) {
        linkSum += linkRtts[li];
      }
      c.speedDelayMs = linkRtts.length > 0 ? linkSum / linkRtts.length : 0;
      // N=1 没有稳定性维度：数据层也写 -1，避免未来新出口漏掉轮数判断时把满分泄出去。
      c.stabilityScore = (cfgRounds > 1 && linkTries > 0)
        ? Math.round((linkOk + 1) / (linkTries + 1) * 100)
        : -1;
      if (rounds > 0) {
        // 方案 A：有效速度 = 成功轮中位数 ×（成功轮数 ÷ 设定轮数）。
        //   - 失败轮不进「平均」分子，但通过比例把「只成功 1/3」的节点压到 1/3；
        //   - 两轮成功时中位数取两个数的平均值，一轮成功时就是该轮速度；
        //   - 比例用「设定轮数」而不是「实际执行轮数」，中途停止也按未完成惩罚。
        // 平均/最低/最高另外记录，只用于展示，不参与评分。
        const sorted: number[] = okSpeeds.slice();
        sorted.sort((a: number, b: number): number => a - b);
        const half: number = Math.floor(rounds / 2);
        const median: number = rounds % 2 === 0
          ? (sorted[half - 1] + sorted[half]) / 2
          : sorted[half];
        const ratio: number = rounds / cfgRounds;
        const eff: number = median * ratio;
        c.speedMbps = eff > 0 ? eff : 0;
        c.speedAvgMbps = total / rounds;
        c.speedMinMbps = sorted[0];
        c.speedMaxMbps = best;
        c.speedRounds = rounds;
        c.speedOk = true;
        c.verdict = Verdict.SPEEDED;
        okCount++;
      } else {
        c.speedOk = false;
        c.speedMbps = 0;
        c.speedAvgMbps = 0;
        c.speedMinMbps = 0;
        // 清掉上一轮残留的峰值/轮数：否则「这次全失败」的节点会带着旧峰值导出，
        // 看起来像「有峰值却测不出平均速度」的自相矛盾数据。
        c.speedMaxMbps = 0;
        c.speedRounds = 0;
        // 标记成「已进过测速阶段」，这样结果行会显示「测速失败」，
        // 而不是停在 PASS 显示成「延迟达标」（用户会误以为没测）。
        c.verdict = Verdict.SPEEDED;
        c.remark = lastErr.length > 0 ? lastErr : '测速失败';
      }
      hooks.onSpeedTick(index, c, true);
      done++;
      if (done % 1 === 0 || done === targets.length) {
        hooks.onProgress(done, targets.length, okCount, targets.length - okCount);
      }
    });
    hooks.onLog('测速完成：' + targets.length.toString() + ' 个地址中 ' + okCount.toString() + ' 个成功');
  }

  /** 入口 */
  /** 第一阶段：生成候选 + ping 初筛 + 取 colo；返回完整列表（含被淘汰项），不测速 */
  static async runPing(cfg: ScanConfig, hooks: ScanHooks, token: CancellationToken): Promise<Candidate[]> {
    hooks.onPhase(0, '准备候选');
    let list: Candidate[] = [];
    if (cfg.mode === ScanMode.OFFICIAL) {
      list = Scanner.officialCandidates(cfg);
      if (cfg.ipVersion === IpVersion.V6) {
        hooks.onLog('候选来源：官方 IP 段（IPv6 社区 /48 池共 ' +
          Scanner.lastLayeredBlock48.toString() + ' 个 /48），生成 ' + list.length.toString() + ' 个');
      } else {
        hooks.onLog('候选来源：官方 IP 段（IPv4 按 /24 分层' +
        (cfg.sampleCount <= 0 ? '，采样全部段' : '') + '），生成 ' + list.length.toString() + ' 个');
      }
    } else {
      let entries: number = 0;
      const rawLines: string[] = cfg.customText.split('\n');
      for (let li = 0; li < rawLines.length; li++) {
        const t: string = rawLines[li].trim();
        if (t.length > 0 && !t.startsWith('#')) {
          entries++;
        }
      }
      // 采样数统一约束候选总量：来源行数多于采样数时（典型是社区段库 6000+ 行），
      // 随机抽取「采样数」条再采样，否则候选量会被行数顶满、采样数形同虚设。
      const wantAll: boolean = cfg.sampleCount <= 0;
      const picked: number = wantAll ? entries : (entries > cfg.sampleCount ? cfg.sampleCount : entries);
      const scanText: string = (!wantAll && entries > cfg.sampleCount)
        ? Scanner.pickLines(cfg.customText, cfg.sampleCount)
        : cfg.customText;
      const perCidr: number = wantAll ? 1 : Math.max(1, Math.ceil(cfg.sampleCount / Math.max(1, picked)));
      list = Scanner.customCandidates(scanText, cfg.port, perCidr);
      const srcLabel: string = cfg.sourceGroupName.length > 0 ? '「' + cfg.sourceGroupName + '」' : '';
      hooks.onLog('候选来源：自定义分组' + srcLabel + '（' + entries.toString() + ' 行' +
        (wantAll ? '，采样全部段' : (picked < entries ? '，随机取样 ' + picked.toString() + ' 行' : '')) +
        '，每条采 ' + perCidr.toString() + '），解析出 ' + list.length.toString() + ' 个');
    }
    list = Scanner.dedupe(list);
    // 候选来源与 IP 版本严格隔离：进入筛选流程前按实际地址格式再校验一遍，
    // 历史配置 / 缓存 / 异常数据里混进来的另一种类型在这里被剔除，绝不进入 ping/测速。
    const beforeVer: number = list.length;
    list = Scanner.filterByVersion(list, cfg.ipVersion);
    if (list.length !== beforeVer) {
      hooks.onLog('类型校验：丢弃 ' + (beforeVer - list.length).toString() +
        ' 个与当前 IP 版本（' + (cfg.ipVersion === IpVersion.V6 ? 'IPv6' : 'IPv4') + '）不符的候选');
    }
    if (list.length === 0) {
      hooks.onLog('没有可用候选');
      return [];
    }

    // 域名解析采样：填了域名就自动解析（IPv4→A，IPv6→AAAA）并入候选，保留随机地址。
    // IPv6 随机地址命中率低，域名记录是正向补充，不能替换掉随机候选。
    const seedDomain: string = cfg.domain.length > 0 ? cfg.domain :
      (cfg.ipVersion === IpVersion.V6 ? DEFAULT_TRACE_HOST : '');
    if (seedDomain.length > 0) {
      try {
        const info = await DnsService.resolve(seedDomain);
        const seeds: string[] = [];
        for (let i = 0; i < info.ips.length; i++) {
          const ipIsV6: boolean = IpUtil.isV6(info.ips[i]);
          if (cfg.ipVersion === IpVersion.V6 ? ipIsV6 : !ipIsV6) {
            // 只放纯 IP：带端口拼接对 IPv6 会产生 2606:4700::1:443 这类歧义写法
            seeds.push(info.ips[i]);
          }
        }
        if (seeds.length > 0) {
          const extra: Candidate[] = Scanner.customCandidates(seeds.join('\n'), cfg.port, 1);
          list = Scanner.dedupe(list.concat(extra));
          hooks.onLog('域名采样：' + seedDomain + ' 解析到 ' + seeds.length.toString() +
            ' 个地址，已并入候选（保留随机地址）');
        } else {
          hooks.onLog('域名采样：' + seedDomain + ' 无匹配记录（A/AAAA），继续用随机地址');
        }
      } catch (e) {
        hooks.onLog('域名采样失败：' + seedDomain + ' 解析异常，继续用随机地址');
      }
    }
    if (Scanner.lastParseSkipped > 0) {
      hooks.onLog('自定义候选：有 ' + Scanner.lastParseSkipped.toString() + ' 行无法解析，已忽略');
    }
    // 域名采样并入后再校验一次（种子理论上是同族，这里仍然以实际地址为准）
    const beforeVer2: number = list.length;
    list = Scanner.filterByVersion(list, cfg.ipVersion);
    if (list.length !== beforeVer2) {
      hooks.onLog('类型校验：域名采样后又剔除 ' + (beforeVer2 - list.length).toString() + ' 个类型不符的候选');
    }
    if (list.length === 0) {
      hooks.onLog('没有可用候选');
      return [];
    }
    if (cfg.ipVersion === IpVersion.V6) {
      const envOk: boolean = await Scanner.checkV6Env();
      hooks.onLog(envOk ? 'IPv6 环境自检：可用（测试地址已连通）' :
        'IPv6 环境自检：不可用或超时（本机无 IPv6 或网络掉线时属环境问题，不是代码故障）');
    }

    // 可观测性：进入 ping 前打印候选的实际类型分布，命令行即可验证「V4 流程只出 IPv4 节点」
    let nv4: number = 0;
    let nv6: number = 0;
    const sampleIps: string[] = [];
    for (let si = 0; si < list.length; si++) {
      const sc: Candidate = list[si];
      if (Scanner.strictV6(sc.ip)) {
        nv6++;
      } else if (Scanner.strictV4(sc.ip)) {
        nv4++;
      }
      if (si < 3) {
        sampleIps.push(sc.ip);
      }
    }
    hooks.onLog('候选类型分布：v4=' + nv4.toString() + '，v6=' + nv6.toString() + '，样本 ' + sampleIps.join('、'));
    hilog.info(0x0001, 'cflark', '%{public}s', '候选类型分布：v4=' + nv4.toString() + '，v6=' + nv6.toString() + '，样本 ' + sampleIps.join('、'));
    const passedPing: Candidate[] = await Scanner.stagePing(cfg, list, hooks, token);
    if (token.isCancelled() || passedPing.length === 0) {
      hooks.onPhase(4, '完成');
      hooks.onResult(list);
      return list;
    }

    // colo 已在上一步与 ping 并行完成，这里不再串行跑一轮
    hooks.onPhase(4, '第一轮完成');
    const gated: Candidate[] = passedPing;
    Ranker.apply(gated, cfg);
    hooks.onResult(gated);
    const ok = Ranker.countPassed(gated);
    hooks.onLog('第一轮完成：' + list.length.toString() + ' 个候选，通过 ' + ok.toString() + ' 个');
    return gated;
  }

  /** 第二阶段：只对给定候选做下载测速（就地写入结果） */
  static async runSpeed(cfg: ScanConfig, list: Candidate[], hooks: ScanHooks,
    token: CancellationToken): Promise<void> {
    if (list.length === 0) {
      hooks.onLog('没有可测速的节点');
      return;
    }
    await Scanner.stageSpeed(cfg, list, hooks, token);
    hooks.onPhase(4, '测速完成');
  }

  /** 一次性跑完两轮（保留给旧调用方） */
  static async run(cfg: ScanConfig, hooks: ScanHooks, token: CancellationToken): Promise<Candidate[]> {
    const list: Candidate[] = await Scanner.runPing(cfg, hooks, token);
    if (token.isCancelled()) {
      return list;
    }
    if (cfg.enableSpeed) {
      await Scanner.stageSpeed(cfg, list, hooks, token);
    }
    hooks.onPhase(4, '排序');
    Ranker.apply(list, cfg);
    hooks.onResult(list);
    const ok = Ranker.countPassed(list);
    hooks.onLog('全部完成：' + list.length.toString() + ' 个候选，可用 ' + ok.toString() + ' 个');
    return list;
  }
}
