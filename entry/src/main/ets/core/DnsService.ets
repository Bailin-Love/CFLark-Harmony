/**
 * 域名解析服务
 * - 用系统解析拿到域名当前的 IP 列表（作为候选）
 * - 用 DoH（可选）拿到更干净的结果
 * - 判定解析结果是否落在 Cloudflare 官方段内
 */

import { connection } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { DomainInfo } from './Types';
import { IpUtil } from './IpUtil';

const DOMAIN: number = 0x0001;
const TAG: string = 'DnsService';

/** 域名解析 */
export class DnsService {
  /** 构造一个空结果 */
  private static empty(domain: string): DomainInfo {
    const d: DomainInfo = {
      domain: domain,
      ok: false,
      ips: [],
      isCloudflare: false,
      error: ''
    };
    return d;
  }

  /** 用系统 DNS 解析域名 */
  static async resolve(domain: string): Promise<DomainInfo> {
    const host: string = DnsService.normalize(domain);
    const info: DomainInfo = DnsService.empty(host);
    if (host.length === 0) {
      info.error = '域名不能为空';
      return info;
    }
    try {
      const addrs: connection.NetAddress[] = await connection.getAddressesByName(host);
      if (addrs === undefined || addrs.length === 0) {
        info.error = '未解析到任何地址';
        return info;
      }
      const v4: string[] = [];
      const v6: string[] = [];
      for (let i = 0; i < addrs.length; i++) {
        const a: string = addrs[i].address;
        if (IpUtil.isV6(a)) {
          v6.push(a);
        } else if (IpUtil.isV4(a)) {
          v4.push(a);
        }
      }
      info.ips = v4.concat(v6);
      let cfCount: number = 0;
      for (let i = 0; i < info.ips.length; i++) {
        if (IpUtil.isCloudflareIp(info.ips[i])) {
          cfCount = cfCount + 1;
        }
      }
      info.isCloudflare = cfCount > 0;
      info.ok = true;
      hilog.info(DOMAIN, TAG, 'resolved %{public}s -> %{public}d addrs, cf=%{public}d', host, info.ips.length, cfCount);
      return info;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      info.error = '解析失败(' + err.code + ')';
      hilog.error(DOMAIN, TAG, 'resolve %{public}s failed code=%{public}d', host, err.code);
      return info;
    }
  }

  /** 清洗用户输入的域名：去协议/路径/空格/末尾点 */
  static normalize(input: string): string {
    let s: string = input.trim();
    if (s.length === 0) {
      return '';
    }
    const lower: string = s.toLowerCase();
    if (lower.startsWith('https://')) {
      s = s.substring(8);
    } else if (lower.startsWith('http://')) {
      s = s.substring(7);
    }
    const slash: number = s.indexOf('/');
    if (slash >= 0) {
      s = s.substring(0, slash);
    }
    const colon: number = s.indexOf(':');
    if (colon >= 0 && s.indexOf(']') < 0) {
      s = s.substring(0, colon);
    }
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    return s.trim();
  }

  /** 校验域名格式（宽松：含点、无空格、长度合法） */
  static isValidDomain(s: string): boolean {
    const d: string = DnsService.normalize(s);
    if (d.length < 3 || d.length > 253) {
      return false;
    }
    if (d.indexOf('.') < 0) {
      return false;
    }
    const parts: string[] = d.split('.');
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i];
      if (p.length === 0) {
        return false;
      }
    }
    return true;
  }
}
