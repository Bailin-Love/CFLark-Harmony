/**
 * Sources.ets —— 候选来源的「分组 / 来源 / 候选数据」三层模型
 *
 * 设计要点（对应改造需求）：
 *  1. 分组（SourceGroup）是用户用来组织和选择候选来源的逻辑集合；来源（SourceItem）
 *     是具体的链接 / 文件 / 文本输入；候选数据是来源解析成功后得到的标准网段行（lines）。
 *     三者不混在同一个字段里：分组只保存名称 + 来源列表，来源保存来源信息与导入状态，
 *     候选数据是来源里的 lines 数组（已通过严格 IP/CIDR 校验的标准写法）。
 *  2. IPv4 / IPv6 严格隔离：每个分组和每个来源都带 family（4 或 6），两族各有独立的
 *     分组数组、独立的社区库缓存、独立的「当前选中来源」持久化键（src_sel_v4 / src_sel_v6）。
 *     切换 V4/V6 不会读到另一族的数据；跨族选中会被业务层拒绝。
 *  3. 官方 IP 段保护：内置分组（builtin.official / builtin.community）不进入用户分组数组，
 *     任何改名 / 删除 / 增删来源 / 启用切换的调用都会在业务逻辑层被拒绝（不只是隐藏按钮）。
 *     官方 IP 段的定义仍然只存在于 IpUtil（CF_IPV4_RANGES / CF_IPV6_RANGES / V6Pool），
 *     本文件不复制、不修改它们。
 *  4. 导入严格校验：classify() 按内容的实际格式判断 IP 类型（不是按当前页面类型），
 *     逐行给出 accepted / rejected（带中文原因）与 duplicate 计数；错误类型必定被拒绝，
 *     混合内容会明确报告哪些行不符合当前类型要求。
 *  5. 持久化：preferences 单键（上限 16MB）+ 行式序列化（转义后按 \t 分字段），
 *     版本键 src_model_ver 避免每次启动重复迁移；旧版 scan_custom 数据按实际网段格式
 *     分类迁入，无法识别的行进入隔离区（保留并提示，不静默丢弃），scan_custom 原值不动。
 */
import { ConfigStore } from './ConfigStore';
import { IpUtil } from './IpUtil';
import { ScanConfig, ScanMode, IpVersion } from './Types';

/** IP 族：4 = IPv4，6 = IPv6（不用 0，避免和"未知"混淆） */
export const SRC_FAM_V4: number = 4;
export const SRC_FAM_V6: number = 6;

/** 内置分组 id（虚拟分组，不出现在用户分组数组里，因此不可能被改写） */
export const SRC_ID_OFFICIAL: string = 'builtin.official';
export const SRC_ID_COMMUNITY: string = 'builtin.community';
const BUILTIN_PREFIX: string = 'builtin.';

/** 来源类型 */
export const SRC_KIND_LINK: string = 'link';
export const SRC_KIND_FILE: string = 'file';
export const SRC_KIND_TEXT: string = 'text';

/** 来源导入状态 */
export const SRC_STATUS_OK: string = 'ok';
export const SRC_STATUS_PARTIAL: string = 'partial';
export const SRC_STATUS_FAILED: string = 'failed';

// v3：IPv4 / IPv6 各自一份模型，互不影响
const KEY_MODEL_V4: string = 'src_v4_model';
const KEY_MODEL_V6: string = 'src_v6_model';
// v2 的单键模型（两族混在一个 blob），只用于升级读取，不再写入
const KEY_MODEL_V2: string = 'src_model';
const KEY_VER: string = 'src_model_ver';
const KEY_SEL_V4: string = 'src_sel_v4';
const KEY_SEL_V6: string = 'src_sel_v6';
const VER_CURRENT: string = '3';
const VER_V2: string = '2';

const MAX_LINE_LEN: number = 200;
const MAX_LINES_PER_SOURCE: number = 20000;
const MAX_GROUPS_PER_FAMILY: number = 60;
const MAX_NAME_LEN: number = 40;
const MAX_REJECT_KEEP: number = 50;

/** 单行分类结果 */
export interface LineClass {
  /** 是否为合法网段行 */
  ok: boolean;
  /** 4 / 6 / 0（0 = 无法识别） */
  family: number;
  /** 标准写法（去注释、统一端口写法），ok 时有效 */
  canonical: string;
  /** 不通过时的中文原因 */
  reason: string;
}

/** 被拒绝的一行（含原因），用于"部分成功"的明确展示 */
export interface SourceReject {
  line: string;
  reason: string;
}

/** 一条来源：链接 / 文件 / 文本，带导入状态与解析出的候选数据 */
export interface SourceItem {
  id: string;
  /** SRC_KIND_* */
  kind: string;
  /** 4 / 6，必须与所属分组一致 */
  family: number;
  /** 链接 URL / 文件名 / 空串（文本粘贴） */
  ref: string;
  /** 展示名（链接取主机名+路径，文件取文件名，文本取前几个字） */
  name: string;
  /** 候选数据：标准网段行（已通过严格校验） */
  lines: string[];
  /** 被拒绝的行数（lines 之外的无效行） */
  rejectedCount: number;
  /** 被拒绝行的样本（最多 50 条），用于展示"为什么没导入" */
  rejects: SourceReject[];
  /** SRC_STATUS_* */
  status: string;
  /** 失败原因（网络 / 读取 / 无有效数据），空串表示无 */
  error: string;
  /** 是否参与扫描（启用状态，按族独立保存） */
  enabled: boolean;
  addedAt: number;
}

/** 一个自定义分组：名称 + 来源列表 + 固定 IP 族 */
export interface SourceGroup {
  id: string;
  name: string;
  /** 4 / 6 */
  family: number;
  /** 用户分组恒为 false（内置分组不写入本数组） */
  builtin: boolean;
  sources: SourceItem[];
  createdAt: number;
  updatedAt: number;
}

/** 隔离区：无法安全转换的旧数据（保留并提示，不参与扫描） */
export interface QuarantineItem {
  line: string;
  reason: string;
  family: number;
  at: number;
}

/** 导入解析结果 */
export interface ImportOutcome {
  /** 是否有可用的候选数据 */
  ok: boolean;
  family: number;
  /** 通过校验的标准行（已去重、保持原顺序） */
  accepted: string[];
  /** 被拒绝的行与原因 */
  rejected: SourceReject[];
  /** 内容内重复（同一行出现多次）被合并的数量 */
  duplicates: number;
  /** 整体失败原因（ok=true 时为空串） */
  error: string;
}

/** 旧版 scan_custom 的纯函数分流结果（v1 → v2 迁移用，不改任何静态状态） */
export interface MigratePlan {
  v4: string[];
  v6: string[];
  bad: number;
  badSamples: SourceReject[];
}

/** 通用操作结果（业务层保护也走这里返回错误，不抛异常） */
export interface OpResult {
  ok: boolean;
  error: string;
  groupId: string;
  sourceId: string;
}

/** 添加来源的结果：既报告操作本身，也报告导入成功/失败明细 */
export interface AddSourceResult {
  ok: boolean;
  error: string;
  groupId: string;
  sourceId: string;
  accepted: number;
  rejected: number;
  duplicates: number;
  sampleRejects: SourceReject[];
}

/** 编译结果：把选中的分组 → 交给扫描器的候选文本 */
export interface CompileResult {
  ok: boolean;
  family: number;
  groupId: string;
  label: string;
  /** 分组内来源总数 */
  sourceCount: number;
  /** 启用的来源数 */
  enabledCount: number;
  /** 最终候选行数（跨来源去重后） */
  lineCount: number;
  /** 二次校验时因 IP 类型不符被丢弃的行数 */
  wrongFamily: number;
  text: string;
  error: string;
}

