/**
 * 结果导出：TXT / CSV
 *
 * TXT 对齐 CFData-WEB 的常见用法，是「拿来直接粘进客户端」的格式：
 *  - PLAIN：ip:port
 *  - PLAIN_COLO：ip:port#HKG
 *  - PLAIN_COLO_DELAY：ip:port#HKG#49ms
 *  - PLAIN_SPEED：ip:port#HKG#49ms#50.12MB/s（失败的写 fail）
 *
 * CSV 是「给人看结果、也能拿去二次分析」的表格，全部中文表头。
 * 两边的延迟/速度取自同一份 Candidate，不会出现同一个节点两个数值。
 */
import { Candidate, ScanConfig, Verdict, Stage } from './Types';
import { Ranker } from './Ranker';
import { IpUtil } from './IpUtil';
import { Geo } from './Geo';

/**
 * CSV 需要的「本次扫描的配置元信息」。
 * 这些值不随单个节点变化，但离开它们就无法判断「测了 3 次只成功 1 次」这类事实，
 * 所以与每行数据一起落盘，方便离线还原测试过程。
 */
export interface ExportMeta {
  /** 配置的 Ping 次数（与每行 pingSent 对比即可看出是否提前结束） */
  pingTimes: number;
  /** 配置的 Ping 单次超时（ms） */
  pingTimeoutMs: number;
  /** 配置的每地址测速轮数（与每行成功轮数对比即可看出失败了几轮） */
  speedRounds: number;
  /** 配置的单轮下载统计窗口（ms）；换过窗口的历史数据不能直接比速度 */
  speedWindowMs: number;
  /** 应用版本号，便于跨版本对比 */
  appVersion: string;
  /** 本轮计分用的最小延迟基准（ms）；0 表示未取到 */
  scoreBaseDelayMs: number;
  /** 本轮计分用的最高速度基准（MB/s）；0 表示未取到 */
  scoreBaseSpeedMbps: number;
  /**
   * 配置的「合格速度」门槛（MB/s）。
   * 用来把「测速成功但低于门槛」标成「未达标」——这条信息只影响「说明」列，
   * 不参与评分，也不改变任何通过/淘汰判定。
   */
  minSpeedMbps: number;
  /** 延迟上限（ms）：TXT 报告「筛选条件」用 */
  latencyLimitMs: number;
  /** 丢包率上限（%）：TXT 报告「筛选条件」用 */
  maxLossPct: number;
  /** 测速并发：TXT 报告「测速参数」用 */
  speedConcurrency: number;
  /** 本轮测速完成时间（yyyy-MM-dd HH:mm:ss）；留空则用导出时间 */
  scanTime: string;
}

/** 导出格式 */
export enum ExportFormat {
  PLAIN = 0,
  PLAIN_COLO = 1,
  PLAIN_COLO_DELAY = 2,
  /**
   * 完整测速报告（TXT）：概况 + 节点统计表 + 逐轮明细 + 可复制地址列表。
   * 数值沿用 3（历史值），只是语义从「单行粘贴格式」升级成「人读报告」。
   */
  REPORT = 3,
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

  /** 是否可用（延迟达标或已测速） */
  static isUsable(c: Candidate): boolean {
    return c.verdict === Verdict.PASS || c.verdict === Verdict.SPEEDED;
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

  /**
   * TXT 导出的统一入口。
   *
   * REPORT（导出按钮默认使用的格式）输出完整报告：任务概况 + 节点统计表 + 逐轮明细
   * + 可复制地址列表。旧版 TXT 只有一行 `ip:port 地区 延迟 速度 状态`，等于把三轮
   * 结果压缩成最后一个数——失败轮、成功轮数、评分、延迟统计全部丢失，所以用户看到
   * 的 TXT 和 CSV 像两次不同的测试。现在两种格式都从同一份 Candidate 字段取数，
   * 轮次、统计、评分必然一致。
   *
   * 纯 IP 的三种格式仍然跳过「测速失败/没有有效数据」的节点——这些地址连不上或
   * 测不出速度，混进列表只会让用户拿到不可用 IP。这部分行为保持不变。
   */
  static toText(list: Candidate[], opt: ExportOptions, meta?: ExportMeta): string {
    const picked: Candidate[] = Exporter.pick(list, opt);
    if (opt.format === ExportFormat.REPORT) {
      return Exporter.toReport(picked, opt, meta);
    }
    const lines: string[] = [];
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      const ep: string = Exporter.endpoint(c, opt.v6Bracket);
      if (opt.format === ExportFormat.PLAIN) {
        if (!c.speedOk) {
          continue;
        }
        lines.push(ep);
      } else if (opt.format === ExportFormat.PLAIN_COLO) {
        if (!c.speedOk) {
          continue;
        }
        lines.push(ep + '#' + (c.colo.length > 0 ? c.colo : '-'));
      } else {
        if (!c.speedOk) {
          continue;
        }
        lines.push(ep + '#' + (c.colo.length > 0 ? c.colo : '-') + '#' + Exporter.delayText(c));
      }
    }
    return lines.join('\n');
  }

