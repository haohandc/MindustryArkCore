import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { currentGamesDir, currentUserHome, dirExists, ensureDir } from '../storage/StorageRoot';
import { GameVersion } from './GameVersion';
import { Granularity, readGranularitySync } from './Granularity';
import { isValidInstanceName, instanceNameError, MAX_INSTANCE_NAME_LEN } from './InstanceName';
import { resolveOwnString } from '../i18n/UiLanguage';
import { jarVersion, slotFor, SLOT_SHARED } from './InstanceSlot';
import { compareInstances, emptyMeta, InstanceInfo, InstanceMeta } from './InstanceTypes';

/**
 * 实例：一套游戏数据（存档、设置、模组、蓝图）加上一个名字。
 * 归属在导入那一刻定下来，之后不再变。 档位只在新包第一次导入时起作用；
 *    若每次启动按档位现算目录，改一次档位就会让同一个包的存档「消失」。
 * 三个概念：
 *   游戏包 —— `games/` 下的一个文件，就是一个版本，不重复存；
 *   实例   —— `instances/<名字>/`，名字即目录名；
 *   槽位   —— 一个实例代表哪一批版本。自动实例有槽位，手动实例没有。
 * 这个文件只管一份实例的读写：名字、目录、元数据、增删改查、导入后的归位。
 * 一次要动好几份的那些操作（置顶、分组、排序、时长）在 `InstanceOrder.ets`；
 * 数据形状与比较函数在 `InstanceTypes.ets`；名字判据在 `InstanceName.ets`。
 */

const DOMAIN = 0x0000;
const TAG = 'Instance';

/** 实例目录里那份元数据。 */
const META_NAME: string = 'instance.json';
/** 子目录名。放在 `<数据根>` 下，与 `games/`、`trash/` 并列。 */
export const DIR_INSTANCES: string = '/instances';

/* ====================================================================
 * 目录
 * ==================================================================== */

/** `instances/` 这一层。 */
export function instancesDir(ctx: common.UIAbilityContext): string {
  const root: string = currentUserHome(ctx);
  return root === '' ? '' : `${root}${DIR_INSTANCES}`;
}

/** 一个实例的目录。实例名就是目录名。 */
export function instanceDir(ctx: common.UIAbilityContext, name: string): string {
  if (!isValidInstanceName(name)) {
    return '';
  }
  const dir: string = instancesDir(ctx);
  return dir === '' ? '' : `${dir}/${name}`;
}

/** 元数据文件。 */
export function instanceMetaPath(ctx: common.UIAbilityContext, name: string): string {
  const dir: string = instanceDir(ctx, name);
  return dir === '' ? '' : `${dir}/${META_NAME}`;
}

/* ====================================================================
 * 元数据读写（这几个要给出到 InstanceOrder）
 * ==================================================================== */

/**
 * 文件在不在。
 * `fs.accessSync` 不存在时会抛 `13900002`，不是返回 false。
 *    直接写 `if (!fs.accessSync(p))` 会让「没有这个文件」变成一句异常。
 */
