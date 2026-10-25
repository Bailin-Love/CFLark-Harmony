/**
 * IP 地址工具：IPv4 / IPv6 解析、CIDR 采样、Cloudflare 段判定
 */

/** IPv4 CIDR 解析结果 */
export interface CidrV4 {
  /** 起始整数 */
  start: number;
  /** 结束整数 */
  end: number;
  /** 地址数量 */
  count: number;
}

/** Cloudflare 官方 IPv4 段（来源 https://www.cloudflare.com/ips-v4） */
export const CF_IPV4_RANGES: string[] = [
  '173.245.48.0/20',
  '103.21.244.0/22',
  '103.22.200.0/22',
  '103.31.4.0/22',
  '141.101.64.0/18',
  '108.162.192.0/18',
  '190.93.240.0/20',
  '188.114.96.0/20',
  '197.234.240.0/22',
  '198.41.128.0/17',
  '162.158.0.0/15',
  '104.16.0.0/13',
  '172.64.0.0/13',
  '131.0.72.0/22'
];

/** Cloudflare 官方 IPv6 段（来源 https://www.cloudflare.com/ips-v6） */
export const CF_IPV6_RANGES: string[] = [
  '2400:cb00::/32',
  '2606:4700::/32',
  '2803:f800::/32',
  '2405:b500::/32',
  '2405:8100::/32',
  '2a06:98c0::/29',
  '2c0f:f248::/32'
];

export class IpUtil {
  /** IPv4 地址转 32 位整数 */
  static ipv4ToInt(ip: string): number {
    const parts: string[] = ip.split('.');
    if (parts.length !== 4) {
      return -1;
    }
    let n: number = 0;
    for (let i = 0; i < 4; i++) {
      const v: number = Number(parts[i]);
      if (isNaN(v) || v < 0 || v > 255) {
        return -1;
      }
      n = n * 256 + v;
    }
    return n >>> 0;
  }

  /** 32 位整数转 IPv4 */
  static intToIpv4(n: number): string {
    const a: number = (n >>> 24) & 255;
    const b: number = (n >>> 16) & 255;
    const c: number = (n >>> 8) & 255;
    const d: number = n & 255;
    return a.toString() + '.' + b.toString() + '.' + c.toString() + '.' + d.toString();
  }

  /** 判断字符串是否为 IPv4 */
  static isV4(ip: string): boolean {
    return ip.indexOf(':') < 0 && ip.split('.').length === 4;
  }

  /** 判断字符串是否为 IPv6 */
  static isV6(ip: string): boolean {
    return ip.indexOf(':') >= 0;
  }