  /** 两位小数；<= 0 表示没有成功样本，输出 `-`（不写 0，避免被读成「测出 0 MB/s」） */
  private static mbps(v: number): string {
    if (v <= 0) {
      return '-';
    }
    return v.toFixed(2);
  }

  /** 终端显示宽度：CJK / 全角标点按 2 列算，保证中文表格不错位 */
  private static dispWidth(s: string): number {
    let w: number = 0;
    for (let i = 0; i < s.length; i++) {
      const code: number = s.charCodeAt(i);
      if ((code >= 0x1100 && code <= 0x115F) || (code >= 0x2E80 && code <= 0xA4CF) ||
        (code >= 0xAC00 && code <= 0xD7A3) || (code >= 0xF900 && code <= 0xFAFF) ||
        (code >= 0xFE30 && code <= 0xFE6F) || (code >= 0xFF00 && code <= 0xFF60) ||
        (code >= 0xFFE0 && code <= 0xFFE6)) {
        w += 2;
      } else {
        w += 1;
      }
    }
    return w;
  }

  private static pad(s: string, width: number): string {
    let out: string = s;
    let w: number = Exporter.dispWidth(s);
    while (w < width) {
      out += ' ';
      w++;
    }
    return out;
  }

  private static tableLine(cells: string[], widths: number[]): string {
    let line: string = '';
    for (let c = 0; c < cells.length; c++) {
      if (c > 0) {
        line += ' | ';
      }
      line += Exporter.pad(cells[c], widths[c]);
    }
    return line;
  }

  /** 列宽按表头与全部单元格的显示宽度取最大，避免内容被截断或错位 */
  private static table(header: string[], rows: string[][]): string[] {
    const cols: number = header.length;
    const widths: number[] = [];
    for (let c = 0; c < cols; c++) {
      widths.push(Exporter.dispWidth(header[c]));
    }
    for (let r = 0; r < rows.length; r++) {
      for (let c = 0; c < cols; c++) {
        const w: number = Exporter.dispWidth(rows[r][c]);
        if (w > widths[c]) {
          widths[c] = w;
        }
      }
    }
    const out: string[] = [];
    out.push(Exporter.tableLine(header, widths));
    const seps: string[] = [];
    for (let c = 0; c < cols; c++) {
      let s: string = '';
      for (let k = 0; k < widths[c]; k++) {
        s += '-';
      }
      seps.push(s);
    }
    out.push(Exporter.tableLine(seps, widths));
    for (let r = 0; r < rows.length; r++) {
      out.push(Exporter.tableLine(rows[r], widths));
    }
    return out;
  }