export function exists(path: string): boolean {
  if (path === '') {
    return false;
  }
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

function readTextFile(path: string): string {
  if (!exists(path)) {
    return '';
  }
  try {
    return fs.readTextSync(path);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read %{public}s: %{public}s', path, JSON.stringify(e));
    return '';
  }
}

/**
 * 按路径读一份元数据。文件不在或读不懂就给缺省值 ——
 * 一个坏掉的实例不该拖垮整张列表。
 * 后加的四个字段缺失时取缺省值，不回写。
 *    为了补字段去改写玩家的实例文件，代价远大于少几个字段。
 */
export function readMetaAt(path: string): InstanceMeta {
  const meta: InstanceMeta = emptyMeta();
  const text: string = readTextFile(path);
  if (text === '') {
    return meta;
  }
  try {
    const parsed = JSON.parse(text) as InstanceMeta;
    if (typeof parsed.slot === 'string') {
      meta.slot = parsed.slot;
    }
    if (typeof parsed.jar === 'string') {
      meta.jar = parsed.jar;
    }
    if (typeof parsed.createdAt === 'number') {
      meta.createdAt = parsed.createdAt;
    }
    if (typeof parsed.lastPlayedAt === 'number') {
      meta.lastPlayedAt = parsed.lastPlayedAt;
    }
    if (typeof parsed.groupId === 'string') {
      meta.groupId = parsed.groupId;
    }
    if (typeof parsed.pinned === 'boolean') {
      meta.pinned = parsed.pinned;
    }
    if (typeof parsed.sortKey === 'number') {
      meta.sortKey = parsed.sortKey;
    }
    if (typeof parsed.playtimeMs === 'number') {
      meta.playtimeMs = parsed.playtimeMs;
    }
    /* 老实例没有这个字段，缺席时留空串 —— 不回写，
     *    见本函数开头那条「为了补字段去改写玩家的实例文件，代价远大于少几个字段」。 */
    if (typeof parsed.expectedVersion === 'string') {
      meta.expectedVersion = parsed.expectedVersion;
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '%{public}s is not valid JSON: %{public}s', path, JSON.stringify(e));
  }
  return meta;
}

/** 写一份元数据。先写临时名再改名，半截文件不会冒充成完整的一份。 */
export function writeMetaAt(ctx: common.UIAbilityContext, name: string,
                            meta: InstanceMeta): boolean {
  const dir: string = instanceDir(ctx, name);
  if (dir === '') {
    return false;
  }
  if (!ensureDir(dir)) {
    return false;
  }

  const target: string = `${dir}/${META_NAME}`;
  const temp: string = `${target}.tmp`;
  try {
    const file: fs.File = fs.openSync(temp,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(file.fd, JSON.stringify(meta));
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, target);
    return true;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not write %{public}s: %{public}s', target, JSON.stringify(e));
    try {
      if (fs.accessSync(temp)) {
        fs.unlinkSync(temp);
      }
    } catch (ignored) {
      /* 临时文件删不掉不影响本次的结论。 */
    }
    return false;
  }
}

/* ====================================================================
 * 查询
 * ==================================================================== */

/** 这个包在不在 `games/` 里。 */
function jarExists(ctx: common.UIAbilityContext, jar: string): boolean {
  if (jar === '') {
    return false;
  }
  const dir: string = currentGamesDir(ctx);
  if (dir === '') {
    return false;
  }
  return exists(`${dir}/${jar}`);
}

function infoFrom(ctx: common.UIAbilityContext, name: string, meta: InstanceMeta): InstanceInfo {
  const info: InstanceInfo = {
    name: name,
    slot: meta.slot,
    jar: meta.jar,
    createdAt: meta.createdAt,
    lastPlayedAt: meta.lastPlayedAt,
    jarPresent: jarExists(ctx, meta.jar),
    groupId: meta.groupId,
    pinned: meta.pinned,
    sortKey: meta.sortKey,
    playtimeMs: meta.playtimeMs,
    expectedVersion: meta.expectedVersion,
  };
  return info;
}

/**
 * 列出全部实例。置顶的在前，然后按手工顺序，再按最近玩过。
 * 没有 `instance.json` 的目录不算实例，跳过并记一条日志。老布局留下的
 *    `instances/n8/sets/` 就属于这一类 —— 把它当实例列出来只会让玩家看见一个打不开的行。
 */
export function listInstances(ctx: common.UIAbilityContext): InstanceInfo[] {
  const dir: string = instancesDir(ctx);
  if (dir === '' || !dirExists(dir)) {
    return [];
  }

  let names: string[] = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not list %{public}s: %{public}s', dir, JSON.stringify(e));
    return [];
  }

  const out: InstanceInfo[] = [];
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    if (!isValidInstanceName(name)) {
      continue;
    }
    const path: string = `${dir}/${name}`;
    try {
      if (!fs.statSync(path).isDirectory()) {
        continue;
      }
    } catch (e) {
      continue;
    }
    if (!exists(`${path}/${META_NAME}`)) {
      hilog.warn(DOMAIN, TAG, '%{public}s has no %{public}s -- not an instance', path, META_NAME);
      continue;
    }
    out.push(infoFrom(ctx, name, readMetaAt(`${path}/${META_NAME}`)));
  }

  out.sort(compareInstances);
  return out;
}

/**
 * 还没有绑定游戏包的实例。
 * 导入游戏包时用：先问玩家要把新包绑到哪个现成的实例上，再决定要不要新建。
 *    没有这个列表的话，整合包导入建的实例（`slot` 为空、`jar` 为空）就永远
 *    等不到包 —— 自动归位只认槽位，认不出它。
 */
export function listUnboundInstances(ctx: common.UIAbilityContext): InstanceInfo[] {
  const all: InstanceInfo[] = listInstances(ctx);
  const out: InstanceInfo[] = [];
  for (let i = 0; i < all.length; i++) {
    if (all[i].jar === '') {
      out.push(all[i]);
    }
  }
  return out;
}

