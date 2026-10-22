import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 应用级 preferences。
 * 必须走 `getApplicationContext()`，不能用传进来的 UIAbilityContext 直接开。
 *    UIAbilityContext 的 preferencesDir 带模块名 —— `…/base/haps/<模块>/preferences/`，
 *    每个 HAP 一个文件。entry 里存的值，runtime 里的 GameAbility 读不到，反过来也一样。
 *    ApplicationContext 的路径是 `…/base/preferences/`，整个应用共用一个文件。
 * 凡是跨 HAP 要读的偏好（窗口、弹窗画法、后面那批功能开关）都从这里开。
 *   只在单个 HAP 内用的偏好可以继续用 UIAbilityContext，但那属于例外。
 */

const DOMAIN = 0x0000;
const TAG = 'AppPrefs';

/** 打开一个应用级偏好文件。打不开返回 null，调用方退回默认值。 */
export async function openAppPrefs(ctx: common.UIAbilityContext,
                                   name: string): Promise<preferences.Preferences | null> {
  try {
    const options: preferences.Options = { name: name };
    return await preferences.getPreferences(ctx.getApplicationContext(), options);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not open %{public}s: %{public}s', name, JSON.stringify(e));
    return null;
  }
}

/**
 * 同步版。给 Ability 的生命周期回调用 —— `onWindowStageCreate` 里要先把窗口
 * 摆好再 loadContent，等一个 Promise 会让第一帧先按旧状态画出来。
 */
export function openAppPrefsSync(ctx: common.UIAbilityContext,
                                 name: string): preferences.Preferences | null {
  try {
    const options: preferences.Options = { name: name };
    return preferences.getPreferencesSync(ctx.getApplicationContext(), options);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not open %{public}s (sync): %{public}s', name, JSON.stringify(e));
    return null;
  }
}
