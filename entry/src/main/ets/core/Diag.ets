/**
 * CFLark 网络诊断（IPv6 专用）
 *  - 读取默认网络的地址/路由/DNS（仅诊断，不修改网络）
 *  - 对固定 IPv6 地址做单连接 TCP 自检（3000ms）
 *  - 对每个 Cloudflare IPv6 段各取 1 个随机地址自检（3000ms，顺序执行）
 *  - 调用 IpUtil.selfCheckV6() 校验采样与前缀判定
 */
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TcpProbe, TcpResult } from './Probe';
import { IpUtil, CF_IPV6_RANGES, CF_IPV4_RANGES } from './IpUtil';

/** 一个 TCP 自检目标 */
export interface DiagTcpTarget {
  label: string;
  ip: string;
  port: number;
  timeoutMs: number;
}

/** 一条 TCP 自检结果（展开 TcpResult 便于打印） */
export interface DiagTcpLine {
  label: string;
  ip: string;
  port: number;
  ok: boolean;
  rttMs: number;
  elapsedMs: number;
  family: number;
  stage: string;
  rawCode: number;
  errMsg: string;
}

export class Diag {
  static errText(e: Object | undefined | null): string {
    if (e === undefined || e === null) {
      return '未知错误';
    }
    try {
      const be: BusinessError = e as BusinessError;
      const code: string = be.code === undefined || be.code === null ? '?' : be.code.toString();
      const msg: string = be.message === undefined || be.message === null ? '' : be.message;
      return 'code=' + code + ' msg=' + msg;
    } catch (err) {
      return '错误对象解析失败';
    }
  }

  static fmtTcp(l: DiagTcpLine): string {
    const addr: string = l.ip.indexOf(':') >= 0 ? ('[' + l.ip + ']') : l.ip;
    const head: string = '[' + l.label + '] ' + addr + ':' + l.port.toString() + ' family=' + l.family.toString();
    if (l.ok) {
      return head + ' OK rtt=' + l.rttMs.toString() + 'ms elapsed=' + l.elapsedMs.toString() + 'ms';
    }
    return head + ' FAIL stage=' + l.stage + ' code=' + l.rawCode.toString() +
      (l.errMsg.length > 0 ? (' msg=' + l.errMsg) : '') + ' elapsed=' + l.elapsedMs.toString() + 'ms';
  }

  /** 默认网络信息（只读） */
  static netInfo(): string[] {
    const lines: string[] = [];
    try {
      const has: boolean = connection.hasDefaultNetSync();
      lines.push('[网络] hasDefaultNet=' + has.toString());
      if (!has) {
        return lines;
      }
      const net: connection.NetHandle = connection.getDefaultNetSync();
      lines.push('[网络] netId=' + net.netId.toString());
      const p: connection.ConnectionProperties = connection.getConnectionPropertiesSync(net);
      const iface: string = p.interfaceName === undefined ? '?' : p.interfaceName;
      lines.push('[网络] iface=' + iface + ' mtu=' + p.mtu.toString());
      const v6Flag: boolean | undefined = p.isIPv6LinkValid;
      const v4Flag: boolean | undefined = p.isIPv4LinkValid;
      lines.push('[网络] isIPv6LinkValid=' + (v6Flag === undefined ? 'n/a' : v6Flag.toString()) +
        ' isIPv4LinkValid=' + (v4Flag === undefined ? 'n/a' : v4Flag.toString()));

      let v6AddrCount: number = 0;
      const addrs: connection.LinkAddress[] = p.linkAddresses;
      if (addrs !== undefined) {
        lines.push('[网络] linkAddresses=' + addrs.length.toString());
        for (let i = 0; i < addrs.length; i++) {
          const la: connection.LinkAddress = addrs[i];
          const laf: number | undefined = la.address.family;
          const f: number = laf === undefined ? -1 : laf;
          if (f === 2) {
            v6AddrCount++;
          }
          lines.push('  addr family=' + f.toString() + ' ' + la.address.address + '/' + la.prefixLength.toString());
        }
      }

      let v6DefaultRoute: number = 0;
      const routes: connection.RouteInfo[] = p.routes;
      if (routes !== undefined) {
        for (let i = 0; i < routes.length; i++) {
          const rt: connection.RouteInfo = routes[i];
          const df: number | undefined = rt.destination.address.family;
          const destFamily: number = df === undefined ? -1 : df;
          if (rt.isDefaultRoute && destFamily === 2) {
            v6DefaultRoute++;
          }
        }
        lines.push('[网络] routes=' + routes.length.toString() + ' IPv6默认路由=' + v6DefaultRoute.toString());
      }

      let v6Dns: number = 0;
      const dns: connection.NetAddress[] = p.dnses;
      if (dns !== undefined) {
        for (let i = 0; i < dns.length; i++) {
          const dfm: number | undefined = dns[i].family;
          const f: number = dfm === undefined ? -1 : dfm;
          if (f === 2) {
            v6Dns++;
          }
        }
        lines.push('[网络] DNS=' + dns.length.toString() + ' IPv6DNS=' + v6Dns.toString());
      }
      lines.push('[网络] IPv6地址数=' + v6AddrCount.toString());
    } catch (e) {
      lines.push('[网络] 查询异常 ' + Diag.errText(e as Object));
    }
    return lines;
  }

