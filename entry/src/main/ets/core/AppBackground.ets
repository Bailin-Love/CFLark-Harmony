import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
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
      await backgroundTaskManager.startBackgroundRunning(
        ctx, backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
      AppBackground.running = true;
      hilog.info(DOMAIN, 'cflark', 'keep-alive started');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, 'cflark', 'startBackgroundRunning failed: %{public}s', err.message);
    }
  }

  private static async stop(): Promise<void> {
    const ctx: common.UIAbilityContext | null = AppBackground.ctx;
    if (ctx === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      AppBackground.running = false;
      hilog.info(DOMAIN, 'cflark', 'keep-alive stopped');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, 'cflark', 'stopBackgroundRunning failed: %{public}s', err.message);
    }
  }
}
