/**
 * CFLark 底层探测
 *  - TcpProbe：TCPSocket 直连测量握手耗时（阶段 1）
 *  - TraceProbe：rcp + 每请求 dnsRules 把域名指到候选 IP，URL 仍用域名 => SNI 与 Host 都是域名（阶段 2 / 域名细筛）
 *
 * 关键约束（已实测）：
 *  1. rcp 的 Session 会按 host 做 DNS 缓存与连接复用，同一个 Session 测多个 IP 会"串台"
 *     （实测把目标指到黑洞 IP 192.0.2.1 仍返回 200），因此必须"一个样本一个 Session"。
 *  2. rcp 全局 Session 上限 1024（超限错误码 1007900994），大样本量要分波。
 *  3. timeInfo 必须在 tracing.collectTimeInfo=true 时才有值，否则为 undefined。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 常见 Cloudflare TLS 端口 */
export const TLS_PORTS: number[] = [443, 2053, 2083, 2087, 2096, 8443];

export function isTlsPort(port: number): boolean {
  for (let i = 0; i < TLS_PORTS.length; i++) {
    if (TLS_PORTS[i] === port) {
      return true;
    }
  }
  return false;
}

/** 一次 TCP 握手的结果 */
export interface TcpResult {
  ok: boolean;
  rttMs: number;
  errorCode: number;
}

/** trace 请求参数 */
export interface TraceTarget {
  ip: string;
  port: number;
  host: string;
  path: string;
  timeoutMs: number;
}

/** 一次 trace 请求的结果 */
export interface TraceResult {
  ok: boolean;
  tcpMs: number;
  tlsMs: number;
  ttfbMs: number;
  totalMs: number;
  httpCode: number;
  colo: string;
  coloFromRay: boolean;
  errorCode: number;
  errorMsg: string;
}

/** TCP 握手探测 */
export class TcpProbe {
  /**
   * 连一次并返回握手耗时。
   * 注意：TCPSocket 连接超时时 reject 的错误码是 2301115（Operation in progress），
   * 不是专用超时码，所以必须自己用 setTimeout 兜底。
   */
  static pingOnce(ip: string, port: number, timeoutMs: number): Promise<TcpResult> {
    return new Promise<TcpResult>((resolve: (r: TcpResult) => void) => {
      let settled: boolean = false;
      const started: number = Date.now();
      let sock: socket.TCPSocket | undefined = undefined;
      let timer: number = -1;

      const finish = (ok: boolean, rtt: number, code: number): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        if (sock !== undefined) {
          const s: socket.TCPSocket = sock;
          try {
            s.off('connect');
            s.off('error');
          } catch (e) {
            // 忽略清理异常
          }
          s.close().then(() => {
          }).catch(() => {
          });
        }
        const r: TcpResult = { ok: ok, rttMs: rtt, errorCode: code };
        resolve(r);
      };

      try {
        sock = socket.constructTCPSocketInstance();
      } catch (e) {
        finish(false, -1, -900);
        return;
      }

      timer = setTimeout(() => {
        finish(false, -1, -1);
      }, timeoutMs);

      sock.on('connect', () => {
        finish(true, Date.now() - started, 0);
      });
      sock.on('error', () => {
        finish(false, -1, -2);
      });

      const isV6: boolean = ip.indexOf(':') >= 0;
      const addr: socket.NetAddress = { address: ip, family: isV6 ? 2 : 1, port: port };
      const opts: socket.TCPConnectOptions = { address: addr, timeout: timeoutMs };
      sock.connect(opts).then(() => {
        // 有的实现 connect 后再触发 connect 事件，这里只兜底超时
      }).catch(() => {
        finish(false, -1, -3);
      });
    });
  }
}

/** 把 /cdn-cgi/trace 的 body 解析成键值表 */
export function parseTrace(body: string): Map<string, string> {
  const out: Map<string, string> = new Map<string, string>();
  if (body.length === 0) {
    return out;
  }
  const lines: string[] = body.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    const idx: number = line.indexOf('=');
    if (idx <= 0) {
      continue;
    }
    const k: string = line.substring(0, idx).trim();
    const v: string = line.substring(idx + 1).trim();
    out.set(k, v);
  }
  return out;
}

/** 从 cf-ray 头里提取 3 位机场码，例如 "8a1b2c3d4e5f-LAX" -> "LAX" */
export function extractColoFromRay(ray: string): string {
  if (ray.length === 0) {
    return '';
  }
  const idx: number = ray.lastIndexOf('-');
  if (idx < 0 || idx + 3 >= ray.length + 1) {
    return '';
  }
  const code: string = ray.substring(idx + 1).toUpperCase();
  if (code.length === 3) {
    return code;
  }
  return '';
}

