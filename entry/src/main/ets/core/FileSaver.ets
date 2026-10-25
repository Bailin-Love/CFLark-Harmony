/**
 * FileSaver.ets
 * 把应用内生成的文本导出成「用户看得见、找得到」的文件。
 *
 * 保存策略（按优先级）：
 * 1. picker.DocumentViewPicker.save()：拉起系统「保存到文件管理」页面，文件名已预填，
 *    用户可自己选 Download / Documents 或新建文件夹。不需要任何存储权限，所有设备可用。
 * 2. 用户取消（关闭保存页）→ 返回空字符串，调用方提示「已取消」。
 * 3. picker 异常时 → 直接写公共 Download 目录（Environment.getUserDownloadDir()）。
 *    注意：该接口官方仅声明支持 2in1（API 26 起 tablet）；Phone 模拟器实测可用且文件
 *    在「文件管理 > 我的手机 > Download」可见，但真机 Phone 不保证，故只做兜底。
 * 4. 仍失败 → 写应用沙箱 filesDir，保证内容不丢，并在返回值里说明。
 */
import { common } from '@kit.AbilityKit';
import { Environment, fileIo, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileSaver';
/** 兜底用的公共下载目录（Environment 不可用时的硬编码路径）。 */
const FALLBACK_DOWNLOAD_DIR: string = '/storage/Users/currentUser/Download';

export class FileSaver {
  /**
   * 让用户选择位置并保存文本文件。
   * @param ctx UIAbilityContext（必须是 UIAbility 的 context，否则拉不起 picker）
   * @param fileName 预填文件名，例如 cflark-20261024.txt
   * @param content 文本内容，按 UTF-8 写入
   * @returns 成功：保存位置的完整路径（可直接 toast）；用户取消：空字符串 ''；失败：失败原因描述
   */
  static async saveText(ctx: common.UIAbilityContext, fileName: string, content: string): Promise<string> {
    const name: string = FileSaver.normalizeName(fileName);

    // 1. 首选：系统保存选择器，用户自选目录
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [name];
      const suffixChoices: Array<string> | undefined = FileSaver.suffixChoices(name);
      if (suffixChoices !== undefined) {
        options.fileSuffixChoices = suffixChoices;
      }
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const uris: Array<string> = await documentPicker.save(options);
      if (uris.length === 0) {
        // 用户取消（部分版本以空数组返回）
        return '';
      }
      const uri: string = uris[0];
      const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, content);
      } finally {
        fileIo.closeSync(file);
      }
      const path: string = FileSaver.toDisplayPath(uri);
      hilog.info(DOMAIN, TAG, 'picker saved: %{public}s', path);
      return path;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'picker save failed: %{public}d %{public}s', err.code, err.message);
      if (FileSaver.isCancel(err)) {
        return '';
      }
    }

    // 2. 兜底：直接写公共 Download 目录
    const downloadPath: string = FileSaver.writeToDownloadDir(name, content);
    if (downloadPath.length > 0) {
      hilog.info(DOMAIN, TAG, 'fallback download saved: %{public}s', downloadPath);
      return downloadPath;
    }

    // 3. 最后兜底：应用沙箱，至少不丢数据
    const sandboxPath: string = FileSaver.writeToSandbox(ctx, name, content);
    if (sandboxPath.length > 0) {
      return '保存失败，已暂存到应用沙箱：' + sandboxPath;
    }
    return '保存失败，请重试';
  }

  /** 整理成安全的单层文件名（去掉路径分隔符和非法字符）。 */
  private static normalizeName(fileName: string): string {
    let name: string = fileName.replace(/[\\/:*?"<>|]/g, '_').trim();
    if (name.length === 0) {
      name = 'export.txt';
    }
    return name;
  }

  /** 文件名没后缀时给 picker 一个后缀选项，避免存出无后缀文件。 */
  private static suffixChoices(name: string): Array<string> | undefined {
    if (name.lastIndexOf('.') > 0) {
      return undefined;
    }
    return ['文本文件|txt'];
  }

  /** file://docs/storage/... → /storage/... 的可读路径。 */
  private static toDisplayPath(uri: string): string {
    const prefix: string = 'file://docs';
    let path: string = uri;
    if (path.startsWith(prefix)) {
      path = path.substring(prefix.length);
    }
    try {
      path = decodeURIComponent(path);
    } catch (e) {
      // 解码失败保留原始 URI，不影响提示
    }
    return path;
  }

  /** 识别用户取消保存（picker 以异常形式返回）。 */
  private static isCancel(err: BusinessError): boolean {
    if (err.code === 13900042) {
      return true;
    }
    const msg: string = err.message === undefined ? '' : err.message.toLowerCase();
    return msg.indexOf('cancel') >= 0 || msg.indexOf('取消') >= 0;
  }

  /** 直接写公共 Download 目录；成功返回完整路径，失败返回空串。 */
  private static writeToDownloadDir(name: string, content: string): string {
    let dir: string = '';
    try {
      dir = Environment.getUserDownloadDir();
    } catch (e) {
      dir = '';
    }
    if (dir.length === 0) {
      dir = FALLBACK_DOWNLOAD_DIR;
    }
    const path: string = dir + '/' + name;
    return FileSaver.writeFile(path, content) ? path : '';
  }

  /** 写应用沙箱 filesDir；成功返回完整路径，失败返回空串。 */
  private static writeToSandbox(ctx: common.UIAbilityContext, name: string, content: string): string {
    const path: string = ctx.filesDir + '/' + name;
    return FileSaver.writeFile(path, content) ? path : '';
  }

  /** 覆盖写入一个 UTF-8 文本文件。 */
  private static writeFile(path: string, content: string): boolean {
    try {
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, content);
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'write %{public}s failed: %{public}d %{public}s', path, err.code, err.message);
      return false;
    }
  }
}
