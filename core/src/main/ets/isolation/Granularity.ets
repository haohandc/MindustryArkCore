import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openAppPrefs, openAppPrefsSync } from '../utils/AppPrefs';

/**
 * 「默认版本隔离」的档位。
 * 它只决定之后新导入的游戏包落到哪个实例里。已经归好位的包不动 ——
 *    改一次档位就让所有存档换个目录，等于玩家的数据凭空消失一次。
 */

const DOMAIN = 0x0000;
const TAG = 'Granularity';
const STORE = 'isolation';
const KEY_GRANULARITY = 'granularity';

/** 按哪个粒度给新导入的包分实例。 */
export enum Granularity {
  /** 不隔离。所有版本落到「共用」这一个实例里。 */
  Off,
  /** 按大版本分（`n8`）。 */
  Number,
  /** 按构建号分（`b160`）。160.x 共用。 */
  Build,
  /** 按完整版本分（`b160.5`）。 */
  Revision,
}

export const DEFAULT_GRANULARITY: Granularity = Granularity.Off;

/** 全部档位，由粗到细。设置页照这个数组生成选项。 */
export const ALL_GRANULARITIES: Granularity[] = [
  Granularity.Off, Granularity.Number, Granularity.Build, Granularity.Revision,
];

/**
 * 档位的显示名。
 * 返回 `Resource` 而不是取好的 `string`。`Resource` 自带 `moduleName`，
 *    渲染方（entry）按它路由到本模块的资源表 —— 不需要调用方知道这条字住在哪。
 *    别改成 `getStringSync` 取成 `string` 再返回：那样语言就得在本函数里定格，
 *    而本函数是模块加载期被调的，界面还没建。
 */
export function granularityLabel(g: Granularity): ResourceStr {
  if (g === Granularity.Number) {
    return $r('app.string.core_granularity_number');
  }
  if (g === Granularity.Build) {
    return $r('app.string.core_granularity_build');
  }
  if (g === Granularity.Revision) {
    return $r('app.string.core_granularity_revision');
  }
  return $r('app.string.core_granularity_off');
}

export function granularityToKey(g: Granularity): string {
  if (g === Granularity.Number) {
    return 'number';
  }
  if (g === Granularity.Build) {
    return 'build';
  }
  if (g === Granularity.Revision) {
    return 'revision';
  }
  return 'off';
}

export function keyToGranularity(key: string): Granularity {
  if (key === 'number') {
    return Granularity.Number;
  }
  if (key === 'build') {
    return Granularity.Build;
  }
  if (key === 'revision') {
    return Granularity.Revision;
  }
  return Granularity.Off;
}

export async function readGranularity(ctx: common.UIAbilityContext): Promise<Granularity> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return DEFAULT_GRANULARITY;
  }
  try {
    const raw = await store.get(KEY_GRANULARITY, granularityToKey(DEFAULT_GRANULARITY)) as string;
    return keyToGranularity(raw);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the granularity: %{public}s', JSON.stringify(e));
    return DEFAULT_GRANULARITY;
  }
}

export function readGranularitySync(ctx: common.UIAbilityContext): Granularity {
  const store: preferences.Preferences | null = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return DEFAULT_GRANULARITY;
  }
  try {
    return keyToGranularity(store.getSync(KEY_GRANULARITY,
      granularityToKey(DEFAULT_GRANULARITY)) as string);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the granularity (sync): %{public}s',
      JSON.stringify(e));
    return DEFAULT_GRANULARITY;
  }
}

export async function writeGranularity(ctx: common.UIAbilityContext,
                                       g: Granularity): Promise<void> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return;
  }
  try {
    await store.put(KEY_GRANULARITY, granularityToKey(g));
    await store.flush();
    hilog.info(DOMAIN, TAG, 'granularity set to %{public}s', granularityToKey(g));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not save the granularity: %{public}s', JSON.stringify(e));
  }
}
