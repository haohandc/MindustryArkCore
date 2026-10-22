import { common } from '@kit.AbilityKit';
import { currentGamesDir } from '../storage/StorageRoot';
import { resolveOwnString } from '../i18n/UiLanguage';
import { JarNaming } from '../launch/ImportPrefs';
import { GameVersion, readGameVersion, versionDisplayText, versionText } from './GameVersion';
import { Granularity } from './Granularity';
import { InstanceInfo } from './InstanceTypes';

/**
 * 槽位与版本判定：一个游戏包属于哪一批、它是什么版本、版本之间谁高谁低。
 * 三样放一起，是因为它们在导入归位那一步是一起用的：
 * 先读版本，再按档位算槽位，再决定要不要给玩家提一句「这是降级」。
 */

/** 不隔离时那个槽位。 */
export const SLOT_SHARED: string = 'shared';

/**
 * 不隔离那个实例的缺省名字。
 * 它会变成目录名，所以必须在这里解析成 string —— 资源对象不能拼进路径。
 *   已有实例不受影响：这只在「新建」那一刻取一次。
 */
export function sharedSlotName(ctx: common.UIAbilityContext): string {
  return resolveOwnString(ctx, $r('app.string.core_slot_shared_name'), 'core_slot_shared_name');
}

/**
 * 一个版本在某档位下属于哪个槽位。空串表示版本信息不够，判不出来。
 * 判不出来时不猜 —— 给一个错的槽位会让两个本来不同的版本落进同一个实例。
 *    调用方退回「共用」，并在日志里说清楚。
 */
export function slotFor(g: Granularity, version: GameVersion): string {
  if (g === Granularity.Off) {
    return SLOT_SHARED;
  }
  if (g === Granularity.Number) {
    return version.number === '' ? '' : `n${version.number}`;
  }
  if (version.build === '') {
    return '';
  }
  if (g === Granularity.Build) {
    return `b${version.build}`;
  }
  return version.revision === '' ? `b${version.build}` : `b${version.build}.${version.revision}`;
}

/** 某个槽位新建实例时的缺省名字。 */
export function defaultNameForSlot(ctx: common.UIAbilityContext, slot: string): string {
  if (slot === SLOT_SHARED || slot === '') {
    return sharedSlotName(ctx);
  }
  /* `n8` -> `v8`：游戏自己的 `v8` 指的是大版本，我们的前缀是 `n`，两者不能混。 */
  if (slot.charAt(0) === 'n') {
    return `v${slot.substring(1)}`;
  }
  if (slot.charAt(0) === 'b') {
    return slot.substring(1);
  }
  return slot;
}

/** 某个游戏包的版本。包名是 `games/` 下的文件名。 */
export async function jarVersion(ctx: common.UIAbilityContext,
                                 jar: string): Promise<GameVersion> {
  if (jar === '') {
    return await readGameVersion(ctx, '');
  }
  const dir: string = currentGamesDir(ctx);
  return await readGameVersion(ctx, dir === '' ? jar : `${dir}/${jar}`);
}

/**
 * 一个实例对应的游戏版本，纯数字形式（`160.5`）。读不出来是空串。
 * 这是给逻辑用的：`isDowngrade` 拿它逐段比数字。
 *    界面上要显示的是下面那个 `instanceVersionDisplay`。
 */
export async function instanceVersionText(ctx: common.UIAbilityContext,
                                          info: InstanceInfo): Promise<string> {
  const version: GameVersion = await jarVersion(ctx, info.jar);
  return versionText(version);
}

/**
 * 一个实例对应的游戏版本，给人看的形式。跟着「游戏包按版本号改名」这个开关走。
 *   开关开：`v8 build160.5` —— 读不出版本时退回文件名
 *   开关关：`Mindustry-160.5.jar` —— 玩家导入时叫什么就显示什么
 *
 * 显示口径与文件命名用同一个开关，不各说各的。 开着改名时文件名本来就是
 *    版本号，卡片再写一遍 `v8 build160.5（Mindustry-160.5.jar）` 是同一件事说两遍，
 *    而卡片那一行只有一行宽（右边还挂着「版本隔离」胶囊），两个值必然被截断。
 *    关着时文件名是玩家自己起的，卡片跟着显示它才对得上「我导入的那个文件」。
 * 偏好由调用方读好再传进来，这里不自己读。 首页对每个实例调一次，
 *    藏进来就是 N 次隐性 IO；一个叫 Display 的函数也不该有这类副作用。
 * 这个结果不能喂给 `isDowngrade` —— `build` 前缀会解析成 NaN，
 *    降级警告静默失效。那种比较用上面的 `instanceVersionText`。
 */
export async function instanceVersionDisplay(ctx: common.UIAbilityContext,
                                             info: InstanceInfo,
                                             naming: JarNaming): Promise<string> {
  if (info.jar === '') {
    return '';
  }
  if (naming !== JarNaming.On) {
    return info.jar;
  }
  const version: GameVersion = await jarVersion(ctx, info.jar);
  const text: string = versionDisplayText(version);
  return text === '' ? info.jar : text;
}

/**
 * `to` 是不是比 `from` 低。
 * 逐段比数字，按位置对齐 —— `160` 与 `160.5` 比时短的补 0，于是 `160` 小于 `160.5`。
 * 任一边读不出来就返回 false：判不出来时不打扰玩家，与「不猜」同一条。
 */
export function isDowngrade(from: string, to: string): boolean {
  if (from === '' || to === '') {
    return false;
  }
  const a: string[] = from.split('.');
  const b: string[] = to.split('.');
  const n: number = a.length > b.length ? a.length : b.length;
  for (let i = 0; i < n; i++) {
    const x: number = Number.parseInt(i < a.length ? a[i] : '0', 10);
    const y: number = Number.parseInt(i < b.length ? b[i] : '0', 10);
    if (Number.isNaN(x) || Number.isNaN(y)) {
      return false;
    }
    if (y < x) {
      return true;
    }
    if (y > x) {
      return false;
    }
  }
  return false;
}
