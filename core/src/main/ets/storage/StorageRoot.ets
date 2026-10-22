import { common, bundleManager } from '@kit.AbilityKit';
import { Environment, fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openAppPrefs, openAppPrefsSync } from '../utils/AppPrefs';

/**
 * 游戏数据放在哪。
 *
 * 两种模式，目录同名同形，只有根不同：
 *
 *   沙箱                                    外部
 *   <应用级 filesDir>/                      Download/<包名>/
 *     instances/<实例名>/                     data/instances/<实例名>/
 *       .local/share/Mindustry/                 .local/share/Mindustry/
 *     games/                                  games/
 *     trash/                                  trash/
 *     exports/                                exports/
 *     backups/                                backups/
 *
 * 沙箱那份没有 `data/` 这一层，外部那份有。
 * 外部根的名字必须是包名：系统据此认作本应用所有，跨重启有效。
 *    换名字就拿不到访问权。
 */

const DOMAIN = 0x0000;
const TAG = 'StorageRoot';
const STORE = 'storage_mode';

const KEY_MODE = 'mode';

/** 存储模式。 */
export enum StorageMode {
  /** 应用沙箱。出厂值。 */
  Sandbox,
  /** 下载目录下与包名同名的那个文件夹。 */
  External,
}

/**
 * 外部根自带的位置标记。
 * 用文件而不是 preferences：preferences 在卸载时被系统清掉，而外部目录活得下来。
 *    这是「删了应用再装回来，还能知道玩家选的是外部」的唯一线索。
 * 不变量：标记存在 ⟺ 数据在外部 切回沙箱时必须删掉它。
 */
const MODE_MARKER: string = '.storage_mode';
const MARKER_EXTERNAL: string = 'external';

/** 外部根下，游戏数据那一层的目录名。沙箱没有这一层。 */
const EXTERNAL_DATA_DIR: string = 'data';

/** 游戏数据在两种根下的共同相对路径。 */
const GAME_DATA_RELATIVE: string = '/.local/share/Mindustry';

/** 子目录名。两种根下都叫这个名字。 */
export const DIR_GAMES: string = '/games';
export const DIR_EXPORTS: string = '/exports';
export const DIR_BACKUPS: string = '/backups';

function modeToKey(mode: StorageMode): string {
  return mode === StorageMode.External ? 'external' : 'sandbox';
}

function keyToMode(key: string): StorageMode {
  return key === 'external' ? StorageMode.External : StorageMode.Sandbox;
}

/** 包名。取不到返回空串 —— 那时外部根就不可用。 */
export function bundleName(): string {
  try {
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return info.name;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the bundle name: %{public}s', JSON.stringify(e));
    return '';
  }
}

/**
 * 外部根。拿不到就是空串。
 * `getUserDownloadDir()` 需要 `SystemCapability.FileManagement.File.Environment.FolderObtain`，
 *    个别设备没有这个能力，会抛 801。拿不到就等于没有外部存储，回退沙箱，不崩。
 * 不要申请 `READ_WRITE_DOWNLOAD_DIRECTORY`：本应用访问的是下载目录下自己包名那个文件夹，
 *    读写、逐文件复制都不需要任何权限。
 */
export function externalRoot(): string {
  const name: string = bundleName();
  if (name === '') {
    return '';
  }
  try {
    const download: string = Environment.getUserDownloadDir();
    if (download === '') {
      return '';
    }
    return `${download}/${name}`;
  } catch (e) {
    hilog.info(DOMAIN, TAG, 'this device has no user download directory: %{public}s',
      JSON.stringify(e));
    return '';
  }
}

/** 一个模式的根。外部不可用时沙箱模式总是可用，外部模式返回空串。 */
export function rootFor(ctx: common.UIAbilityContext, mode: StorageMode): string {
  if (mode === StorageMode.Sandbox) {
    return ctx.getApplicationContext().filesDir;
  }
  return externalRoot();
}

/**
 * 某个模式下 `-Duser.home` 该指哪。
 * 这是数据根，不是游戏数据目录：游戏自己在它下面找 `.local/share/Mindustry`。
 *    两者差一层 —— 传错的话游戏会在 `<userHome>/.local/share/Mindustry` 找不到东西，
 *    当成全新安装，玩家的存档就"消失"了。
 */
export function userHomeFor(ctx: common.UIAbilityContext, mode: StorageMode): string {
  const root: string = rootFor(ctx, mode);
  if (root === '') {
    return '';
  }
  return (mode === StorageMode.External) ? `${root}/${EXTERNAL_DATA_DIR}` : root;
}

