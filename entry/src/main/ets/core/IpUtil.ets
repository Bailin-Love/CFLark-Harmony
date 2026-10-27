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

  /** 在 IPv6 CIDR 内随机采样 n 个地址（严格保留前缀位，只随机前缀之后的位） */
  static sampleV6(cidr: string, n: number): string[] {
    const base: number[] = IpUtil.cidrV6ToBytes(cidr);
    const prefix: number = IpUtil.cidrV6Prefix(cidr);
    const out: string[] = [];
    if (base.length !== 16 || prefix < 0) {
      return out;
    }
    for (let i = 0; i < n; i++) {
      const b: number[] = base.slice(0);
      for (let bi = 0; bi < 16; bi++) {
        const start: number = bi * 8;
        if (start >= prefix) {
          b[bi] = Math.floor(Math.random() * 256);
        } else if (start + 8 > prefix) {
          const keep: number = prefix - start;
          const mask: number = (0xFF << (8 - keep)) & 0xFF;
          b[bi] = (b[bi] & mask) | (Math.floor(Math.random() * 256) & (0xFF ^ mask));
        }
      }
      out.push(IpUtil.bytesToV6(b));
    }
    return out;
  }

  /** IPv6 CIDR 内可用的 /48 块数量（前缀长于 48 时视为 1 个块） */
  static v6Block48Count(cidr: string): number {
    const prefix: number = IpUtil.cidrV6Prefix(cidr);
    if (prefix < 0) {
      return 0;
    }
    if (prefix >= 48) {
      return 1;
    }
    return Math.pow(2, 48 - prefix);
  }

  /**
   * 显式分层采样：每个 /48 块里只保留 1 个地址（不重复），
   * 不足 n 时先覆盖尽可能多的 /48，再回到随机主机位补齐。
   */
  static sampleV6Layered(cidr: string, n: number): string[] {
    const out: string[] = [];
    const base: number[] = IpUtil.cidrV6ToBytes(cidr);
    const prefix: number = IpUtil.cidrV6Prefix(cidr);
    if (base.length !== 16 || prefix < 0 || n <= 0) {
      return out;
    }
    const blocks: number = IpUtil.v6Block48Count(cidr);
    const picked: number[] = [];
    const used: Set<number> = new Set<number>();
    const target: number = Math.min(n, blocks);
    let guard: number = 0;
    while (picked.length < target && guard < target * 20 + 100) {
      guard++;
      const idx: number = Math.floor(Math.random() * blocks);
      if (used.has(idx)) {
        continue;
      }
      used.add(idx);
      picked.push(idx);
    }
    for (let k = 0; k < picked.length; k++) {
      const b: number[] = base.slice(0);
      const idx: number = picked[k];
      // prefix..48 位写入块索引
      if (prefix < 48) {
        for (let bit = prefix; bit < 48; bit++) {
          const byteIdx: number = Math.floor(bit / 8);
          const bitPos: number = 7 - (bit % 8);
          const v: number = Math.floor(idx / Math.pow(2, 47 - bit)) & 1;
          if (v === 1) {
            b[byteIdx] = b[byteIdx] | (1 << bitPos);
          } else {
            b[byteIdx] = b[byteIdx] & ((0xFF ^ (1 << bitPos)) & 0xFF);
          }
        }
      }
      // /48 之后随机（保证每个 /48 内地址不同，但仍在同一 /48）
      for (let byteIdx = 6; byteIdx < 16; byteIdx++) {
        b[byteIdx] = Math.floor(Math.random() * 256);
      }
      out.push(IpUtil.bytesToV6(b));
    }
    // 覆盖完所有 /48 后仍有剩余需求：再随机补齐
    let extra: number = n - out.length;
    while (extra > 0) {
      const b: number[] = base.slice(0);
      for (let bi = 0; bi < 16; bi++) {
        const start: number = bi * 8;
        if (start >= prefix) {
          b[bi] = Math.floor(Math.random() * 256);
        } else if (start + 8 > prefix) {
          const keep: number = prefix - start;
          const mask: number = (0xFF << (8 - keep)) & 0xFF;
          b[bi] = (b[bi] & mask) | (Math.floor(Math.random() * 256) & (0xFF ^ mask));
        }
      }
      out.push(IpUtil.bytesToV6(b));
      extra--;
    }
    return out;
  }

  /** IPv6 文本 -> 16 字节数组（非法返回空数组） */
  static ipv6ToBytes(s: string): number[] {
    const groups: string[] = IpUtil.expandV6(s);
    if (groups.length !== 8) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < 8; i++) {
      const v: number = parseInt(groups[i], 16);
      if (isNaN(v) || v < 0 || v > 0xFFFF) {
        return [];
      }
      out.push((v >> 8) & 0xFF);
      out.push(v & 0xFF);
    }
    return out;
  }

  /** 16 字节数组 -> IPv6 文本 */
  static bytesToV6(b: number[]): string {
    if (b.length !== 16) {
      return '';
    }
    const groups: string[] = [];
    for (let i = 0; i < 8; i++) {
      const v: number = ((b[i * 2] & 0xFF) << 8) | (b[i * 2 + 1] & 0xFF);
      groups.push(v.toString(16));
    }
    return groups.join(':');
  }

  /** IPv6 CIDR 的基础地址字节 */
  static cidrV6ToBytes(cidr: string): number[] {
    const idx: number = cidr.indexOf('/');
    const base: string = idx >= 0 ? cidr.substring(0, idx) : cidr;
    return IpUtil.ipv6ToBytes(base);
  }

  /** IPv6 CIDR 的前缀长度；非法返回 -1 */
  static cidrV6Prefix(cidr: string): number {
    const idx: number = cidr.indexOf('/');
    const p: number = idx >= 0 ? Number(cidr.substring(idx + 1)) : 128;
    if (isNaN(p) || p < 0 || p > 128) {
      return -1;
    }
    return p;
  }

  /** 按前缀比较两个 IPv6 字节数组 */
  static prefixEqualV6(a: number[], b: number[], prefix: number): boolean {
    const full: number = Math.floor(prefix / 8);
    for (let i = 0; i < full; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    const rem: number = prefix % 8;
    if (rem === 0) {
      return true;
    }
    const mask: number = (0xFF << (8 - rem)) & 0xFF;
    return (a[full] & mask) === (b[full] & mask);
  }

  /** IPv6 是否落在指定 CIDR 内（按真实前缀位比较，支持 /29 等非字节对齐前缀） */
  static inCidrV6(ip: string, cidr: string): boolean {
    const a: number[] = IpUtil.ipv6ToBytes(ip);
    const b: number[] = IpUtil.cidrV6ToBytes(cidr);
    const prefix: number = IpUtil.cidrV6Prefix(cidr);
    if (a.length !== 16 || b.length !== 16 || prefix < 0) {
      return false;
    }
    return IpUtil.prefixEqualV6(a, b, prefix);
  }

  /** IPv6 CIDR 的最后一个地址字节（用于边界测试） */
  static cidrV6Last(cidr: string): number[] {
    const b: number[] = IpUtil.cidrV6ToBytes(cidr);
    const prefix: number = IpUtil.cidrV6Prefix(cidr);
    if (b.length !== 16 || prefix < 0) {
      return [];
    }
    for (let bi = 0; bi < 16; bi++) {
      const start: number = bi * 8;
      if (start >= prefix) {
        b[bi] = 0xFF;
      } else if (start + 8 > prefix) {
        const keep: number = prefix - start;
        const mask: number = (0xFF << (8 - keep)) & 0xFF;
        b[bi] = (b[bi] & mask) | (0xFF ^ mask);
      }
    }
    return b;
  }

  /** 采样/前缀自检：返回可直接打印的检查行（不依赖网络） */
  static selfCheckV6(): string[] {
    const lines: string[] = [];
    const cases: string[] = ['2400:cb00::/32', '2606:4700::/32', '2a06:98c0::/29'];
    for (let i = 0; i < cases.length; i++) {
      const cidr: string = cases[i];
      const base: number[] = IpUtil.cidrV6ToBytes(cidr);
      const prefix: number = IpUtil.cidrV6Prefix(cidr);
      if (base.length !== 16 || prefix < 0) {
        lines.push('[采样自检] ' + cidr + ' 解析失败 FAIL');
        continue;
      }
      const baseText: string = IpUtil.bytesToV6(base);
      const samples: string[] = IpUtil.sampleV6(cidr, 20);
      let bad: number = 0;
      for (let k = 0; k < samples.length; k++) {
        if (!IpUtil.inCidrV6(samples[k], cidr)) {
          bad++;
        }
      }
      const last: number[] = IpUtil.cidrV6Last(cidr);
      const lastText: string = IpUtil.bytesToV6(last);
      const pass: boolean = bad === 0 && IpUtil.inCidrV6(baseText, cidr) && IpUtil.inCidrV6(lastText, cidr);
      lines.push('[采样自检] ' + cidr + '  prefix=' + prefix.toString());
      lines.push('  基准 base=' + baseText + '  baseInCidr=' + IpUtil.inCidrV6(baseText, cidr).toString());
      lines.push('  样本数=' + samples.length.toString() + '  样本越界=' + bad.toString());
      lines.push('  末地址 last=' + lastText + '  lastInCidr=' + IpUtil.inCidrV6(lastText, cidr).toString());
      lines.push('  结果=' + (pass ? 'PASS' : 'FAIL'));
    }
    const boundA: string = '2a06:98c7:ffff:ffff:ffff:ffff:ffff:ffff';
    const boundB: string = '2a06:98c8::';
    lines.push('[边界] ' + boundA + ' 属于 2a06:98c0::/29 = ' + IpUtil.inCidrV6(boundA, '2a06:98c0::/29').toString() + '（应为 true）');
    lines.push('[边界] ' + boundB + ' 属于 2a06:98c0::/29 = ' + IpUtil.inCidrV6(boundB, '2a06:98c0::/29').toString() + '（应为 false）');
    return lines;
  }

  /** 把 IPv6 简写展开为 8 组（正确处理开头/结尾/中间的 ::；不支持内嵌 IPv4） */
  static expandV6(ip: string): string[] {
    const s: string = ip.trim();
    if (s.indexOf('.') >= 0) {
      return [];
    }
    const out: string[] = [];
    const dbl: number = s.indexOf('::');
    if (dbl < 0) {
      const all: string[] = s.split(':');
      for (let i = 0; i < all.length; i++) {
        out.push(all[i]);
      }
    } else {
      const headText: string = s.substring(0, dbl);
      const tailText: string = s.substring(dbl + 2);
      const head: string[] = headText.length > 0 ? headText.split(':') : [];
      const tail: string[] = tailText.length > 0 ? tailText.split(':') : [];
      for (let i = 0; i < head.length; i++) {
        out.push(head[i]);
      }
      const fill: number = 8 - head.length - tail.length;
      if (fill < 0) {
        return [];
      }
      for (let i = 0; i < fill; i++) {
        out.push('0');
      }
      for (let i = 0; i < tail.length; i++) {
        out.push(tail[i]);
      }
    }
    if (out.length !== 8) {
      return [];
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

  /** 判断 IPv6 是否落在 Cloudflare 官方段内（按真实前缀位比较，支持 /29） */
  static isCfV6(ip: string): boolean {
    for (let i = 0; i < CF_IPV6_RANGES.length; i++) {
      if (IpUtil.inCidrV6(ip, CF_IPV6_RANGES[i])) {
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