  /** 解析 IPv4 CIDR */
  static parseCidrV4(cidr: string): CidrV4 {
    const idx: number = cidr.indexOf('/');
    const ip: string = idx >= 0 ? cidr.substring(0, idx) : cidr;
    const prefix: number = idx >= 0 ? Number(cidr.substring(idx + 1)) : 32;
    const ipInt: number = IpUtil.ipv4ToInt(ip);
    // 掩码（注意 JS 位运算是有符号 32 位，用 >>> 保证无符号）
    const mask: number = prefix === 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) >>> 0;
    const start: number = (ipInt & mask) >>> 0;
    const count: number = Math.pow(2, 32 - prefix);
    const end: number = count >= 4294967296 ? 0xFFFFFFFF : (start + count - 1) >>> 0;
    const result: CidrV4 = { start: start, end: end, count: count };
    return result;
  }

  /**
   * 在 IPv4 CIDR 内随机采样 n 个地址
   * 避免 .0 与广播地址
   */
  static sampleV4(cidr: string, n: number): string[] {
    const r: CidrV4 = IpUtil.parseCidrV4(cidr);
    if (r.count <= 0) {
      return [];
    }
    const out: string[] = [];
    const usable: number = r.count > 2 ? r.count - 2 : r.count;
    for (let i = 0; i < n; i++) {
      const offset: number = Math.floor(Math.random() * usable) + (r.count > 2 ? 1 : 0);
      out.push(IpUtil.intToIpv4((r.start + offset) >>> 0));
    }
    return out;
  }

  /** 在 IPv6 CIDR 内随机采样 n 个地址（保留前缀，随机后 64 位） */
  static sampleV6(cidr: string, n: number): string[] {
    const idx: number = cidr.indexOf('/');
    const base: string = idx >= 0 ? cidr.substring(0, idx) : cidr;
    const prefix: number = idx >= 0 ? Number(cidr.substring(idx + 1)) : 128;
    // 只处理 /32 及以内的常见 CF 段
    const groups: string[] = IpUtil.expandV6(base);
    const out: string[] = [];
    for (let i = 0; i < n; i++) {
      const g: string[] = groups.slice(0);
      const suffixGroups: number = Math.floor((128 - prefix) / 16);
      for (let k = 0; k < suffixGroups; k++) {
        const pos: number = 7 - k;
        if (pos >= 0) {
          g[pos] = IpUtil.randHex16();
        }
      }
      out.push(g.join(':'));
    }
    return out;
  }

  /** 把 IPv6 简写展开为 8 组 */
  static expandV6(ip: string): string[] {
    const parts: string[] = ip.split(':');
    const out: string[] = [];
    let emptyIdx: number = -1;
    for (let i = 0; i < parts.length; i++) {
      if (parts[i] === '') {
        emptyIdx = i;
        break;
      }
    }
    if (emptyIdx >= 0) {
      const head: string[] = parts.slice(0, emptyIdx);
      const tail: string[] = parts.slice(emptyIdx + 1);
      for (let i = 0; i < head.length; i++) {
        out.push(head[i]);
      }
      const fill: number = 8 - head.length - tail.length;
      for (let i = 0; i < fill; i++) {
        out.push('0');
      }
      for (let i = 0; i < tail.length; i++) {
        out.push(tail[i]);
      }
    } else {
      for (let i = 0; i < parts.length; i++) {
        out.push(parts[i]);
      }
      while (out.length < 8) {
        out.push('0');
      }
    }
    return out;
  }

  /** 随机 16 位十六进制串 */
  static randHex16(): string {
    let s: string = '';
    for (let i = 0; i < 4; i++) {
      s += Math.floor(Math.random() * 16).toString(16);
    }
    return s;
  }

  /** 判断 IPv4 是否落在 Cloudflare 官方段内 */
  static isCfV4(ip: string): boolean {
    const n: number = IpUtil.ipv4ToInt(ip);
    if (n < 0) {
      return false;
    }
    for (let i = 0; i < CF_IPV4_RANGES.length; i++) {
      const r: CidrV4 = IpUtil.parseCidrV4(CF_IPV4_RANGES[i]);
      if (n >= r.start && n <= r.end) {
        return true;
      }
    }
    return false;
  }

  /** 判断 IPv6 是否落在 Cloudflare 官方段内（按前缀比较） */
  static isCfV6(ip: string): boolean {
    const g: string[] = IpUtil.expandV6(ip);
    for (let i = 0; i < CF_IPV6_RANGES.length; i++) {
      const idx: number = CF_IPV6_RANGES[i].indexOf('/');
      const base: string = CF_IPV6_RANGES[i].substring(0, idx);
      const bg: string[] = IpUtil.expandV6(base);
      if (bg[0].toLowerCase() === g[0].toLowerCase() && bg[1].toLowerCase() === g[1].toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  /** 判断任意 IP 是否为 Cloudflare */
  static isCloudflareIp(ip: string): boolean {
    if (IpUtil.isV6(ip)) {
      return IpUtil.isCfV6(ip);
    }
    return IpUtil.isCfV4(ip);
  }

  /** 校验用户输入的 IP:port 形式，返回解析结果 */
  static parseHostPort(input: string, defaultPort: number): string {
    const s: string = input.trim();
    if (s.length === 0) {
      return '';
    }
    // IPv6 带端口形式 [2606::1]:443
    if (s.charAt(0) === '[') {
      return s;
    }
    return s;
  }

  /** 打乱数组（Fisher-Yates） */
  static shuffle<T>(arr: T[]): T[] {
    const a: T[] = arr.slice(0);
    for (let i = a.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const t: T = a[i];
      a[i] = a[j];
      a[j] = t;
    }
    return a;
  }
}
