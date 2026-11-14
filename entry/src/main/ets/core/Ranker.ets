/**
 * CFLark 排名（用户要求：测速数据权重高）
 *
 * 计分方式对齐 CFST-GUI 的加权思路，但简化为两维：
 *   delayScore = (maxDelay - minLatency) / (maxDelay - minDelay)    延迟越低越接近 1
 *   speedScore = (speed - minSpeed) / (maxSpeed - minSpeed)          速度越高越接近 1
 *   finalScore = delayScore * delayWeight + speedScore * speedWeight
 * 默认 delayWeight = 0.3、speedWeight = 0.7，因为真实下载带宽比握手延迟更能代表使用体验。
 * 没测速的候选 speedScore = 0，finalScore 只有延迟分贡献，因此自然排在测过速的后面。
 *
 * 排序层级（不可被分数跨越）：已测速 > 延迟达标 > 延迟超限 > 无法连通 > 未测试；
 * 同层内按 finalScore 降序 → 速度降序 → 延迟升序 → IP。
 */
import { Candidate, Verdict, ScanConfig, VerdictText, Stage } from './Types';

export class StabilityInfo {
  text: string;
  color: string;

  constructor(text: string, color: string) {
    this.text = text;
    this.color = color;
  }
}

/**
 * 一次计分的基准值。
 *
 * 分数是「本轮相对分」：延迟得分 = minDelayMs ÷ 本节点延迟，速度得分 = 本节点速度 ÷ maxSpeedMbps。
 * 把基准带出来，导出时才能让用户自己验算分数——此前 benchmark 只在函数内部
 * 作为局部变量存在，导出的 CSV 里有分数却没有任何办法反推，看起来像算错了。
 */
export interface ScoreBase {
  /** 本轮参与计分节点中的最小延迟（ms）；<= 0 表示没有可用延迟 */
  minDelayMs: number;
  /** 本轮参与计分节点中的最高测速速度（MB/s）；<= 0 表示没有成功测速的节点 */
  maxSpeedMbps: number;
  calcWeightDelay: number;
  calcWeightSpeed: number;
  /** 稳定性权重（34 号方案；N=1 时为 0） */
  calcWeightStability: number;
  calcWsum: number;
}

export class Ranker {
  /** 层级：越小越靠前 */
  static tierOf(v: Verdict): number {
    if (v === Verdict.SPEEDED) {
      return 1;
    }
    if (v === Verdict.PASS) {
      return 2;
    }
    if (v === Verdict.SLOW) {
      return 3;
    }
    if (v === Verdict.FAILED) {
      return 4;
    }
    return 5;
  }

  /**
   * 排序层级（含测速阶段的细分）：越小越靠前。
   *
   * 原来「进过测速阶段」一律 tier=1，于是三轮全部失败的节点和测速成功的节点同层，
   * 只靠 finalScore 竞争——它还能拿到延迟分（约 0.1），看起来像「可用节点」。
   * 现在把测速阶段拆成两层：
   *   1 = 至少一轮测速成功（方案 A 有效速度 > 0）
   *   2 = 全部轮次失败（保留在结果里，但排在任何有效测速成功的节点之后）
   * 其余节点沿用原层级并整体后移：延迟达标 3、延迟超限 4、无法连通 5、未测试 6。
   */
  static rankOf(c: Candidate): number {
    if (c.stage === Stage.SPEED) {
      if (c.speedOk && c.speedMbps > 0) {
        return 1;
      }
      return 2;
    }
    const t: number = Ranker.tierOf(c.verdict);
    if (t === 1) {
      // 兜底：verdict 是 SPEEDED 却没标记 stage 的历史数据，仍按「已测速」处理
      return 1;
    }
    return t + 1;
  }

  /** 用于评分与展示的延迟值：优先 2 次 ping 的最小值 */
  static delayOf(c: Candidate): number {
    if (c.minLatencyMs > 0) {
      return c.minLatencyMs;
    }
    if (c.avgLatencyMs > 0) {
      return c.avgLatencyMs;
    }
    return -1;
  }

  static speedOf(c: Candidate): number {
    return c.speedMbps > 0 ? c.speedMbps : 0;
  }

  /**
   * 评分用延迟：优先第三阶段有效握手的平均值（34 号方案口径），
   * 没有第三阶段样本时退回第一阶段的延迟，保证老旧数据仍可排序。
   */
  static scoreDelayOf(c: Candidate): number {
    if (c.speedDelayMs > 0) {
      return c.speedDelayMs;
    }
    return Ranker.delayOf(c);
  }

