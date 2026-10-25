/**
 * 结果导出：TXT / CSV
 *
 * 三种 TXT 格式对齐 CFData-WEB 的常见用法：
 *  - PLAIN：ip:port
 *  - PLAIN_COLO：ip:port#HKG
 *  - PLAIN_COLO_DELAY：ip:port#HKG#49ms
 * CSV 给出全部测量字段，方便二次分析。
 */
import { Candidate, ScanConfig, Verdict } from './Types';
import { Ranker } from './Ranker';

/** 导出格式 */
export enum ExportFormat {
  PLAIN = 0,
  PLAIN_COLO = 1,
  PLAIN_COLO_DELAY = 2,
  /** ip:port#COLO#延迟#速度 */
  PLAIN_SPEED = 3,
  CSV = 4
}

/** 导出选项 */
export interface ExportOptions {
  format: ExportFormat;
  onlyQualified: boolean;
  limit: number;
  v6Bracket: boolean;
}

export function defaultExportOptions(): ExportOptions {
  const o: ExportOptions = {
    format: ExportFormat.PLAIN_COLO,
    onlyQualified: false,
    limit: 0,
    v6Bracket: true
  };
  return o;
}

export class Exporter {
  /** 拼 ip:port（IPv6 视配置加方括号） */
  static endpoint(c: Candidate, v6Bracket: boolean): string {
    const host: string = c.version === 6 && v6Bracket ? '[' + c.ip + ']' : c.ip;
    return host + ':' + c.port.toString();
  }

  /** 延迟文本 */
  static delayText(c: Candidate): string {
    const d: number = Ranker.delayOf(c);
    if (d < 0) {
      return '-';
    }
    return Math.round(d).toString() + 'ms';
  }

  /** 速度文本 */
  static speedText(c: Candidate): string {
    if (c.speedMbps <= 0) {
      return '-';
    }
    return c.speedMbps.toFixed(2) + 'MB/s';
  }

  /** 是否可用（延迟达标或已测速） */
  static isUsable(c: Candidate): boolean {
    return c.verdict === Verdict.PASS || c.verdict === Verdict.SPEEDED;
  }

  /** 兼容旧调用 */
  static isQualified(c: Candidate): boolean {
    return Exporter.isUsable(c);
  }

  /** 选取要导出的条目 */
  static pick(list: Candidate[], opt: ExportOptions): Candidate[] {
    const out: Candidate[] = [];
    for (let i = 0; i < list.length; i++) {
      const c: Candidate = list[i];
      if (opt.onlyQualified && !Exporter.isUsable(c)) {
        continue;
      }
      out.push(c);
      if (opt.limit > 0 && out.length >= opt.limit) {
        break;
      }
    }
    return out;
  }

  /** TXT */
  static toText(list: Candidate[], opt: ExportOptions): string {
    const picked: Candidate[] = Exporter.pick(list, opt);
    const lines: string[] = [];
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      const ep: string = Exporter.endpoint(c, opt.v6Bracket);
      if (opt.format === ExportFormat.PLAIN) {
        lines.push(ep);
      } else if (opt.format === ExportFormat.PLAIN_COLO) {
        lines.push(ep + '#' + (c.colo.length > 0 ? c.colo : '-'));
      } else if (opt.format === ExportFormat.PLAIN_SPEED) {
        // 测速结果：ip:port#COLO#延迟#速度（失败写 fail）
        const sp: string = (c.verdict === Verdict.SPEEDED && c.speedMbps > 0)
          ? c.speedMbps.toFixed(2) + 'MB/s'
          : 'fail';
        lines.push(ep + '#' + (c.colo.length > 0 ? c.colo : '-') + '#' + Exporter.delayText(c) + '#' + sp);
      } else {
        lines.push(ep + '#' + (c.colo.length > 0 ? c.colo : '-') + '#' + Exporter.delayText(c));
      }
    }
    return lines.join('\n');
  }

  /** CSV */
  static toCsv(list: Candidate[], opt: ExportOptions): string {
    const picked: Candidate[] = Exporter.pick(list, opt);
    const head: string = 'ip,port,minLatencyMs,avgLatencyMs,lossRate,pingRecv,pingSent,colo,traceOk,traceDelayMs,speedMbps,speedMaxMbps,speedRounds,delayScore,speedScore,finalScore,verdict';
    const rows: string[] = [head];
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      const cols: string[] = [
        c.ip,
        c.port.toString(),
        c.minLatencyMs > 0 ? c.minLatencyMs.toFixed(1) : '',
        c.avgLatencyMs > 0 ? c.avgLatencyMs.toFixed(1) : '',
        c.lossRate.toFixed(3),
        c.pingRecv.toString(),
        c.pingSent.toString(),
        c.colo,
        c.traceOk ? '1' : '0',
        c.traceDelayMs > 0 ? c.traceDelayMs.toFixed(1) : '',
        c.speedMbps > 0 ? c.speedMbps.toFixed(3) : '',
        c.speedMaxMbps > 0 ? c.speedMaxMbps.toFixed(3) : '',
        c.speedRounds.toString(),
        c.delayScore.toFixed(4),
        c.speedScore.toFixed(4),
        c.finalScore.toFixed(4),
        Ranker.labelOf(c.verdict)
      ];
      rows.push(cols.join(','));
    }
    return rows.join('\n');
  }

  /** 建议文件名 */
  static suggestFileName(fmt: ExportFormat, cfg: ScanConfig): string {
    const d: Date = new Date();
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    const t: string = d.getFullYear().toString() + pad(d.getMonth() + 1) + pad(d.getDate()) +
      '-' + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
    const ext: string = fmt === ExportFormat.CSV ? 'csv' : 'txt';
    return 'cflark-' + t + '.' + ext;
  }
}