/**
 * CFLark 下载测速（对齐 CloudFlareScan 的 download_speed）
 *
 * CloudFlareScan 的做法：
 *  - 裸 socket 连 ip:port，TLS 的 SNI/校验 Host 固定为 speed.cloudflare.com（不校验证书）
 *  - GET /__down?bytes=50000000，下载窗口 3 秒，只统计 body 字节
 *  - MB/s = body / 1024 / 1024 / 实际耗时
 *
 * 我们改用 rcp 的流式下载 + 每请求 dnsRules：URL 仍然是 https://<host>/...，
 * 由 dnsRules 把该 host 指到候选 IP，于是 SNI 与 Host 天然正确，
 * 而且 host 可以换成用户自己的域名（用户要求：域名在测速阶段生效，可填可不填）。
 *
 * 注意：一个样本必须一个 Session（同 Session 复用连接会串台，实测过）。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SpeedResult } from './Types';

export interface SpeedTarget {
  ip: string;
  port: number;
  /** 测速使用的域名（Host / SNI） */
  host: string;
  /** 完整下载 URL，host 必须与上面的 host 一致 */
  url: string;
  timeoutMs: number;
  /** 下载统计窗口（ms），CloudFlareScan 默认 3000 */
  windowMs: number;
  /** 读到这么多字节就提前结束，防超大文件 */
  maxBytes: number;
}

export class SpeedTest {
  static async run(t: SpeedTarget): Promise<SpeedResult> {
    const started: number = Date.now();
    const conf: rcp.SessionConfiguration = {
      requestConfiguration: {
        transfer: { timeout: { connectMs: t.timeoutMs, transferMs: t.windowMs + t.timeoutMs }, autoRedirect: true }
      }
    };
    let session: rcp.Session | undefined = undefined;
    let bytes: number = 0;
    let stopped: boolean = false;
    let endAt: number = 0;

    const finish = (ok: boolean, err: string): SpeedResult => {
      let elapsed: number = endAt > 0 ? endAt - started : Date.now() - started;
      if (elapsed <= 0) {
        elapsed = t.windowMs;
      }
      let avg: number = 0;
      if (ok && elapsed > 0) {
        avg = bytes / elapsed * 1000 / 1024 / 1024;
      }
      const r: SpeedResult = {
        ok: ok,
        avgMbps: avg,
        maxMbps: avg,
        bytes: bytes,
        costMs: elapsed,
        error: err
      };
      return r;
    };

    try {
      session = rcp.createSession(conf);
      const req = new rcp.Request(t.url, 'GET');
      req.headers = { 'Accept-Encoding': 'identity', 'User-Agent': 'Mozilla/5.0' };
      req.configuration = {
        dns: {
          dnsRules: (host: string, port: number): string[] => {
            return [t.ip];
          }
        }
      };

      const onChunk = (buf: ArrayBuffer): Promise<void | number> => {
        return new Promise<void | number>((resolve: (v: void | number) => void) => {
          if (stopped) {
            resolve(0);
            return;
          }
          const now: number = Date.now();
          bytes += buf.byteLength;
          if (now - started >= t.windowMs || bytes >= t.maxBytes) {
            stopped = true;
            endAt = now;
            if (session !== undefined) {
              const s: rcp.Session = session;
              try {
                s.cancel(req);
              } catch (e) {
                // 忽略
              }
            }
            resolve(0);
            return;
          }
          resolve(buf.byteLength);
        });
      };

      const stream: rcp.WriteStream = { write: onChunk };
      const dest: rcp.DownloadToStream = { kind: 'stream', stream: stream };
      req.destination = dest;

      const watcher: number = setInterval(() => {
        if (stopped) {
          return;
        }
        if (Date.now() - started >= t.windowMs) {
          stopped = true;
          endAt = Date.now();
          if (session !== undefined) {
            const s: rcp.Session = session;
            try {
              s.cancel(req);
            } catch (e) {
              // 忽略
            }
          }
        }
      }, 120);

      try {
        await session.fetch(req);
      } catch (e) {
        // 主动 cancel 会抛错，用 stopped 区分：窗口内自然结束也是 cancel 结束的
      } finally {
        clearInterval(watcher);
      }
      if (endAt === 0) {
        endAt = Date.now();
      }
      if (bytes <= 0) {
        return finish(false, '未读到数据');
      }
      return finish(true, '');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      const code: number = err !== undefined && err.code !== undefined ? err.code : -999;
      return finish(false, '测速失败 ' + code);
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
}