  /**
   * 逐轮测速：成功轮直接写数值，失败轮写「—（失败原因）」。
   * 数据来自 speedSamples / speedStates 两个同下标字符串，与 CSV 的
   * 「每轮速度 / 每轮结果」两列完全同源。
   */
  private static roundsText(c: Candidate): string {
    if (c.speedSamples.length === 0 && c.speedStates.length === 0) {
      return '-';
    }
    const samples: string[] = c.speedSamples.length > 0 ? c.speedSamples.split('/') : [];
    const states: string[] = c.speedStates.length > 0 ? c.speedStates.split('/') : [];
    const n: number = samples.length > states.length ? samples.length : states.length;
    const parts: string[] = [];
    for (let i = 0; i < n; i++) {
      const s: string = i < samples.length ? samples[i] : '\u2014';
      const st: string = i < states.length ? states[i] : '';
      if (s !== '\u2014' && s.length > 0) {
        parts.push(s);
      } else {
        parts.push('\u2014\uff08' + (st.length > 0 ? st : '失败') + '\uff09');
      }
    }
    return parts.join(' / ');
  }

  /** 报告里的状态：失败必须写出原因，达标情况与 CSV「说明」列同口径 */
  private static reportStatus(c: Candidate, meta?: ExportMeta): string {
    if (c.stage !== Stage.SPEED) {
      return Exporter.statusOf(c);
    }
    if (!c.speedOk || c.speedMbps <= 0) {
      return '测速失败\uff08' + (c.remark.length > 0 ? c.remark : '无有效速度') + '\uff09';
    }
    const note: string = Exporter.noteOf(c, meta);
    const cfgRounds: number = c.speedCfgRounds > 0 ? c.speedCfgRounds : c.speedRounds;
    const partial: string = cfgRounds > 0 && c.speedRounds > 0 && c.speedRounds < cfgRounds
      ? ' · ' + c.speedRounds.toString() + '/' + cfgRounds.toString() + ' 轮' : '';
    if (note.indexOf('未达标') === 0) {
      return '已测速 · 未达标' + partial;
    }
    return '已测速' + partial;
  }

  /** 统一的时间文本（yyyy-MM-dd HH:mm:ss），TXT 报告与界面共用同一格式 */
  static timeText(d: Date): string {
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return d.getFullYear().toString() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }

  /** 完整 TXT 报告（概况 / 统计表 / 逐轮明细 / 可复制地址） */
  private static toReport(picked: Candidate[], opt: ExportOptions, meta?: ExportMeta): string {
    const scanTime: string = meta !== undefined && meta.scanTime.length > 0
      ? meta.scanTime : Exporter.timeText(new Date());
    const cfgRounds: number = meta !== undefined && meta.speedRounds > 0 ? meta.speedRounds : 1;
    let okNodes: number = 0;
    let failNodes: number = 0;
    let totalRounds: number = 0;
    let okRounds: number = 0;
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      if (c.stage !== Stage.SPEED) {
        continue;
      }
      if (c.speedOk && c.speedMbps > 0) {
        okNodes++;
      } else {
        failNodes++;
      }
      const states: string[] = c.speedStates.length > 0 ? c.speedStates.split('/') : [];
      totalRounds += states.length;
      for (let k = 0; k < states.length; k++) {
        if (states[k] === '成功') {
          okRounds++;
        }
      }
    }

    const lines: string[] = [];
    lines.push('CFLark 测速报告');
    lines.push('========================================');
    lines.push('');
    lines.push('【一、测速概况】');
    lines.push('测速时间：' + scanTime);
    if (meta !== undefined) {
      lines.push('应用版本：' + meta.appVersion);
    }
    lines.push('节点总数：' + picked.length.toString() + ' 个（测速成功 ' + okNodes.toString() +
      ' / 测速失败 ' + failNodes.toString() + '）');
    lines.push('设定轮数：每节点 ' + cfgRounds.toString() + ' 轮');
    lines.push('实际执行：' + totalRounds.toString() + ' 轮（成功 ' + okRounds.toString() +
      ' / 失败 ' + (totalRounds - okRounds).toString() + '）');
    if (meta !== undefined) {
      lines.push('筛选条件：延迟上限 ' + meta.latencyLimitMs.toString() + 'ms · 连接失败率上限 ' +
        meta.maxLossPct.toFixed(1) + '% · Ping ' + meta.pingTimes.toString() + ' 次 / 超时 ' +
        meta.pingTimeoutMs.toString() + 'ms');
      lines.push('测速参数：窗口 ' + meta.speedWindowMs.toString() + 'ms · 并发 ' +
        meta.speedConcurrency.toString() + ' · 合格速度 ' + meta.minSpeedMbps.toFixed(2) + 'MB/s');
      lines.push('计分基准：最低延迟 ' +
        (meta.scoreBaseDelayMs > 0 ? Math.round(meta.scoreBaseDelayMs).toString() + 'ms' : '-') +
        ' · 最高速度 ' +
        (meta.scoreBaseSpeedMbps > 0 ? meta.scoreBaseSpeedMbps.toFixed(2) + 'MB/s' : '-'));
    }
    lines.push('评分口径：有效速度 = 成功轮中位数 ×（成功轮数 ÷ 设定轮数）；' +
      '三轮全失败记 0，并排在有效测速成功的节点之后');
    lines.push('');

