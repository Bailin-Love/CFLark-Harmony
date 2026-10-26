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

export class Scanner {
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
      remark: ''
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
      remark: c.remark
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

  /** 官方 IP 段候选：每个 /24 随机取 1 个，对齐 CFData-WEB 的 getRandomIPv4s */
  static officialCandidates(cfg: ScanConfig): Candidate[] {
    const out: Candidate[] = [];
    if (cfg.ipVersion === IpVersion.V6) {
      const per: number = Math.max(1, Math.ceil(cfg.sampleCount / CF_IPV6_RANGES.length));
      for (let i = 0; i < CF_IPV6_RANGES.length; i++) {
        const ips: string[] = IpUtil.sampleV6(CF_IPV6_RANGES[i], per);
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
  static customCandidates(text: string, defaultPort: number): Candidate[] {
    const out: Candidate[] = [];
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
        const r: CidrV4 = IpUtil.parseCidrV4(raw);
        if (r.count <= 0) {
          continue;
        }
        const ips: string[] = IpUtil.sampleV4(raw, 20);
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
        const colon: number = host.lastIndexOf(':');
        if (colon > 0 && host.indexOf(':') === colon) {
          const pv: number = parseInt(host.substring(colon + 1), 10);
          if (pv > 0 && pv < 65536) {
            port = pv;
            host = host.substring(0, colon);
          }
        }
      }
      if (!IpUtil.isV4(host) && !IpUtil.isV6(host)) {
        continue;
      }
      out.push(Scanner.makeCandidate(host, port, IpUtil.isV6(host) ? 6 : 4));
    }
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
  static async stagePing(cfg: ScanConfig, list: Candidate[], hooks: ScanHooks,
    token: CancellationToken): Promise<Candidate[]> {
    hooks.onPhase(1, '第一阶段 · TCP 筛选 + 数据中心（TCP ' + cfg.pingTimes.toString() + ' 次，上限 ' +
      cfg.latencyLimitMs.toString() + 'ms，并行取 colo）');
    hooks.onLog('候选 IP 共 ' + list.length.toString() + ' 个，开始第一轮 TCP 延迟筛选');
    let done: number = 0;
    let passed: number = 0;
    let overLimit: number = 0;
    let timeouts: number = 0;
    let otherErrors: number = 0;
    let skipped: number = 0;
    let speedLow: number = 0;
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
        if (r.ok && r.rttMs > 0 && r.rttMs <= cfg.latencyLimitMs * 0.6) {
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
      } else if (c.minLatencyMs >= cfg.latencyLimitMs) {
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
      if (done % 10 === 0 || done === list.length) {
        hooks.onProgress(done, list.length, passed, timeouts + otherErrors + overLimit);
      }
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
    // 「合格速度」预检（第一轮末端、进入测速之前）：按延迟从低到高，
    // 只挑出可能进入测速的 N 个节点做小幅估速；测不动或不达标的直接淘汰，
    // 并顺延到后面的候选，保证「测速地址数」能凑满且都是可测速的节点。
    if (cfg.minSpeedMbps > 0 && keep.length > 0) {
      keep.sort((a: Candidate, b: Candidate): number => {
        const la: number = a.minLatencyMs > 0 ? a.minLatencyMs : 1e9;
        const lb: number = b.minLatencyMs > 0 ? b.minLatencyMs : 1e9;
        return la - lb;
      });
      const regionMode: boolean = cfg.speedScope === SpeedScope.PER_REGION;
      const per: number = Math.max(1, Math.min(20, cfg.speedPerRegion));
      const need: Map<string, number> = new Map<string, number>();
      let quota: number = 0;
      if (regionMode) {
        for (let i = 0; i < keep.length; i++) {
          const k: string = keep[i].colo.length > 0 ? keep[i].colo.toUpperCase() : 'UNK';
          const n0: number | undefined = need.get(k);
          if (n0 === undefined) {
            need.set(k, per);
            quota += per;
          }
        }
      } else {
        quota = Math.min(Math.max(1, cfg.speedCount), keep.length);
      }
      const gateWindow: number = Math.min(2500, Math.max(1600, Math.floor(cfg.speedWindowMs * 2 / 3)));
      const gateConc: number = 2;
      // 不设硬性上限：一直从低延迟往下测，直到凑满配额或候选耗尽。
      // 但若明显异常（检测很多但几乎不达标/耗时过长），中止并提示排查网络。
      const gateSoftLimit: number = Math.max(24, quota * 4);
      const gateElapsedLimitMs: number = 90000;
      const gateStartAt: number = Date.now();
      hooks.onPhase(1, '第一阶段 · 合格速度预检（目标 ' + quota.toString() + ' 个，窗口 ' +
        gateWindow.toString() + 'ms）');
      hooks.onLog('合格速度预检：TCP 通过 ' + keep.length.toString() + ' 个，目标测速 ' +
        quota.toString() + ' 个，单次窗口 ' + gateWindow.toString() + 'ms，合格速度 ' +
        cfg.minSpeedMbps.toString() + ' MB/s');
      const probeOne = async (c: Candidate): Promise<boolean> => {
        const pt: SpeedTarget = {
          ip: c.ip,
          port: c.port,
          host: DEFAULT_TRACE_HOST,
          url: 'https://' + DEFAULT_TRACE_HOST + SPEED_PATH,
          timeoutMs: Math.min(cfg.traceTimeoutMs, 3000),
          windowMs: gateWindow,
          maxBytes: 2 * 1024 * 1024
        };
        const r = await SpeedTest.run(pt);
        return r.ok && r.avgMbps >= cfg.minSpeedMbps;
      };
      const qualified: Candidate[] = [];
      let taken: number = 0;
      let idx: number = 0;
      while (qualified.length < quota && idx < keep.length) {
        const batch: Candidate[] = [];
        while (batch.length < gateConc && idx < keep.length) {
          const c: Candidate = keep[idx];
          idx++;
          if (regionMode) {
            const k: string = c.colo.length > 0 ? c.colo.toUpperCase() : 'UNK';
            const n0: number | undefined = need.get(k);
            const n: number = n0 === undefined ? 0 : n0;
            if (n <= 0) {
              continue;
            }
          }
          batch.push(c);
        }
        if (batch.length === 0) {
          break;
        }
        if (taken >= gateSoftLimit && qualified.length * 10 < taken) {
          hooks.onLog('合格速度预检提前中止：已检测 ' + taken.toString() + ' 个，仅合格 ' +
            qualified.length.toString() + ' 个（达标率过低，疑似网络异常或「合格速度」设置过高），请检查网络或调低合格速度');
          break;
        }
        if ((Date.now() - gateStartAt) > gateElapsedLimitMs && qualified.length < quota) {
          hooks.onLog('合格速度预检超时中止：已用 ' + Math.round((Date.now() - gateStartAt) / 1000).toString() +
            ' 秒，已检测 ' + taken.toString() + ' 个，合格 ' + qualified.length.toString() +
            ' 个（疑似网络异常或整体速度偏低），请检查网络或调低合格速度');
          break;
        }
        const rs: boolean[] = await Promise.all(batch.map((c: Candidate): Promise<boolean> => probeOne(c)));
        taken += batch.length;
        for (let i = 0; i < batch.length; i++) {
          const c: Candidate = batch[i];
          if (rs[i]) {
            qualified.push(c);
            if (regionMode) {
              const k: string = c.colo.length > 0 ? c.colo.toUpperCase() : 'UNK';
              const n0: number | undefined = need.get(k);
              need.set(k, (n0 === undefined ? 1 : n0) - 1);
            }
          } else {
            c.verdict = Verdict.FAILED;
            c.remark = '合格速度不达标';
            speedLow++;
          }
        }
        hooks.onProgress(taken, keep.length, qualified.length, speedLow);
      }
      hooks.onLog('合格速度预检完成：检测 ' + taken.toString() + ' 个，合格 ' +
        qualified.length.toString() + ' 个进入测速，淘汰 ' + speedLow.toString() + ' 个');
      if (qualified.length === 0) {
        hooks.onLog('合格速度预检后没有剩余节点，跳过测速');
      }
      keep.splice(0, keep.length);
      for (let i = 0; i < qualified.length; i++) {
        keep.push(qualified[i]);
      }
    }
    const coloOk: number = keep.length;
    const coloDropped: number = Math.max(0, passed - speedLow - keep.length);
    hooks.onLog('第一阶段完成：候选 ' + list.length.toString() + ' 个；TCP 成功 ' + passed.toString() +
      ' 个（延迟达标）；延迟超限 ' + overLimit.toString() + ' 个；连接超时 ' + timeouts.toString() +
      ' 个；合格速度未达标 ' + speedLow.toString() +
      ' 个；其他错误 ' + otherErrors.toString() + ' 个；取消/未执行 ' + skipped.toString() +
      ' 个；最终通过 ' + keep.length.toString() + ' 个（拿到 colo ' + coloOk.toString() + ' 个）' +
      (coloDropped > 0 ? ('，另有 ' + coloDropped.toString() + ' 个无法完成 HTTPS 探测') : ''));
    if (errSamples.length > 0) {
      hooks.onLog('连接错误示例：' + errSamples.join('；'));
    }
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
      if (done % 10 === 0 || done === list.length) {
        hooks.onProgress(done, list.length, okCount, list.length - okCount);
      }
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
      hooks.onLog('候选来源：官方 IP 段，生成 ' + list.length.toString() + ' 个');
    } else {
      list = Scanner.customCandidates(cfg.customText, cfg.port);
      hooks.onLog('候选来源：自定义，解析出 ' + list.length.toString() + ' 个');
    }
    list = Scanner.dedupe(list);
    if (list.length === 0) {
      hooks.onLog('没有可用候选');
      return [];
    }

    // 域名解析采样：开启后用测速域名解析（IPv4 取 A，IPv6 取 AAAA）并并入候选
    if (cfg.domainSampling && cfg.domain.length > 0) {
      try {
        const info = await DnsService.resolve(cfg.domain);
        const seeds: string[] = [];
        for (let i = 0; i < info.ips.length; i++) {
          const ipIsV6: boolean = IpUtil.isV6(info.ips[i]);
          if (cfg.ipVersion === IpVersion.V6 ? ipIsV6 : !ipIsV6) {
            seeds.push(info.ips[i] + ':' + cfg.port.toString());
          }
        }
        if (seeds.length > 0) {
          list = list.concat(Scanner.customCandidates(seeds.join('\n'), cfg.port));
          list = Scanner.dedupe(list);
          hooks.onLog('域名采样：' + cfg.domain + ' 解析到 ' + seeds.length.toString() + ' 个地址，已并入候选');
        } else {
          hooks.onLog('域名采样：' + cfg.domain + ' 无可用记录（A/AAAA）');
        }
      } catch (e) {
        hooks.onLog('域名采样失败：域名解析异常');
      }
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
