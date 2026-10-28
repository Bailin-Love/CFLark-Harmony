import { http } from '@kit.NetworkKit';
import { AppMeta } from './AppMeta';

/** 更新检查状态 */
export enum UpdateStatus {
  IDLE = 0,
  CHECKING = 1,
  UP_TO_DATE = 2,
  UPDATE_AVAILABLE = 3,
  NO_RELEASE = 4,
  NETWORK_ERROR = 5,
  RATE_LIMITED = 6,
  PARSE_ERROR = 7
}

/** GitHub Release 的资源文件（只保留判断发布包需要的字段） */
export interface ReleaseAssetDto {
  name?: string;
  size?: number;
  browser_download_url?: string;
}

/** GitHub Release 原始结构（只声明用到的字段） */
export interface ReleaseDto {
  tag_name?: string;
  name?: string;
  body?: string;
  published_at?: string;
  html_url?: string;
  draft?: boolean;
  prerelease?: boolean;
  assets?: ReleaseAssetDto[];
}

/** 归一化后的发布信息 */
export interface ReleaseInfo {
  /** 归一化版本号（去掉 v 前缀），如 1.5.0 */
  version: string;
  /** 原始 tag，如 v1.5.0 */
  tag: string;
  title: string;
  publishedAt: string;
  notes: string;
  htmlUrl: string;
  /** Releases 里是否包含鸿蒙安装包（.hap / .app.hap） */
  hasHarmonyPackage: boolean;
  /** 是否来自 HTML 回退通道（此时无更新说明与资源信息） */
  fromFallback: boolean;
}

export interface UpdateCheckResult {
  status: UpdateStatus;
  current: string;
  latest: ReleaseInfo | null;
  /** 已排序（新→旧）的全部正式发布，用于更新日志兜底 */
  releases: ReleaseInfo[];
  /** 面向用户的简短原因（已本地化由调用方决定展示文案，此处给技术原因） */
  detail: string;
}

/**
 * 基于 GitHub Releases 的版本检查。
 *
 * 设计要点：
 * 1. 只使用公开、无需鉴权的接口；匿名调用有频率限制（403/429），会被识别为 RATE_LIMITED。
 * 2. 接口不可用时回退到 `releases/latest` 的 HTTP 302 跳转目标（无频率限制），
 *    仅能拿到版本号，拿不到更新说明与资源信息。
 * 3. 任何失败都不会被当成「已是最新版本」。
 * 4. 只读取与比较版本，不做下载与安装。
 */
export class UpdateChecker {
  private static readonly TIMEOUT_MS: number = 9000;

  static async check(currentVersion: string): Promise<UpdateCheckResult> {
    const api: UpdateCheckResult | null = await UpdateChecker.fromApi(currentVersion);
    if (api !== null && api.status !== UpdateStatus.NETWORK_ERROR && api.status !== UpdateStatus.PARSE_ERROR) {
      return api;
    }
    const fb: UpdateCheckResult = await UpdateChecker.fromRedirect(currentVersion);
    if (fb.status === UpdateStatus.NO_RELEASE) {
      // 接口失败且回退也拿不到版本：保留更具体的接口失败原因
      if (api !== null) {
        return api;
      }
    }
    return fb;
  }