/** 这个槽位已经归谁了。没有就返回 null。 */
export function findBySlot(ctx: common.UIAbilityContext, slot: string): InstanceInfo | null {
  if (slot === '') {
    return null;
  }
  const all: InstanceInfo[] = listInstances(ctx);
  for (let i = 0; i < all.length; i++) {
    if (all[i].slot === slot) {
      return all[i];
    }
  }
  return null;
}

/** 按名字找一个实例。没有就返回 null。 */
export function findInstance(ctx: common.UIAbilityContext, name: string): InstanceInfo | null {
  if (!isValidInstanceName(name)) {
    return null;
  }
  const path: string = instanceMetaPath(ctx, name);
  if (!exists(path)) {
    return null;
  }
  return infoFrom(ctx, name, readMetaAt(path));
}

/**
 * `base` 这个实例名被占了，就依次试 `base (2)`、`base (3)`。
 * 超过上限时用时间戳兜底，并且必须再验一次合法性 ——
 *    `base` 已经接近长度上限时，后缀会把结果顶出 48 字。
 */
export function uniqueInstanceName(ctx: common.UIAbilityContext, base: string): string {
  const safe: string = isValidInstanceName(base) ? base
    : resolveOwnString(ctx, $r('app.string.core_name_default_instance'), 'core_name_default_instance');
  if (!dirExists(instanceDir(ctx, safe))) {
    return safe;
  }
  for (let n = 2; n < 1000; n++) {
    const candidate: string = `${safe} (${n})`;
    if (candidate.length <= MAX_INSTANCE_NAME_LEN && !dirExists(instanceDir(ctx, candidate))) {
      return candidate;
    }
  }
  hilog.warn(DOMAIN, TAG, 'could not find a free name based on %{public}s', base);
  return resolveOwnString(ctx, $r('app.string.core_name_default_instance_ts', String(Date.now())),
    'core_name_default_instance_ts');
}

/* ====================================================================
 * 写入
 * ==================================================================== */

/**
 * 建一个实例。返回空串表示成功，否则是一句失败原因。
 * 目录建出来就是「这个实例已初始化」的凭据；`instance.json` 是它作为实例被认出的凭据。
 * @param expectedVersion 这个实例本该绑哪个版本（`160.5`）。整合包导入时从
 *        包里的 `lastBuildString` 取；手动新建给空串。只用于界面提示，
 *        见 `InstanceInfo.expectedVersion`。
 */
export function createInstance(ctx: common.UIAbilityContext, name: string,
                               slot: string, jar: string,
                               expectedVersion: string = ''): string {
  const bad: string = instanceNameError(ctx, name);
  if (bad !== '') {
    return bad;
  }
  if (dirExists(instanceDir(ctx, name))) {
    return resolveOwnString(ctx, $r('app.string.core_instance_exists', name), 'core_instance_exists');
  }
  if (!ensureDir(instanceDir(ctx, name))) {
    return resolveOwnString(ctx,
      $r('app.string.core_instance_dir_create_fail', instanceDir(ctx, name)),
      'core_instance_dir_create_fail');
  }
  const meta: InstanceMeta = emptyMeta();
  meta.slot = slot;
  meta.jar = jar;
  meta.expectedVersion = expectedVersion;
  meta.createdAt = Date.now();
  if (!writeMetaAt(ctx, name, meta)) {
    // 目录建出来就算「已初始化」，元数据没写进去就得把目录收回去，
    // 否则这个名字被永久占用，玩家没法重建同名实例。
    // 目录里最多只有一份半截的 instance.json，可以安全整棵删。
    const dir: string = instanceDir(ctx, name);
    try {
      fs.rmdirSync(dir);
    } catch (cleanupErr) {
      // 删失败不覆盖原始错误串，只记一条日志。
      hilog.warn(DOMAIN, TAG, 'could not remove half-created %{public}s: %{public}s',
        dir, JSON.stringify(cleanupErr));
    }
    return resolveOwnString(ctx, $r('app.string.core_instance_meta_write_fail'),
      'core_instance_meta_write_fail');
  }
  hilog.info(DOMAIN, TAG, 'created the instance %{public}s (slot=%{public}s jar=%{public}s)',
    name, slot, jar);
  return '';
}

