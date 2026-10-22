import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 从一个大 jar 里读出某一个小文本条目的内容。
 * 为什么不直接把整个 jar 交给解压器：Mindustry 的包有 80 多 MB，而我们每次只要
 * 一百多字节（语言清单、版本属性）。全解一遍不划算，也没有必要。
 * 为什么能这么做：zip 的中央目录记着每个条目的本地头偏移与压缩长度，
 * 把那一小段原样搬过来、配上一条重建的中央目录和一个 EOCD，就是一个合法 zip。
 * 重建而不是照抄中央目录，是因为照抄的话里面记的偏移仍指向原 jar，解压器会读错位置。
 * 拼出来的迷你 zip 在 `ctx.tempDir` 下，读完就删。
 */

const DOMAIN = 0x0000;
const TAG = 'JarEntry';

/** zip 结构签名。 */
const SIG_EOCD = 0x06054b50;
const SIG_CEN = 0x02014b50;

/** EOCD 最长可能被 65535 字节注释推远，再加 22 字节记录本身。 */
const EOCD_SEARCH_MAX = 65535 + 22;

/** 小端读 16 位。 */
function u16(buf: Uint8Array, off: number): number {
  return buf[off] | (buf[off + 1] << 8);
}

/** 小端读 32 位。无符号化 —— 中央目录的偏移会超过 2^31 的一半。 */
function u32(buf: Uint8Array, off: number): number {
  return (buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)) >>> 0;
}

/**
 * 读文件的一段到内存。
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

function decodeUtf8(bytes: Uint8Array): string {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes);
}

/**
 * 在 jar 里找一条，把「只含这一条」的迷你 zip 拼出来。
 * @return 迷你 zip 的字节。找不到条目返回 null。
 */
function buildEntryZip(fd: fs.File, fileSize: number,
                       entryName: string): Uint8Array | null {
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

  /* ② 扫中央目录找条目。五千多个条目约 450 KB，整块读进来比逐条读快得多。 */
  const cd: Uint8Array = readRange(fd, cdOffset, cdSize);
  let p: number = 0;
  let localOffset: number = -1;
  let nameLen: number = 0;

  while (p + 46 <= cd.length && u32(cd, p) === SIG_CEN) {
    const fnLen: number = u16(cd, p + 28);
    const extraLen: number = u16(cd, p + 30);
    const commentLen: number = u16(cd, p + 32);

    if (fnLen === entryName.length) {
      const name: string = decodeUtf8(cd.subarray(p + 46, p + 46 + fnLen));
      if (name === entryName) {
        localOffset = u32(cd, p + 42);
        nameLen = fnLen;
        break;
      }
    }

    p += 46 + fnLen + extraLen + commentLen;
  }

  if (localOffset === -1) {
    hilog.info(DOMAIN, TAG, 'this jar has no %{public}s entry', entryName);
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
    hilog.warn(DOMAIN, TAG, 'the %{public}s entry runs past the end of the file', entryName);
    return null;
  }

  const segment: Uint8Array = readRange(fd, localOffset, segmentLen);

  /* ④ 重建中央目录条目：除本地头偏移改成 0 之外，其余字段照抄本地头。 */
  const cen: Uint8Array = new Uint8Array(46 + nameLen);
  cen[0] = 0x50;
  cen[1] = 0x4b;
  cen[2] = 0x01;
  cen[3] = 0x02;
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
  eocd[0] = 0x50;
  eocd[1] = 0x4b;
  eocd[2] = 0x05;
  eocd[3] = 0x06;
  eocd[8] = 1;
  eocd[9] = 0;
  eocd[10] = 1;
  eocd[11] = 0;
  const cdLen: number = cen.length;
  eocd[12] = cdLen & 0xFF;
  eocd[13] = (cdLen >> 8) & 0xFF;
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

/**
 * 读 jar 里某一条文本内容。
 * 任何失败都返回空串 —— 调用方据此走缺省路径，不让读不到 jar 内容挡住启动。
 * @param entryName 条目名，例如 `locales`、`version.properties`。区分大小写。
 */
export async function readJarTextEntry(ctx: common.UIAbilityContext, jarPath: string,
                                       entryName: string): Promise<string> {
  if (jarPath === '') {
    return '';
  }

  /* 每次用一个独立的临时目录：同一个 jar 可能同时被两个读取者问（语言、版本）。 */
  const probeDir: string = `${ctx.tempDir}/jar_entry_${entryName.replace(/[^a-zA-Z0-9]/g, '_')}`;
  const zipPath: string = `${probeDir}/entry.zip`;
  const outDir: string = `${probeDir}/out`;
  const outPath: string = `${outDir}/${entryName}`;

  try {
    const size: number = fs.statSync(jarPath).size;
    const file: fs.File = fs.openSync(jarPath, fs.OpenMode.READ_ONLY);
    let bytes: Uint8Array | null = null;
    try {
      bytes = buildEntryZip(file, size, entryName);
    } finally {
      fs.closeSync(file);
    }
    if (bytes === null) {
      return '';
    }

    /* 解压器要求目标目录先存在。目录可以复用，同名文件会被覆盖。 */
    if (!fs.accessSync(probeDir)) {
      fs.mkdirSync(probeDir, true);
    }
    if (!fs.accessSync(outDir)) {
      fs.mkdirSync(outDir, true);
    }
    writeAll(zipPath, bytes);

    await zlib.decompressFile(zipPath, outDir);

    return fs.readTextSync(outPath);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read %{public}s from the jar: %{public}s',
      entryName, JSON.stringify(e));
    return '';
  } finally {
    /* 临时物用完就删。目录留着复用 —— 递归删要比这里多写一段，而两个空目录没有代价。 */
    try {
      fs.unlinkSync(zipPath);
    } catch (e) {
      /* 第一次跑、或者上次已经删过，删不掉是正常的。 */
    }
    try {
      fs.unlinkSync(outPath);
    } catch (e) {
      /* 同上。 */
    }
  }
}