/** trace 请求（阶段 2 与域名细筛共用） */
export class TraceProbe {
  static async request(t: TraceTarget): Promise<TraceResult> {
    const scheme: string = t.port === 443 ? 'https' : (isTlsPort(t.port) ? 'https' : 'http');
    const url: string = scheme + '://' + t.host + t.path;
    const fail = (code: number, msg: string): TraceResult => {
      const r: TraceResult = {
        ok: false, tcpMs: -1, tlsMs: -1, ttfbMs: -1, totalMs: -1,
        httpCode: 0, colo: '', coloFromRay: false, errorCode: code, errorMsg: msg
      };
      return r;
    };

    const conf: rcp.SessionConfiguration = {
      requestConfiguration: {
        tracing: { collectTimeInfo: true },
        transfer: { timeout: { connectMs: t.timeoutMs, transferMs: t.timeoutMs * 2 } }
      }
    };
    let session: rcp.Session | undefined = undefined;
    try {
      session = rcp.createSession(conf);
      const req = new rcp.Request(url, 'GET');
      req.configuration = {
        dns: {
          dnsRules: (host: string, port: number): string[] => {
            return [t.ip];
          }
        }
      };
      const resp: rcp.Response = await session.fetch(req);
      const code: number = resp.statusCode;
      let body: string = '';
      try {
        const s: string | null = await resp.toString();
        body = s === null ? '' : s;
      } catch (e) {
        body = '';
      }
      const kv: Map<string, string> = parseTrace(body);
      let colo: string = '';
      if (kv.has('colo')) {
        colo = (kv.get('colo') as string).toUpperCase();
      }
      let ray: string = '';
      try {
        const h: rcp.ResponseHeaders = resp.headers;
        if (h !== undefined) {
          const raw: string | string[] | undefined = h['cf-ray'];
          if (typeof raw === 'string') {
            ray = raw;
          } else if (raw !== undefined) {
            ray = raw.length > 0 ? raw[0] : '';
          }
        }
      } catch (e) {
        ray = '';
      }
      let fromRay: boolean = false;
      if (colo.length === 0 && ray.length > 0) {
        const rc: string = extractColoFromRay(ray);
        if (rc.length > 0) {
          colo = rc;
          fromRay = true;
        }
      }
      const ti: rcp.TimeInfo | undefined = resp.timeInfo;
      let tcpMs: number = -1;
      let tlsMs: number = -1;
      let ttfbMs: number = -1;
      let totalMs: number = -1;
      if (ti !== undefined) {
        tcpMs = ti.connectTimeMs;
        tlsMs = ti.tlsHandshakeTimeMs - ti.connectTimeMs;
        ttfbMs = ti.startTransferTimeMs - ti.preTransferTimeMs;
        totalMs = ti.totalTimeMs;
      }
      const ok: boolean = (code >= 200 && code < 400 && colo.length > 0);
      const r: TraceResult = {
        ok: ok, tcpMs: tcpMs, tlsMs: tlsMs, ttfbMs: ttfbMs, totalMs: totalMs,
        httpCode: code, colo: colo, coloFromRay: fromRay, errorCode: ok ? 0 : -100, errorMsg: ok ? '' : ''
      };
      if (!ok) {
        if (code >= 200 && code < 400 && colo.length === 0) {
          r.errorCode = -100;
          r.errorMsg = '响应里没有 colo';
        } else if (code === 403) {
          r.errorCode = 403;
          r.errorMsg = '403（该 IP 不对这个域名提供服务）';
        } else if (code === 429) {
          r.errorCode = 429;
          r.errorMsg = '429 限流';
        } else {
          r.errorCode = -101;
          r.errorMsg = 'HTTP ' + code;
        }
      }
      return r;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      const c: number = err !== undefined && err.code !== undefined ? err.code : -999;
      return fail(c, TraceProbe.describeError(c));
    } finally {
      if (session !== undefined) {
        const s: rcp.Session = session;
        try {
          s.close();
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  static describeError(code: number): string {
    if (code === 1007900028) {
      return '连接超时';
    }
    if (code === 1007900021) {
      return '域名解析失败';
    }
    if (code === 1007900025) {
      return 'TLS 握手失败';
    }
    if (code === 1007900022) {
      return '连接被拒绝';
    }
    if (code === 1007900020) {
      return '网络不可用';
    }
    if (code === 1007900994) {
      return 'Session 超限';
    }
    return '网络错误 ' + code;
  }
}