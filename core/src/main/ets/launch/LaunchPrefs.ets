import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openAppPrefs, openAppPrefsSync } from '../utils/AppPrefs';

/**
 * 启动行为偏好：启动后进哪里、游戏语言跟不跟系统。
 * 「启动后直接进入游戏」的出厂值必须是「先进首页」。
 *    若上次选中的包有问题，打开即闪退，且没有任何界面能改回来 —— 玩家被锁在崩溃循环里。
 *    「先进首页」是唯一不依赖任何检测机制也一定出得来的选择。
 *    打开这个开关是玩家自己的决定；但下面还有一层安全网。
 * 安全网（判据在 entry 的 decideAutoStart）：
 *    上次没正常结束、或者上次退出码非 0，就这一次不自动进游戏，先回首页。
 *    这样即使真的撞上崩溃循环，玩家也总能回到设置里把开关关掉。
 */

const DOMAIN = 0x0000;
const TAG = 'LaunchPrefs';
const STORE = 'launch_prefs';

const KEY_AUTO_START = 'auto_start_game';
const KEY_AUTO_LOCALE = 'auto_locale';

/** 出厂值：先进首页。理由见文件头。 */
export const DEFAULT_AUTO_START_GAME: boolean = false;

/**
 * 出厂值：语言跟随系统。开。
 * Mindustry 本来就没有「跟随系统」这个设置 —— 不传 locale 时 JVM 的默认 locale 是 C，
 * 游戏于是落在英文。这不是玩家的选择，是这个功能的缺失，所以出厂就该开着。
 */
export const DEFAULT_AUTO_LOCALE: boolean = true;

/** 一次读回的两个启动开关。 */
export interface LaunchBehaviour {
  autoStartGame: boolean;
  autoLocale: boolean;
}

function defaults(): LaunchBehaviour {
  const out: LaunchBehaviour = {
    autoStartGame: DEFAULT_AUTO_START_GAME,
    autoLocale: DEFAULT_AUTO_LOCALE,
  };
  return out;
}

/** 读两个开关。读不出来的那一项退回出厂值。 */
export async function readLaunchBehaviour(ctx: common.UIAbilityContext): Promise<LaunchBehaviour> {
  const out: LaunchBehaviour = defaults();
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return out;
  }
  try {
    out.autoStartGame = await store.get(KEY_AUTO_START, DEFAULT_AUTO_START_GAME) as boolean;
    out.autoLocale = await store.get(KEY_AUTO_LOCALE, DEFAULT_AUTO_LOCALE) as boolean;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the prefs: %{public}s', JSON.stringify(e));
  }
  return out;
}

/**
 * 同步版。启动那一刻要立刻拿主意时用它 —— 等 Promise 的话首页已经画出来了，
 * 自动进游戏就会变成「先闪一下首页再切走」。
 */
export function readLaunchBehaviourSync(ctx: common.UIAbilityContext): LaunchBehaviour {
  const out: LaunchBehaviour = defaults();
  const store: preferences.Preferences | null = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return out;
  }
  try {
    out.autoStartGame = store.getSync(KEY_AUTO_START, DEFAULT_AUTO_START_GAME) as boolean;
    out.autoLocale = store.getSync(KEY_AUTO_LOCALE, DEFAULT_AUTO_LOCALE) as boolean;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the prefs (sync): %{public}s', JSON.stringify(e));
  }
  return out;
}

async function writeFlag(ctx: common.UIAbilityContext, key: string, on: boolean): Promise<void> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return;
  }
  try {
    await store.put(key, on);
    await store.flush();
    hilog.info(DOMAIN, TAG, '%{public}s set to %{public}s', key, on ? 'on' : 'off');
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not save %{public}s: %{public}s', key, JSON.stringify(e));
  }
}

/** 写「启动后直接进入游戏」。 */
export async function writeAutoStartGame(ctx: common.UIAbilityContext,
                                         on: boolean): Promise<void> {
  await writeFlag(ctx, KEY_AUTO_START, on);
}

/** 写「游戏语言跟随系统」。 */
export async function writeAutoLocale(ctx: common.UIAbilityContext, on: boolean): Promise<void> {
  await writeFlag(ctx, KEY_AUTO_LOCALE, on);
}
