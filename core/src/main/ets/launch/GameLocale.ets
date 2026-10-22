import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openAppPrefs } from '../utils/AppPrefs';
import { ensureDir } from '../storage/StorageRoot';

/**
 * 把设备语言翻译成游戏认得的 locale。
 * 为什么需要这一层：Mindustry 没有「跟随系统」这个设置。
 *    它的 `Vars.loadLocales()` 在 `settings.bin` 的 `locale` 是 `default` 时用
 *    `Locale.getDefault()`；`LanguageDialog.findClosestLocale()` 拿它在语言清单里找，
 *    找不到就硬编码 `new Locale("en")` 并写回 `settings.bin`。
 *    而我们不传 locale 时，HotSpot 的默认 locale 是 `C` —— 落在英文上。
 *    「不设语言」的实际含义是「英文」，不是「跟随系统」。这就是旧版本一进游戏是英文的原因。
 * 判据是「这个值在游戏自己的语言清单里」，不是「Java 能不能构造出这个 Locale」。
 *    给一个游戏没有的值，结果是它静默落到英文根包 —— 比不给更糟，因为玩家以为设过了。
 * 清单从玩家导入的那个 jar 里读，不用内建表。
 *    游戏版本会变、语言会增删，内建表迟早过期；jar 里那份永远是这一版游戏真正认的。
 */

const DOMAIN = 0x0000;
const TAG = 'GameLocale';

/** jar 里那份语言清单的条目名。Mindustry 把它放在包的根上。 */
const LOCALES_ENTRY = 'locales';

/** zip 结构签名。 */
const SIG_EOCD = 0x06054b50;
const SIG_CEN = 0x02014b50;

/** EOCD 最长可能被 65535 字节注释推远，再加 22 字节记录本身。 */
const EOCD_SEARCH_MAX = 65535 + 22;

/* 缓存。第一次读 jar 要解压一次，之后按「路径 + 大小 + 修改时间」判命中。 */
const STORE = 'jar_locale_cache';
const KEY_CACHE = 'cache';

interface LocaleCache {
  path: string;
  size: number;
  mtime: number;
  locales: string[];
}

/** 一次语言判定的结果。 */
export interface GameLocale {
  /** 语言段，例如 `zh`。空串 = 不设。 */
  lang: string;
  /** 地区段，例如 `CN`。空串 = 不设。 */
  country: string;
  /** 完整取值，例如 `zh_CN`。空串 = 不设 —— 此时不应给 JVM 传任何语言参数。 */
  locale: string;
  /** 为什么是这个结果，只写日志与排查用。 */
  reason: string;
}

function emptyLocale(reason: string): GameLocale {
  const out: GameLocale = { lang: '', country: '', locale: '', reason: reason };
  return out;
}

/** 小端读 16 位。 */
function u16(buf: Uint8Array, off: number): number {
  return buf[off] | (buf[off + 1] << 8);
}

/** 小端读 32 位。无符号化 —— 中央目录的偏移会超过 2^31 的一半。 */
function u32(buf: Uint8Array, off: number): number {
  return (buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)) >>> 0;
}

/**
 * 读文件的一段到内存。读不满就返回实际读到的那么多。
 * 必须先 lseek。`readSync` 的 `offset` 是相对当前文件指针的，不是绝对位置
 *    （官方原文：start position = current filePointer plus offset）。
 *    连续读三段时，第二段的 offset 会被加在「第一段读完之后」的位置上 —— 越界、读到空。
 */
function readRange(fd: fs.File, offset: number, length: number): Uint8Array {
  fs.lseek(fd.fd, offset, fs.WhenceType.SEEK_SET);
  const buf: ArrayBuffer = new ArrayBuffer(length);
  const view: Uint8Array = new Uint8Array(buf);
  const read: number = fs.readSync(fd.fd, buf);
  if (read === length) {
    return view;
  }
  /* 短读只在文件被并发改动时出现，把它截断成实际长度即可。 */
  return view.subarray(0, read);
}

/** 用 UTF-8 解一段字节。文件名都是 ASCII，但别假设。 */
function decodeUtf8(bytes: Uint8Array): string {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes);
}

/**
 * 在 jar 里找 `locales` 条目，把「只含这一条」的迷你 zip 拼出来。
 * 为什么不直接把整个 jar 交给解压器：那要把 80 MB 全解到磁盘，只为读 127 字节。
 * 为什么能这么做：zip 的中央目录记录了每个条目的本地头偏移与压缩长度，
 * 把那一小段原样搬过来、配上一条重建的中央目录和一个 EOCD，就是一个合法 zip。
 * 重建而不是照抄中央目录，是因为照抄的话里面记的偏移仍指向原 jar，解压器会读错位置。
 * @return 迷你 zip 的字节。找不到条目返回 null。
 */