  private static async fromApi(currentVersion: string): Promise<UpdateCheckResult | null> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(AppMeta.RELEASES_API, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'CFLark-Harmony-App',
          'Accept': 'application/vnd.github+json'
        },
        connectTimeout: UpdateChecker.TIMEOUT_MS,
        readTimeout: UpdateChecker.TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode === 403 || resp.responseCode === 429) {
        return {
          status: UpdateStatus.RATE_LIMITED, current: currentVersion, latest: null, releases: [],
          detail: 'HTTP ' + resp.responseCode.toString() + ' (rate limited)'
        };
      }
      if (resp.responseCode !== 200) {
        return {
          status: UpdateStatus.NETWORK_ERROR, current: currentVersion, latest: null, releases: [],
          detail: 'HTTP ' + resp.responseCode.toString()
        };
      }
      const body: string = typeof resp.result === 'string' ? resp.result as string : '';
      if (body.length === 0) {
        return {
          status: UpdateStatus.PARSE_ERROR, current: currentVersion, latest: null, releases: [],
          detail: 'empty body'
        };
      }
      let list: ReleaseDto[] = [];
      try {
        list = JSON.parse(body) as ReleaseDto[];
      } catch (e) {
        return {
          status: UpdateStatus.PARSE_ERROR, current: currentVersion, latest: null, releases: [],
          detail: 'invalid json'
        };
      }
      if (list.length === 0) {
        return {
          status: UpdateStatus.NO_RELEASE, current: currentVersion, latest: null, releases: [],
          detail: 'no release'
        };
      }
      const releases: ReleaseInfo[] = [];
      for (let i = 0; i < list.length; i++) {
        const d: ReleaseDto = list[i];
        if (d.draft === true || d.prerelease === true) {
          continue;
        }
        const tag: string = d.tag_name === undefined ? '' : d.tag_name;
        if (tag.length === 0) {
          continue;
        }
        releases.push(UpdateChecker.toInfo(d, tag));
      }
      if (releases.length === 0) {
        return {
          status: UpdateStatus.NO_RELEASE, current: currentVersion, latest: null, releases: [],
          detail: 'only prerelease/draft'
        };
      }
      releases.sort((a: ReleaseInfo, b: ReleaseInfo): number => AppMeta.compareVersion(b.version, a.version));
      return UpdateChecker.judge(currentVersion, releases[0], releases);
    } catch (e) {
      return {
        status: UpdateStatus.NETWORK_ERROR, current: currentVersion, latest: null, releases: [],
        detail: 'request failed'
      };
    } finally {
      req.destroy();
    }
  }

  /** 回退通道：读取 releases/latest 的跳转地址，解析 tag */
  private static async fromRedirect(currentVersion: string): Promise<UpdateCheckResult> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(AppMeta.LATEST_RELEASE_URL, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'CFLark-Harmony-App' },
        connectTimeout: UpdateChecker.TIMEOUT_MS,
        readTimeout: UpdateChecker.TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode !== 200) {
        return {
          status: UpdateStatus.NETWORK_ERROR, current: currentVersion, latest: null, releases: [],
          detail: 'fallback HTTP ' + resp.responseCode.toString()
        };
      }
      const html: string = typeof resp.result === 'string' ? resp.result as string : '';
      const tag: string = UpdateChecker.firstTag(html);
      if (tag.length === 0) {
        return {
          status: UpdateStatus.NO_RELEASE, current: currentVersion, latest: null, releases: [],
          detail: 'no tag in page'
        };
      }
      const info: ReleaseInfo = {
        version: AppMeta.base(tag),
        tag: tag,
        title: tag,
        publishedAt: '',
        notes: '',
        htmlUrl: AppMeta.RELEASES_URL + '/tag/' + tag,
        hasHarmonyPackage: false,
        fromFallback: true
      };
      return UpdateChecker.judge(currentVersion, info, [info]);
    } catch (e) {
      return {
        status: UpdateStatus.NETWORK_ERROR, current: currentVersion, latest: null, releases: [],
        detail: 'fallback request failed'
      };
    } finally {
      req.destroy();
    }
  }

  private static toInfo(d: ReleaseDto, tag: string): ReleaseInfo {
    let hasPkg: boolean = false;
    const assets: ReleaseAssetDto[] = d.assets === undefined ? [] : d.assets;
    for (let i = 0; i < assets.length; i++) {
      const n: string = assets[i].name === undefined ? '' : assets[i].name as string;
      const lower: string = n.toLowerCase();
      if (lower.endsWith('.hap')) {
        hasPkg = true;
        break;
      }
    }
    return {
      version: AppMeta.base(tag),
      tag: tag,
      title: d.name === undefined || d.name.length === 0 ? tag : d.name,
      publishedAt: d.published_at === undefined ? '' : d.published_at,
      notes: d.body === undefined ? '' : d.body,
      htmlUrl: d.html_url === undefined ? AppMeta.RELEASES_URL : d.html_url,
      hasHarmonyPackage: hasPkg,
      fromFallback: false
    };
  }

  private static judge(current: string, latest: ReleaseInfo, all: ReleaseInfo[]): UpdateCheckResult {
    const cmp: number = AppMeta.compareVersion(latest.version, current);
    const status: UpdateStatus = cmp > 0 ? UpdateStatus.UPDATE_AVAILABLE : UpdateStatus.UP_TO_DATE;
    return { status: status, current: current, latest: latest, releases: all, detail: 'compare=' + cmp.toString() };
  }

  /** 从 releases/latest 页面里取第一个 tag 链接 */
  private static firstTag(html: string): string {
    const marker: string = '/releases/tag/';
    const at: number = html.indexOf(marker);
    if (at < 0) {
      return '';
    }
    let end: number = at + marker.length;
    while (end < html.length) {
      const c: string = html.charAt(end);
      const ok: boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
        c === '.' || c === '-' || c === '_';
      if (!ok) {
        break;
      }
      end++;
    }
    return html.substring(at + marker.length, end);
  }
}
