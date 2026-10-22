import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openAppPrefs, openAppPrefsSync } from '../utils/AppPrefs';
import { resolveOwnString } from '../i18n/UiLanguage';

/**
 * 操作方式：PC 模式还是触屏模式。
 * 这是启动参数，不是游戏内设置。
 *    Mindustry 的整个输入层和 UI 都派生自 `Vars.mobile` 一个位，在 `Vars.init()`
 *    里写一次。它自带的那个游戏内开关只改输入处理器，于是会在移动端 UI 上给出桌面
 *    控制。所以只能在启动之前定好，改了要重启游戏。
 * 出厂值跟设备走：PC / 2in1 直接给 PC 模式，其余（手机、平板、车机、
 *    电视、穿戴）一律触屏。2in1 上接键盘用 PC、拆下来用触屏是常态，
 *    所以玩家改过之后必须记住，不能被设备判据顶回去。
 * 跨 HAP 要读（entry 写、runtime 读），所以走应用级 preferences。见 `AppPrefs.ets`。
 */

const DOMAIN = 0x0000;
const TAG = 'ControlMode';
const STORE = 'launch_prefs';
const KEY_CONTROL_MODE = 'control_mode';

const VALUE_TOUCH: string = 'touch';
const VALUE_DESKTOP: string = 'desktop';

export enum ControlMode {
  Touch = 0,
  Desktop = 1,
}

/**
 * 设备判据：只有 `2in1` 算 PC，其他一律触屏。
 * 不要写成「phone / tablet 算触屏、其余算 PC」—— 那样 `tv`、`wearable`、
 *    `car`、`default` 会被误判成 PC 模式，而那些设备全是触摸屏。
 *    取值见 `@ohos.deviceInfo` 的 `DeviceTypes`。
 */
export function defaultControlMode(): ControlMode {
  return deviceInfo.deviceType === '2in1' ? ControlMode.Desktop : ControlMode.Touch;
}

/** 显示文字。 */
export function controlModeLabel(ctx: common.UIAbilityContext, mode: ControlMode): string {
  if (mode === ControlMode.Desktop) {
    return resolveOwnString(ctx, $r('app.string.core_mode_desktop'), 'core_mode_desktop');
  }
  return resolveOwnString(ctx, $r('app.string.core_mode_touch'), 'core_mode_touch');
}

/**
 * 另一个档位。这个开关只有两个值，界面上一点就翻过去。
 */
export function otherControlMode(mode: ControlMode): ControlMode {
  return mode === ControlMode.Desktop ? ControlMode.Touch : ControlMode.Desktop;
}

/**
 * 读当前值。
 * 键不存在时用设备判据，键存在时无条件用它 —— 见文件头「玩家改过之后必须记住」。
 *    `hasSync` 用来区分「没设过」和「设成了触屏」；用带默认值的 `getSync` 分不出来。
 * 同步版：启动那一刻就要拿主意，等 Promise 会让首页先按旧状态画一帧。
 */
export function readControlModeSync(ctx: common.UIAbilityContext): ControlMode {
  const store: preferences.Preferences | null = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return defaultControlMode();
  }
  try {
    if (!store.hasSync(KEY_CONTROL_MODE)) {
      return defaultControlMode();
    }
    const raw: string = store.getSync(KEY_CONTROL_MODE, VALUE_TOUCH) as string;
    return raw === VALUE_DESKTOP ? ControlMode.Desktop : ControlMode.Touch;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the control mode: %{public}s', JSON.stringify(e));
    return defaultControlMode();
  }
}

/** 读当前值（异步）。界面初始化用。 */
export async function readControlMode(ctx: common.UIAbilityContext): Promise<ControlMode> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return defaultControlMode();
  }
  try {
    if (!(await store.has(KEY_CONTROL_MODE))) {
      return defaultControlMode();
    }
    const raw: string = await store.get(KEY_CONTROL_MODE, VALUE_TOUCH) as string;
    return raw === VALUE_DESKTOP ? ControlMode.Desktop : ControlMode.Touch;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the control mode: %{public}s', JSON.stringify(e));
    return defaultControlMode();
  }
}

/** 写。写失败不抛 —— 界面上那句「已切换」由调用方按返回值决定要不要说。 */
export async function writeControlMode(ctx: common.UIAbilityContext,
                                       mode: ControlMode): Promise<boolean> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return false;
  }
  try {
    await store.put(KEY_CONTROL_MODE,
      mode === ControlMode.Desktop ? VALUE_DESKTOP : VALUE_TOUCH);
    await store.flush();
    hilog.info(DOMAIN, TAG, 'control mode set to %{public}s',
      mode === ControlMode.Desktop ? VALUE_DESKTOP : VALUE_TOUCH);
    return true;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not save the control mode: %{public}s', JSON.stringify(e));
    return false;
  }
}
