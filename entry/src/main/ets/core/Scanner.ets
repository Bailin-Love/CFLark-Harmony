/**
 * CFLark 扫描编排 —— 两阶段，对齐 CloudFlareScan
 *
 * 阶段一「快速筛选」（对应 CloudFlareScan 的 ScanWorker）：
 *   每个候选 IP 连 pingTimes 次 TCP（默认 2 次，间隔 pingIntervalMs），取最小延迟；
 *   最小延迟 >= latencyLimitMs（默认 220ms）或全部失败就淘汰；
 *   通过的再做一次 /cdn-cgi/trace 拿 colo（Host 固定 speed.cloudflare.com）。
 *
 * 阶段二「测速」（对应 CloudFlareScan 的 SpeedTestWorker）：
 *   把通过的候选按延迟升序排序（可选先按 regionCode 过滤 colo）；
 *   取延迟最低的前 speedCount 个（默认 10，范围 1~99），逐个测速；
 *   每个地址测 speedRounds 次取平均，每个之间 sleep(speedGapMs)；
 *   测速的 Host / SNI 用用户填的域名（留空则 speed.cloudflare.com）。
 *
 * 排名：Ranker 负责 min-max 归一化 + 加权（延迟 0.3 / 速度 0.7）。
 */
import { Candidate, ScanConfig, ScanMode, IpVersion, Stage, Verdict, SpeedScope } from './Types';
import { IpUtil, CidrV4, CF_IPV4_RANGES, CF_IPV6_RANGES } from './IpUtil';
import { CF_IPV6_POOL_48 } from './V6Pool';
import { TcpProbe, TcpResult, TraceProbe, TraceResult } from './Probe';
import { SpeedTest, SpeedTarget } from './SpeedTest';
import { DnsService } from './DnsService';
import { Ranker } from './Ranker';

export const DEFAULT_TRACE_HOST: string = 'speed.cloudflare.com';
export const DEFAULT_TRACE_PATH: string = '/cdn-cgi/trace';
export const SPEED_PATH: string = '/__down?bytes=50000000';
export const MIN_LATENCY_LIMIT: number = 50;
export const MAX_LATENCY_LIMIT: number = 1000;

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