    lines.push('【二、节点统计表】');
    lines.push('说明：延迟单位 ms（低/均/高）；速度单位 MB/s；评分与 CSV「综合评分」同源');
    const header: string[] = ['排名', '节点', '延迟 低/均/高(ms)', '最低', '最高', '平均',
      '有效', '稳定性(%)', '成功/设定', '评分', '状态'];
    const rows: string[][] = [];
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      const lo: string = c.minLatencyMs > 0 ? Math.round(c.minLatencyMs).toString() : '-';
      const av: string = c.avgLatencyMs > 0 ? Math.round(c.avgLatencyMs).toString() : '-';
      const hi: string = c.maxLatencyMs > 0 ? Math.round(c.maxLatencyMs).toString() : '-';
      const roundsCell: string = c.stage === Stage.SPEED
        ? (c.speedRounds.toString() + '/' +
          (c.speedCfgRounds > 0 ? c.speedCfgRounds : cfgRounds).toString())
        : '-';
      rows.push([
        (i + 1).toString(),
        Exporter.endpoint(c, true),
        lo + '/' + av + '/' + hi,
        Exporter.mbps(c.speedMinMbps),
        Exporter.mbps(c.speedMaxMbps),
        Exporter.mbps(c.speedAvgMbps),
        Exporter.mbps(c.speedMbps),
        (c.speedCfgRounds > 1 && c.stabilityScore >= 0 ? Math.round(c.stabilityScore).toString() : '-'),
        roundsCell,
        Exporter.pct(c.finalScore),
        Exporter.reportStatus(c, meta)
      ]);
    }
    const tableLines: string[] = Exporter.table(header, rows);
    for (let i = 0; i < tableLines.length; i++) {
      lines.push(tableLines[i]);
    }
    lines.push('');
    lines.push('注：有效 = 参与评分的方案 A 有效速度；平均 = 成功轮算术平均；' +
      '两者不同说明有轮次失败被折算');
    lines.push('');

    lines.push('【三、逐轮测速明细】');
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      const place: string = Exporter.placeOf(c);
      const states: string[] = c.speedStates.length > 0 ? c.speedStates.split('/') : [];
      lines.push((i + 1).toString() + '. ' + Exporter.endpoint(c, true) +
        (place.length > 0 ? ' · ' + place : '') +
        '（' + states.length.toString() + ' 轮，成功 ' + c.speedRounds.toString() + '）');
      lines.push('   ' + Exporter.roundsText(c));
    }
    lines.push('');

    lines.push('【四、可复制地址（仅测速成功）】');
    let usable: number = 0;
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      if (c.speedOk && c.speedMbps > 0) {
        lines.push(Exporter.endpoint(c, opt.v6Bracket));
        usable++;
      }
    }
    if (usable === 0) {
      lines.push('（本轮没有测速成功的节点）');
    }
    lines.push('');
    lines.push('—— 本报告与 CSV 导出使用同一份测速结果，可直接对照核验 ——');
    return lines.join('\n');
  }

  /** CSV 单元格转义：含逗号/引号/换行时用双引号包起来。 */
  private static csvCell(s: string): string {
    if (s.indexOf(',') < 0 && s.indexOf('"') < 0 && s.indexOf('\n') < 0 && s.indexOf('\r') < 0) {
      return s;
    }
    return '"' + s.replace(/"/g, '""') + '"';
  }

  /**
   * 「说明」列：只描述这个节点最后发生了什么，不再直接复用内部阶段的 remark。
   *
   * 旧版本会把第三阶段测速成功的节点写成「预检达标」——那是第一阶段的残留文案，
   * 看上去像「它只是通过了预检、并没有测速」。现在的口径：
   *   测速成功              → 测速成功
   *   成功但低于合格速度    → 未达标
   *   测速失败              → 具体失败原因（HTTP 429 / 未读到数据 / 数据不足(…) …）
   *   未进入第三阶段        → 沿用阶段说明（预检不达标 / 延迟超限 / 无法连通 …）
   */
  private static noteOf(c: Candidate, meta?: ExportMeta): string {
    if (c.stage === Stage.SPEED) {
      if (!c.speedOk) {
        return c.remark.length > 0 ? c.remark : '测速失败';
      }
      const minSpeed: number = meta === undefined ? 0 : meta.minSpeedMbps;
      let note: string = '测速成功';
      if (minSpeed > 0 && c.speedMbps < minSpeed) {
        note = '未达标';
      }
      // 有失败轮时把「有效速度」写进说明：CSV 的速度列仍是实测平均值，
      // 不给折算结果的话，用户无法解释「20 MB/s 为什么评分低于 11 MB/s」。
      if (c.speedRounds > 0 && c.speedCfgRounds > c.speedRounds) {
        note += '（有效 ' + c.speedMbps.toFixed(2) + ' MB/s，' + c.speedRounds.toString() +
          '/' + c.speedCfgRounds.toString() + ' 轮）';
      }
      return note;
    }
    return c.remark;
  }

  /** 地区：输出「HKG 香港」这种一眼能看懂的写法；未知 colo 时原样返回。 */
  private static placeOf(c: Candidate): string {
    if (c.colo.length === 0) {
      return '';
    }
    return Geo.placeZh(c.colo);
  }

  /**
   * 状态：导出给用户看的，必须和「说明」自洽。
   *
   * 内部 verdict 对测速阶段一律是 SPEEDED（层级排序要靠它，不能动），
   * 但测速失败时 verdict 仍是 SPEEDED，直接照搬就会出现
   * 「状态=已测速、速度=空、说明=HTTP 429」这种自相矛盾的行。
   */
  private static statusOf(c: Candidate): string {
    if (c.stage === Stage.SPEED) {
      return c.speedOk && c.speedMbps > 0 ? '已测速' : '测速失败';
    }
    return Ranker.labelOf(c.verdict);
  }

  /** 百分制分数：三个得分用同一口径，用户能直接比较。 */
  private static pct(v: number): string {
    return Math.round(v * 100).toString();
  }

  /**
   * CSV（中文表头，UTF-8 带 BOM，保证 Excel/WPS 直接打开不乱码）
   *
   * 与旧版的区别：
   *  - 列名全部改成中文，不需要对照字典；
   *  - 去掉 stage / traceOk / speedOk / failReason 这类纯内部字段；
   *  - 增加「排名」，与应用里看到的顺序一一对应；
   *  - 三个得分都输出百分制，用户看得懂「82 分 / 100 分」；
   *  - 测速失败的速度列留空，由「状态 / 说明」解释原因，
   *    不会出现「0.000 MB/s」被误读成「测出来就是 0」。
   *
   * 分数口径说明：延迟得分 = 本轮最快延迟 ÷ 本节点延迟，速度得分 = 本节点速度 ÷ 本轮最高速度，
   * 稳定性得分来自测速阶段每轮开始的 TCP 握手成功率；综合评分按设定轮数取三维权重
   * （N=1 为 0.3/0/0.7，N=2 为 0.25/0.1/0.65，N≥3 为 0.3/0.2/0.5）。都是「本轮结果内的相对分」，
   * 不同批次之间的分数不可直接比较。
   */
  static toCsv(list: Candidate[], opt: ExportOptions, meta?: ExportMeta): string {
    const picked: Candidate[] = Exporter.pick(list, opt);
    // 列名说明：
    //   平均速度      —— 成功轮的算术平均（与 TXT「平均」同源）
    //   最低单轮      —— 成功轮里的最小值（与 TXT「最低」同源）
    //   最快单轮      —— 成功轮里的最大值（与 TXT「最高」同源）
    //   有效速度      —— 方案 A 参与评分的速度（成功轮中位数 × 成功/设定）
    //   成功轮数/设定轮数 —— 拆成两个整数，避免 `1/1` 被 Excel 认成日期
    //   每轮速度/每轮结果 —— 本轮真实执行到的每一轮，失败轮速度留空
    //   本轮最快延迟/本轮最高速度 —— 本轮评分归一化用的基准，用来复算得分
    const head: string = '排名,IP地址,端口,地区,延迟(ms),平均延迟(ms),最大延迟(ms),连接失败率(%),'
      + '平均速度(MB/s),最低单轮(MB/s),最快单轮(MB/s),有效速度(MB/s),成功轮数,设定轮数,'
      + '每轮速度(MB/s),每轮结果,'
      + '本轮最快延迟(ms),本轮最高速度(MB/s),稳定性(%),'
      + '延迟得分,速度得分,综合评分,状态,说明,所属网段,IP版本,测速窗口(ms),应用版本';
    const cfgRounds: string = meta === undefined || meta.speedRounds <= 0
      ? '' : meta.speedRounds.toString();
    const cfgWindow: string = meta === undefined ? '' : meta.speedWindowMs.toString();
    const appVer: string = meta === undefined ? '' : meta.appVersion;
    const baseDelay: string = meta === undefined || meta.scoreBaseDelayMs <= 0
      ? '' : Math.round(meta.scoreBaseDelayMs).toString();
    const baseSpeed: string = meta === undefined || meta.scoreBaseSpeedMbps <= 0
      ? '' : meta.scoreBaseSpeedMbps.toFixed(2);
    const rows: string[] = [head];
    for (let i = 0; i < picked.length; i++) {
      const c: Candidate = picked[i];
      const cols: string[] = [
        (i + 1).toString(),
        c.ip,
        c.port.toString(),
        Exporter.placeOf(c),
        c.minLatencyMs > 0 ? Math.round(c.minLatencyMs).toString() : '',
        c.avgLatencyMs > 0 ? Math.round(c.avgLatencyMs).toString() : '',
        c.maxLatencyMs > 0 ? Math.round(c.maxLatencyMs).toString() : '',
        c.pingSent > 0 ? (c.lossRate * 100).toFixed(1) : '',
        c.speedAvgMbps > 0 ? c.speedAvgMbps.toFixed(2) : '',
        c.speedMinMbps > 0 ? c.speedMinMbps.toFixed(2) : '',
        c.speedMaxMbps > 0 ? c.speedMaxMbps.toFixed(2) : '',
        c.speedMbps > 0 ? c.speedMbps.toFixed(2) : '',
        c.stage === Stage.SPEED ? c.speedRounds.toString() : '',
        c.stage === Stage.SPEED
          ? (c.speedCfgRounds > 0 ? c.speedCfgRounds.toString() : cfgRounds)
          : '',
        c.speedSamples,
        c.speedStates,
        baseDelay,
        baseSpeed,
        c.speedCfgRounds > 1 && c.stabilityScore >= 0 ? Math.round(c.stabilityScore).toString() : '',
        Exporter.pct(c.delayScore),
        Exporter.pct(c.speedScore),
        Exporter.pct(c.finalScore),
        Exporter.statusOf(c),
        Exporter.noteOf(c, meta),
        IpUtil.cidrOf(c.ip),
        c.version === 6 ? '6' : '4',
        cfgWindow,
        appVer
      ];
      const cells: string[] = [];
      for (let k = 0; k < cols.length; k++) {
        cells.push(Exporter.csvCell(cols[k]));
      }
      rows.push(cells.join(','));
    }
    // BOM 只加在 CSV：Excel 靠它识别 UTF-8，否则中文表头会乱码。
    // TXT 不加，避免破坏 ip:port 这类按行解析的用法。
    return '\uFEFF' + rows.join('\n');
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
