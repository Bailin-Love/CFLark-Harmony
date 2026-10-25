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
import { Candidate, Verdict, ScanConfig, VerdictText } from './Types';

export class StabilityInfo {
  text: string;
  color: string;

  constructor(text: string, color: string) {
    this.text = text;
    this.color = color;
  }
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

  /** 计算全体候选的归一化分数（min-max，退化时取 1 或 0） */
  /**
   * 计分：速度主导（默认权重 0.1 延迟 / 0.9 速度）。
   *
   * 不用 min-max 归一化，改用「相对最优」：
   *   delayScore = minDelay / delay      （延迟越低越接近 1）
   *   speedScore = speed / maxSpeed      （速度越高越接近 1，最高速 = 1）
   *
   * 理由：min-max 会把「最低速」压成 0 分，导致所有低速节点在速度维度上被抹平，
   * 最后又变成只看延迟；相对最优能保留「0.9 比 0.7 好」这种低速段差异。
   */
  static scoreSet(list: Candidate[], cfg: ScanConfig): void {
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
    const wd: number = cfg.delayWeight;
    const ws: number = cfg.speedWeight;
    const wsum: number = wd + ws > 0 ? wd + ws : 1;
    for (let i = 0; i < list.length; i++) {
      const c: Candidate = list[i];
      const d: number = Ranker.delayOf(c);
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
      c.delayScore = ds;
      c.speedScore = ss;
      c.finalScore = (ds * wd + ss * ws) / wsum;
    }
  }
  static compare(a: Candidate, b: Candidate): number {
    const ta: number = Ranker.tierOf(a.verdict);
    const tb: number = Ranker.tierOf(b.verdict);
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

  static apply(list: Candidate[], cfg: ScanConfig): void {
    Ranker.scoreSet(list, cfg);
    list.sort((a: Candidate, b: Candidate): number => {
      return Ranker.compare(a, b);
    });
    const limit: number = cfg.resultLimit;
    if (limit > 0 && list.length > limit) {
      list.length = limit;
    }
  }

  /** 可用数量（延迟达标或已测速） */
  static countPassed(list: Candidate[]): number {
    let n: number = 0;
    for (let i = 0; i < list.length; i++) {
      const v: Verdict = list[i].verdict;
      if (v === Verdict.SPEEDED || v === Verdict.PASS) {
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
        parts.push('丢包 ' + (c.pingSent - c.pingRecv).toString() + '/' + c.pingSent.toString());
      }
    }
    if (c.speedOk && c.speedRounds > 1) {
      parts.push('峰值 ' + c.speedMaxMbps.toFixed(2));
    }
    if (c.remark.length > 0) {
      parts.push(c.remark);
    }
    return parts.join(' · ');
  }

  /** 综合分百分制，便于展示 */
  static scoreText(c: Candidate): string {
    return Math.round(c.finalScore * 100).toString();
  }
}