export class Scanner {
  /** 上一次 customCandidates 解析跳过的行数（用于日志提示） */
  static lastParseSkipped: number = 0;

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
      speedRounds: 0,
      speedOk: false,
      delayScore: 0,
      speedScore: 0,
      finalScore: 0,
      verdict: Verdict.UNKNOWN,
      remark: '',
      failReason: ''
    };
    return c;
  }

  static clone(c: Candidate): Candidate {
    const r: Candidate = {
      ip: c.ip,
      port: c.port,
      version: c.version,
      stage: c.stage,
      pingSent: c.pingSent,
      pingRecv: c.pingRecv,
      minLatencyMs: c.minLatencyMs,
      avgLatencyMs: c.avgLatencyMs,
      maxLatencyMs: c.maxLatencyMs,
      lossRate: c.lossRate,
      colo: c.colo,
      traceOk: c.traceOk,
      traceDelayMs: c.traceDelayMs,
      httpCode: c.httpCode,
      speedMbps: c.speedMbps,
      speedMaxMbps: c.speedMaxMbps,
      speedRounds: c.speedRounds,
      speedOk: c.speedOk,
      delayScore: c.delayScore,
      speedScore: c.speedScore,
      finalScore: c.finalScore,
      verdict: c.verdict,
      remark: c.remark,
      failReason: c.failReason
    };
    return r;
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
        const per: number = Math.max(1, Math.ceil(cfg.sampleCount / CF_IPV6_POOL_48.length));
        for (let i = 0; i < CF_IPV6_POOL_48.length; i++) {
          const ips: string[] = IpUtil.sampleV6Layered(CF_IPV6_POOL_48[i], per);
          for (let j = 0; j < ips.length; j++) {
            out.push(Scanner.makeCandidate(ips[j], cfg.port, 6));
          }
        }
        return out;
      }
      const per: number = Math.max(1, Math.ceil(cfg.sampleCount / CF_IPV6_RANGES.length));
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
    const need: number = Math.min(cfg.sampleCount, shuffled.length);
    for (let i = 0; i < need; i++) {
      const base: number = shuffled[i];
      const off: number = 1 + Math.floor(Math.random() * 254);
      out.push(Scanner.makeCandidate(IpUtil.intToIpv4((base + off) >>> 0), cfg.port, 4));
    }
    return out;
  }

  /** 自定义候选：支持 CIDR / ip:port / [v6]:port / 纯 IPv6，一行一个，# 开头是注释 */
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
            } else if (pv > 0 && pv < 65536 && IpUtil.isV6(head)) {
              // 纯 IPv6 带端口：只有前段仍是合法 IPv6 才拆分端口
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

  /** 质量预检单节点：小窗口快速估速（只用于判断能否达标，不参与最终统计） */
  private static async probeQuality(c: Candidate, cfg: ScanConfig, windowMs: number): Promise<boolean> {
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
      return r.ok && r.avgMbps >= cfg.minSpeedMbps;
    } catch (e) {
      return false;
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
        const ok: boolean = await Scanner.probeQuality(c, cfg, gateWindow);
        inflight.delete(key);
        if (token.isCancelled()) {
          abortReason = 'cancelled';
          return;
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
   * IPv6 有效延迟上限：随机 IPv6 地址在 Cloudflare 段内通常走较远的移动路由，
   * 实测平均最小延迟约 375ms；若沿用 IPv4 的 260ms 口径会误杀 90% 以上可达节点。
   * 这里按用户阈值放大 2.2 倍并封顶 800ms，IPv4 保持原值不变。
   */
  static effectiveLatencyLimit(cfg: ScanConfig): number {
    if (cfg.ipVersion !== IpVersion.V6) {
      return cfg.latencyLimitMs;
    }
    const adaptive: number = Math.round(cfg.latencyLimitMs * 2.2);
    return Math.max(cfg.latencyLimitMs, Math.min(800, adaptive));
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
    hooks.onLog('候选 IP 共 ' + list.length.toString() + ' 个，开始第一轮 TCP 延迟筛选');
    const statStartMs: number = Date.now();
    let done: number = 0;
    let passed: number = 0;
    let overLimit: number = 0;
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
        if (r.stage === 'timeout') {
          break;
        }
        // 第一次延迟已明显低于门槛（≤ 门槛 60%）：无需再重试，直接省一次连接
        if (r.ok && r.rttMs > 0 && r.rttMs <= limitMsEff * 0.6) {
          break;
        }
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
      c.lossRate = cfg.pingTimes > 0 ? (cfg.pingTimes - recv) / cfg.pingTimes : 1;
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
      ' 个（延迟达标）；延迟超限 ' + overLimit.toString() + ' 个；连接超时 ' + timeouts.toString() +
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

  /** 阶段一补充：对通过的候选取 colo（保留给单独调用；主流程已合并进 stagePing） */
  static async stageColo(cfg: ScanConfig, list: Candidate[], hooks: ScanHooks,
    token: CancellationToken): Promise<void> {
    hooks.onPhase(2, '第二阶段 · 获取数据中心（colo）');
    let done: number = 0;
    let okCount: number = 0;
    await Scanner.pool<void>(list.length, cfg.traceConcurrency, token, async (index: number): Promise<void> => {
      const c: Candidate = list[index];
      const r: TraceResult = await TraceProbe.request({
        ip: c.ip,
        port: c.port,
        host: DEFAULT_TRACE_HOST,
        path: DEFAULT_TRACE_PATH,
        timeoutMs: cfg.traceTimeoutMs
      });
      c.stage = Stage.COLO;
      c.traceOk = r.ok;
      c.traceDelayMs = r.ok ? r.totalMs : -1;
      c.httpCode = r.httpCode;
      c.colo = r.colo;
      if (r.ok && r.colo.length > 0) {
        okCount++;
      }
      hooks.onSpeedTick(index, c, true);
      done++;
      // 每完成一个真实探测就上报（UI 侧再做 80ms 节流），避免按批次跳跃
      hooks.onProgress(done, list.length, okCount, list.length - okCount);
    });
    hooks.onLog('数据中心获取完成：' + list.length.toString() + ' 个中 ' + okCount.toString() + ' 个拿到 colo');
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

    await Scanner.pool<void>(targets.length, cfg.speedConcurrency, token, async (index: number): Promise<void> => {
      const c: Candidate = targets[index];
      hooks.onSpeedTick(index, c, false);
      let total: number = 0;
      let best: number = 0;
      let rounds: number = 0;
      let lastErr: string = '';
      for (let k = 0; k < cfg.speedRounds; k++) {
        if (token.isCancelled()) {
          break;
        }
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
          if (r.avgMbps > best) {
            best = r.avgMbps;
          }
          rounds++;
        } else {
          lastErr = r.error;
        }
        if (k < cfg.speedRounds - 1) {
          await Scanner.sleep(gap);
        }
      }
      c.stage = Stage.SPEED;
      if (rounds > 0) {
        c.speedMbps = total / rounds;
        c.speedMaxMbps = best;
        c.speedRounds = rounds;
        c.speedOk = true;
        c.verdict = Verdict.SPEEDED;
        okCount++;
      } else {
        c.speedOk = false;
        c.speedMbps = 0;
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
        hooks.onLog('候选来源：官方 IP 段（IPv4 按 /24 分层），生成 ' + list.length.toString() + ' 个');
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
      const perCidr: number = Math.max(1, Math.ceil(cfg.sampleCount / Math.max(1, entries)));
      list = Scanner.customCandidates(cfg.customText, cfg.port, perCidr);
      hooks.onLog('候选来源：自定义（' + entries.toString() + ' 行，每条个采 ' + perCidr.toString() +
        '），解析出 ' + list.length.toString() + ' 个');
    }
    list = Scanner.dedupe(list);
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
    if (cfg.ipVersion === IpVersion.V6) {
      const envOk: boolean = await Scanner.checkV6Env();
      hooks.onLog(envOk ? 'IPv6 环境自检：可用（测试地址已连通）' :
        'IPv6 环境自检：不可用或超时（本机无 IPv6 或网络掉线时属环境问题，不是代码故障）');
    }

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