function buildEntryZip(fd: fs.File, fileSize: number): Uint8Array | null {
  /* ① 从文件尾部往前找 EOCD。它可能被注释推开，所以要按「记录 + 注释长度 = 文件尾」验一次。 */
  const tailLen: number = fileSize < EOCD_SEARCH_MAX ? fileSize : EOCD_SEARCH_MAX;
  const tail: Uint8Array = readRange(fd, fileSize - tailLen, tailLen);

  let eocdAt: number = -1;
  for (let i = tailLen - 22; i >= 0; i--) {
    if (u32(tail, i) !== SIG_EOCD) {
      continue;
    }
    const commentLen: number = u16(tail, i + 20);
    if (i + 22 + commentLen === tailLen) {
      eocdAt = i;
      break;
    }
    /* 签名对但长度不符：这是文件内容里碰巧出现的四个字节，继续往前找。 */
  }
  if (eocdAt === -1) {
    hilog.warn(DOMAIN, TAG, 'no end-of-central-directory record -- not a zip');
    return null;
  }

  const cdOffset: number = u32(tail, eocdAt + 16);
  const cdSize: number = u32(tail, eocdAt + 12);
  if (cdSize === 0 || cdOffset + cdSize > fileSize) {
    hilog.warn(DOMAIN, TAG, 'central directory is out of range');
    return null;
  }

  /* ② 扫中央目录找条目。5411 个条目约 450 KB，整块读进来比逐条读快得多。 */
  const cd: Uint8Array = readRange(fd, cdOffset, cdSize);
  let p: number = 0;
  let localOffset: number = -1;
  let nameLen: number = 0;

  while (p + 46 <= cd.length && u32(cd, p) === SIG_CEN) {
    const fnLen: number = u16(cd, p + 28);
    const extraLen: number = u16(cd, p + 30);
    const commentLen: number = u16(cd, p + 32);

    if (fnLen === LOCALES_ENTRY.length) {
      const name: string = decodeUtf8(cd.subarray(p + 46, p + 46 + fnLen));
      if (name === LOCALES_ENTRY) {
        localOffset = u32(cd, p + 42);
        nameLen = fnLen;
        break;
      }
    }

    p += 46 + fnLen + extraLen + commentLen;
  }

  if (localOffset === -1) {
    hilog.info(DOMAIN, TAG, 'this jar has no %{public}s entry', LOCALES_ENTRY);
    return null;
  }

  /* ③ 搬本地头那一段。长度按本地头自己记的字段算 —— 它可能与中央目录里的不同。 */
  const localHead: Uint8Array = readRange(fd, localOffset, 30);
  if (localHead.length < 30) {
    return null;
  }
  const localFnLen: number = u16(localHead, 26);
  const localExtraLen: number = u16(localHead, 28);
  const compressedSize: number = u32(localHead, 18);
  const segmentLen: number = 30 + localFnLen + localExtraLen + compressedSize;

  if (localOffset + segmentLen > fileSize) {
    hilog.warn(DOMAIN, TAG, 'the %{public}s entry runs past the end of the file', LOCALES_ENTRY);
    return null;
  }

  const segment: Uint8Array = readRange(fd, localOffset, segmentLen);

  /* ④ 重建中央目录条目：除本地头偏移改成 0 之外，其余字段照抄本地头。
   * 大小、CRC 本地头里都有，不用再读中央目录那一份。 */
  const cen: Uint8Array = new Uint8Array(46 + nameLen);
  cen[0] = 0x50; cen[1] = 0x4b; cen[2] = 0x01; cen[3] = 0x02;
  cen[4] = 20;
  cen[5] = 0;                                   /* version made by */
  cen[6] = localHead[4];
  cen[7] = localHead[5];                        /* version needed，照抄本地头 */
  for (let i = 0; i < 4; i++) {
    cen[8 + i] = localHead[6 + i];              /* 标志位与压缩方法 */
  }
  /* 时间、日期、CRC、压缩后长度、原始长度 —— 共 16 字节。
   * 少抄 4 字节（原始长度）会让解压器以为产物是空的。 */
  for (let i = 0; i < 16; i++) {
    cen[12 + i] = localHead[10 + i];
  }
  cen[28] = nameLen & 0xFF;
  cen[29] = (nameLen >> 8) & 0xFF;
  /* 30..45 是 extra 长度、注释长度、磁盘号、属性 —— 全是 0，已初始化。 */
  for (let i = 0; i < nameLen; i++) {
    cen[46 + i] = segment[30 + i];              /* 文件名照抄本地头里的那一份 */
  }

  /* ⑤ EOCD：一个条目，中央目录紧跟在本地段之后。 */
  const eocd: Uint8Array = new Uint8Array(22);
  eocd[0] = 0x50; eocd[1] = 0x4b; eocd[2] = 0x05; eocd[3] = 0x06;
  eocd[8] = 1; eocd[9] = 0;
  eocd[10] = 1; eocd[11] = 0;
  const cdLen: number = cen.length;
  eocd[12] = cdLen & 0xFF; eocd[13] = (cdLen >> 8) & 0xFF;
  const cdPos: number = segment.length;
  eocd[16] = cdPos & 0xFF;
  eocd[17] = (cdPos >> 8) & 0xFF;
  eocd[18] = (cdPos >> 16) & 0xFF;
  eocd[19] = (cdPos >> 24) & 0xFF;

  /* ⑥ 拼起来。 */
  const out: Uint8Array = new Uint8Array(segment.length + cen.length + eocd.length);
  out.set(segment, 0);
  out.set(cen, segment.length);
  out.set(eocd, segment.length + cen.length);
  return out;
}