/** 当前模式下的 `user.home`。拿不到就回退沙箱，与 native 的「任何失败都回退」一致。 */
export function currentUserHome(ctx: common.UIAbilityContext): string {
  const root: string = userHomeFor(ctx, readStorageModeSync(ctx));
  return (root !== '') ? root : userHomeFor(ctx, StorageMode.Sandbox);
}

/**
 * 实例名进路径之前的最后一道校验。
 * 与 `isolation/Instance.ets` 的 `isValidInstanceName` 是同一套判据，这里是刻意重复的：
 *    那个文件依赖本文件，反向 import 会成环。名字来自玩家输入，每一条拼路径的路都要自己挡一次
 *    —— 只靠调用方先校验，漏一处就是路径能穿出数据根。
 */
function isSafeInstanceName(name: string): boolean {
  if (name === '' || name === '.' || name === '..' || name.length > 48) {
    return false;
  }
  if (/[\/\\:*?"<>|\x00-\x1f]/.test(name)) {
    return false;
  }
  if (name !== name.trim() || name.charAt(0) === '.' || name.charAt(name.length - 1) === '.') {
    return false;
  }
  return true;
}

/**
 * 某个实例的 `user.home`。
 * 布局：`<数据根>/instances/<实例名>`
 *
 * `instances/` 与 `.local/share/` 是兄弟目录，不是嵌套 —— 前者是各实例的数据根，
 *    后者由游戏自己在 `user.home` 下面建。
 * 实例名不合法或根拿不到时返回空串，不回退到数据根 —— 让调用方看见失败，
 *    而不是把两套数据悄悄写进同一棵树。
 */
export function instanceUserHome(ctx: common.UIAbilityContext, name: string): string {
  if (!isSafeInstanceName(name)) {
    return '';
  }
  const base: string = currentUserHome(ctx);
  if (base === '') {
    return '';
  }
  return `${base}/instances/${name}`;
}

/** 某个实例的游戏数据目录（游戏自己在 `user.home` 下面建的那一层）。 */
export function instanceGameDataDir(ctx: common.UIAbilityContext, name: string): string {
  const home: string = instanceUserHome(ctx, name);
  return home === '' ? '' : `${home}${GAME_DATA_RELATIVE}`;
}

/** 当前模式下游戏包放哪。 */
export function currentGamesDir(ctx: common.UIAbilityContext): string {
  let root: string = rootFor(ctx, readStorageModeSync(ctx));
  if (root === '') {
    root = rootFor(ctx, StorageMode.Sandbox);
  }
  return root + DIR_GAMES;
}

/** 某个模式下游戏包放哪。迁移时"从哪搬到哪"要用它。 */
export function gamesDirFor(ctx: common.UIAbilityContext, mode: StorageMode): string {
  const root: string = rootFor(ctx, mode);
  return root === '' ? '' : root + DIR_GAMES;
}

/**
 * 确保一个目录存在。
 * 不能直接 `mkdirSync(path, true)` —— 对已存在的目录它会抛 13900015 `File exists`
 *    不是静默成功。所以先判存在。
 */
export function ensureDir(path: string): boolean {
  if (path === '') {
    return false;
  }
  try {
    if (fs.accessSync(path)) {
      return true;
    }
  } catch (e) {
    /* 不存在，往下走。 */
  }
  try {
    fs.mkdirSync(path, true);
    return true;
  } catch (e) {
    /* 并发建目录时也可能抛 File exists，再判一次。 */
    try {
      return fs.accessSync(path);
    } catch (ignored) {
      hilog.warn(DOMAIN, TAG, 'could not create %{public}s: %{public}s', path, JSON.stringify(e));
      return false;
    }
  }
}

/** 目录存在吗。 */
export function dirExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

/** 目录里的条目数。不存在算 0。 */
export function countEntries(path: string): number {
  try {
    return fs.listFileSync(path).length;
  } catch (e) {
    return 0;
  }
}

/**
 * 布局升级：把根目录上的 `.jar` 挪进 `games/`。
 * 上几版的导入直接把包放在数据根上（`<根>/game.jar`）。现在游戏包的落点是 `games/`，
 * 不移过去的话，老玩家打开应用会看到「还没有添加游戏」—— 而包明明还在。
 * 幂等，每次启动跑一遍没有代价（根上没有 jar 就直接返回）。
 * 只搬 `.jar`，其它文件一概不碰。
 */
export function upgradeLayout(ctx: common.UIAbilityContext): void {
  const root: string = rootFor(ctx, readStorageModeSync(ctx));
  if (root === '' || !dirExists(root)) {
    return;
  }

  let names: string[] = [];
  try {
    names = fs.listFileSync(root);
  } catch (e) {
    return;
  }

  const jars: string[] = [];
  for (let i = 0; i < names.length; i++) {
    if (names[i].toLowerCase().endsWith('.jar')) {
      jars.push(names[i]);
    }
  }
  if (jars.length === 0) {
    return;
  }

  const games: string = root + DIR_GAMES;
  if (!ensureDir(games)) {
    hilog.warn(DOMAIN, TAG, 'could not create %{public}s -- leaving the jars where they are', games);
    return;
  }

  for (let i = 0; i < jars.length; i++) {
    const from: string = `${root}/${jars[i]}`;
    const to: string = `${games}/${jars[i]}`;
    try {
      if (dirExists(to)) {
        /* 目标已有同名文件（上次升到一半）。两边的包都不删，让玩家自己选。 */
        hilog.warn(DOMAIN, TAG, 'both %{public}s and %{public}s exist -- leaving them', from, to);
        continue;
      }
      fs.renameSync(from, to);
      hilog.info(DOMAIN, TAG, 'moved %{public}s into games/', jars[i]);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'could not move %{public}s: %{public}s', jars[i], JSON.stringify(e));
    }
  }
}

