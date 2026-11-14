/**
 * 测速历史本地存储（第十一轮新增）
 *
 * 设计目标：
 * 1. 每次正式测速写一条独立 JSON 快照，后续测速绝不覆盖旧记录；
 * 2. 列表只读 index.json（摘要），完整记录点开详情时才读对应文件，
 *    历史很多时也不会把所有节点常驻内存；
 * 3. 记录里存的是「当时算好的评分/排名」，读取时不再跑 Ranker，
 *    以后改评分算法不会改写过去的结果；
 * 4. 只保留最近「保存上限」条，超过后按时间删除最旧的一条，
 *    避免长期使用把手机存储撑大。
 *
 * 存储位置：filesDir/cflark_history/
 *   - index.json        摘要数组（时间戳倒序）
 *   - <id>.json         单条完整快照
 */
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HistoryNode, HistoryRecord, HistorySummary } from './Types';

const DIR_NAME: string = 'cflark_history';
const INDEX_FILE: string = 'index.json';
/** 默认最多保留的历史条数：单条通常几 KB，50 条对存储与列表性能都安全 */
export const DEFAULT_HISTORY_LIMIT: number = 50;

export class HistoryStore {
  private static dir: string = '';
  /** 用户设置的保存上限（0=关闭自动保存，30/50=保留最近 N 条） */
  private static limit: number = DEFAULT_HISTORY_LIMIT;

  /** 应用启动时调用一次；filesDir 由调用方从 UIAbilityContext 取 */
  static init(filesDir: string): void {
    if (filesDir.length === 0) {
      return;
    }
    HistoryStore.dir = filesDir + '/' + DIR_NAME;
    HistoryStore.ensureDir();
  }

  /** 设置保存上限；返回 false 表示设置为 0（调用方据此跳过保存） */
  static setLimit(n: number): boolean {
    HistoryStore.limit = (n === 0 || n === 30 || n === 50) ? n : DEFAULT_HISTORY_LIMIT;
    return HistoryStore.limit > 0;
  }

  static getLimit(): number {
    return HistoryStore.limit;
  }

  /** 上限调小时立即裁掉最旧的记录（调大时不会恢复已删除的数据） */
  static trimToLimit(): void {
    if (HistoryStore.limit <= 0 || HistoryStore.dir.length === 0) {
      return;
    }
    const list: HistorySummary[] = HistoryStore.loadIndex();
    if (list.length <= HistoryStore.limit) {
      return;
    }
    const next: HistorySummary[] = list.slice(0, HistoryStore.limit);
    for (let i = HistoryStore.limit; i < list.length; i++) {
      HistoryStore.removeFile(list[i].id);
    }
    HistoryStore.writeText(HistoryStore.indexPath(), JSON.stringify(next));
  }

  /** 清空全部历史（只动历史目录内的文件，不碰任何测速参数与应用配置） */
  static clearAll(): boolean {
    if (HistoryStore.dir.length === 0) {
      return false;
    }
    const list: HistorySummary[] = HistoryStore.loadIndex();
    for (let i = 0; i < list.length; i++) {
      HistoryStore.removeFile(list[i].id);
    }
    const empty: HistorySummary[] = [];
    return HistoryStore.writeText(HistoryStore.indexPath(), JSON.stringify(empty));
  }

  /** 存储是否就绪（目录初始化失败时详情节流会明确提示，而不是静默丢记录） */
  static ready(): boolean {
    return HistoryStore.dir.length > 0;
  }

  private static ensureDir(): void {
    if (HistoryStore.dir.length === 0) {
      return;
    }
    try {
      if (!fileIo.accessSync(HistoryStore.dir)) {
        fileIo.mkdirSync(HistoryStore.dir, true);
      }
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      console.error('[HistoryStore] mkdir failed: ' + be.message);
    }
  }

  private static indexPath(): string {
    return HistoryStore.dir + '/' + INDEX_FILE;
  }

  private static recordPath(id: string): string {
    return HistoryStore.dir + '/' + id + '.json';
  }