  /** 顺序执行 TCP 自检（并发 1） */
  static async tcpCheck(targets: DiagTcpTarget[]): Promise<DiagTcpLine[]> {
    const out: DiagTcpLine[] = [];
    for (let i = 0; i < targets.length; i++) {
      const t: DiagTcpTarget = targets[i];
      const r: TcpResult = await TcpProbe.pingOnce(t.ip, t.port, t.timeoutMs);
      const line: DiagTcpLine = {
        label: t.label, ip: t.ip, port: t.port,
        ok: r.ok, rttMs: r.rttMs, elapsedMs: r.elapsedMs,
        family: r.family, stage: r.stage,
        rawCode: r.rawErrorCode, errMsg: r.errorMessage
      };
      out.push(line);
    }
    return out;
  }

  /** IPv4 自检：默认网络 + 固定 IPv4 + 各段随机 IPv4 */
  static async runV4(): Promise<string> {
    const lines: string[] = [];
    lines.push('=== CFLark IPv4 诊断 ===');
    lines.push('时间：' + new Date().toLocaleString());
    lines.push('说明：自检使用 3000ms 超时、顺序执行（并发 1），不会修改扫描配置。');
    lines.push('');
    lines.push('--- 1. 默认网络信息 ---');
    const netLines: string[] = Diag.netInfo();
    for (let i = 0; i < netLines.length; i++) {
      lines.push(netLines[i]);
    }
    lines.push('');
    lines.push('--- 2. 固定 IPv4 地址 TCP 自检（3000ms）---');
    const fixedTargets: DiagTcpTarget[] = [
      { label: '固定1', ip: '104.16.132.229', port: 443, timeoutMs: 3000 },
      { label: '固定2', ip: '1.1.1.1', port: 443, timeoutMs: 3000 }
    ];
    const fixedLines: DiagTcpLine[] = await Diag.tcpCheck(fixedTargets);
    let fixedOk: number = 0;
    for (let i = 0; i < fixedLines.length; i++) {
      lines.push(Diag.fmtTcp(fixedLines[i]));
      if (fixedLines[i].ok) {
        fixedOk++;
      }
    }
    lines.push('');
    lines.push('--- 3. 各段随机 IPv4 地址 TCP 自检（每段 1 个，3000ms）---');
    const randTargets: DiagTcpTarget[] = [];
    for (let i = 0; i < CF_IPV4_RANGES.length; i++) {
      const ips: string[] = IpUtil.sampleV4(CF_IPV4_RANGES[i], 1);
      if (ips.length > 0) {
        randTargets.push({ label: '随机' + (i + 1).toString(), ip: ips[0], port: 443, timeoutMs: 3000 });
      }
    }
    const randLines: DiagTcpLine[] = await Diag.tcpCheck(randTargets);
    let randOk: number = 0;
    for (let i = 0; i < randLines.length; i++) {
      lines.push(Diag.fmtTcp(randLines[i]));
      if (randLines[i].ok) {
        randOk++;
      }
    }
    lines.push('');
    lines.push('--- 4. 初步判断（依据本次结果，不代表最终结论）---');
    if (fixedOk === 0) {
      lines.push('固定 IPv4 全部失败：先看第 1 节是否有 IPv4 地址/默认路由/DNS，再看错误 stage/code。');
      lines.push('若本机 IPv4 网络正常，则更可能是端口/防火墙/目标侧问题；可换 443 与 80 再试。');
    } else if (randOk === 0) {
      lines.push('固定 IPv4 可达，但随机 IPv4 全部失败：多为目标随机地址不响应或中间网络过滤，不代表 App 的 IPv4 socket 不可用。');
    } else {
      lines.push('固定与随机 IPv4 均可连（随机成功 ' + randOk.toString() + '/' + randLines.length.toString() + '）。');
      lines.push('如正式扫描仍 0 通过，优先核对「端口 / 延迟上限 / 并发」等参数。');
    }
    return lines.join('\n');
  }

