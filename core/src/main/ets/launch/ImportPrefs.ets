import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openAppPrefs, openAppPrefsSync } from '../utils/AppPrefs';

/**
 * 导入偏好：落进 `games/` 的那份游戏包，要不要改名成版本号。
 * 一个游戏包就是一个版本，文件名带上版本号之后，在外部存储模式下打开文件管理器
 *    就能直接认出是哪一个 —— 不用回应用里看。
 * 三态。「还没问过」与「问过、选了关」必须分开：合并成一个布尔值的话，
 *    第一次导入时会按「关」处理，那个询问框永远都不会出现。
 */

const DOMAIN = 0x0000;
const TAG = 'ImportPrefs';
const STORE = 'import_prefs';

const KEY_JAR_NAMING = 'jar_naming';
const KEY_PARSE_ON_IMPORT = 'parse_on_import';

/**
 * 导入整合包时要不要顺手解析每个存档的元数据。
 * 出厂开。 关闭只是省下导入时那不到一秒，代价是导入之后第一次
 *    点进存档页要现场解一遍（那时卡的是存档页，不是导入面板）。
 * 与「时间修正」已经解耦：`saves/` 里每份存档的日期显示取自存档内部的
 *    `saved` 字段，不依赖文件时间。这个开关只影响预读，
 *    关掉不会让日期变错。 */
export function readParseOnImportSync(ctx: common.UIAbilityContext): boolean {
  const store: preferences.Preferences | null = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return true;
  }
  try {
    return store.getSync(KEY_PARSE_ON_IMPORT, true) as boolean;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the parse-on-import flag: %{public}s',
      JSON.stringify(e));
    return true;
  }
}

export async function writeParseOnImport(ctx: common.UIAbilityContext, on: boolean): Promise<void> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return;
  }
  try {
    await store.put(KEY_PARSE_ON_IMPORT, on);
    await store.flush();
    hilog.info(DOMAIN, TAG, 'parse on import set to %{public}s', `${on}`);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not save the parse-on-import flag: %{public}s',
      JSON.stringify(e));
  }
}

/** 游戏包改名成版本号的三种状态。 */
export enum JarNaming {
  /** 还没问过。第一次导入时问一次。 */
  Unset,
  /** 开启。 */
  On,
  /** 关掉。 */
  Off,
}

function toKey(mode: JarNaming): string {
  if (mode === JarNaming.On) {
    return 'on';
  }
  if (mode === JarNaming.Off) {
    return 'off';
  }
  return '';
}

function toMode(key: string): JarNaming {
  if (key === 'on') {
    return JarNaming.On;
  }
  if (key === 'off') {
    return JarNaming.Off;
  }
  return JarNaming.Unset;
}

export async function readJarNaming(ctx: common.UIAbilityContext): Promise<JarNaming> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return JarNaming.Unset;
  }
  try {
    return toMode(await store.get(KEY_JAR_NAMING, '') as string);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the jar naming mode: %{public}s', JSON.stringify(e));
    return JarNaming.Unset;
  }
}

/** 同步版。导入那一刻要立刻拿主意，等 Promise 会让询问框晚于文件选择器冒出来。 */
export function readJarNamingSync(ctx: common.UIAbilityContext): JarNaming {
  const store: preferences.Preferences | null = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return JarNaming.Unset;
  }
  try {
    return toMode(store.getSync(KEY_JAR_NAMING, '') as string);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the jar naming mode (sync): %{public}s',
      JSON.stringify(e));
    return JarNaming.Unset;
  }
}

export async function writeJarNaming(ctx: common.UIAbilityContext,
                                     mode: JarNaming): Promise<void> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return;
  }
  try {
    await store.put(KEY_JAR_NAMING, toKey(mode));
    await store.flush();
    hilog.info(DOMAIN, TAG, 'jar naming set to %{public}s', toKey(mode));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not save the jar naming mode: %{public}s', JSON.stringify(e));
  }
}