  private static writeText(path: string, text: string): boolean {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      return true;
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      console.error('[HistoryStore] write failed: ' + be.message);
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (e2) {
          // 关闭失败不影响返回值：本次写入已经失败
        }
      }
      return false;
    }
  }

  private static readText(path: string): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      return fileIo.readTextSync(path);
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      console.error('[HistoryStore] read failed: ' + be.message);
      return '';
    }
  }

  /** 历史节点地址：IPv6 加方括号，和导出格式保持一致 */
  static endpointOf(n: HistoryNode): string {
    const addr: string = n.version === 6 ? '[' + n.ip + ']' : n.ip;
    return addr + ':' + n.port.toString();
  }

  /** 从完整记录提炼列表摘要（取排名第一的节点） */
  private static summaryOf(rec: HistoryRecord): HistorySummary {
    let topEndpoint: string = '';
    let topScore: number = 0;
    if (rec.nodes.length > 0) {
      const top: HistoryNode = rec.nodes[0];
      topEndpoint = HistoryStore.endpointOf(top);
      topScore = top.finalScore;
    }
    const sum: HistorySummary = {
      id: rec.meta.id,
      time: rec.meta.time,
      nodeCount: rec.meta.nodeCount,
      okCount: rec.meta.okCount,
      failCount: rec.meta.failCount,
      cfgRounds: rec.meta.cfgRounds,
      topEndpoint: topEndpoint,
      topScore: topScore
    };
    return sum;
  }

  /**
   * 保存一条完整记录并刷新索引。
   * 返回 false 表示磁盘写入失败（调用方会记一条日志，不影响当前测速结果）。
   */
  static save(rec: HistoryRecord): boolean {
    HistoryStore.ensureDir();
    if (HistoryStore.dir.length === 0 || rec.meta.id.length === 0) {
      return false;
    }
    if (HistoryStore.limit <= 0) {
      return false;
    }
    const ok: boolean = HistoryStore.writeText(HistoryStore.recordPath(rec.meta.id), JSON.stringify(rec));
    if (!ok) {
      return false;
    }
    const list: HistorySummary[] = HistoryStore.loadIndex();
    const sum: HistorySummary = HistoryStore.summaryOf(rec);
    // 新记录永远在最前；同 id（时钟回拨等极端情况）直接覆盖旧摘要
    const next: HistorySummary[] = [sum];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id !== sum.id) {
        next.push(list[i]);
      }
    }
    while (next.length > HistoryStore.limit) {
      const drop: HistorySummary = next[next.length - 1];
      next.splice(next.length - 1, 1);
      HistoryStore.removeFile(drop.id);
    }
    return HistoryStore.writeText(HistoryStore.indexPath(), JSON.stringify(next));
  }

  /** 读列表摘要；索引损坏时返回已成功解析的部分，不抛异常打断页面 */
  static loadIndex(): HistorySummary[] {
    const out: HistorySummary[] = [];
    if (HistoryStore.dir.length === 0) {
      return out;
    }
    const text: string = HistoryStore.readText(HistoryStore.indexPath());
    if (text.length === 0) {
      return out;
    }
    try {
      const rawList: HistorySummary[] = JSON.parse(text) as HistorySummary[];
      for (let i = 0; i < rawList.length; i++) {
        const r: HistorySummary = rawList[i];
        if (typeof r.id !== 'string' || r.id.length === 0) {
          continue;
        }
        const item: HistorySummary = {
          id: r.id,
          time: typeof r.time === 'string' ? r.time : '',
          nodeCount: typeof r.nodeCount === 'number' ? r.nodeCount : 0,
          okCount: typeof r.okCount === 'number' ? r.okCount : 0,
          failCount: typeof r.failCount === 'number' ? r.failCount : 0,
          cfgRounds: typeof r.cfgRounds === 'number' ? r.cfgRounds : 1,
          topEndpoint: typeof r.topEndpoint === 'string' ? r.topEndpoint : '',
          topScore: typeof r.topScore === 'number' ? r.topScore : 0
        };
        out.push(item);
      }
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      console.error('[HistoryStore] index parse failed: ' + be.message);
    }
    return out;
  }

  /** 按需读取一条完整记录；文件缺失/损坏返回 null */
  static read(id: string): HistoryRecord | null {
    if (HistoryStore.dir.length === 0 || id.length === 0) {
      return null;
    }
    const text: string = HistoryStore.readText(HistoryStore.recordPath(id));
    if (text.length === 0) {
      return null;
    }
    try {
      const rec: HistoryRecord = JSON.parse(text) as HistoryRecord;
      if (typeof rec.meta.id !== 'string' || !Array.isArray(rec.nodes)) {
        return null;
      }
      return rec;
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      console.error('[HistoryStore] record parse failed: ' + be.message);
      return null;
    }
  }

  private static removeFile(id: string): void {
    try {
      const path: string = HistoryStore.recordPath(id);
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      console.error('[HistoryStore] unlink failed: ' + be.message);
    }
  }

  /** 删除指定一条（只删这一条，其他记录与索引保持原样） */
  static remove(id: string): boolean {
    if (HistoryStore.dir.length === 0 || id.length === 0) {
      return false;
    }
    HistoryStore.removeFile(id);
    const list: HistorySummary[] = HistoryStore.loadIndex();
    const next: HistorySummary[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id !== id) {
        next.push(list[i]);
      }
    }
    return HistoryStore.writeText(HistoryStore.indexPath(), JSON.stringify(next));
  }
}