/**
 * 从 jar 里读出语言清单。
 * 失败一律返回空数组 —— 没有清单时我们什么都不设，游戏落英文，也就是现状。
 * 为此让启动失败是不划算的。
 */
async function readLocalesFromJar(ctx: common.UIAbilityContext,
                                  jarPath: string): Promise<string[]> {
  const probeDir: string = `${ctx.tempDir}/locale_probe`;
  const zipPath: string = `${probeDir}/entry.zip`;
  const outDir: string = `${probeDir}/out`;

  try {
    const file: fs.File = fs.openSync(jarPath, fs.OpenMode.READ_ONLY);
    let bytes: Uint8Array | null = null;
    try {
      bytes = buildEntryZip(file, fs.statSync(jarPath).size);
    } finally {
      fs.closeSync(file);
    }
    if (bytes === null) {
      return [];
    }

    /* 解压器要求目标目录先存在。目录可以复用，同名文件会被覆盖。
     * 不能直接 `mkdirSync(…, true)`。 对已存在的目录它会抛 13900015
     *    `File exists`，而下面的 `finally` 是刻意
     *    「留目录复用」的 —— 所以第二次进来（换了个 jar、或缓存未命中）
     *    必定撞上它，异常被外层 `catch` 吞掉，只剩一句
     *    「could not read the locales」。表现是游戏语言静默回落英文，
     *    日志里没有任何线索指向真因。
     *    走 `ensureDir`：它先判存在、并发建目录时再判一次。 */
    if (!ensureDir(probeDir) || !ensureDir(outDir)) {
      hilog.warn(DOMAIN, TAG, 'could not prepare the probe directory %{public}s', probeDir);
      return [];
    }
    writeAll(zipPath, bytes);

    await zlib.decompressFile(zipPath, outDir);

    const text: string = fs.readTextSync(`${outDir}/${LOCALES_ENTRY}`);
    const lines: string[] = text.split('\n');
    const out: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const one: string = lines[i].trim();
      if (one !== '' && out.indexOf(one) === -1) {
        out.push(one);
      }
    }
    hilog.info(DOMAIN, TAG, 'the jar knows %{public}d locales', out.length);
    return out;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the locales from the jar: %{public}s',
      JSON.stringify(e));
    return [];
  } finally {
    /* 临时物用完就删。目录留着复用 —— 递归删要比这里多写一段，而两个空目录没有代价。 */
    try {
      fs.unlinkSync(zipPath);
    } catch (e) {
      /* 第一次跑、或者上次已经删过，删不掉是正常的。 */
    }
    try {
      fs.unlinkSync(`${outDir}/${LOCALES_ENTRY}`);
    } catch (e) {
      /* 同上。 */
    }
  }
}

/** 把一段字节整个写进文件。 */
function writeAll(path: string, bytes: Uint8Array): void {
  const file: fs.File = fs.openSync(path,
    fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
  try {
    fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
  } finally {
    fs.closeSync(file);
  }
}

/** 读缓存里的清单。路径、大小、修改时间三者全对才算命中。 */
async function readCachedLocales(ctx: common.UIAbilityContext,
                                 jarPath: string, size: number,
                                 mtime: number): Promise<string[]> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return [];
  }
  try {
    const raw = await store.get(KEY_CACHE, '') as string;
    if (raw === '') {
      return [];
    }
    const parsed = JSON.parse(raw) as LocaleCache;
    if (parsed.path !== jarPath || parsed.size !== size || parsed.mtime !== mtime) {
      return [];
    }
    return parsed.locales;
  } catch (e) {
    return [];
  }
}

