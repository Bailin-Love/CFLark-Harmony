/**
 * CFLark · edgetunnel 订阅自动上传
 *
 * 支持两种上传方式：
 *  A) 登录上传（uploadWay=login，默认）
 *     协议依据（edgetunnel 2.1，_worker.js）：
 *      1) POST {base}/login   Content-Type: application/x-www-form-urlencoded，body = password=xxx
 *         成功：HTTP 200 + JSON {"success":true} + Set-Cookie: auth=MD5MD5(UA + KEY + 管理员密码)
 *         失败：HTTP 200 + Pages 登录页 HTML（没有任何 Set-Cookie）
 *      2) GET  {base}/admin/ADD.txt   Cookie: auth=...
 *         成功：HTTP 200 + text/plain，内容为「自定义节点」当前文本
 *         失败：HTTP 302 -> /login（HTTP 模块默认自动跟随，最终拿到登录页 HTML）
 *      3) POST {base}/admin/ADD.txt   Cookie: auth=...，Content-Type: text/plain，body = 完整新内容
 *         成功：HTTP 200 + JSON {"success":true,"message":"自定义IP已保存"}
 *     关键约束：服务端每次请求都用「当次请求的 User-Agent」重新计算 auth cookie，
 *     所以登录、读取、写入三次请求必须带完全相同的 User-Agent。
 *
 *  B) Cloudflare API 直传（uploadWay=api）
 *     当 Worker 域名被网络层阻断（TLS SNI 被 RST）、但 api.cloudflare.com 可达时使用。
 *     等价于后台「自定义节点」写 ADD.txt 的效果：
 *      1) GET  {api}/accounts/{accountId}/storage/kv/namespaces/{namespaceId}/values/ADD.txt
 *         200：text/plain 原值；404：键不存在（按空内容处理）
 *      2) PUT  同 URL，body = 完整新内容（text/plain），Authorization: Bearer {token}
 *         成功：200 + JSON {"success":true,...}；失败：4xx/5xx + JSON {"errors":[{code,message}]}
 *     需要用户在设置页填写 Account ID、KV 命名空间 ID、API Token（Workers KV 读写权限）。
 *
 * 实测结论（HarmonyOS NEXT API 26 模拟器，@ohos.net.http）：
 *  - Set-Cookie 不会出现在 HttpResponse.cookies —— 该字段是 Netscape 格式的 cookie jar
 *    （形如 "host\tFALSE\t/\tFALSE\t0\tauth\t<值>"），普通 200 响应里为 null/空；
 *    因此只能从 HttpResponse.header 的 set-cookie 数组解析（header 键为小写，值为字符串数组）。
 *  - 自定义 User-Agent、Cookie 请求头可以原样透传（服务端看到的与代码设置一致）。
 *  - 302 会被自动跟随；跟随后的响应 responseCode 才是最终状态码，header 里仍保留 location。
 *  - maxRedirects=0 不表示「不跟随」，而是直接抛 2300047（重定向次数超过上限），不要依赖它。
 */
