/**
 * 极简启动页。
 *
 * 为什么需要它：HarmonyOS 的系统启动窗口（module.json5 的 startWindowIcon /
 * startWindowBackground）是在应用进程起来之前由系统绘制的，它只能读到**系统**
 * 的深浅色配置，读不到应用内自己保存的主题偏好。所以如果把背景色交给
 * start_window_background，就会出现「应用选了浅色、系统是深色 → 启动一闪深色」。
 *
 * 现在的做法：start_window_background 设成完全透明（只留系统画的图标），
 * 背景色改由这里决定 —— 这里能读到 ConfigStore 里的主题偏好，颜色与应用一致。
 */
@Component
export struct SplashPage {
  /** 应用当前是否为深色（由上层按 themeMode 算好传进来） */
  dark: boolean = true;
  onFinished: () => void = () => {
  };
  @State private gone: boolean = false;

  aboutToAppear(): void {
    setTimeout(() => {
      this.gone = true;
      this.onFinished();
    }, 650);
  }

  build() {
    Column() {
      // 图标尺寸对齐系统启动窗口的视觉大小（约 12% 屏宽），避免两帧之间跳变
      // splash_icon.png 是 1024×1024 透明画布、图标只占 22%，所以这里的宽高要放大 4.5 倍，
      // 图标最终的视觉尺寸才和系统启动窗口一致（约 12% 屏宽）。
      Image($r('app.media.splash_icon'))
        .width(241)
        .height(241)
        .objectFit(ImageFit.Contain)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.dark ? '#0B0B12' : '#F5F7FC')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}