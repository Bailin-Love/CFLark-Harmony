import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ConfigStore } from '../core/ConfigStore';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;

/** 系统栏（状态栏 / 手势导航条）配色与沉浸式控制 */
export class BarStyle {
  private static win: window.Window | undefined = undefined;

  /** 在 loadContent 成功回调里调用 */
  static attach(stage: window.WindowStage): void {
    try {
      BarStyle.win = stage.getMainWindowSync();
      BarStyle.apply(true);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'BarStyle.attach failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 深/浅色主题切换、以及窗口创建时都会调这里，统一维护「沉浸式」四件事：
   *
   * 1. setWindowLayoutFullScreen(true)：内容铺满到状态栏 / 底部手势导航条下方。
   *    这是关键一步 —— 不开全屏时，即使把 navigationBarColor 设成透明，
   *    系统仍会在底部手势条区域画一块自己的背景，看起来就是「白色隔离板」。
   * 2. 系统栏颜色全部透明，只控制图标/文字颜色，避免状态栏出现色带。
   * 3. 尝试隐藏底部导航指示条（部分设备/系统版本会直接忽略，属正常）。
   * 4. 窗口背景色与页面渐变底部保持同色，兜住系统栏区域可能露出的一帧底色。
   */
  static apply(dark: boolean): void {
    const win = BarStyle.win;
    if (!win) {
      return;
    }

    // 1) 全屏布局；成功后读出系统栏占用的高度，写进 AppStorage 让页面给内容让位
    win.setWindowLayoutFullScreen(true).then(() => {
      try {
        const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        AppStorage.setOrCreate<number>('statusBarPx', area.topRect.height);
        AppStorage.setOrCreate<number>('navBarPx', area.bottomRect.height);
        hilog.info(DOMAIN, 'testTag', 'safe area top=%{public}d bottom=%{public}d',
          area.topRect.height, area.bottomRect.height);
      } catch (e) {
        hilog.warn(DOMAIN, 'testTag', 'getWindowAvoidArea failed: %{public}s', JSON.stringify(e));
      }
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', 'setWindowLayoutFullScreen failed: %{public}s', e.message);
    });

    // 1.5) 隐藏顶部状态栏（鸿蒙原生 API；个别系统版本会忽略，忽略即可）
    // 状态栏保持显示（仅透明底、图标可见）

    // 2) 系统栏透明化
    win.setWindowSystemBarProperties({
      statusBarColor: '#00FFFFFF',
      statusBarContentColor: dark ? '#FFFFFF' : '#000000',
      navigationBarColor: '#00000000',
      navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', 'setWindowSystemBarProperties failed: %{public}s', e.message);
    });

    // 3) 隐藏底部导航指示器（小白条）：拿不到或不支持时忽略即可
    win.setSpecificSystemBarEnabled('navigationIndicator', false).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, 'testTag', 'hide navigationIndicator ignored: %{public}s', e.message);
    });

    // 4) 窗口底色与页面渐变末尾一致，避免最底一帧出现色差
    try {
      win.setWindowBackgroundColor(dark ? '#0C0D12' : '#FFFFFF');
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(e));
    }
  }
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 启动窗口是系统画的、读不到应用偏好；这里在进程一开始就同步读一次主题，
    // 写进 AppStorage，页面首帧（应用内启动页）就能直接用它，不会先闪一下系统色。
    try {
      const st: preferences.Preferences = preferences.getPreferencesSync(this.context, { name: 'cflark_store' });
      const mode: number = st.getSync('themeMode', 2) as number;
      let initialDark: boolean = true;
      if (mode === 0) {
        initialDark = true;
      } else if (mode === 1) {
        initialDark = false;
      } else {
        initialDark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
      AppStorage.setOrCreate<boolean>('initialDark', initialDark);
      hilog.info(DOMAIN, 'testTag', 'initialDark=%{public}s (themeMode=%{public}d)',
        initialDark ? 'dark' : 'light', mode);
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'read themeMode failed: %{public}s', JSON.stringify(err));
    }
    ConfigStore.init(this.context).then(() => {
      hilog.info(DOMAIN, 'testTag', '%{public}s', 'preferences initialized');
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', 'preferences init failed: %{public}s', e.message);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    // 先把主窗口的初始尺寸写进 AppStorage：页面在首帧 build 之前就能按真实窗口宽高
    // 决定手机 / 平板布局，避免「先按手机布局渲染一帧、再重排成平板三列」的闪动。
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      const rect: window.Rect = win.getWindowProperties().windowRect;
      AppStorage.setOrCreate<number>('initWinWpx', rect.width);
      AppStorage.setOrCreate<number>('initWinHpx', rect.height);
      // 系统栏（状态栏 / 手势条）高度也提前写入，页面首帧的沉浸式留白就是最终值，
      // 免得首帧先按 0 排版、avoidArea 异步回来后再往下挪一次。
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate<number>('statusBarPx', area.topRect.height);
      AppStorage.setOrCreate<number>('navBarPx', area.bottomRect.height);
      hilog.info(DOMAIN, 'testTag', 'initial window px=%{public}d x %{public}d, bar=%{public}d/%{public}d',
        rect.width, rect.height, area.topRect.height, area.bottomRect.height);
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'read initial window size failed: %{public}s', JSON.stringify(e));
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      BarStyle.attach(windowStage);
    });
  }

  onWindowStageDestroy(): void { }
  onForeground(): void { }
  onBackground(): void { }
  onDestroy(): void { }
}