/** 分组概况（列表展示"N 个来源 · M 行"） */
export interface GroupStats {
  sourceCount: number;
  enabledCount: number;
  lineCount: number;
  failedCount: number;
}

/** 某族当前选中项的可选列表项（下拉菜单/管理页共用） */
export interface SourceChoice {
  id: string;
  label: string;
  builtin: boolean;
  family: number;
  stats: GroupStats;
}

export class Sources {
  /** 用户自定义分组（两个族混存在这里，靠 family 字段区分；内置分组不写入） */
  static groups: SourceGroup[] = [];
  /** 社区段库缓存（按族分开保存，避免互相覆盖） */
  static communityV4: string = '';
  static communityV6: string = '';
  /** 隔离区 */
  static quarantines: QuarantineItem[] = [];
  /** 当前选中来源 id（按族独立） */
  static selV4: string = 'builtin.official';
  static selV6: string = 'builtin.official';
  /** 是否已从持久化加载 */
  static loaded: boolean = false;
  /** 迁移/加载时产生的提示（空串 = 无） */
  static loadNote: string = '';

  // ————————————————————————————————— 基础工具 —————————————————————————————————

  static famLabel(family: number): string {
    return family === SRC_FAM_V6 ? 'IPv6' : 'IPv4';
  }

  static kindLabel(kind: string): string {
    if (kind === SRC_KIND_LINK) {
      return '链接';
    }
    if (kind === SRC_KIND_FILE) {
      return '文件';
    }
    return '文本';
  }

  static isBuiltinId(id: string): boolean {
    return id.startsWith(BUILTIN_PREFIX);
  }

  /** 内置分组：只读。业务层用这个守卫，不能只依赖 UI 隐藏按钮 */
  static builtinError(id: string): string {
    if (id === SRC_ID_OFFICIAL) {
      return '官方 IP 段受保护，不允许修改或删除';
    }
    if (id === SRC_ID_COMMUNITY) {
      return '社区段库为内置只读来源，不允许修改或删除';
    }
    return '';
  }

