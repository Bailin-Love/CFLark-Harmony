import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BarStyle } from '../entryability/EntryAbility';
import { wantAgent, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;

/**
 * 连续任务保活：扫描 / 测速 / 订阅上传期间持有长任务，全部结束后释放。
 * 用 tag 集合做引用计数，避免阶段交接时被提前释放。
 */
export class AppBackground {
  private static holds: Set<string> = new Set<string>();
  private static running: boolean = false;
  /** 用户在设置里开启后台保活后才生效 */
  static enabled: boolean = false;
  /** 后台保活最近一次结果，供 UI 日志展示 */
  static lastState: string = '';
  private static ctx: common.UIAbilityContext | null = null;

  static init(ctx: common.UIAbilityContext): void {
    AppBackground.ctx = ctx;
  }

  static hold(tag: string): void {
    if (!AppBackground.enabled) {
      return;
    }
    AppBackground.holds.add(tag);
    if (!AppBackground.running) {
      AppBackground.start();
    }
  }

  static release(tag: string): void {
    AppBackground.holds.delete(tag);
    if (AppBackground.holds.size === 0 && AppBackground.running) {
      AppBackground.stop();
    }
  }

  private static async start(): Promise<void> {
    const ctx: common.UIAbilityContext | null = AppBackground.ctx;
    if (ctx === null) {
      return;
    }
    const modes: backgroundTaskManager.BackgroundMode[] = [
      backgroundTaskManager.BackgroundMode.TASK_KEEPING,
      backgroundTaskManager.BackgroundMode.DATA_TRANSFER
    ];
    const names: string[] = ['TASK_KEEPING', 'DATA_TRANSFER'];
    let lastMsg: string = '';
    for (let i = 0; i < modes.length; i++) {
      try {
        const info: wantAgent.WantAgentInfo = {
          wants: [{
            bundleName: ctx.abilityInfo.bundleName,
            abilityName: ctx.abilityInfo.name
          }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        const agent = await wantAgent.getWantAgent(info);
        await backgroundTaskManager.startBackgroundRunning(ctx, modes[i], agent);
        AppBackground.running = true;
        BarStyle.setKeepScreenOn(true);
      AppBackground.lastState = '后台保活已开启（' + names[i] + '）';
        hilog.info(DOMAIN, 'cflark', 'keep-alive started with %{public}s', names[i]);
        return;
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        lastMsg = err.message !== undefined ? err.message : '未知错误';
        hilog.warn(DOMAIN, 'cflark', 'startBackgroundRunning(%{public}s) failed: %{public}s', names[i], lastMsg);
      }
    }
    AppBackground.lastState = '后台保活开启失败：' + lastMsg;
  }

  private static async stop(): Promise<void> {
    BarStyle.setKeepScreenOn(false);
    const ctx: common.UIAbilityContext | null = AppBackground.ctx;
    if (ctx === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      AppBackground.running = false;
      AppBackground.lastState = '已停止长时任务';
      hilog.info(DOMAIN, 'cflark', 'keep-alive stopped');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, 'cflark', 'stopBackgroundRunning failed: %{public}s', err.message);
    }
  }
}
