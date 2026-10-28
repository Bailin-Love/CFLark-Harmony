import { i18n } from '@kit.LocalizationKit';

/** 语言模式：0 跟随系统 / 1 简体中文 / 2 English */
export enum LangMode {
  SYSTEM = 0,
  ZH = 1,
  EN = 2
}

/**
 * 语言解析：
 *  - 用户显式选择优先；
 *  - 跟随系统时，系统语言为英文系列则英文，其余（含中文与其他语言）回退简体中文；
 *  - 任何异常都回退中文，避免启动崩溃。
 */
export class I18n {
  static systemIsEnglish(): boolean {
    try {
      const lang: string = i18n.System.getSystemLanguage();
      if (lang === undefined || lang === null || lang.length === 0) {
        return false;
      }
      return lang.toLowerCase().indexOf('en') === 0;
    } catch (e) {
      return false;
    }
  }

  /** 归一化外部传入的模式值 */
  static clampMode(mode: number): number {
    if (mode === LangMode.ZH || mode === LangMode.EN) {
      return mode;
    }
    return LangMode.SYSTEM;
  }

  /** 该模式下是否使用英文 */
  static resolve(mode: number): boolean {
    const m: number = I18n.clampMode(mode);
    if (m === LangMode.EN) {
      return true;
    }
    if (m === LangMode.ZH) {
      return false;
    }
    return I18n.systemIsEnglish();
  }
}