/** 改名。同卷下是一次 rename，数据规模多大都不影响。 */
export function renameInstance(ctx: common.UIAbilityContext,
                               from: string, to: string): string {
  const bad: string = instanceNameError(ctx, to);
  if (bad !== '') {
    return bad;
  }
  if (from === to) {
    return '';
  }
  const src: string = instanceDir(ctx, from);
  const dst: string = instanceDir(ctx, to);
  if (src === '' || dst === '') {
    return resolveOwnString(ctx, $r('app.string.core_name_err_invalid'), 'core_name_err_invalid');
  }
  if (!dirExists(src)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_not_found', from),
      'core_instance_not_found');
  }
  if (dirExists(dst)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_exists', to), 'core_instance_exists');
  }
  try {
    fs.renameSync(src, dst);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not rename %{public}s: %{public}s', src, JSON.stringify(e));
    return resolveOwnString(ctx, $r('app.string.core_instance_rename_fail'),
      'core_instance_rename_fail');
  }
  hilog.info(DOMAIN, TAG, 'renamed the instance %{public}s -> %{public}s', from, to);
  return '';
}

/** 改绑到另一个游戏包。包名是 `games/` 下的文件名。 */
export function bindInstanceJar(ctx: common.UIAbilityContext, name: string, jar: string): string {
  const path: string = instanceMetaPath(ctx, name);
  if (!exists(path)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_not_found', name),
      'core_instance_not_found');
  }
  if (!jarExists(ctx, jar)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_jar_not_found', jar),
      'core_instance_jar_not_found');
  }
  const meta: InstanceMeta = readMetaAt(path);
  meta.jar = jar;
  if (!writeMetaAt(ctx, name, meta)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_bind_meta_fail'),
      'core_instance_bind_meta_fail');
  }
  hilog.info(DOMAIN, TAG, 'instance %{public}s now binds %{public}s', name, jar);
  return '';
}

/**
 * 复制一个实例。只复制数据目录，不复制游戏包 —— 包是共用的，复制一份白占地方。
 * 新实例的槽位是空串：它不参与「默认版本隔离」的自动归位。
 * 一个包可能同时被好几个实例绑着，那正是「一个版本多套存档」的用意。
 * 用异步复制。一个实例几百兆，同步复制会把界面冻住好几秒。
 */
export async function duplicateInstance(ctx: common.UIAbilityContext,
                                        from: string, to: string): Promise<string> {
  const bad: string = instanceNameError(ctx, to);
  if (bad !== '') {
    return bad;
  }
  const src: string = instanceDir(ctx, from);
  const dst: string = instanceDir(ctx, to);
  if (src === '' || dst === '') {
    return resolveOwnString(ctx, $r('app.string.core_name_err_invalid'), 'core_name_err_invalid');
  }
  if (!dirExists(src)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_not_found', from),
      'core_instance_not_found');
  }
  if (dirExists(dst)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_exists', to), 'core_instance_exists');
  }

  const source: InstanceMeta = readMetaAt(`${src}/${META_NAME}`);
  const copyError: string = await copyTreeFiles(ctx, src, dst);
  if (copyError !== '') {
    /* 复制到一半失败：把残缺的目标删掉，别让它冒充一个能用的实例。 */
    try {
      fs.rmdirSync(dst);
    } catch (e) {
      /* 删不掉只是留个残渣，不影响本次的结论。 */
    }
    return resolveOwnString(ctx, $r('app.string.core_instance_dup_failed', copyError),
      'core_instance_dup_failed');
  }

  /* 元数据重新写一份：时间是新实例的，槽位清空，其余照抄。 */
  const meta: InstanceMeta = emptyMeta();
  meta.jar = source.jar;
  meta.createdAt = Date.now();
  if (!writeMetaAt(ctx, to, meta)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_dup_meta_fail'),
      'core_instance_dup_meta_fail');
  }

  hilog.info(DOMAIN, TAG, 'duplicated the instance %{public}s -> %{public}s', from, to);
  return '';
}

/** 逐文件复制一棵树。目录结构照搬。 */
async function copyTreeFiles(ctx: common.UIAbilityContext, src: string, dst: string): Promise<string> {
  if (!ensureDir(dst)) {
    return resolveOwnString(ctx, $r('app.string.core_copy_dir_create_fail', dst),
      'core_copy_dir_create_fail');
  }

  let names: string[] = [];
  try {
    names = fs.listFileSync(src);
  } catch (e) {
    return resolveOwnString(ctx, $r('app.string.core_copy_dir_read_fail', src),
      'core_copy_dir_read_fail');
  }

  for (let i = 0; i < names.length; i++) {
    const from: string = `${src}/${names[i]}`;
    const to: string = `${dst}/${names[i]}`;

    let stat: fs.Stat;
    try {
      stat = fs.statSync(from);
    } catch (e) {
      return resolveOwnString(ctx, $r('app.string.core_copy_dir_read_fail', from),
        'core_copy_dir_read_fail');
    }

    if (stat.isDirectory()) {
      const err: string = await copyTreeFiles(ctx, from, to);
      if (err !== '') {
        return err;
      }
      continue;
    }

    try {
      await fs.copyFile(from, to);
    } catch (e) {
      return resolveOwnString(ctx, $r('app.string.core_copy_file_fail', from),
        'core_copy_file_fail');
    }
  }
  return '';
}