  /**
   * 稳定性 0–1；-1 表示没有有效握手样本（N=1 或全部取消）。
   *
   * 加一平滑取 (成功数+1)/(尝试数+1)，与 34 号设计示例一致：
   *   N=2：0/2→33、1/2→67、2/2→100
   *   N=3：0/3→25、1/3→50、2/3→75、3/3→100
   * 注意不能写成 /(tries+2)：那样全成功只能到 100×tries/(tries+1)（N=3 仅 80 分），
   * 100 分永远不可达，稳定性维度失去区分度。
   */
  static stabilityOf(c: Candidate): number {
    if (c.linkTries > 0) {
      return (c.linkOk + 1) / (c.linkTries + 1);
    }
    if (c.stabilityScore >= 0) {
      return c.stabilityScore / 100;
    }
    return -1;
  }

  /** 按设定轮数取三维权重（34 号方案）：N=1 不计稳定性 */
  static weightsFor(rounds: number): number[] {
    const n: number = rounds > 0 ? rounds : 1;
    if (n <= 1) {
      return [0.30, 0.00, 0.70];
    }
    if (n === 2) {
      return [0.25, 0.10, 0.65];
    }
    return [0.30, 0.20, 0.50];
  }

  /** 计算全体候选的归一化分数（min-max，退化时取 1 或 0） */
  /**
   * 计分：三维加权（延迟 / 稳定性 / 速度），权重随每个节点的设定轮数变化，见 weightsFor。
   *
   * 不用 min-max 归一化，改用「相对最优」：
   *   delayScore = minDelay / delay      （延迟越低越接近 1）
   *   speedScore = speed / maxSpeed      （速度越高越接近 1，最高速 = 1）
   *
   * 理由：min-max 会把「最低速」压成 0 分，导致所有低速节点在速度维度上被抹平，
   * 最后又变成只看延迟；相对最优能保留「0.9 比 0.7 好」这种低速段差异。
   */
  static scoreSet(list: Candidate[], cfg: ScanConfig): ScoreBase {
    let minDelay: number = -1;
    let maxSpeed: number = 0;
    let speedSum: number = 0;
    let speedCnt: number = 0;
    for (let i = 0; i < list.length; i++) {
      const d: number = Ranker.delayOf(list[i]);
      if (d > 0 && (minDelay < 0 || d < minDelay)) {
        minDelay = d;
      }
      if (list[i].speedOk && list[i].speedMbps > 0) {
        if (list[i].speedMbps > maxSpeed) {
          maxSpeed = list[i].speedMbps;
        }
        speedSum += list[i].speedMbps;
        speedCnt++;
      }
    }
    // ScoreBase 记录本轮配置的全局权重；逐个节点的计分权重在循环内按它自己的设定轮数取，
    // 这样单节点复测改用其它轮数时，不会追溯改写其它节点的分数与排名。
    const wGlobal: number[] = Ranker.weightsFor(cfg.speedRounds);
    for (let i = 0; i < list.length; i++) {
      const c: Candidate = list[i];
      const nodeRounds: number = c.speedCfgRounds > 0 ? c.speedCfgRounds : cfg.speedRounds;
      const w: number[] = Ranker.weightsFor(nodeRounds);
      const wd: number = w[0];
      const wst: number = w[1];
      const ws: number = w[2];
      const d: number = Ranker.scoreDelayOf(c);
      let ds: number = 0;
      if (d > 0 && minDelay > 0) {
        ds = minDelay / d;
        if (ds > 1) {
          ds = 1;
        }
      }
      let ss: number = 0;
      if (maxSpeed > 0 && c.speedMbps > 0) {
        ss = c.speedMbps / maxSpeed;
      }
      const st: number = Ranker.stabilityOf(c);
      c.stabilityScore = st >= 0 ? Math.round(st * 100) : -1;
      // 没有有效握手样本时丢弃稳定性维度，把权重按 30:70 还给延迟与速度。
      const useSt: boolean = st >= 0;
      const lwd: number = useSt ? wd : 0.30;
      const lst: number = useSt ? wst : 0.00;
      const lws: number = useSt ? ws : 0.70;
      const wsum: number = lwd + lst + lws;
      c.delayScore = ds;
      c.speedScore = ss;
      c.finalScore = (ds * lwd + (useSt ? st : 0) * lst + ss * lws) / (wsum > 0 ? wsum : 1);
    }
    const base: ScoreBase = {
      minDelayMs: minDelay,
      maxSpeedMbps: maxSpeed,
      calcWeightDelay: wGlobal[0],
      calcWeightSpeed: wGlobal[2],
      calcWeightStability: wGlobal[1],
      calcWsum: wGlobal[0] + wGlobal[1] + wGlobal[2]
    };
    return base;
  }
  static compare(a: Candidate, b: Candidate): number {
    const ta: number = Ranker.rankOf(a);
    const tb: number = Ranker.rankOf(b);
    if (ta !== tb) {
      return ta - tb;
    }
    if (b.finalScore !== a.finalScore) {
      return b.finalScore - a.finalScore;
    }
    const sa: number = Ranker.speedOf(a);
    const sb: number = Ranker.speedOf(b);
    if (sb !== sa) {
      return sb - sa;
    }
    const da: number = Ranker.delayOf(a);
    const db: number = Ranker.delayOf(b);
    const na: number = da > 0 ? da : 1e9;
    const nb: number = db > 0 ? db : 1e9;
    if (na !== nb) {
      return na - nb;
    }
    if (a.ip === b.ip) {
      return 0;
    }
    return a.ip < b.ip ? -1 : 1;
  }