  private static allDigits(s: string): boolean {
    if (s.length === 0) {
      return false;
    }
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c < 48 || c > 57) {
        return false;
      }
    }
    return true;
  }

  /** 严格 IPv4：四段十进制、每段 0-255、不允许空段 */
  static strictV4(ip: string): boolean {
    const parts: string[] = ip.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < 4; i++) {
      const p: string = parts[i];
      if (p.length === 0 || p.length > 3 || !Sources.allDigits(p)) {
        return false;
      }
      const v: number = Number(p);
      if (isNaN(v) || v < 0 || v > 255) {
        return false;
      }
    }
    return true;
  }

  /** 严格 IPv6：交给 IpUtil 展开成 8 组再校验（正确处理 :: 压缩，拒绝内嵌 IPv4） */
  static strictV6(ip: string): boolean {
    if (ip.indexOf('.') >= 0) {
      return false;
    }
    return IpUtil.ipv6ToBytes(ip).length === 16;
  }

  static newGroupId(): string {
    const t: string = Date.now().toString(36);
    const r: number = Math.floor(Math.random() * 46656);
    return 'g' + t + r.toString(36);
  }

  static newSourceId(): string {
    const t: string = Date.now().toString(36);
    const r: number = Math.floor(Math.random() * 46656);
    return 's' + t + r.toString(36);
  }

  static trimName(name: string): string {
    const s: string = name.trim();
    if (s.length <= MAX_NAME_LEN) {
      return s;
    }
    return s.substring(0, MAX_NAME_LEN);
  }

  // ————————————————————————————————— 单行分类（核心校验） —————————————————————————————————

  /**
   * 按内容实际格式判断一行是 IPv4 / IPv6 网段，并返回标准写法。
   * 支持（与项目原有自定义输入保持一致）：
   *   1.2.3.0/24、2606:4700::/32     —— CIDR
   *   1.2.3.4、1.2.3.4:443           —— 单地址 / 带端口
   *   2606:4700::1、[2606:4700::1]:443 —— 裸 IPv6 / 带端口
   *   2606:4700::1:2053              —— 沿用原有规则：末尾全数字且前缀是合法 IPv6 时视为端口
   * 注释（# 开头或行内 # 之后）由调用方或本函数剥离。
   */
  static classify(rawIn: string): LineClass {
    const out: LineClass = { ok: false, family: 0, canonical: '', reason: '' };
    let s: string = rawIn.trim();
    if (s.length === 0) {
      out.reason = '空行';
      return out;
    }
    if (s.length > MAX_LINE_LEN) {
      out.reason = '单行过长（超过 ' + MAX_LINE_LEN.toString() + ' 字符）';
      return out;
    }
    const hash: number = s.indexOf('#');
    if (hash === 0) {
      out.reason = '注释行';
      return out;
    }
    if (hash > 0) {
      s = s.substring(0, hash).trim();
    }
    if (s.length === 0) {
      out.reason = '注释行';
      return out;
    }
    const slash: number = s.indexOf('/');
    if (slash > 0) {
      return Sources.classifyCidr(s, slash);
    }
    return Sources.classifyAddr(s);
  }

  private static classifyCidr(s: string, slash: number): LineClass {
    const out: LineClass = { ok: false, family: 0, canonical: '', reason: '' };
    const base: string = s.substring(0, slash).trim();
    const pfxText: string = s.substring(slash + 1).trim();
    if (base.length === 0) {
      out.reason = '网段缺少地址部分';
      return out;
    }
    if (pfxText.length === 0 || !Sources.allDigits(pfxText)) {
      out.reason = '掩码长度必须是数字（如 /24、/32、/64）';
      return out;
    }
    const pfx: number = Number(pfxText);
    if (base.indexOf(':') >= 0) {
      // IPv6 网段
      if (pfx < 0 || pfx > 128) {
        out.reason = 'IPv6 掩码长度需在 0-128 之间';
        return out;
      }
      if (!Sources.strictV6(base)) {
        out.reason = 'IPv6 地址格式不合法';
        return out;
      }
      out.ok = true;
      out.family = SRC_FAM_V6;
      out.canonical = base.toLowerCase() + '/' + pfx.toString();
      return out;
    }
    // IPv4 网段
    if (pfx < 0 || pfx > 32) {
      out.reason = 'IPv4 掩码长度需在 0-32 之间';
      return out;
    }
    if (!Sources.strictV4(base)) {
      out.reason = 'IPv4 地址格式不合法（需四段 0-255）';
      return out;
    }
    out.ok = true;
    out.family = SRC_FAM_V4;
    out.canonical = base + '/' + pfx.toString();
    return out;
  }

  private static classifyAddr(s: string): LineClass {
    const out: LineClass = { ok: false, family: 0, canonical: '', reason: '' };

    // 1) [v6]:port
    if (s.startsWith('[')) {
      const close: number = s.indexOf(']');
      if (close < 0) {
        out.reason = 'IPv6 端口写法缺少右方括号 ]';
        return out;
      }
      const host: string = s.substring(1, close).trim();
      const rest: string = s.substring(close + 1).trim();
      if (!Sources.strictV6(host)) {
        out.reason = '方括号内不是合法 IPv6 地址';
        return out;
      }
      if (rest.length === 0) {
        out.ok = true;
        out.family = SRC_FAM_V6;
        out.canonical = host.toLowerCase();
        return out;
      }
      if (!rest.startsWith(':')) {
        out.reason = '右方括号后只能是端口（形如 [地址]:443）';
        return out;
      }
      const pv: number = Sources.parsePort(rest.substring(1));
      if (pv <= 0) {
        out.reason = '端口必须是 1-65535 的数字';
        return out;
      }
      out.ok = true;
      out.family = SRC_FAM_V6;
      out.canonical = '[' + host.toLowerCase() + ']:' + pv.toString();
      return out;
    }

    // 2) 含冒号：裸 IPv6 / IPv4:port / IPv6 + 末尾端口（沿用原有拆分规则）
    if (s.indexOf(':') >= 0) {
      const colon: number = s.lastIndexOf(':');
      const head: string = s.substring(0, colon);
      const tail: string = s.substring(colon + 1);
      if (tail.length > 0 && Sources.allDigits(tail) && Sources.strictV6(s)) {
        // 整串本身是合法 IPv6：沿用原有规则，末尾全数字且前缀仍是合法 IPv6 → 拆成端口
        const pv: number = Sources.parsePort(tail);
        if (pv <= 0) {
          out.reason = '端口必须是 1-65535 的数字';
          return out;
        }
        if (Sources.strictV6(head)) {
          out.ok = true;
          out.family = SRC_FAM_V6;
          out.canonical = '[' + head.toLowerCase() + ']:' + pv.toString();
          return out;
        }
        // 前缀不是合法 IPv6（例如 2606:4700::1:2053 里头部仍合法时不会走到这里），
        // 整串按地址处理
        out.ok = true;
        out.family = SRC_FAM_V6;
        out.canonical = s.toLowerCase();
        return out;
      }
      if (Sources.strictV6(s)) {
        out.ok = true;
        out.family = SRC_FAM_V6;
        out.canonical = s.toLowerCase();
        return out;
      }
      // 不是合法 IPv6：尝试 IPv4:port
      const pv4: number = Sources.parsePort(tail);
      if (pv4 > 0 && Sources.strictV4(head)) {
        out.ok = true;
        out.family = SRC_FAM_V4;
        out.canonical = head + ':' + pv4.toString();
        return out;
      }
      out.reason = '既不是合法 IPv6 地址，也不是 地址:端口 形式';
      return out;
    }

    // 3) 纯 IPv4
    if (Sources.strictV4(s)) {
      out.ok = true;
      out.family = SRC_FAM_V4;
      out.canonical = s;
      return out;
    }
    out.reason = '不是合法 IPv4 地址（需四段 0-255）';
    return out;
  }

  /** 端口解析：合法返回 1-65535，非法返回 0 */
  private static parsePort(text: string): number {
    if (text.length === 0 || text.length > 5 || !Sources.allDigits(text)) {
      return 0;
    }
    const v: number = Number(text);
    if (isNaN(v) || v < 1 || v > 65535) {
      return 0;
    }
    return v;
  }

  // ————————————————————————————————— 导入解析 —————————————————————————————————

  /**
   * 解析一段导入文本。
   * @param text 原始文本（链接下载 / 文件内容 / 粘贴内容）
   * @param family 当前来源族（4/6）：与实际格式不符的行会被拒绝并给出原因
   * @param maxLines 单来源行数上限（0 = 用默认上限）
   */
  static parseImport(text: string, family: number, maxLines: number): ImportOutcome {
    const out: ImportOutcome = {
      ok: false, family: family, accepted: [], rejected: [], duplicates: 0, error: ''
    };
    const cap: number = maxLines > 0 ? maxLines : MAX_LINES_PER_SOURCE;
    const lines: string[] = text.split('\n');
    const seen: Set<string> = new Set<string>();
    let comments: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i].trim();
      if (raw.length === 0) {
        continue;
      }
      const c: LineClass = Sources.classify(raw);
      if (!c.ok) {
        if (c.reason === '注释行') {
          comments++;
          continue;
        }
        out.rejected.push({ line: raw, reason: c.reason });
        continue;
      }
      if (c.family !== family) {
        out.rejected.push({
          line: raw,
          reason: '这是 ' + Sources.famLabel(c.family) + ' 网段，当前为 ' + Sources.famLabel(family) + ' 来源'
        });
        continue;
      }
      if (seen.has(c.canonical)) {
        out.duplicates++;
        continue;
      }
      if (out.accepted.length >= cap) {
        out.rejected.push({ line: raw, reason: '超出单来源行数上限（' + cap.toString() + ' 行）' });
        continue;
      }
      seen.add(c.canonical);
      out.accepted.push(c.canonical);
    }
    out.ok = out.accepted.length > 0;
    if (!out.ok) {
      if (out.rejected.length === 0) {
        out.error = comments > 0 ? '没有可用数据（内容全是注释或空行）' : '没有可用数据（内容为空）';
      } else {
        out.error = '内容中没有符合 ' + Sources.famLabel(family) + ' 要求的网段';
      }
    }
    return out;
  }

  // ————————————————————————————————— 分组 / 来源业务操作（含官方保护） —————————————————————————————————

  static findGroup(id: string): SourceGroup | undefined {
    for (let i = 0; i < Sources.groups.length; i++) {
      if (Sources.groups[i].id === id) {
        return Sources.groups[i];
      }
    }
    return undefined;
  }

  static groupsOf(family: number): SourceGroup[] {
    const out: SourceGroup[] = [];
    for (let i = 0; i < Sources.groups.length; i++) {
      if (Sources.groups[i].family === family) {
        out.push(Sources.groups[i]);
      }
    }
    return out;
  }

  /** 分组概况 */
  static stats(group: SourceGroup): GroupStats {
    const st: GroupStats = { sourceCount: 0, enabledCount: 0, lineCount: 0, failedCount: 0 };
    st.sourceCount = group.sources.length;
    for (let i = 0; i < group.sources.length; i++) {
      const s: SourceItem = group.sources[i];
      // 失败来源（没有有效行）不算「启用」：它不参与扫描，也不该让人以为它在生效
      if (s.enabled && s.lines.length > 0) {
        st.enabledCount++;
      }
      st.lineCount += s.lines.length;
      if (s.status === SRC_STATUS_FAILED) {
        st.failedCount++;
      }
    }
    return st;
  }

  /** 创建自定义分组（同名允许，内部 id 唯一；两族各自独立） */
  static createGroup(name: string, family: number): OpResult {
    const r: OpResult = { ok: false, error: '', groupId: '', sourceId: '' };
    if (family !== SRC_FAM_V4 && family !== SRC_FAM_V6) {
      r.error = 'IP 版本不合法';
      return r;
    }
    const n: string = Sources.trimName(name);
    if (n.length === 0) {
      r.error = '分组名称不能为空';
      return r;
    }
    if (Sources.groupsOf(family).length >= MAX_GROUPS_PER_FAMILY) {
      r.error = '分组数量已达上限（' + MAX_GROUPS_PER_FAMILY.toString() + ' 个）';
      return r;
    }
    const now: number = Date.now();
    const g: SourceGroup = {
      id: Sources.newGroupId(),
      name: n,
      family: family,
      builtin: false,
      sources: [],
      createdAt: now,
      updatedAt: now
    };
    Sources.groups.push(g);
    r.ok = true;
    r.groupId = g.id;
    return r;
  }

  static renameGroup(id: string, name: string): OpResult {
    const r: OpResult = { ok: false, error: '', groupId: id, sourceId: '' };
    const b: string = Sources.builtinError(id);
    if (b.length > 0) {
      r.error = b;
      return r;
    }
    const g: SourceGroup | undefined = Sources.findGroup(id);
    if (g === undefined) {
      r.error = '分组不存在';
      return r;
    }
    const n: string = Sources.trimName(name);
    if (n.length === 0) {
      r.error = '分组名称不能为空';
      return r;
    }
    g.name = n;
    g.updatedAt = Date.now();
    r.ok = true;
    return r;
  }

  static deleteGroup(id: string): OpResult {
    const r: OpResult = { ok: false, error: '', groupId: id, sourceId: '' };
    const b: string = Sources.builtinError(id);
    if (b.length > 0) {
      r.error = b;
      return r;
    }
    let hit: number = -1;
    for (let i = 0; i < Sources.groups.length; i++) {
      if (Sources.groups[i].id === id) {
        hit = i;
        break;
      }
    }
    if (hit < 0) {
      r.error = '分组不存在';
      return r;
    }
    Sources.groups.splice(hit, 1);
    // 删除的正是当前选中项时回退到官方段（不自动改用另一族，也不引用已删除数据）
    if (Sources.selV4 === id) {
      Sources.selV4 = SRC_ID_OFFICIAL;
    }
    if (Sources.selV6 === id) {
      Sources.selV6 = SRC_ID_OFFICIAL;
    }
    r.ok = true;
    return r;
  }

  /**
   * 向分组追加一条来源。
   * @param text 已获取到的原始文本（链接正文 / 文件内容 / 粘贴内容）
   * @param failure 非空表示获取阶段就失败了（网络/读取），此时仍记录一条失败来源便于追踪
   */
  static addSource(groupId: string, kind: string, ref: string, name: string,
    text: string, failure: string): AddSourceResult {
    const r: AddSourceResult = {
      ok: false, error: '', groupId: groupId, sourceId: '',
      accepted: 0, rejected: 0, duplicates: 0, sampleRejects: []
    };
    const b: string = Sources.builtinError(groupId);
    if (b.length > 0) {
      r.error = b;
      return r;
    }
    const g: SourceGroup | undefined = Sources.findGroup(groupId);
    if (g === undefined) {
      r.error = '分组不存在';
      return r;
    }
    const now: number = Date.now();
    const src: SourceItem = {
      id: Sources.newSourceId(),
      kind: kind,
      family: g.family,
      ref: ref,
      name: Sources.trimName(name.length > 0 ? name : Sources.kindLabel(kind)),
      lines: [],
      rejectedCount: 0,
      rejects: [],
      status: SRC_STATUS_FAILED,
      error: '',
      enabled: true,
      addedAt: now
    };
    if (failure.length > 0) {
      src.error = failure;
    } else {
      const out: ImportOutcome = Sources.parseImport(text, g.family, 0);
      src.lines = out.accepted;
      src.rejectedCount = out.rejected.length;
      for (let i = 0; i < out.rejected.length && i < MAX_REJECT_KEEP; i++) {
        src.rejects.push(out.rejected[i]);
      }
      r.accepted = out.accepted.length;
      r.rejected = out.rejected.length;
      r.duplicates = out.duplicates;
      for (let i = 0; i < src.rejects.length; i++) {
        r.sampleRejects.push(src.rejects[i]);
      }
      if (out.accepted.length === 0) {
        src.error = out.error;
      } else if (out.rejected.length > 0) {
        src.status = SRC_STATUS_PARTIAL;
      } else {
        src.status = SRC_STATUS_OK;
      }
    }
    g.sources.push(src);
    g.updatedAt = now;
    r.sourceId = src.id;
    if (src.lines.length > 0) {
      r.ok = true;
    } else {
      r.error = src.error.length > 0 ? src.error : '没有可用数据';
    }
    return r;
  }

  /**
   * 用新拉取的内容覆盖某条来源（链接来源「一键更新」用）。
   * 只替换解析结果与状态，保留来源 id / 类型 / 地址 / 名称 / 启用状态；
   * 分组、官方段、其他来源都不受影响。
   */
  static applyText(groupId: string, sourceId: string, text: string, failure: string): AddSourceResult {
    const r: AddSourceResult = {
      ok: false, error: '', groupId: groupId, sourceId: sourceId,
      accepted: 0, rejected: 0, duplicates: 0, sampleRejects: []
    };
    const b: string = Sources.builtinError(groupId);
    if (b.length > 0) {
      r.error = b;
      return r;
    }
    const g: SourceGroup | undefined = Sources.findGroup(groupId);
    if (g === undefined) {
      r.error = '分组不存在';
      return r;
    }
    const src: SourceItem | undefined = Sources.findSource(groupId, sourceId);
    if (src === undefined) {
      r.error = '来源不存在';
      return r;
    }
    src.lines = [];
    src.rejects = [];
    src.rejectedCount = 0;
    src.error = '';
    src.status = SRC_STATUS_FAILED;
    if (failure.length > 0) {
      src.error = failure;
      r.error = failure;
      g.updatedAt = Date.now();
      return r;
    }
    const out: ImportOutcome = Sources.parseImport(text, g.family, 0);
    src.lines = out.accepted;
    src.rejectedCount = out.rejected.length;
    for (let i = 0; i < out.rejected.length && i < MAX_REJECT_KEEP; i++) {
      src.rejects.push(out.rejected[i]);
    }
    r.accepted = out.accepted.length;
    r.rejected = out.rejected.length;
    r.duplicates = out.duplicates;
    for (let i = 0; i < src.rejects.length; i++) {
      r.sampleRejects.push(src.rejects[i]);
    }
    if (out.accepted.length === 0) {
      src.error = out.error;
      r.error = out.error;
    } else if (out.rejected.length > 0) {
      src.status = SRC_STATUS_PARTIAL;
      r.ok = true;
    } else {
      src.status = SRC_STATUS_OK;
      r.ok = true;
    }
    g.updatedAt = Date.now();
    return r;
  }

  static deleteSource(groupId: string, sourceId: string): OpResult {
    const r: OpResult = { ok: false, error: '', groupId: groupId, sourceId: sourceId };
    const b: string = Sources.builtinError(groupId);
    if (b.length > 0) {
      r.error = b;
      return r;
    }
    const g: SourceGroup | undefined = Sources.findGroup(groupId);
    if (g === undefined) {
      r.error = '分组不存在';
      return r;
    }
    let hit: number = -1;
    for (let i = 0; i < g.sources.length; i++) {
      if (g.sources[i].id === sourceId) {
        hit = i;
        break;
      }
    }
    if (hit < 0) {
      r.error = '来源不存在';
      return r;
    }
    g.sources.splice(hit, 1);
    g.updatedAt = Date.now();
    r.ok = true;
    return r;
  }

  static setSourceEnabled(groupId: string, sourceId: string, enabled: boolean): OpResult {
    const r: OpResult = { ok: false, error: '', groupId: groupId, sourceId: sourceId };
    const b: string = Sources.builtinError(groupId);
    if (b.length > 0) {
      r.error = b;
      return r;
    }
    const g: SourceGroup | undefined = Sources.findGroup(groupId);
    if (g === undefined) {
      r.error = '分组不存在';
      return r;
    }
    for (let i = 0; i < g.sources.length; i++) {
      if (g.sources[i].id === sourceId) {
        // 启用状态必须与所属族一致：这里再校验一次，异常数据不会被跨族启用
        if (g.sources[i].family !== g.family) {
          r.error = '来源 IP 类型与分组不一致，已拒绝启用';
          return r;
        }
        g.sources[i].enabled = enabled;
        g.updatedAt = Date.now();
        r.ok = true;
        return r;
      }
    }
    r.error = '来源不存在';
    return r;
  }

  static renameSource(groupId: string, sourceId: string, name: string): OpResult {
    const r: OpResult = { ok: false, error: '', groupId: groupId, sourceId: sourceId };
    const b: string = Sources.builtinError(groupId);
    if (b.length > 0) {
      r.error = b;
      return r;
    }
    const g: SourceGroup | undefined = Sources.findGroup(groupId);
    if (g === undefined) {
      r.error = '分组不存在';
      return r;
    }
    const n: string = Sources.trimName(name);
    if (n.length === 0) {
      r.error = '来源名称不能为空';
      return r;
    }
    for (let i = 0; i < g.sources.length; i++) {
      if (g.sources[i].id === sourceId) {
        g.sources[i].name = n;
        g.updatedAt = Date.now();
        r.ok = true;
        return r;
      }
    }
    r.error = '来源不存在';
    return r;
  }

  // ————————————————————————————————— 当前选中（按族独立） —————————————————————————————————

  static selected(family: number): string {
    return family === SRC_FAM_V6 ? Sources.selV6 : Sources.selV4;
  }

  /** 选中项是否合法（存在且族匹配）；内置 id 恒合法 */
  static selectionValid(family: number, id: string): boolean {
    if (id === SRC_ID_OFFICIAL || id === SRC_ID_COMMUNITY) {
      return true;
    }
    const g: SourceGroup | undefined = Sources.findGroup(id);
    if (g === undefined) {
      return false;
    }
    return g.family === family;
  }

  /**
   * 修改某族的选中来源并持久化选择键。
   * 返回空串表示成功，否则是中文错误原因（跨族选择在业务层拒绝）。
   */
  static async setSelected(family: number, id: string): Promise<string> {
    if (!Sources.selectionValid(family, id)) {
      const g: SourceGroup | undefined = Sources.findGroup(id);
      if (g !== undefined && g.family !== family) {
        return '所选分组属于 ' + Sources.famLabel(g.family) + '，当前为 ' + Sources.famLabel(family) + ' 模式';
      }
      return '所选来源不存在';
    }
    if (family === SRC_FAM_V6) {
      Sources.selV6 = id;
    } else {
      Sources.selV4 = id;
    }
    await ConfigStore.rawPut(family === SRC_FAM_V6 ? KEY_SEL_V6 : KEY_SEL_V4, id);
    return '';
  }

  /** 选中项的展示名 */
  static selectionLabel(family: number, id: string): string {
    if (id === SRC_ID_OFFICIAL) {
      return '官方 IP 段';
    }
    if (id === SRC_ID_COMMUNITY) {
      return '社区段库';
    }
    const g: SourceGroup | undefined = Sources.findGroup(id);
    return g === undefined ? '（已删除）' : g.name;
  }

  /** 当前族可选项：官方、社区、自定义分组（下拉菜单与管理页共用，只列本族） */
  static choices(family: number): SourceChoice[] {
    const out: SourceChoice[] = [];
    const stOff: GroupStats = { sourceCount: 1, enabledCount: 1, lineCount: 0, failedCount: 0 };
    const off: SourceChoice = {
      id: SRC_ID_OFFICIAL, label: '官方 IP 段', builtin: true, family: family, stats: stOff
    };
    out.push(off);
    const stComm: GroupStats = {
      sourceCount: 1, enabledCount: 1, lineCount: Sources.communityLineCount(family), failedCount: 0
    };
    const comm: SourceChoice = {
      id: SRC_ID_COMMUNITY, label: '社区段库', builtin: true, family: family, stats: stComm
    };
    out.push(comm);
    const gs: SourceGroup[] = Sources.groupsOf(family);
    for (let i = 0; i < gs.length; i++) {
      const stG: GroupStats = Sources.stats(gs[i]);
      out.push({ id: gs[i].id, label: gs[i].name, builtin: false, family: family, stats: stG });
    }
    return out;
  }

  // ————————————————————————————————— 社区段库（内置只读来源） —————————————————————————————————

  static communityText(family: number): string {
    return family === SRC_FAM_V6 ? Sources.communityV6 : Sources.communityV4;
  }

  /** 社区库有效行数（按族严格校验后计数，错误类型不会被算进当前族） */
  static communityLineCount(family: number): number {
    const out: ImportOutcome = Sources.parseImport(Sources.communityText(family), family, 0);
    return out.accepted.length;
  }

  static async setCommunityText(family: number, text: string): Promise<void> {
    if (family === SRC_FAM_V6) {
      Sources.communityV6 = text;
    } else {
      Sources.communityV4 = text;
    }
    await Sources.save();
  }

  // ————————————————————————————————— 编译：分组 → 扫描候选文本 —————————————————————————————————

  /**
   * 把当前族选中的来源编译成交给扫描器的文本。
   * - 只取该族已启用的来源（官方/社区/自定义分组）
   * - 每一行都重新过 classify 做二次校验，类型不符的行丢弃并计数
   * - 跨来源去重（同一标准写法只保留一次），保持来源顺序
   */
  static compile(family: number, selId: string): CompileResult {
    const out: CompileResult = {
      ok: false, family: family, groupId: selId,
      label: Sources.selectionLabel(family, selId),
      sourceCount: 0, enabledCount: 0, lineCount: 0, wrongFamily: 0, text: '', error: ''
    };
    if (family !== SRC_FAM_V4 && family !== SRC_FAM_V6) {
      out.error = 'IP 版本不合法';
      return out;
    }
    if (!Sources.selectionValid(family, selId)) {
      // 异常调用路径：选中项跨族或已被删除，明确报错，不自动回退到另一族
      out.error = '当前来源已失效，请重新选择（' + Sources.selectionLabel(family, selId) + '）';
      return out;
    }

    // 收集「来源行集合」：官方段走 Scanner 内置定义，不在这里拼文本
    const batches: string[][] = [];
    if (selId === SRC_ID_OFFICIAL) {
      out.sourceCount = 1;
      out.enabledCount = 1;
      out.ok = true;
      out.lineCount = 0;
      out.error = '';
      return out;
    }
    if (selId === SRC_ID_COMMUNITY) {
      out.sourceCount = 1;
      out.enabledCount = 1;
      const raw: string = Sources.communityText(family);
      if (raw.trim().length === 0) {
        out.error = '社区段库还没有内容，请点「编辑」进入管理页更新';
        return out;
      }
      batches.push(raw.split('\n'));
    } else {
      const g: SourceGroup | undefined = Sources.findGroup(selId);
      if (g === undefined) {
        out.error = '分组不存在';
        return out;
      }
      out.sourceCount = g.sources.length;
      for (let i = 0; i < g.sources.length; i++) {
        const s: SourceItem = g.sources[i];
        if (!s.enabled || s.lines.length === 0) {
          continue;
        }
        out.enabledCount++;
        batches.push(s.lines);
      }
      if (out.enabledCount === 0) {
        out.error = g.sources.length === 0
          ? '分组「' + g.name + '」还没有来源，请点「编辑」添加'
          : '分组「' + g.name + '」的所有来源都已停用';
        return out;
      }
    }

    const seen: Set<string> = new Set<string>();
    const kept: string[] = [];
    for (let bi = 0; bi < batches.length; bi++) {
      const batch: string[] = batches[bi];
      for (let li = 0; li < batch.length; li++) {
        const raw: string = batch[li].trim();
        if (raw.length === 0 || raw.startsWith('#')) {
          continue;
        }
        const c: LineClass = Sources.classify(raw);
        if (!c.ok) {
          out.wrongFamily++;
          continue;
        }
        if (c.family !== family) {
          // 二次校验：历史/异常数据里的错误类型绝不能进入当前族的扫描
          out.wrongFamily++;
          continue;
        }
        if (seen.has(c.canonical)) {
          continue;
        }
        seen.add(c.canonical);
        kept.push(c.canonical);
      }
    }
    if (kept.length === 0) {
      out.error = out.wrongFamily > 0
        ? '没有符合 ' + Sources.famLabel(family) + ' 的可用网段（已跳过 ' + out.wrongFamily.toString() + ' 行类型不符/无效内容）'
        : '当前来源没有可用网段';
      return out;
    }
    out.text = kept.join('\n');
    out.lineCount = kept.length;
    out.ok = true;
    return out;
  }

  // ————————————————————————————————— 持久化 —————————————————————————————————

  private static esc(s: string): string {
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      const ch: string = s.charAt(i);
      if (ch === '\\') {
        out += '\\\\';
      } else if (ch === '\t') {
        out += '\\t';
      } else if (ch === '\n') {
        out += '\\n';
      } else if (ch === '\r') {
        // 丢弃回车
      } else {
        out += ch;
      }
    }
    return out;
  }

  private static unesc(s: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      const ch: string = s.charAt(i);
      if (ch === '\\' && i + 1 < s.length) {
        const nx: string = s.charAt(i + 1);
        if (nx === 't') {
          out += '\t';
          i += 2;
          continue;
        }
        if (nx === 'n') {
          out += '\n';
          i += 2;
          continue;
        }
        if (nx === '\\') {
          out += '\\';
          i += 2;
          continue;
        }
        out += ch;
        i++;
        continue;
      }
      out += ch;
      i++;
    }
    return out;
  }

  /** 序列化单个 IP 族的来源模型：V4 / V6 各存一份，互不影响 */
  static serializeFamily(family: number): string {
    const rows: string[] = [];
    rows.push('V\t' + VER_CURRENT);
    const lib: string = family === SRC_FAM_V6 ? Sources.communityV6 : Sources.communityV4;
    rows.push('C\t' + family.toString() + '\t' + Sources.esc(lib));
    for (let qi = 0; qi < Sources.quarantines.length; qi++) {
      const q: QuarantineItem = Sources.quarantines[qi];
      if (q.family !== family) {
        continue;
      }
      rows.push('Q\t' + q.family.toString() + '\t' + Sources.esc(q.line) + '\t' + Sources.esc(q.reason));
    }
    for (let gi = 0; gi < Sources.groups.length; gi++) {
      const g: SourceGroup = Sources.groups[gi];
      if (g.family !== family) {
        continue;
      }
      rows.push('G\t' + g.id + '\t' + Sources.esc(g.name) + '\t' + g.family.toString()
        + '\t' + g.createdAt.toString() + '\t' + g.updatedAt.toString());
      for (let si = 0; si < g.sources.length; si++) {
        const s: SourceItem = g.sources[si];
        rows.push('S\t' + g.id + '\t' + s.id + '\t' + s.kind + '\t' + Sources.esc(s.ref)
          + '\t' + Sources.esc(s.name) + '\t' + s.status + '\t' + (s.enabled ? '1' : '0')
          + '\t' + s.addedAt.toString() + '\t' + s.family.toString()
          + '\t' + s.rejectedCount.toString() + '\t' + Sources.esc(s.error));
        for (let li = 0; li < s.lines.length; li++) {
          rows.push('L\t' + g.id + '\t' + s.id + '\t' + Sources.esc(s.lines[li]));
        }
        for (let ri = 0; ri < s.rejects.length; ri++) {
          rows.push('R\t' + g.id + '\t' + s.id + '\t' + Sources.esc(s.rejects[ri].line)
            + '\t' + Sources.esc(s.rejects[ri].reason));
        }
      }
    }
    return rows.join('\n');
  }

  /** 清空内存态（load / deserialize 前调用） */
  private static resetState(): void {
    Sources.groups = [];
    Sources.communityV4 = '';
    Sources.communityV6 = '';
    Sources.quarantines = [];
  }

  static deserialize(text: string): void {
    Sources.resetState();
    Sources.parseRows(text);
  }

  /** 解析一份序列化文本并追加到内存态（不重置，供分族加载复用） */
  private static parseRows(text: string): void {
    if (text.length === 0) {
      return;
    }
    const rows: string[] = text.split('\n');
    for (let i = 0; i < rows.length; i++) {
      const row: string = rows[i];
      if (row.length === 0) {
        continue;
      }
      const f: string[] = row.split('\t');
      const tag: string = f[0];
      if (tag === 'C' && f.length >= 3) {
        if (f[1] === '6') {
          Sources.communityV6 = Sources.unesc(f[2]);
        } else {
          Sources.communityV4 = Sources.unesc(f[2]);
        }
      } else if (tag === 'Q' && f.length >= 4) {
        Sources.quarantines.push({
          family: Number(f[1]), line: Sources.unesc(f[2]), reason: Sources.unesc(f[3]), at: 0
        });
      } else if (tag === 'G' && f.length >= 6) {
        const fam: number = Number(f[3]);
        if (fam !== SRC_FAM_V4 && fam !== SRC_FAM_V6) {
          // 族非法的历史数据进隔离区，不参与扫描
          Sources.quarantines.push({ family: 0, line: Sources.unesc(f[2]), reason: '分组 IP 类型缺失或非法', at: 0 });
          continue;
        }
        Sources.groups.push({
          id: f[1], name: Sources.unesc(f[2]), family: fam, builtin: false,
          sources: [], createdAt: Number(f[4]), updatedAt: Number(f[5])
        });
      } else if (tag === 'S' && f.length >= 12) {
        const g: SourceGroup | undefined = Sources.findGroup(f[1]);
        if (g === undefined) {
          continue;
        }
        const fam: number = Number(f[9]);
        g.sources.push({
          id: f[2], kind: f[3], ref: Sources.unesc(f[4]), name: Sources.unesc(f[5]),
          family: fam === SRC_FAM_V6 ? SRC_FAM_V6 : SRC_FAM_V4,
          lines: [], rejectedCount: Number(f[10]), rejects: [],
          status: f[6], error: Sources.unesc(f[11]),
          enabled: f[7] === '1', addedAt: Number(f[8])
        });
      } else if (tag === 'L' && f.length >= 4) {
        const s: SourceItem | undefined = Sources.findSource(f[1], f[2]);
        if (s !== undefined) {
          s.lines.push(Sources.unesc(f[3]));
        }
      } else if (tag === 'R' && f.length >= 5) {
        const s: SourceItem | undefined = Sources.findSource(f[1], f[2]);
        if (s !== undefined && s.rejects.length < MAX_REJECT_KEEP) {
          s.rejects.push({ line: Sources.unesc(f[3]), reason: Sources.unesc(f[4]) });
        }
      }
    }
  }

  static findSource(groupId: string, sourceId: string): SourceItem | undefined {
    const g: SourceGroup | undefined = Sources.findGroup(groupId);
    if (g === undefined) {
      return undefined;
    }
    for (let i = 0; i < g.sources.length; i++) {
      if (g.sources[i].id === sourceId) {
        return g.sources[i];
      }
    }
    return undefined;
  }

  /** 修正异常数据：族非法的来源、越界的选中项（不静默丢弃来源行，只做归类修复） */
  private static sanitize(): void {
    for (let gi = Sources.groups.length - 1; gi >= 0; gi--) {
      const g: SourceGroup = Sources.groups[gi];
      if (g.family !== SRC_FAM_V4 && g.family !== SRC_FAM_V6) {
        // 理论上不会出现（deserialize 已拦），兜底进隔离区
        Sources.quarantines.push({ family: 0, line: g.name, reason: '分组 IP 类型非法', at: 0 });
        Sources.groups.splice(gi, 1);
        continue;
      }
      for (let si = g.sources.length - 1; si >= 0; si--) {
        const s: SourceItem = g.sources[si];
        if (s.family !== g.family) {
          // 来源族与分组不一致：从分组移除并进隔离区，避免跨族污染
          const head: string = s.lines.length > 0 ? s.lines[0] : s.name;
          Sources.quarantines.push({
            family: s.family, line: head, reason: '来源 IP 类型与分组不一致，已隔离', at: 0
          });
          g.sources.splice(si, 1);
        }
      }
    }
    if (!Sources.selectionValid(SRC_FAM_V4, Sources.selV4)) {
      Sources.selV4 = SRC_ID_OFFICIAL;
    }
    if (!Sources.selectionValid(SRC_FAM_V6, Sources.selV6)) {
      Sources.selV6 = SRC_ID_OFFICIAL;
    }
  }

  static async save(): Promise<void> {
    await ConfigStore.rawPut(KEY_MODEL_V4, Sources.serializeFamily(SRC_FAM_V4));
    await ConfigStore.rawPut(KEY_MODEL_V6, Sources.serializeFamily(SRC_FAM_V6));
    await ConfigStore.rawPut(KEY_VER, VER_CURRENT);
    await ConfigStore.rawPut(KEY_SEL_V4, Sources.selV4);
    await ConfigStore.rawPut(KEY_SEL_V6, Sources.selV6);
  }

  /**
   * 启动时加载。有版本键说明是 v2 数据，直接反序列化；否则从旧版 scan_custom 迁移。
   * @param legacy ConfigStore.load() 得到的旧配置（迁移时只读它的 customText / mode / ipVersion）
   * @returns 给用户看的迁移/加载提示（空串 = 无）
   */
  static async load(legacy: ScanConfig): Promise<string> {
    if (Sources.loaded) {
      return Sources.loadNote;
    }
    const ver: string = ConfigStore.rawStr(KEY_VER, '');
    Sources.selV4 = ConfigStore.rawStr(KEY_SEL_V4, SRC_ID_OFFICIAL);
    Sources.selV6 = ConfigStore.rawStr(KEY_SEL_V6, SRC_ID_OFFICIAL);
    if (ver === VER_CURRENT) {
      Sources.resetState();
      Sources.parseRows(ConfigStore.rawStr(KEY_MODEL_V4, ''));
      Sources.parseRows(ConfigStore.rawStr(KEY_MODEL_V6, ''));
      Sources.sanitize();
      Sources.loaded = true;
      Sources.loadNote = '';
      const q: string = Sources.quarantineSummary();
      if (q.length > 0) {
        Sources.loadNote = q;
      }
      return Sources.loadNote;
    }
    if (ver === VER_V2) {
      // v2 是两族混存的单键模型：读出来按族重新落盘为 v3 的两份模型，不重复导入
      Sources.deserialize(ConfigStore.rawStr(KEY_MODEL_V2, ''));
      Sources.sanitize();
      Sources.loaded = true;
      Sources.loadNote = '';
      const q2: string = Sources.quarantineSummary();
      if (q2.length > 0) {
        Sources.loadNote = q2;
      }
      await Sources.save();
      return Sources.loadNote;
    }
    const note: string = Sources.migrate(legacy);
    Sources.sanitize();
    Sources.loaded = true;
    Sources.loadNote = note;
    await Sources.save();
    return note;
  }

  /**
   * 旧版文本 → v4 / v6 / 无法识别 三路分流（纯函数，不改静态状态，便于自检回归）。
   * 分类只看每一行自身的网段格式，不看旧配置的 scan_ipver。
   */
  static planLegacy(text: string): MigratePlan {
    const v4: string[] = [];
    const v6: string[] = [];
    const seen4: Set<string> = new Set<string>();
    const seen6: Set<string> = new Set<string>();
    const badSamples: SourceReject[] = [];
    let bad: number = 0;
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i].trim();
      if (raw.length === 0) {
        continue;
      }
      const c: LineClass = Sources.classify(raw);
      if (!c.ok) {
        if (c.reason === '注释行') {
          continue;
        }
        bad++;
        if (badSamples.length < 200) {
          badSamples.push({ line: raw, reason: c.reason });
        }
        continue;
      }
      if (c.family === SRC_FAM_V6) {
        if (!seen6.has(c.canonical)) {
          seen6.add(c.canonical);
          v6.push(c.canonical);
        }
      } else if (!seen4.has(c.canonical)) {
        seen4.add(c.canonical);
        v4.push(c.canonical);
      }
    }
    const out: MigratePlan = { v4: v4, v6: v6, bad: bad, badSamples: badSamples };
    return out;
  }

  /** 旧版 scan_custom → v2 分组（按实际网段格式分类，不是按 scan_ipver 一刀切） */
  /** 旧版 scan_custom → v2 分组（按实际网段格式分类，不是按 scan_ipver 一刀切） */
  static migrate(legacy: ScanConfig): string {
    Sources.groups = [];
    Sources.communityV4 = '';
    Sources.communityV6 = '';
    Sources.quarantines = [];
    Sources.selV4 = SRC_ID_OFFICIAL;
    Sources.selV6 = SRC_ID_OFFICIAL;
    const text: string = legacy.customText;
    if (text.trim().length === 0) {
      return '';
    }
    const v4: string[] = [];
    const v6: string[] = [];
    const seen4: Set<string> = new Set<string>();
    const seen6: Set<string> = new Set<string>();
    let bad: number = 0;
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i].trim();
      if (raw.length === 0) {
        continue;
      }
      const c: LineClass = Sources.classify(raw);
      if (!c.ok) {
        if (c.reason === '注释行') {
          continue;
        }
        bad++;
        if (Sources.quarantines.length < 200) {
          Sources.quarantines.push({ family: 0, line: raw, reason: c.reason, at: Date.now() });
        }
        continue;
      }
      if (c.family === SRC_FAM_V6) {
        if (!seen6.has(c.canonical)) {
          seen6.add(c.canonical);
          v6.push(c.canonical);
        }
      } else {
        if (!seen4.has(c.canonical)) {
          seen4.add(c.canonical);
          v4.push(c.canonical);
        }
      }
    }
    const now: number = Date.now();
    let g4: string = '';
    let g6: string = '';
    if (v4.length > 0) {
      const r4: OpResult = Sources.createGroup('旧版自定义导入（IPv4）', SRC_FAM_V4);
      if (r4.ok) {
        g4 = r4.groupId;
        const ar: AddSourceResult = Sources.addSource(g4, SRC_KIND_TEXT, '', '旧版文本导入', v4.join('\n'), '');
        if (!ar.ok) {
          g4 = '';
        }
      }
    }
    if (v6.length > 0) {
      const r6: OpResult = Sources.createGroup('旧版自定义导入（IPv6）', SRC_FAM_V6);
      if (r6.ok) {
        g6 = r6.groupId;
        const ar6: AddSourceResult = Sources.addSource(g6, SRC_KIND_TEXT, '', '旧版文本导入', v6.join('\n'), '');
        if (!ar6.ok) {
          g6 = '';
        }
      }
    }
    // 旧配置是「自定义」模式时，把对应族的迁移分组设为选中；另一族保持官方段
    if (legacy.mode === ScanMode.CUSTOM) {
      if (legacy.ipVersion === IpVersion.V6 && g6.length > 0) {
        Sources.selV6 = g6;
      } else if (legacy.ipVersion === IpVersion.V4 && g4.length > 0) {
        Sources.selV4 = g4;
      }
    }
    let note: string = '';
    if (v4.length > 0 || v6.length > 0) {
      note = '旧版自定义导入已迁移：IPv4 ' + v4.length.toString() + ' 行、IPv6 ' + v6.length.toString() + ' 行';
      if (legacy.mode !== ScanMode.CUSTOM) {
        note += '（旧配置为官方模式，迁移分组已保留但未启用）';
      }
    }
    if (bad > 0) {
      note += (note.length > 0 ? '；' : '') + '另有 ' + bad.toString() + ' 行无法识别，已隔离保留（仍保存在旧配置中，可在来源管理中查看）';
    }
    return note;
  }

  /** 隔离区摘要（给 UI 的横幅提示） */
  static quarantineSummary(): string {
    if (Sources.quarantines.length === 0) {
      return '';
    }
    return '有 ' + Sources.quarantines.length.toString() + ' 行历史数据无法识别或类型异常，已隔离（不参与扫描）';
  }

  static async clearQuarantine(): Promise<void> {
    Sources.quarantines = [];
    await Sources.save();
  }

  // ————————————————————————————————— 自检（回归用，不参与正常流程） —————————————————————————————————

  /**
   * 纯逻辑自检：覆盖导入校验、跨类型拒绝、编译二次校验、官方保护。
   * 只在明确调用时执行（管理页「自检」入口 / 排查用），返回逐条结果。
   */
  static selfCheck(): string[] {
    const out: string[] = [];
    const ok = (name: string, cond: boolean): void => {
      out.push((cond ? 'PASS ' : 'FAIL ') + name);
    };
    // 分类
    ok('classify 1.2.3.0/24 → v4', Sources.classify('1.2.3.0/24').family === SRC_FAM_V4);
    ok('classify 2a06:98c0::/29 → v6', Sources.classify('2a06:98c0::/29').family === SRC_FAM_V6);
    ok('classify 1.2.3.4:443 → v4+port', Sources.classify('1.2.3.4:443').canonical === '1.2.3.4:443');
    ok('classify [2a06::1]:8443 → v6+port', Sources.classify('[2a06::1]:8443').canonical === '[2a06::1]:8443');
    ok('classify 1.2.3.256 非法', !Sources.classify('1.2.3.256').ok);
    ok('classify 1.2.3/24 非法', !Sources.classify('1.2.3/24').ok);
    ok('classify 1.2.3.0/33 非法', !Sources.classify('1.2.3.0/33').ok);
    ok('classify 2a06::/129 非法', !Sources.classify('2a06::/129').ok);
    ok('classify 1.2.3.0/24#注释 → v4', Sources.classify('1.2.3.0/24 # c').canonical === '1.2.3.0/24');
    // 导入隔离
    const mixed: ImportOutcome = Sources.parseImport('1.2.3.0/24\n2a06:98c0::/29\nbadline', SRC_FAM_V4, 0);
    ok('V4 导入混合内容只收 v4', mixed.accepted.length === 1 && mixed.accepted[0] === '1.2.3.0/24');
    ok('V4 导入拒绝 v6 行', mixed.rejected.length === 2);
    ok('V4 导入拒绝原因含 IPv6', mixed.rejected.length > 0 && mixed.rejected[0].reason.indexOf('IPv6') >= 0);
    const dup: ImportOutcome = Sources.parseImport('1.2.3.0/24\n1.2.3.0/24', SRC_FAM_V4, 0);
    ok('同内容去重', dup.accepted.length === 1 && dup.duplicates === 1);
    const empty: ImportOutcome = Sources.parseImport('   \n# c', SRC_FAM_V4, 0);
    ok('空内容报错', !empty.ok && empty.error.length > 0);
    // 官方保护
    ok('官方段拒绝改名', !Sources.renameGroup(SRC_ID_OFFICIAL, 'x').ok);
    ok('官方段拒绝删除', !Sources.deleteGroup(SRC_ID_OFFICIAL).ok);
    ok('官方段拒绝加来源', !Sources.addSource(SRC_ID_OFFICIAL, SRC_KIND_TEXT, '', 'x', '1.2.3.0/24', '').ok);
    ok('官方段拒绝删来源', !Sources.deleteSource(SRC_ID_OFFICIAL, 'x').ok);
    ok('社区库拒绝改名', !Sources.renameGroup(SRC_ID_COMMUNITY, 'x').ok);
    // 编译二次校验：往分组里塞一行错类型（模拟历史脏数据）后编译只保留本族
    const g: OpResult = Sources.createGroup('__selfcheck__', SRC_FAM_V4);
    if (g.ok) {
      const a: AddSourceResult = Sources.addSource(g.groupId, SRC_KIND_TEXT, '', 't', '1.2.3.0/24\n9.9.9.9', '');
      const gg: SourceGroup | undefined = Sources.findGroup(g.groupId);
      if (gg !== undefined && gg.sources.length > 0) {
        // 直接注入一行 IPv6，模拟历史/异常数据
        gg.sources[0].lines.push('2a06:98c0::/29');
      }
      const cp: CompileResult = Sources.compile(SRC_FAM_V4, g.groupId);
      ok('编译只留 v4 行', cp.ok && cp.text.indexOf(':') < 0 && cp.wrongFamily === 1);
      ok('编译行数正确', cp.lineCount === 2);
      ok('V4 分组不能被 V6 选中', !Sources.selectionValid(SRC_FAM_V6, g.groupId));
      ok('删除分组成功', Sources.deleteGroup(g.groupId).ok);
    }
    // 旧版迁移：混合文本按实际格式分流、去重、注释忽略、无法识别隔离
    const legacyText: string = '1.2.3.0/24' + String.fromCharCode(10) + '1.2.3.0/24' + String.fromCharCode(10) +
      '1.1.1.0/24' + String.fromCharCode(10) + '2606:4700::/32' + String.fromCharCode(10) +
      '2a06:98c0::/29' + String.fromCharCode(10) + '# comment' + String.fromCharCode(10) + 'not-an-ip';
    const mp: MigratePlan = Sources.planLegacy(legacyText);
    ok('迁移分流 v4=2 行', mp.v4.length === 2 && mp.v4[0] === '1.2.3.0/24');
    ok('迁移分流 v6=2 行', mp.v6.length === 2);
    ok('迁移按实际格式而非 ipver', mp.v4.length === 2 && mp.v6.length === 2);
    ok('迁移去重不留重复', mp.v4.length === 2 && mp.v6.length === 2);
    ok('迁移隔离无法识别行', mp.bad === 1 && mp.badSamples.length === 1);
    ok('迁移注释行不计数', mp.bad === 1);
    // 链接「一键更新」：覆盖内容但不丢来源、不跨族
    const gr: OpResult = Sources.createGroup('__refresh__', SRC_FAM_V6);
    if (gr.ok) {
      const ar: AddSourceResult = Sources.addSource(gr.groupId, SRC_KIND_LINK, 'https://example.com/a', 'a', '2606:4700::/32', '');
      const sid: string = ar.sourceId;
      const rr: AddSourceResult = Sources.applyText(gr.groupId, sid, '2001:db8::/32', '');
      ok('更新链接替换内容', rr.ok && rr.accepted === 1);
      const fs: SourceItem | undefined = Sources.findSource(gr.groupId, sid);
      ok('更新后来源仍存在且为新内容', fs !== undefined && fs.lines.length === 1 && fs.lines[0] === '2001:db8::/32');
      const bad: AddSourceResult = Sources.applyText(gr.groupId, sid, '1.2.3.0/24', '');
      ok('更新时跨类型内容被拒', !bad.ok && bad.error.length > 0);
      const f2: SourceItem | undefined = Sources.findSource(gr.groupId, sid);
      ok('更新失败后不留错误数据', f2 !== undefined && f2.lines.length === 0 && f2.enabled);
      Sources.deleteGroup(gr.groupId);
    }
    const mpEmpty: MigratePlan = Sources.planLegacy('  ' + String.fromCharCode(10) + String.fromCharCode(10));
    ok('迁移空文本无来源', mpEmpty.v4.length === 0 && mpEmpty.v6.length === 0 && mpEmpty.bad === 0);
    return out;
  }
}