async function writeCachedLocales(ctx: common.UIAbilityContext, jarPath: string,
                                  size: number, mtime: number,
                                  locales: string[]): Promise<void> {
  const store = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return;
  }
  try {
    const cache: LocaleCache = { path: jarPath, size: size, mtime: mtime, locales: locales };
    await store.put(KEY_CACHE, JSON.stringify(cache));
    await store.flush();
  } catch (e) {
    /* 缓存写不进去不影响任何事，下次再解一次。 */
  }
}

/** 读出这个 jar 认得的语言。带缓存。 */
export async function readJarLocales(ctx: common.UIAbilityContext,
                                     jarPath: string): Promise<string[]> {
  if (jarPath === '') {
    return [];
  }

  let size: number = 0;
  let mtime: number = 0;
  try {
    const st: fs.Stat = fs.statSync(jarPath);
    size = st.size;
    mtime = st.mtime;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not stat the jar: %{public}s', JSON.stringify(e));
    return [];
  }

  const cached: string[] = await readCachedLocales(ctx, jarPath, size, mtime);
  if (cached.length > 0) {
    return cached;
  }

  const locales: string[] = await readLocalesFromJar(ctx, jarPath);
  if (locales.length > 0) {
    await writeCachedLocales(ctx, jarPath, size, mtime, locales);
  }
  return locales;
}

/**
 * 在清单里挑一个最贴设备语言的值。
 * 顺序：先试「语言_地区」，再退回裸语言。
 * 顺序不能反：`zh` 不在 Mindustry 的清单里，而 `Locale("zh")` 会落到根包 = 英文
 *    —— 游戏只有 `zh_CN` / `zh_TW` 两套中文。先试带地区的，才能命中。
 * 地区一律大写，与 jar 里的写法一致。
 * 两个都命中不了就返回空。不猜 —— 猜错的话游戏会把这个错值写进 settings.bin。
 */
export function pickGameLocale(systemLang: string, systemRegion: string,
                               available: string[]): GameLocale {
  /* 系统标签可能带书写系统子标签（`zh-Hans` / `sr-Latn`），取第一段。
   * 别把子标签当地区：`zh_Hans` 不在任何清单里。 */
  const dash: number = systemLang.indexOf('-');
  const base: string = (dash === -1 ? systemLang : systemLang.substring(0, dash)).toLowerCase();

  if (base === '') {
    return emptyLocale('the system reported no language');
  }
  if (available.length === 0) {
    return emptyLocale('no locales list was read from the jar');
  }

  if (systemRegion !== '') {
    const region: string = systemRegion.toUpperCase();
    const withRegion: string = base + '_' + region;
    if (available.indexOf(withRegion) !== -1) {
      const hit: GameLocale = { lang: base, country: region, locale: withRegion,
                                reason: 'matched the language and region' };
      return hit;
    }
  }

  if (available.indexOf(base) !== -1) {
    const bare: GameLocale = { lang: base, country: '', locale: base,
                               reason: 'matched the language only' };
    return bare;
  }

  return emptyLocale(`the game does not ship ${base}`);
}

/**
 * 给一次启动定语言。
 * @param enabled 设置里那个「游戏语言跟随系统」开关。
 */
export async function resolveGameLocale(ctx: common.UIAbilityContext, jarPath: string,
                                        enabled: boolean): Promise<GameLocale> {
  if (!enabled) {
    return emptyLocale('the switch is off');
  }

  let systemLang: string = '';
  let systemRegion: string = '';
  try {
    systemLang = i18n.System.getSystemLanguage();
    systemRegion = i18n.System.getSystemRegion();
  } catch (e) {
    /* 拿不到就什么都不设 —— 硬猜一个会让游戏把它写死进 settings.bin。 */
    return emptyLocale('the system language could not be read');
  }

  const available: string[] = await readJarLocales(ctx, jarPath);
  const picked: GameLocale = pickGameLocale(systemLang, systemRegion, available);
  hilog.info(DOMAIN, TAG, 'locale: system=%{public}s/%{public}s -> %{public}s (%{public}s)',
    systemLang, systemRegion,
    picked.locale === '' ? '(none)' : picked.locale, picked.reason);
  return picked;
}
