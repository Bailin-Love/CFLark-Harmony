/**
 * 应用元信息与版本比较工具。
 *
 * 仓库地址与版本号均取自项目真实信息：
 *  - 仓库：https://github.com/Bailin-Love/CFLark-Harmony
 *  - 版本：AppScope/app.json5 的 versionName / versionCode
 */
export class AppMeta {
  static readonly REPO_OWNER: string = 'Bailin-Love';
  static readonly REPO_NAME: string = 'CFLark-Harmony';
  static readonly REPO_URL: string = 'https://github.com/Bailin-Love/CFLark-Harmony';
  static readonly RELEASES_URL: string = 'https://github.com/Bailin-Love/CFLark-Harmony/releases';
  static readonly LATEST_RELEASE_URL: string = 'https://github.com/Bailin-Love/CFLark-Harmony/releases/latest';
  /** 官方 Releases 列表接口（无需鉴权，注意匿名限流） */
  static readonly RELEASES_API: string =
    'https://api.github.com/repos/Bailin-Love/CFLark-Harmony/releases?per_page=10';

  /** 去掉前缀 v/V，去掉 +build 与 -prerelease 后的主体部分 */
  static base(v: string): string {
    let s: string = v.trim();
    if (s.length > 0 && (s.charAt(0) === 'v' || s.charAt(0) === 'V')) {
      s = s.substring(1);
    }
    const plus: number = s.indexOf('+');
    if (plus > 0) {
      s = s.substring(0, plus);
    }
    const dash: number = s.indexOf('-');
    if (dash > 0) {
      s = s.substring(0, dash);
    }
    return s;
  }

  static isPrerelease(v: string): boolean {
    return v.indexOf('-') > 0;
  }

  /**
   * 语义化版本比较：a > b 返回 1，a < b 返回 -1，相等返回 0。
   * 数字段逐段比较（1.10.0 > 1.9.9），缺失段按 0 处理；
   * 同主体时预发布版本小于正式版本（1.5.0-beta < 1.5.0）。
   */
  static compareVersion(a: string, b: string): number {
    const pa: string[] = AppMeta.base(a).split('.');
    const pb: string[] = AppMeta.base(b).split('.');
    const n: number = Math.max(pa.length, pb.length);
    for (let i = 0; i < n; i++) {
      const sa: string = i < pa.length ? pa[i].trim() : '0';
      const sb: string = i < pb.length ? pb[i].trim() : '0';
      const na: number = AppMeta.leadingNumber(sa);
      const nb: number = AppMeta.leadingNumber(sb);
      if (na > nb) {
        return 1;
      }
      if (na < nb) {
        return -1;
      }
    }
    const preA: boolean = AppMeta.isPrerelease(a);
    const preB: boolean = AppMeta.isPrerelease(b);
    if (preA && !preB) {
      return -1;
    }
    if (!preA && preB) {
      return 1;
    }
    return 0;
  }

  private static leadingNumber(s: string): number {
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      if (c >= '0' && c <= '9') {
        out += c;
      } else {
        break;
      }
    }
    if (out.length === 0) {
      return 0;
    }
    return Number(out);
  }

  /** 展示用：确保带 v 前缀 */
  static display(v: string): string {
    const t: string = v.trim();
    if (t.length === 0) {
      return 'v?';
    }
    const c: string = t.charAt(0);
    return (c === 'v' || c === 'V') ? t : ('v' + t);
  }
}