  /** 生成完整 IPv6 诊断文本 */
  static async run(): Promise<string> {
    const lines: string[] = [];
    lines.push('=== CFLark IPv6 诊断 ===');
    lines.push('时间：' + new Date().toLocaleString());
    lines.push('说明：自检使用 3000ms 超时、顺序执行（并发 1），不会修改扫描配置。');
    lines.push('');
    lines.push('--- 1. 默认网络信息 ---');
    const netLines: string[] = Diag.netInfo();
    for (let i = 0; i < netLines.length; i++) {
      lines.push(netLines[i]);
    }
    lines.push('');
    lines.push('--- 2. 固定 IPv6 地址 TCP 自检（3000ms）---');
    const fixedTargets: DiagTcpTarget[] = [
      { label: '固定A', ip: '2606:4700:7::da', port: 443, timeoutMs: 3000 },
      { label: '固定B', ip: '2a06:98c1:58::da', port: 443, timeoutMs: 3000 }
    ];
    const fixedLines: DiagTcpLine[] = await Diag.tcpCheck(fixedTargets);
    let fixedOk: number = 0;
    for (let i = 0; i < fixedLines.length; i++) {
      lines.push(Diag.fmtTcp(fixedLines[i]));
      if (fixedLines[i].ok) {
        fixedOk++;
      }
    }
    lines.push('');
    lines.push('--- 3. 各段随机地址 TCP 自检（每段 1 个，3000ms）---');
    const randTargets: DiagTcpTarget[] = [];
    for (let i = 0; i < CF_IPV6_RANGES.length; i++) {
      const ips: string[] = IpUtil.sampleV6(CF_IPV6_RANGES[i], 1);
      if (ips.length > 0) {
        randTargets.push({ label: '随机' + (i + 1).toString(), ip: ips[0], port: 443, timeoutMs: 3000 });
      }
    }
    const randLines: DiagTcpLine[] = await Diag.tcpCheck(randTargets);
    let randOk: number = 0;
    for (let i = 0; i < randLines.length; i++) {
      lines.push(Diag.fmtTcp(randLines[i]));
      if (randLines[i].ok) {
        randOk++;
      }
    }
    lines.push('');
    lines.push('--- 3b. 固定地址同 /48 邻居 TCP 自检（3000ms）---');
    const nearTargets: DiagTcpTarget[] = [
      { label: '近邻A1', ip: '2606:4700:7:0:1:2:3:4', port: 443, timeoutMs: 3000 },
      { label: '近邻A2', ip: '2606:4700:7:0:aaaa:bbbb:cccc:dddd', port: 443, timeoutMs: 3000 },
      { label: '近邻B1', ip: '2a06:98c1:58:0:1:2:3:4', port: 443, timeoutMs: 3000 },
      { label: '近邻B2', ip: '2a06:98c1:58:0:aaaa:bbbb:cccc:dddd', port: 443, timeoutMs: 3000 }
    ];
    const nearLines: DiagTcpLine[] = await Diag.tcpCheck(nearTargets);
    let nearOk: number = 0;
    for (let i = 0; i < nearLines.length; i++) {
      lines.push(Diag.fmtTcp(nearLines[i]));
      if (nearLines[i].ok) {
        nearOk++;
      }
    }
    lines.push('');
    lines.push('--- 4. 采样与前缀自检 ---');
    const selfLines: string[] = IpUtil.selfCheckV6();
    for (let i = 0; i < selfLines.length; i++) {
      lines.push(selfLines[i]);
    }
    lines.push('');
    lines.push('--- 5. 初步判断（依据本次结果，不代表最终结论）---');
    if (fixedOk === 0) {
      lines.push('固定地址全部失败：优先检查第 1 节是否有 IPv6 地址/默认路由，以及错误 stage/code。');
      lines.push('若网络信息里没有 IPv6 地址或默认路由 → 运营商/系统未提供 IPv6；若有地址路由仍失败 → 结合错误码继续定位。');
    } else if (randOk === 0) {
      lines.push('固定地址可达，但随机采样全部失败：更可能是候选地址可达性/运营商路由/目标响应率问题，而不是 App 不支持 IPv6。');
      if (nearOk > 0) {
        lines.push('补充：固定地址的同 /48 邻居 ' + nearOk.toString() + '/' + nearLines.length.toString() + ' 可连 —— 说明随机采样 /32 内地址不可行，应改用「实际服务前缀（AAAA 记录）」采样。');
      } else {
        lines.push('补充：固定地址的同 /48 邻居也全部不可连 —— 只有固定服务地址可用，应直接用 AAAA 解析出的服务地址。');
      }
    } else {
      const slow: boolean = fixedLines[0].ok && fixedLines[0].rttMs > 220;
      lines.push('固定与随机地址均可连（随机成功 ' + randOk.toString() + '/' + randLines.length.toString() + '）。');
      if (slow) {
        lines.push('注意固定地址 RTT=' + fixedLines[0].rttMs.toString() + 'ms 高于当前延迟门槛 220ms，正式扫描可能因门槛过严而 0 通过。');
      }
      lines.push('建议再回扫描页做一次 IPv6 正式扫描，对比「通过数 / 超时数 / 延迟超限数」。');
    }
    return lines.join('\n');
  }
}