import { http, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { url } from '@kit.ArkTS';

const DOMAIN: number = 0x0000;
const TAG: string = 'EdgeTunnel';
const TIMEOUT_MS: number = 20000;
const EDGE_UA: string = 'CFLark/1.3.7 (HarmonyOS; edgetunnel-upload)';
const ADD_PATH: string = '/admin/ADD.txt';
/** Cloudflare API 站点（本项目实测在模拟器内可正常 TLS 握手） */
const CF_API_BASE: string = 'https://api.cloudflare.com/client/v4';
/** 与 edgetunnel 后台「自定义节点」一致的 KV 键名 */
const ADD_KEY: string = 'ADD.txt';

export interface EdgeTunnelConfig {
  /** 扫描完成后是否自动上传 */
  enabled: boolean;
  /** edgetunnel 域名，例如 abc.example.com 或 https://abc.example.com（也可带 /login、/admin 页面地址） */
  host: string;
  /** 后台登录密码（原样比较，不做 trim） */
  password: string;
  /** overwrite=覆盖  append=追加 */
  mode: string;
  /** 自定义保留内容（域名或节点，每行一个），每次上传都会带上 */
  customHead: string;
  /** 自定义内容写入位置：top=最前 bottom=最后 */
  customPos: string;
  /** 上传代理类型：none=直连 http=HTTP 代理（SDK 26 的 SOCKS5 接口尚未接入 UI） */
  proxyType: string;
  /** 代理服务器地址，例如 127.0.0.1 */
  proxyHost: string;
  /** 代理端口 */
  proxyPort: number;
  /** 代理用户名（可选） */
  proxyUser: string;
  /** 代理密码（可选） */
  proxyPass: string;
  /** 上传方式：login=登录 Worker 上传 api=Cloudflare API 直传 */
  uploadWay: string;
  /** Cloudflare API：账户 ID */
  cfAccountId: string;
  /** Cloudflare API：KV 命名空间 ID */
  cfNamespaceId: string;
  /** Cloudflare API：API Token（需要 Workers KV 编辑权限） */
  cfApiToken: string;
  /** 每次最多上传的结果数：0=全部；N=只上传当前排序最靠前的 N 个 */
  topN: number;
}

export function defaultEdgeTunnelConfig(): EdgeTunnelConfig {
  const c: EdgeTunnelConfig = {
    enabled: false,
    host: '',
    password: '',
    mode: 'overwrite',
    customHead: '',
    customPos: 'top',
    proxyType: 'none',
    proxyHost: '',
    proxyPort: 7890,
    proxyUser: '',
    proxyPass: '',
    uploadWay: 'login',
    cfAccountId: '',
    cfNamespaceId: '',
    cfApiToken: '',
    topN: 3
  };
  return c;
}

/** 一次上传的输入：本次优选节点 + 自定义保留行 + 自定义位置 */
export interface UploadPayload {
  /**
   * 本次优选得到、确认可用的节点，每个元素一行。
   * 统一格式：IPv4 为 "1.2.3.4:443#SG V4新加坡1"，IPv6 为 "[2606:...]:443#HK V6香港1"；
   * 自定义行（custom）保持用户输入原文。
   */
  nodes: string[];
  /** 自定义保留内容，每个元素一行 */
  custom: string[];
  /** 自定义内容位置：top=最前 bottom=最后 */
  customPos: string;
}

/** Cloudflare API 的单条错误 */
interface CfErrorItem {
  code?: number;
  message?: string;
}

/** admin/ADD.txt 与 Cloudflare KV API 的 JSON 响应 */
interface EdgeTunnelAck {
  success?: boolean;
  message?: string;
  error?: string;
  errors?: CfErrorItem[];
}

export interface UploadResult {
  /** login=登录 Worker 上传 api=Cloudflare API 直传 */
  way: string;
  mode: string;
  nodeCount: number;
  customCount: number;
  totalLines: number;
  bytes: number;
  loginMs: number;
  readMs: number;
  writeMs: number;
}

/** 节点行拆解结果：addr:port#CC V4中文名序号（用于追加时跨批次续编号） */
interface NodeLine {
  addr: string;
  port: string;
  code: string;
  family: number;
  label: string;
  index: number;
}

export class EdgeTunnel {
  // ---------------------------------------------------------------- 地址与内容

  /**
   * 用 URL 解析（@ohos.url）而不是字符串 indexOf 截断来得到站点根。
   * - 只填域名时补 https://
   * - 允许带 /login、/admin、/admin/ADD.txt、/sub 这些页面地址，统一收敛为 origin
   * - 其它路径、userinfo、非 http(s) 协议直接报错，避免拼出错误地址
   * - http:// 且非本机地址时升级为 https：_worker.js 对 http 请求会 301 到 https，
   *   若让客户端跟随重定向，POST 登录会被改成 GET，登录必失败。
   */
  static normalizeHost(raw: string): string {
    const text: string = raw.trim();
    if (text.length === 0) {
      return '';
    }
    let input: string = text;
    const hasScheme: boolean = new RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*://').test(input);
    if (!hasScheme) {
      input = 'https://' + input;
    }
    let parsed: url.URL;
    try {
      parsed = url.URL.parseURL(input);
    } catch (e) {
      throw new Error('edgetunnel 域名格式不正确：' + text);
    }
    const scheme: string = parsed.protocol.toLowerCase();
    if (scheme !== 'https:' && scheme !== 'http:') {
      throw new Error('edgetunnel 只支持 http/https 地址：' + text);
    }
    const hostname: string = parsed.hostname;
    if (hostname.length === 0) {
      throw new Error('edgetunnel 域名格式不正确：' + text);
    }
    if (parsed.username.length > 0 || parsed.password.length > 0) {
      throw new Error('edgetunnel 域名里不要带用户名或密码：' + text);
    }
    const path: string = parsed.pathname;
    const knownPath: boolean = path === '' || path === '/'
      || new RegExp('^/(login|admin(/.*)?|sub)$').test(path);
    if (!knownPath) {
      throw new Error('edgetunnel 域名只填站点根地址（可带 /login、/admin 页面地址），不要带其它路径：' + text);
    }
    const port: string = parsed.port;
    const portPart: string = port.length > 0 ? ':' + port : '';
    if (scheme === 'http:' && !EdgeTunnel.isLocalHost(hostname)) {
      return 'https://' + hostname + portPart;
    }
    return scheme + '//' + hostname + portPart;
  }

  private static isLocalHost(hostname: string): boolean {
    const h: string = hostname.toLowerCase();
    return h === 'localhost' || h === '127.0.0.1' || h === '10.0.2.2'
      || h.startsWith('192.168.') || h.endsWith('.local');
  }

  /** 覆盖模式：自定义行 + 节点按位置拼成完整文本（去重、去空行） */
  static compose(custom: string[], customPos: string, nodes: string[]): string {
    const out: string[] = [];
    const seen: Set<string> = new Set<string>();
    if (customPos === 'bottom') {
      EdgeTunnel.pushUnique(out, seen, nodes);
      EdgeTunnel.pushUnique(out, seen, custom);
    } else {
      EdgeTunnel.pushUnique(out, seen, custom);
      EdgeTunnel.pushUnique(out, seen, nodes);
    }
    return out.join('\n');
  }

  /**
   * 追加模式：保留远程已有内容，只补新增行。
   * - 远程已有行原样保留、顺序不变，不会被删除
   * - 新增行如果远程已存在（例如上次追加过的自定义行）就跳过，避免无限增长
   * - 自定义行位置：top=放在最前（远程之前），bottom=放在最后（远程与新增节点之后）
   */
  static mergeAppend(remote: string, custom: string[], customPos: string, nodes: string[]): string {
    const remoteLines: string[] = [];
    const present: Set<string> = new Set<string>();
    const rawLines: string[] = remote.split('\n');
    for (let i = 0; i < rawLines.length; i++) {
      const t: string = rawLines[i].trim();
      if (t.length === 0) {
        continue;
      }
      remoteLines.push(t);
      present.add(EdgeTunnel.lineKey(t));
    }
    const added: Set<string> = new Set<string>();
    const customAdd: string[] = [];
    const nodeAdd: string[] = [];
    for (let i = 0; i < custom.length; i++) {
      const t: string = custom[i].trim();
      const key: string = EdgeTunnel.lineKey(t);
      if (t.length === 0 || present.has(key) || added.has(key)) {
        continue;
      }
      added.add(key);
      customAdd.push(t);
    }
    for (let i = 0; i < nodes.length; i++) {
      const t: string = nodes[i].trim();
      const key: string = EdgeTunnel.lineKey(t);
      if (t.length === 0 || present.has(key) || added.has(key)) {
        continue;
      }
      added.add(key);
      nodeAdd.push(t);
    }
    const merged: string[] = [];
    if (customPos === 'bottom') {
      for (let i = 0; i < remoteLines.length; i++) {
        merged.push(remoteLines[i]);
      }
      for (let i = 0; i < nodeAdd.length; i++) {
        merged.push(nodeAdd[i]);
      }
      for (let i = 0; i < customAdd.length; i++) {
        merged.push(customAdd[i]);
      }
    } else {
      for (let i = 0; i < customAdd.length; i++) {
        merged.push(customAdd[i]);
      }
      for (let i = 0; i < remoteLines.length; i++) {
        merged.push(remoteLines[i]);
      }
      for (let i = 0; i < nodeAdd.length; i++) {
        merged.push(nodeAdd[i]);
      }
    }
    return merged.join('\n');
  }

  /**
   * 节点的去重键：忽略 # 备注，仅比较地址本身。
   * IPv6 统一成不带方括号的 "addr:port"，这样 "addr:port" 与
   * "[addr]:port#备注" 会被视为同一个节点，追加时不会重复写入。
   */
  private static lineKey(line: string): string {
    const t: string = line.trim();
    const hash: number = t.indexOf('#');
    const body: string = hash >= 0 ? t.substring(0, hash).trim() : t;
    if (body.startsWith('[')) {
      const close: number = body.indexOf(']');
      if (close > 0) {
        const host: string = body.substring(1, close).toLowerCase();
        const rest: string = body.substring(close + 1);
        return host + rest.toLowerCase();
      }
    }
    return body.toLowerCase();
  }

  /** 解析本项目生成的节点行；格式不匹配（用户自定义文本）返回 undefined，保持原样不重排 */
  private static parseNodeLine(line: string): NodeLine | undefined {
    const re: RegExp = new RegExp('^(\\[[0-9a-fA-F:.]+\\]|[0-9.]+):(\\d+)#([A-Za-z0-9]{2,4}) V([46])([^0-9]*)(\\d+)$');
    const m: RegExpExecArray | null = re.exec(line.trim());
    if (m === null || m.length < 7) {
      return undefined;
    }
    const n: NodeLine = {
      addr: m[1],
      port: m[2],
      code: m[3],
      family: parseInt(m[4], 10),
      label: m[5],
      index: parseInt(m[6], 10)
    };
    return n;
  }

  /** 编号分组键：同地区、同版本（V4/V6）各自连续编号 */
  private static nodeKey(code: string, family: number): string {
    return code + '|' + family.toString();
  }

  /**
   * 跨批次续编号：新节点按 baseLines 里「同地区 + 同版本」的最大序号往后排，
   * 这样追加多批后不会出现两个「香港1」。已经出现在 baseLines 里的地址直接跳过
   * （不重复写入）；无法识别的行保持原样。
   */
  private static renumberNodes(nodes: string[], baseLines: string[]): string[] {
    const baseKeys: Set<string> = new Set<string>();
    const maxMap: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < baseLines.length; i++) {
      const raw: string = baseLines[i].trim();
      if (raw.length === 0) {
        continue;
      }
      baseKeys.add(EdgeTunnel.lineKey(raw));
      const parsed: NodeLine | undefined = EdgeTunnel.parseNodeLine(raw);
      if (parsed === undefined) {
        continue;
      }
      const k: string = EdgeTunnel.nodeKey(parsed.code, parsed.family);
      const cur: number = maxMap.get(k) ?? 0;
      if (parsed.index > cur) {
        maxMap.set(k, parsed.index);
      }
    }
    const out: string[] = [];
    for (let i = 0; i < nodes.length; i++) {
      const raw: string = nodes[i].trim();
      if (raw.length === 0 || baseKeys.has(EdgeTunnel.lineKey(raw))) {
        continue;
      }
      const parsed: NodeLine | undefined = EdgeTunnel.parseNodeLine(raw);
      if (parsed === undefined) {
        out.push(raw);
        continue;
      }
      const k: string = EdgeTunnel.nodeKey(parsed.code, parsed.family);
      const next: number = (maxMap.get(k) ?? 0) + 1;
      maxMap.set(k, next);
      out.push(parsed.addr + ':' + parsed.port + '#' + parsed.code + ' V' + parsed.family.toString()
        + parsed.label + next.toString());
    }
    return out;
  }

  private static pushUnique(out: string[], seen: Set<string>, lines: string[]): void {
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (t.length === 0) {
        continue;
      }
      const key: string = EdgeTunnel.lineKey(t);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      out.push(t);
    }
  }

  // ---------------------------------------------------------------- 上传主流程

  /**
   * 上传一次，按 uploadWay 分派到「登录上传」或「Cloudflare API 直传」。
   * 追加模式下读取远程失败会直接抛错终止，绝不退化成覆盖，避免把远程已有节点误删。
   */
  static async upload(cfg: EdgeTunnelConfig, payload: UploadPayload,
    onStatus: (msg: string) => void): Promise<UploadResult> {
    if (cfg.uploadWay === 'api') {
      return EdgeTunnel.uploadViaApi(cfg, payload, onStatus);
    }
    return EdgeTunnel.uploadViaWorker(cfg, payload, onStatus);
  }

  /**
   * 登录 Worker 后写入 ADD.txt（uploadWay=login）。
   * 会按 mode 决定覆盖/追加；追加模式下读取远程失败会直接抛错终止。
   */
  private static async uploadViaWorker(cfg: EdgeTunnelConfig, payload: UploadPayload,
    onStatus: (msg: string) => void): Promise<UploadResult> {
    const base: string = EdgeTunnel.normalizeHost(cfg.host);
    if (base.length === 0) {
      throw new Error('edgetunnel 域名不能为空');
    }
    if (cfg.password.length === 0) {
      throw new Error('edgetunnel 密码不能为空');
    }
    const mode: string = cfg.mode === 'append' ? 'append' : 'overwrite';
    const nodes0: string[] = EdgeTunnel.cleanLines(payload.nodes);
    const custom: string[] = EdgeTunnel.cleanLines(payload.custom);
    const pos: string = payload.customPos === 'bottom' ? 'bottom' : 'top';
    if (nodes0.length === 0 && custom.length === 0) {
      throw new Error('没有可上传的内容');
    }
    const proxy: boolean | connection.HttpProxy = EdgeTunnel.proxyOf(cfg);
    hilog.info(DOMAIN, TAG, 'upload start way=login host=%{public}s mode=%{public}s nodes=%{public}d custom=%{public}d',
      base, mode, nodes0.length, custom.length);

    onStatus('正在登录…');
    const t0: number = Date.now();
    const cookie: string = await EdgeTunnel.login(base, cfg.password, proxy);
    const loginMs: number = Date.now() - t0;
    hilog.info(DOMAIN, TAG, 'login ok in %{public}dms, cookie.len=%{public}d', loginMs, cookie.length);

    let content: string = '';
    let readMs: number = 0;
    let nodes: string[] = nodes0;
    if (mode === 'append') {
      onStatus('正在读取远程内容…');
      const t1: number = Date.now();
      const remote: string = await EdgeTunnel.readRemote(base, cookie, proxy);
      readMs = Date.now() - t1;
      const remoteLines: string[] = remote.length === 0
        ? new Array<string>() : EdgeTunnel.cleanLines(remote.split('\n'));
      const baseLines: string[] = new Array<string>();
      for (let i = 0; i < remoteLines.length; i++) {
        baseLines.push(remoteLines[i]);
      }
      for (let i = 0; i < custom.length; i++) {
        baseLines.push(custom[i]);
      }
      nodes = EdgeTunnel.renumberNodes(nodes0, baseLines);
      content = remote.length === 0 ? EdgeTunnel.compose(custom, pos, nodes)
        : EdgeTunnel.mergeAppend(remote, custom, pos, nodes);
      hilog.info(DOMAIN, TAG, 'read ok in %{public}dms, remote.len=%{public}d, merged.len=%{public}d',
        readMs, remote.length, content.length);
    } else {
      nodes = EdgeTunnel.renumberNodes(nodes0, custom);
      content = EdgeTunnel.compose(custom, pos, nodes);
    }
    if (content.length === 0) {
      throw new Error('没有可上传的内容');
    }

    onStatus('正在写入远程文件…');
    const t2: number = Date.now();
    await EdgeTunnel.writeRemote(base, cookie, content, proxy);
    const writeMs: number = Date.now() - t2;
    const lines: number = content.split('\n').length;
    const result: UploadResult = {
      way: 'login',
      mode: mode,
      nodeCount: nodes.length,
      customCount: custom.length,
      totalLines: lines,
      bytes: content.length,
      loginMs: loginMs,
      readMs: readMs,
      writeMs: writeMs
    };
    hilog.info(DOMAIN, TAG,
      'upload ok way=login mode=%{public}s lines=%{public}d bytes=%{public}d login=%{public}dms read=%{public}dms write=%{public}dms',
      mode, lines, content.length, loginMs, readMs, writeMs);
    return result;
  }

  /**
   * Cloudflare API 直传（uploadWay=api）：直接读写 Worker 绑定的 KV 命名空间中的 ADD.txt，
   * 效果等同于在后台「自定义节点」里保存。适用于 Worker 域名被网络阻断、但 api.cloudflare.com 可达的情况。
   */
  private static async uploadViaApi(cfg: EdgeTunnelConfig, payload: UploadPayload,
    onStatus: (msg: string) => void): Promise<UploadResult> {
    const accountId: string = cfg.cfAccountId.trim();
    const namespaceId: string = cfg.cfNamespaceId.trim();
    const token: string = cfg.cfApiToken.trim();
    if (accountId.length === 0) {
      throw new Error('API 直传：Account ID 不能为空');
    }
    if (namespaceId.length === 0) {
      throw new Error('API 直传：KV 命名空间 ID 不能为空');
    }
    if (token.length === 0) {
      throw new Error('API 直传：API Token 不能为空（需要该 Account 的 Workers KV 读写权限）');
    }
    const mode: string = cfg.mode === 'append' ? 'append' : 'overwrite';
    const nodes0: string[] = EdgeTunnel.cleanLines(payload.nodes);
    const custom: string[] = EdgeTunnel.cleanLines(payload.custom);
    const pos: string = payload.customPos === 'bottom' ? 'bottom' : 'top';
    if (nodes0.length === 0 && custom.length === 0) {
      throw new Error('没有可上传的内容');
    }
    const proxy: boolean | connection.HttpProxy = EdgeTunnel.proxyOf(cfg);
    const endpoint: string = EdgeTunnel.kvEndpoint(accountId, namespaceId);
    hilog.info(DOMAIN, TAG,
      'upload start way=api acct=****%{public}s ns=****%{public}s mode=%{public}s nodes=%{public}d custom=%{public}d',
      EdgeTunnel.tail4(accountId), EdgeTunnel.tail4(namespaceId), mode, nodes0.length, custom.length);

    let content: string = '';
    let readMs: number = 0;
    let nodes: string[] = nodes0;
    if (mode === 'append') {
      onStatus('正在读取远端内容…');
      const t1: number = Date.now();
      const remote: string = await EdgeTunnel.cfRead(endpoint, token, proxy);
      readMs = Date.now() - t1;
      const remoteLines: string[] = remote.length === 0
        ? new Array<string>() : EdgeTunnel.cleanLines(remote.split('\n'));
      const baseLines: string[] = new Array<string>();
      for (let i = 0; i < remoteLines.length; i++) {
        baseLines.push(remoteLines[i]);
      }
      for (let i = 0; i < custom.length; i++) {
        baseLines.push(custom[i]);
      }
      nodes = EdgeTunnel.renumberNodes(nodes0, baseLines);
      content = remote.length === 0 ? EdgeTunnel.compose(custom, pos, nodes)
        : EdgeTunnel.mergeAppend(remote, custom, pos, nodes);
      hilog.info(DOMAIN, TAG, 'api read ok in %{public}dms, remote.len=%{public}d, merged.len=%{public}d',
        readMs, remote.length, content.length);
    } else {
      nodes = EdgeTunnel.renumberNodes(nodes0, custom);
      content = EdgeTunnel.compose(custom, pos, nodes);
    }
    if (content.length === 0) {
      throw new Error('没有可上传的内容');
    }

    onStatus('正在写入 Cloudflare KV…');
    const t2: number = Date.now();
    await EdgeTunnel.cfWrite(endpoint, token, content, proxy);
    const writeMs: number = Date.now() - t2;
    const lines: number = content.split('\n').length;
    const result: UploadResult = {
      way: 'api',
      mode: mode,
      nodeCount: nodes.length,
      customCount: custom.length,
      totalLines: lines,
      bytes: content.length,
      loginMs: 0,
      readMs: readMs,
      writeMs: writeMs
    };
    hilog.info(DOMAIN, TAG,
      'upload ok way=api mode=%{public}s lines=%{public}d bytes=%{public}d read=%{public}dms write=%{public}dms',
      mode, lines, content.length, readMs, writeMs);
    return result;
  }

  /** KV 单键的 REST 地址 */
  private static kvEndpoint(accountId: string, namespaceId: string): string {
    return CF_API_BASE + '/accounts/' + accountId + '/storage/kv/namespaces/' + namespaceId
      + '/values/' + ADD_KEY;
  }

  /** 日志里只显示 ID 后 4 位，避免整段 ID 进日志 */
  private static tail4(id: string): string {
    if (id.length <= 4) {
      return id;
    }
    return id.substring(id.length - 4);
  }

  private static cleanLines(lines: string[]): string[] {
    const out: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (t.length === 0 || seen.has(t)) {
        continue;
      }
      seen.add(t);
      out.push(t);
    }
    return out;
  }

  // ---------------------------------------------------------------- 三个请求

  private static async send(endpoint: string, method: http.RequestMethod,
    headers: Record<string, string>, body: string,
    proxy: boolean | connection.HttpProxy): Promise<http.HttpResponse> {
    const req = http.createHttp();
    try {
      const opts: http.HttpRequestOptions = {
        method: method,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        usingProxy: proxy,
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS
      };
      if (body.length > 0) {
        opts.extraData = body;
      }
      return await req.request(endpoint, opts);
    } finally {
      req.destroy();
    }
  }

  /** 登录，返回可直接放进 Cookie 头的 "auth=..." 串 */
  private static async login(base: string, password: string,
    proxy: boolean | connection.HttpProxy): Promise<string> {
    const headers: Record<string, string> = {
      'User-Agent': EDGE_UA,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json, text/plain, */*'
    };
    let resp: http.HttpResponse;
    try {
      resp = await EdgeTunnel.send(base + '/login', http.RequestMethod.POST, headers,
        'password=' + encodeURIComponent(password), proxy);
    } catch (e) {
      throw EdgeTunnel.netError(e, '登录失败');
    }
    const body: string = EdgeTunnel.textOf(resp);
    const cookie: string = EdgeTunnel.extractAuthCookie(resp);
    const ct: string = EdgeTunnel.contentTypeOf(resp);
    hilog.info(DOMAIN, TAG, 'login resp code=%{public}d ct=%{public}s cookie=%{public}d body.len=%{public}d',
      resp.responseCode, ct, cookie.length, body.length);
    if (resp.responseCode !== http.ResponseCode.OK) {
      throw new Error('登录失败：服务端返回 HTTP ' + resp.responseCode.toString());
    }
    if (cookie.length > 0) {
      return cookie;
    }
    if (ct === 'text/html' || EdgeTunnel.looksLikeHtml(body)) {
      throw new Error('登录失败：密码不正确（服务端返回了登录页）');
    }
    if (EdgeTunnel.hasLocationHeader(resp)) {
      throw new Error('登录失败：登录请求被重定向，请确认「域名」只填站点根地址');
    }
    throw new Error('登录失败：响应里没有 auth cookie（服务端没有下发 Set-Cookie）');
  }

  /** 读取远程 ADD.txt；返回去除首尾空白的文本，空文件返回 '' */
  private static async readRemote(base: string, cookie: string,
    proxy: boolean | connection.HttpProxy): Promise<string> {
    const headers: Record<string, string> = {
      'User-Agent': EDGE_UA,
      'Cookie': cookie,
      'Accept': 'text/plain, */*',
      'Cache-Control': 'no-cache, no-store, must-revalidate'
    };
    let resp: http.HttpResponse;
    try {
      resp = await EdgeTunnel.send(base + ADD_PATH + '?_t=' + Date.now().toString(),
        http.RequestMethod.GET, headers, '', proxy);
    } catch (e) {
      throw EdgeTunnel.netError(e, '读取远程文件失败');
    }
    const body: string = EdgeTunnel.textOf(resp);
    const ct: string = EdgeTunnel.contentTypeOf(resp);
    hilog.info(DOMAIN, TAG, 'read resp code=%{public}d ct=%{public}s len=%{public}d',
      resp.responseCode, ct, body.length);
    if (resp.responseCode !== http.ResponseCode.OK) {
      throw new Error('读取远程文件失败：服务端返回 HTTP ' + resp.responseCode.toString());
    }
    if (ct === 'text/html' || EdgeTunnel.looksLikeHtml(body) || EdgeTunnel.hasLocationHeader(resp)) {
      throw new Error('读取远程文件失败：认证已失效（服务端返回登录页），已终止追加，远程文件未被修改');
    }
    const text: string = body.trim();
    if (text.length === 0 || text === 'null') {
      return '';
    }
    return text;
  }

  /** 写入 ADD.txt，必须拿到 {"success":true} 才算成功 */
  private static async writeRemote(base: string, cookie: string, content: string,
    proxy: boolean | connection.HttpProxy): Promise<void> {
    const headers: Record<string, string> = {
      'User-Agent': EDGE_UA,
      'Cookie': cookie,
      'Content-Type': 'text/plain',
      'Accept': 'application/json, text/plain, */*'
    };
    let resp: http.HttpResponse;
    try {
      resp = await EdgeTunnel.send(base + ADD_PATH, http.RequestMethod.POST, headers, content, proxy);
    } catch (e) {
      throw EdgeTunnel.netError(e, '写入失败');
    }
    const body: string = EdgeTunnel.textOf(resp);
    const ct: string = EdgeTunnel.contentTypeOf(resp);
    hilog.info(DOMAIN, TAG, 'write resp code=%{public}d ct=%{public}s len=%{public}d',
      resp.responseCode, ct, body.length);
    if (ct === 'text/html' || EdgeTunnel.looksLikeHtml(body) || EdgeTunnel.hasLocationHeader(resp)) {
      throw new Error('写入失败：认证已失效（服务端返回登录页），远程文件未被修改，请重试');
    }
    if (resp.responseCode !== http.ResponseCode.OK) {
      throw new Error('写入失败：服务端返回 HTTP ' + resp.responseCode.toString()
        + '：' + EdgeTunnel.sanitize(body));
    }
    const ack: EdgeTunnelAck | null = EdgeTunnel.parseAck(body);
    if (ack === null) {
      throw new Error('写入失败：服务端返回的不是合法 JSON：' + EdgeTunnel.sanitize(body));
    }
    if (ack.success !== true) {
      let detail: string = '';
      if (ack.error !== undefined) {
        detail = ack.error as string;
      } else if (ack.message !== undefined) {
        detail = ack.message as string;
      }
      throw new Error('写入失败：服务端未返回 success:true'
        + (detail.length > 0 ? '（' + EdgeTunnel.sanitize(detail) + '）' : ''));
    }
  }

  // ---------------------------------------------------------------- Cloudflare KV API

  /** 读取 KV 键；200 返回原值，404（键不存在）返回 ''，其它抛错 */
  private static async cfRead(endpoint: string, token: string,
    proxy: boolean | connection.HttpProxy): Promise<string> {
    const headers: Record<string, string> = {
      'Authorization': 'Bearer ' + token,
      'User-Agent': EDGE_UA,
      'Accept': 'text/plain, application/json'
    };
    let resp: http.HttpResponse;
    try {
      resp = await EdgeTunnel.send(endpoint, http.RequestMethod.GET, headers, '', proxy);
    } catch (e) {
      throw EdgeTunnel.netError(e, '读取失败');
    }
    const status: number = resp.responseCode as number;
    const body: string = EdgeTunnel.textOf(resp);
    hilog.info(DOMAIN, TAG, 'api read status=%{public}d len=%{public}d', status, body.length);
    if (status === http.ResponseCode.OK) {
      if (EdgeTunnel.looksLikeHtml(body)) {
        throw new Error('读取失败：Cloudflare API 返回了 HTML（可能被网络中间层劫持），请检查网络');
      }
      const text: string = body.trim();
      return text === 'null' ? '' : text;
    }
    if (status === http.ResponseCode.NOT_FOUND) {
      // 键不存在：追加模式按空内容处理；覆盖模式不受影响
      return '';
    }
    throw new Error('读取失败：' + EdgeTunnel.cfErrorText(status, body));
  }

  /** 写入 KV 键，必须拿到 HTTP 200 + {"success":true} 才算成功 */
  private static async cfWrite(endpoint: string, token: string, content: string,
    proxy: boolean | connection.HttpProxy): Promise<void> {
    const headers: Record<string, string> = {
      'Authorization': 'Bearer ' + token,
      'User-Agent': EDGE_UA,
      'Content-Type': 'text/plain',
      'Accept': 'application/json'
    };
    let resp: http.HttpResponse;
    try {
      resp = await EdgeTunnel.send(endpoint, http.RequestMethod.PUT, headers, content, proxy);
    } catch (e) {
      throw EdgeTunnel.netError(e, '写入失败');
    }
    const status: number = resp.responseCode as number;
    const body: string = EdgeTunnel.textOf(resp);
    hilog.info(DOMAIN, TAG, 'api write status=%{public}d len=%{public}d', status, body.length);
    if (status !== http.ResponseCode.OK) {
      throw new Error('写入失败：' + EdgeTunnel.cfErrorText(status, body));
    }
    const ack: EdgeTunnelAck | null = EdgeTunnel.parseAck(body);
    if (ack === null) {
      throw new Error('写入失败：Cloudflare 返回的不是合法 JSON：' + EdgeTunnel.sanitize(body));
    }
    if (ack.success !== true) {
      throw new Error('写入失败：Cloudflare 未返回 success:true（' + EdgeTunnel.cfErrorDetail(body) + '）');
    }
  }

  /** Cloudflare API 错误码 → 中文提示（附服务端 message，并脱敏） */
  private static cfErrorText(status: number, body: string): string {
    const detail: string = EdgeTunnel.cfErrorDetail(body);
    const suffix: string = detail.length > 0 ? '：' + detail : '';
    if (status === http.ResponseCode.BAD_REQUEST) {
      return 'Cloudflare 拒绝了请求参数（HTTP 400）' + suffix;
    }
    if (status === http.ResponseCode.UNAUTHORIZED) {
      return 'API Token 无效或已过期（HTTP 401）' + suffix;
    }
    if (status === http.ResponseCode.FORBIDDEN) {
      return 'API Token 权限不足：该 Account 需要 Workers KV 的读写权限（HTTP 403）' + suffix;
    }
    if (status === http.ResponseCode.NOT_FOUND) {
      return 'Account ID 或 KV 命名空间 ID 不正确（HTTP 404）' + suffix;
    }
    if (status === 413) {
      return '内容超过 Cloudflare KV 单值上限（HTTP 413）' + suffix;
    }
    if (status === 429) {
      return '请求过于频繁或超出配额（HTTP 429）' + suffix;
    }
    if (status === http.ResponseCode.INTERNAL_ERROR || status === http.ResponseCode.BAD_GATEWAY
      || status === http.ResponseCode.GATEWAY_TIMEOUT || status >= 500) {
      return 'Cloudflare 服务异常（HTTP ' + status.toString() + '）' + suffix;
    }
    return 'Cloudflare API 返回 HTTP ' + status.toString() + suffix;
  }

  private static cfErrorDetail(body: string): string {
    const ack: EdgeTunnelAck | null = EdgeTunnel.parseAck(body);
    if (ack !== null && ack.errors !== undefined && ack.errors.length > 0) {
      const first: CfErrorItem = ack.errors[0];
      if (first.message !== undefined && first.message.length > 0) {
        return EdgeTunnel.sanitize(first.message);
      }
    }
    return EdgeTunnel.sanitize(body);
  }

  // ---------------------------------------------------------------- 代理

  private static proxyOf(cfg: EdgeTunnelConfig): boolean | connection.HttpProxy {
    const type: string = cfg.proxyType;
    if (type.length === 0 || type === 'none') {
      return false;
    }
    if (type === 'socks5') {
      throw new Error('当前版本「上传代理」只接入 HTTP 代理；SDK 26 虽有 usingSocks5Proxy，但界面尚未提供 SOCKS5 配置');
    }
    if (type !== 'http') {
      throw new Error('未知的上传代理类型：' + type);
    }
    const host: string = cfg.proxyHost.trim();
    const port: number = cfg.proxyPort;
    if (host.length === 0) {
      throw new Error('已开启上传代理，但代理地址为空');
    }
    if (!(port > 0 && port <= 65535)) {
      throw new Error('上传代理端口不合法：' + port.toString());
    }
    const p: connection.HttpProxy = { host: host, port: port, exclusionList: [] };
    if (cfg.proxyUser.trim().length > 0) {
      p.username = cfg.proxyUser.trim();
      p.password = cfg.proxyPass;
    }
    return p;
  }

  // ---------------------------------------------------------------- 响应解析

  private static textOf(resp: http.HttpResponse): string {
    const r: Object = resp.result;
    if (typeof r === 'string') {
      return r as string;
    }
    return '';
  }

  /** header 序列化成 JSON 文本，便于统一处理「键小写、值为字符串数组」的结构 */
  private static headerJson(resp: http.HttpResponse): string {
    try {
      const j: Object = JSON.stringify(resp.header);
      if (typeof j === 'string') {
        return j as string;
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  private static contentTypeOf(resp: http.HttpResponse): string {
    const hd: string = EdgeTunnel.headerJson(resp).toLowerCase();
    if (hd.indexOf('text/html') >= 0) {
      return 'text/html';
    }
    if (hd.indexOf('application/json') >= 0) {
      return 'application/json';
    }
    if (hd.indexOf('text/plain') >= 0) {
      return 'text/plain';
    }
    return '';
  }

  private static hasLocationHeader(resp: http.HttpResponse): boolean {
    return EdgeTunnel.headerJson(resp).toLowerCase().indexOf('"location"') >= 0;
  }

  private static looksLikeHtml(text: string): boolean {
    const t: string = text.trim();
    if (t.length === 0) {
      return false;
    }
    const head: string = t.substring(0, 256).toLowerCase();
    return head.startsWith('<html') || head.startsWith('<!doctype html')
      || head.startsWith('<!doctype') || head.startsWith('<head');
  }

  /**
   * 从响应里取 auth cookie。
   * 注意：HttpResponse.cookies 是 cookie jar（Netscape 格式），不是本次的 Set-Cookie，
   * 普通 200 响应里为空；真正的 Set-Cookie 在 header 的 set-cookie 数组里。
   */
  private static extractAuthCookie(resp: http.HttpResponse): string {
    const hd: string = EdgeTunnel.headerJson(resp);
    const m: RegExpMatchArray | null = hd.match(new RegExp('auth=([^;"\\s,]+)'));
    if (m !== null && m.length > 1) {
      return 'auth=' + m[1];
    }
    const jar: string = typeof resp.cookies === 'string' ? resp.cookies : '';
    const lines: string[] = jar.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const fields: string[] = lines[i].split('\t');
      if (fields.length >= 7 && fields[5] === 'auth') {
        return 'auth=' + fields[6].trim();
      }
    }
    return '';
  }

  private static parseAck(text: string): EdgeTunnelAck | null {
    const t: string = text.trim();
    if (t.length === 0 || t.charAt(0) !== '{') {
      return null;
    }
    try {
      return JSON.parse(t) as EdgeTunnelAck;
    } catch (e) {
      return null;
    }
  }

  /** 错误信息里只保留可读片段，去掉换行并脱敏 token / auth cookie */
  private static sanitize(text: string): string {
    let t: string = text.replace(new RegExp('auth=[^;\\s,]+', 'g'), 'auth=***');
    t = t.replace(new RegExp('Bearer\\s+[A-Za-z0-9_\\-]{8,}', 'g'), 'Bearer ***');
    t = t.replace(new RegExp('[\\r\\n\\t]+', 'g'), ' ');
    if (t.length > 180) {
      t = t.substring(0, 180) + '…';
    }
    return t;
  }

  private static netReason(code: number, message: string): string {
    if (code === 2300001) {
      return '不支持的网络协议';
    }
    if (code === 2300003) {
      return 'URL 不合法';
    }
    if (code === 2300005) {
      return '代理服务器域名解析失败，请检查上传代理地址';
    }
    if (code === 2300006) {
      return '域名解析失败，请检查网络或地址拼写';
    }
    if (code === 2300007) {
      return '无法连接服务器，请检查网络或改用「上传代理」';
    }
    if (code === 2300008) {
      return '服务器返回的响应无效';
    }
    if (code === 2300028) {
      return '请求超时，请检查网络后重试';
    }
    if (code === 2300047) {
      return '重定向次数超过上限，请确认域名只填站点根地址';
    }
    if (code === 2300052) {
      return '服务器没有返回内容';
    }
    if (code === 2300058) {
      return '本地证书校验失败';
    }
    if (code === 2300060) {
      return '服务器证书无效';
    }
    if (code === 2300094) {
      return 'TLS 认证失败';
    }
    if (code === 2300997) {
      return '系统禁止明文 HTTP，请使用 https 地址';
    }
    if (code === 2300999) {
      return '网络内部错误（' + message + '），请检查网络连接';
    }
    if (message.length > 0) {
      return message;
    }
    return '未知网络错误（错误码 ' + code.toString() + '）';
  }

  private static netError(e: Object, stage: string): Error {
    const be: BusinessError = e as BusinessError;
    const code: number = be.code === undefined ? 0 : be.code;
    const msg: string = be.message === undefined ? '' : be.message;
    return new Error(stage + '：' + EdgeTunnel.netReason(code, msg));
  }
}