/** 读外部根自带的位置标记。只认 `external`，其余一律当没有。 */
function readExternalMarker(): StorageMode {
  const root: string = externalRoot();
  if (root === '') {
    return StorageMode.Sandbox;
  }
  try {
    const path: string = `${root}/${MODE_MARKER}`;
    if (!fs.accessSync(path)) {
      return StorageMode.Sandbox;
    }
    if (fs.readTextSync(path).trim() !== MARKER_EXTERNAL) {
      return StorageMode.Sandbox;
    }
    hilog.info(DOMAIN, TAG, 'the sandbox has no record -- adopting the external marker');
    return StorageMode.External;
  } catch (e) {
    return StorageMode.Sandbox;
  }
}

/**
 * 读当前模式。
 * 沙箱里完全没有记录时去问外部那份自带标记 —— 那是「重装之后」的情形：
 *    preferences 被清了，但外部数据和标记还在。不这样做，玩家重装后会看到「存档全没了」。
 */
export function readStorageModeSync(ctx: common.UIAbilityContext): StorageMode {
  const store = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return readExternalMarker();
  }
  try {
    const raw = store.getSync(KEY_MODE, '') as string;
    if (raw === '') {
      return readExternalMarker();
    }
    if (raw === 'sandbox' || raw === 'external') {
      return keyToMode(raw);
    }
    hilog.warn(DOMAIN, TAG, 'mode "%{public}s" is not usable -- assuming the sandbox', raw);
    return StorageMode.Sandbox;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the mode: %{public}s', JSON.stringify(e));
    return StorageMode.Sandbox;
  }
}

/** 读当前模式（异步版，给界面用）。 */
export async function readStorageMode(ctx: common.UIAbilityContext): Promise<StorageMode> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return readExternalMarker();
  }
  try {
    const raw = await store.get(KEY_MODE, '') as string;
    if (raw === '') {
      return readExternalMarker();
    }
    return (raw === 'external') ? StorageMode.External : StorageMode.Sandbox;
  } catch (e) {
    return StorageMode.Sandbox;
  }
}

/**
 * 写模式，同时维护外部根上的标记。
 * 两处都写不是冗余：沙箱那份是权威，外部那份是重装后唯一的线索。
 * 切回沙箱时删掉标记 —— 留着的话，下次重装会指回一个已经被搬空的目录。
 */
export async function writeStorageMode(ctx: common.UIAbilityContext,
                                       mode: StorageMode): Promise<void> {
  const store = await openAppPrefs(ctx, STORE);
  if (store !== null) {
    try {
      await store.put(KEY_MODE, modeToKey(mode));
      await store.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'could not save the mode: %{public}s', JSON.stringify(e));
    }
  }

  const root: string = externalRoot();
  if (root === '') {
    return;
  }
  const marker: string = `${root}/${MODE_MARKER}`;
  if (mode === StorageMode.External) {
    try {
      ensureDir(root);
      const file: fs.File = fs.openSync(marker,
        fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
      try {
        fs.writeSync(file.fd, MARKER_EXTERNAL + '\n');
      } finally {
        fs.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'wrote the external marker');
    } catch (e) {
      /* 尽力而为：写不了不影响本次，只影响重装后的自动恢复。 */
      hilog.warn(DOMAIN, TAG, 'could not write the external marker: %{public}s',
        JSON.stringify(e));
    }
    return;
  }

  try {
    if (fs.accessSync(marker)) {
      fs.unlinkSync(marker);
      hilog.info(DOMAIN, TAG, 'removed the external marker');
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not remove the external marker: %{public}s',
      JSON.stringify(e));
  }
}
