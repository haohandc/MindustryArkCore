/**
 * 实例的数据形状与排序规则。纯数据，不碰文件系统。
 * 单独一个文件是为了断开循环依赖：读写元数据的在 `Instance.ets`，
 * 改置顶与分组顺序的在 `InstanceOrder.ets`，两边都要用同一套字段与同一个比较函数。
 * 把它们放在任何一边，另一边就得反过来 import，形成一个环。
 */

/** 一个实例。 */
export interface InstanceInfo {
  /** 实例名，也是目录名。 */
  name: string;
  /** 代表的槽位。空串 = 手动建的，不参与自动归位。 */
  slot: string;
  /** 绑定的游戏包文件名（不是绝对路径 —— 存储根会变）。空串 = 没绑。 */
  jar: string;
  createdAt: number;
  lastPlayedAt: number;
  /** 绑的那个包现在还在不在。 */
  jarPresent: boolean;
  /** 所在分组。空串 = 未分组。 */
  groupId: string;
  /** 置顶在被它自己的分组顶上。 */
  pinned: boolean;
  /** 同组内的手工顺序，大的在前。0 = 从没排过，退回按 `lastPlayedAt` 排。 */
  sortKey: number;
  /** 这个实例的累计游玩时长（毫秒）。总时长不靠它求和 —— 见 `PlayStats`。 */
  playtimeMs: number;
  /**
   * 这个实例本该绑哪个游戏版本，纯数字形式（`160.5`）。空串 = 不知道。
   * 唯一来源是整合包导入时读到的 `lastBuildString`。手动新建的实例没有它。
   * 为什么值得单独存一个字段：导入时那个版本号来自包本身，而
   *    `games/` 里未必有对应的包。玩家后来补了一个包，界面上要能说清
   *    「这个实例还要 `160.5`，你绑的这个是 `160.4`」—— 只比对 jar 的版本
   *    看不出「本该是什么」，因为没有基准。
   * 它只用于提示，不参与启动判据：包没了/绑错了，走的仍是
   *    `checkTarget` 那条路。不要拿它去改 `jar`。
   */
  expectedVersion: string;
}

/** 落盘的元数据。名字不写进去 —— 目录名就是它，两处存会打架。 */
export interface InstanceMeta {
  slot: string;
  jar: string;
  createdAt: number;
  lastPlayedAt: number;
  groupId: string;
  pinned: boolean;
  sortKey: number;
  playtimeMs: number;
  /** 本该绑的版本（`160.5`）。空串 = 不知道，见 `InstanceInfo.expectedVersion`。 */
  expectedVersion: string;
}

export function emptyMeta(): InstanceMeta {
  const meta: InstanceMeta = {
    slot: '', jar: '', createdAt: 0, lastPlayedAt: 0,
    groupId: '', pinned: false, sortKey: 0, playtimeMs: 0, expectedVersion: '',
  };
  return meta;
}

export function cloneMeta(m: InstanceMeta): InstanceMeta {
  const out: InstanceMeta = {
    slot: m.slot,
    jar: m.jar,
    createdAt: m.createdAt,
    lastPlayedAt: m.lastPlayedAt,
    groupId: m.groupId,
    pinned: m.pinned,
    sortKey: m.sortKey,
    playtimeMs: m.playtimeMs,
    expectedVersion: m.expectedVersion,
  };
  return out;
}

/**
 * 列表的排序。组内与跨组用同一个比较函数 —— 它不比组，界面按 `groupId`
 * 切块时保持这个顺序就对了。
 * 顺序：置顶的在前 → 手工排过的按 `sortKey` 大的在前 → 没排过的按最近玩过。
 * 置顶不动 `sortKey`。取消置顶之后就回到它原来那个位置，
 *    而不是像塞进手工队列那样把整串顺序打乱。
 */
export function compareInstances(a: InstanceInfo, b: InstanceInfo): number {
  if (a.pinned !== b.pinned) {
    return a.pinned ? -1 : 1;
  }
  if (a.sortKey !== b.sortKey) {
    return b.sortKey - a.sortKey;
  }
  if (a.lastPlayedAt !== b.lastPlayedAt) {
    return b.lastPlayedAt - a.lastPlayedAt;
  }
  return a.createdAt - b.createdAt;
}