  static apply(list: Candidate[], cfg: ScanConfig): ScoreBase {
    const base: ScoreBase = Ranker.scoreSet(list, cfg);
    list.sort((a: Candidate, b: Candidate): number => {
      return Ranker.compare(a, b);
    });
    const limit: number = cfg.resultLimit;
    if (limit > 0 && list.length > limit) {
      list.length = limit;
    }
    return base;
  }

  /** 可用数量（延迟达标，或已测速且至少有 1 轮成功；全失败不算可用） */
  static countPassed(list: Candidate[]): number {
    let n: number = 0;
    for (let i = 0; i < list.length; i++) {
      const c: Candidate = list[i];
      const v: Verdict = c.verdict;
      if (v === Verdict.PASS) {
        n++;
      } else if (v === Verdict.SPEEDED && c.speedOk) {
        n++;
      }
    }
    return n;
  }

  static labelOf(v: Verdict): string {
    return VerdictText.label(v);
  }

  /** 结果行的状态文案与颜色 */
  static info(c: Candidate): StabilityInfo {
    if (c.verdict === Verdict.SPEEDED && c.speedMbps >= 0.01) {
      const t: string = c.speedMbps >= 10 ? c.speedMbps.toFixed(1) : c.speedMbps.toFixed(2);
      return new StabilityInfo(t + ' MB/s', '#10B981');
    }
    if (c.verdict === Verdict.SPEEDED) {
      return new StabilityInfo('测速失败', '#F43F5E');
    }
    if (c.verdict === Verdict.PASS) {
      return new StabilityInfo('延迟达标', '#10B981');
    }
    if (c.verdict === Verdict.SLOW) {
      return new StabilityInfo('延迟超限', '#F59E0B');
    }
    if (c.verdict === Verdict.FAILED) {
      return new StabilityInfo('无法连通', '#F43F5E');
    }
    return new StabilityInfo('未测试', '#A1A1AA');
  }

  /** 结果行的次要说明 */
  static detail(c: Candidate): string {
    const parts: string[] = [];
    if (c.pingSent > 0) {
      if (c.pingRecv === c.pingSent) {
        parts.push('ping ' + c.pingRecv.toString() + '/' + c.pingSent.toString());
      } else {
        parts.push('连接失败 ' + (c.pingSent - c.pingRecv).toString() + '/' + c.pingSent.toString());
      }
    }
    if (c.stage === Stage.SPEED && c.speedStates.length > 0) {
      // 只要进了第三阶段就写出「成功 X/Y 轮」：失败节点也能看出跑了几轮、哪几轮失败，
      // 而不是只留一句「测速失败」。Y 优先取本轮设定轮数（方案 A 的惩罚分母），
      // 老数据没有 speedCfgRounds 时退回实际执行轮数。
      const arr: string[] = c.speedStates.split('/');
      let okCount: number = 0;
      for (let i = 0; i < arr.length; i++) {
        if (arr[i] === '成功') {
          okCount++;
        }
      }
      const cfgRounds: number = c.speedCfgRounds > 0 ? c.speedCfgRounds : arr.length;
      parts.push('成功 ' + okCount.toString() + '/' + cfgRounds.toString() + ' 轮');
      if (okCount > 0 && okCount < cfgRounds) {
        // 方案 A 的折算过程写进副标题：卡片上的速度是「有效速度」，
        // 若不给出实测均值，用户会以为「三轮里测出 20，却显示 6.67」是算错了。
        parts.push('实测均值 ' + c.speedAvgMbps.toFixed(2) + ' MB/s');
      }
    } else if (c.speedOk && c.speedRounds > 1) {
      parts.push('峰值 ' + c.speedMaxMbps.toFixed(2));
    }
    if (c.remark.length > 0) {
      parts.push(c.remark);
    }
    return parts.join(' · ');
  }

}