/**
 * 清空一个实例的游戏数据：存档、模组、蓝图、设置全没。
 * 不删实例本身，也不删它在回收站里的位置 —— 清完之后它还是一个能启动的空实例。
 *    实例信息（`instance.json`）留着，所以绑的包、游玩时长、所在分组都还在。
 * 用 `rmdirSync`：官方原文说它「removes a directory and all its subdirectories
 *    and files」，是递归的，不必自己走一遍。
 */
export function clearInstanceData(ctx: common.UIAbilityContext, name: string): string {
  if (!isValidInstanceName(name)) {
    return resolveOwnString(ctx, $r('app.string.core_name_err_invalid'), 'core_name_err_invalid');
  }
  const dir: string = instanceDir(ctx, name);
  if (dir === '' || !dirExists(dir)) {
    return resolveOwnString(ctx, $r('app.string.core_instance_not_found', name),
      'core_instance_not_found');
  }

  /* 游戏数据在 `<实例>/.local/share/Mindustry`。这一层由游戏自己建，删了它下次会重建。 */
  const dataDir: string = `${dir}/.local/share/Mindustry`;
  if (!dirExists(dataDir)) {
    return '';
  }

  try {
    fs.rmdirSync(dataDir);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not clear %{public}s: %{public}s', dataDir, JSON.stringify(e));
    return resolveOwnString(ctx, $r('app.string.core_instance_clear_busy'),
      'core_instance_clear_busy');
  }
  hilog.info(DOMAIN, TAG, 'cleared the data of %{public}s', name);
  return '';
}

/** 记一笔「这个实例刚玩过」。没排过手工顺序时列表按它排。 */
export function markInstancePlayed(ctx: common.UIAbilityContext, name: string): void {
  const path: string = instanceMetaPath(ctx, name);
  if (!exists(path)) {
    return;
  }
  const meta: InstanceMeta = readMetaAt(path);
  meta.lastPlayedAt = Date.now();
  writeMetaAt(ctx, name, meta);
}

/* ====================================================================
 * 导入后的归位
 * ==================================================================== */

/**
 * 一个包导入之后，把它改绑到同槽位的已有实例上。
 * 规则：
 *   ① 按当前档位算槽位；
 *   ② 有同槽位的实例 把这个实例改绑到新包上（升版本本来就是原地换包）；
 *   ③ 没有 返回 null，不新建实例。
 * 这里不创建实例。 导入一个包就在列表里多出一行，玩家没要求过这件事，
 *    而且多出来的那个实例名字是自动起的，他看不出它从哪来。要建实例让玩家
 *    自己去实例页建，那里会问名字。
 * 版本判不出来时退回「共用」槽位。
 * 只改绑自动实例（`slot` 非空）。手动建的实例不参与归位 —— 那是玩家的东西。
 * @return 改绑到的实例。没有可绑的、或者绑定失败时返回 null。
 */
export async function ensureInstanceForJar(ctx: common.UIAbilityContext,
                                           jar: string): Promise<InstanceInfo | null> {
  const g: Granularity = readGranularitySync(ctx);
  const version: GameVersion = await jarVersion(ctx, jar);
  let slot: string = slotFor(g, version);
  if (slot === '') {
    hilog.info(DOMAIN, TAG, 'cannot tell the version of %{public}s (from %{public}s) -- '
      + 'looking for the shared instance', jar, version.source);
    slot = SLOT_SHARED;
  }

  const existing: InstanceInfo | null = findBySlot(ctx, slot);
  if (existing === null) {
    hilog.info(DOMAIN, TAG, 'no instance owns slot %{public}s -- leaving %{public}s unbound',
      slot, jar);
    return null;
  }

  const error: string = bindInstanceJar(ctx, existing.name, jar);
  if (error !== '') {
    hilog.warn(DOMAIN, TAG, 'could not bind %{public}s to %{public}s: %{public}s',
      jar, existing.name, error);
    return null;
  }
  return findInstance(ctx, existing.name);
}
