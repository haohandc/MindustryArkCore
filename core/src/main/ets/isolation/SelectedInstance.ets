import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openAppPrefs, openAppPrefsSync } from '../utils/AppPrefs';
import { findInstance, listInstances } from './Instance';
import { InstanceInfo } from './InstanceTypes';

/**
 * 「当前选中的实例」。首页那张大卡片显示的就是它。
 * 用应用级 preferences（`AppPrefs`）：写发生在 entry，将来如果游戏侧要回写
 *    最后一次玩的是哪个，也是另一个 HAP。用 UIAbilityContext 开就是两个文件。
 * 存的是实例名，不存目录路径 —— 存储位置切到另一侧之后整棵树都换了根。
 */

const DOMAIN = 0x0000;
const TAG = 'SelectedInstance';
const STORE = 'selected_instance';
const KEY_NAME = 'name';

/** 同步读。首页第一次画就要给出名字，等 Promise 会先画一个空卡片再跳。 */
export function readSelectedSync(ctx: common.UIAbilityContext): string {
  const store: preferences.Preferences | null = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return '';
  }
  try {
    return store.getSync(KEY_NAME, '') as string;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the selection (sync): %{public}s', JSON.stringify(e));
    return '';
  }
}

export async function readSelected(ctx: common.UIAbilityContext): Promise<string> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return '';
  }
  try {
    return await store.get(KEY_NAME, '') as string;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the selection: %{public}s', JSON.stringify(e));
    return '';
  }
}

export async function writeSelected(ctx: common.UIAbilityContext, name: string): Promise<void> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return;
  }
  try {
    await store.put(KEY_NAME, name);
    await store.flush();
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not save the selection: %{public}s', JSON.stringify(e));
  }
}

/**
 * 读出当前可用的那个实例。记着的那个不在了就退到列表第一个，并把它写回去。
 * 回落而不是报错：玩家删掉实例之后，首页不该变成一张打不开的空卡片。
 *    列表已经按置顶与最近玩过排好，第一个就是最合理的那个。
 * @param all 已经读好的实例列表。不传就现场读一次 —— 传进来能省一遍目录扫描。
 */
export function resolveSelected(ctx: common.UIAbilityContext,
                                all: InstanceInfo[]): InstanceInfo | null {
  const saved: string = readSelectedSync(ctx);
  if (saved !== '') {
    for (let i = 0; i < all.length; i++) {
      if (all[i].name === saved) {
        return all[i];
      }
    }
    /* 记着的那一个不见了。往下走挑第一个，并且把记录改过来 ——
     * 不改的话每次启动都要走一遍「找不到」，界面上那句提示会反复闪。 */
    hilog.info(DOMAIN, TAG, 'the selected instance %{public}s is gone, falling back', saved);
  }

  if (all.length === 0) {
    return null;
  }
  const first: InstanceInfo = all[0];
  writeSelected(ctx, first.name).catch((e: Error) => {
    hilog.warn(DOMAIN, TAG, 'could not save the fallback: %{public}s', e.message);
  });
  return first;
}

/**
 * 选中一个实例。名字不存在就不写 —— 免得记录指向一个打不开的东西。
 * @return 成功与否。
 */
export async function selectInstance(ctx: common.UIAbilityContext, name: string): Promise<boolean> {
  if (name === '' || findInstance(ctx, name) === null) {
    hilog.warn(DOMAIN, TAG, 'refusing to select %{public}s: no such instance', name);
    return false;
  }
  await writeSelected(ctx, name);
  return true;
}
