import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { resolveOwnString } from '../i18n/UiLanguage';

/**
 * 游戏自己的 `settings.bin` 的读写。只做格式，不含任何业务判断。
 * 格式（ARC 的 Settings，大端）：
 *
 *   [i32 条目数]
 *   每条：
 *     [u16 键长度][键][u8 类型][值]
 *       0 BOOL   [u8]
 *       1 INT    [i32]
 *       2 LONG   [8 字节]
 *       3 FLOAT  [4 字节]
 *       4 STRING [u16 长度][字节]
 *       5 BYTES  [i32 长度][字节]
 *
 * 游戏永远写明文。见到 zlib 头就整体拒绝 —— 那是别人改过的文件，不是我们能理解的形态，
 *    硬写回去等于把玩家的设置抹掉。
 * 解析必须恰好用完所有字节。多出来说明我们对格式的理解有误，此时宁可不写。
 */

const DOMAIN = 0x0000;
const TAG = 'SettingsBin';

export const TYPE_BOOL: number = 0;
export const TYPE_INT: number = 1;
export const TYPE_LONG: number = 2;
export const TYPE_FLOAT: number = 3;
export const TYPE_STRING: number = 4;
export const TYPE_BYTES: number = 5;

/** 一条设置。`keyRaw` 原样保留，写回时逐字节照抄 —— 键里可能有非 ASCII 字节。 */
export interface GameSetting {
  key: string;
  keyRaw: Uint8Array;
  type: number;
  num: number;
  raw: Uint8Array;
}

/** 读游标。 */
class Cursor {
  private buf: Uint8Array;
  private at: number = 0;

  constructor(buf: Uint8Array) {
    this.buf = buf;
  }

  left(): number {
    return this.buf.length - this.at;
  }

  need(n: number): boolean {
    return this.left() >= n;
  }

  u8(): number {
    const v: number = this.buf[this.at];
    this.at += 1;
    return v;
  }

  u16(): number {
    const v: number = (this.buf[this.at] << 8) | this.buf[this.at + 1];
    this.at += 2;
    return v;
  }

  i32(): number {
    const v: number = (this.buf[this.at] << 24) | (this.buf[this.at + 1] << 16)
                    | (this.buf[this.at + 2] << 8) | this.buf[this.at + 3];
    this.at += 4;
    return v;
  }

  take(n: number): Uint8Array {
    const v: Uint8Array = this.buf.slice(this.at, this.at + n);
    this.at += n;
    return v;
  }
}

/** 键名的字节按 ASCII 看成字符串。只用于比较，不用于写。 */
function asciiView(b: Uint8Array): string {
  let s: string = '';
  for (let i = 0; i < b.length; i++) {
    s += String.fromCharCode(b[i]);
  }
  return s;
}

/** 我们自己造的键名一律是 ASCII 字面量，逐字符取低字节。 */
function asciiBytes(s: string): Uint8Array {
  const b: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    b[i] = s.charCodeAt(i) & 0xFF;
  }
  return b;
}

function isZlibHeader(a: number, b: number): boolean {
  return a === 0x78 && (b === 1 || b === 94 || b === 0x9C || b === 0xDA);
}

/** 解析。返回 null = 读不了或格式不认识 —— 调用方必须当成「不要动这个文件」。 */
export function parseSettings(bytes: Uint8Array): GameSetting[] | null {
  if (bytes.length > 1 && isZlibHeader(bytes[0], bytes[1])) {
    hilog.warn(DOMAIN, TAG, 'the file is zlib-compressed; the game never writes that -- refusing');
    return null;
  }

  const c: Cursor = new Cursor(bytes);
  if (!c.need(4)) {
    return null;
  }
  const count: number = c.i32();
  if (count <= 0) {
    return null;
  }

  const rows: GameSetting[] = [];
  for (let i = 0; i < count; i++) {
    if (!c.need(3)) {
      return null;
    }
    const keyLen: number = c.u16();
    if (!c.need(keyLen + 1)) {
      return null;
    }
    const keyRaw: Uint8Array = c.take(keyLen);
    const type: number = c.u8();
    const row: GameSetting = {
      key: asciiView(keyRaw),
      keyRaw: keyRaw,
      type: type,
      num: 0,
      raw: new Uint8Array(0),
    };

    if (type === TYPE_BOOL) {
      if (!c.need(1)) {
        return null;
      }
      row.num = c.u8() === 0 ? 0 : 1;
    } else if (type === TYPE_INT) {
      if (!c.need(4)) {
        return null;
      }
      row.num = c.i32();
    } else if (type === TYPE_LONG) {
      if (!c.need(8)) {
        return null;
      }
      row.raw = c.take(8);
    } else if (type === TYPE_FLOAT) {
      if (!c.need(4)) {
        return null;
      }
      row.raw = c.take(4);
    } else if (type === TYPE_STRING) {
      if (!c.need(2)) {
        return null;
      }
      const len: number = c.u16();
      if (!c.need(len)) {
        return null;
      }
      row.raw = c.take(len);
    } else if (type === TYPE_BYTES) {
      if (!c.need(4)) {
        return null;
      }
      const len: number = c.i32();
      if (len < 0 || !c.need(len)) {
        return null;
      }
      row.raw = c.take(len);
    } else {
      hilog.warn(DOMAIN, TAG, 'unknown type %{public}d for "%{public}s"', type, row.key);
      return null;
    }

    rows.push(row);
  }

  if (c.left() !== 0) {
    hilog.warn(DOMAIN, TAG, '%{public}d trailing byte(s) -- refusing', c.left());
    return null;
  }
  return rows;
}

/** 序列化成明文字节。 */
export function serializeSettings(rows: GameSetting[]): Uint8Array {
  let size: number = 4;
  for (let i = 0; i < rows.length; i++) {
    const r: GameSetting = rows[i];
    size += 2 + r.keyRaw.length + 1;
    if (r.type === TYPE_BOOL) {
      size += 1;
    } else if (r.type === TYPE_INT) {
      size += 4;
    } else if (r.type === TYPE_STRING) {
      size += 2 + r.raw.length;
    } else if (r.type === TYPE_BYTES) {
      size += 4 + r.raw.length;
    } else {
      size += r.raw.length;
    }
  }

  const out: Uint8Array = new Uint8Array(size);
  let at: number = 0;

  const putU16 = (v: number): void => {
    out[at] = (v >>> 8) & 0xFF;
    out[at + 1] = v & 0xFF;
    at += 2;
  };
  const putI32 = (v: number): void => {
    out[at] = (v >>> 24) & 0xFF;
    out[at + 1] = (v >>> 16) & 0xFF;
    out[at + 2] = (v >>> 8) & 0xFF;
    out[at + 3] = v & 0xFF;
    at += 4;
  };
  const putBytes = (b: Uint8Array): void => {
    out.set(b, at);
    at += b.length;
  };

  putI32(rows.length);
  for (let i = 0; i < rows.length; i++) {
    const r: GameSetting = rows[i];
    putU16(r.keyRaw.length);
    putBytes(r.keyRaw);
    out[at] = r.type;
    at += 1;

    if (r.type === TYPE_BOOL) {
      out[at] = r.num === 0 ? 0 : 1;
      at += 1;
    } else if (r.type === TYPE_INT) {
      putI32(r.num);
    } else if (r.type === TYPE_STRING) {
      putU16(r.raw.length);
      putBytes(r.raw);
    } else if (r.type === TYPE_BYTES) {
      putI32(r.raw.length);
      putBytes(r.raw);
    } else {
      putBytes(r.raw);
    }
  }

  return out;
}

/** 读一个 int 设置。键不在、或类型不是 int fallback。 */
export function intSetting(rows: GameSetting[], key: string, fallback: number): number {
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].key === key && rows[i].type === TYPE_INT) {
      return rows[i].num;
    }
  }
  return fallback;
}

/** 键存在吗（任何类型）。 */
export function hasSetting(rows: GameSetting[], key: string): boolean {
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].key === key) {
      return true;
    }
  }
  return false;
}

/**
 * 改一个 int 设置，不存在则追加。返回是否真的有改动。
 * 键存在但类型不是 int 时不动它 —— 那是别人写的东西，改类型会破坏游戏对它的解释。
 */
export function setIntSetting(rows: GameSetting[], key: string, value: number): boolean {
  for (let i = 0; i < rows.length; i++) {
    const r: GameSetting = rows[i];
    if (r.key !== key) {
      continue;
    }
    if (r.type !== TYPE_INT) {
      hilog.warn(DOMAIN, TAG, '"%{public}s" is type %{public}d, not int -- leaving it',
        key, r.type);
      return false;
    }
    if (r.num === value) {
      return false;
    }
    r.num = value;
    return true;
  }
  const added: GameSetting = {
    key: key,
    keyRaw: asciiBytes(key),
    type: TYPE_INT,
    num: value,
    raw: new Uint8Array(0),
  };
  rows.push(added);
  return true;
}

/** 读文件并解析。文件不存在 空数组（调用方据此判断要不要新建）。格式不认识 null。 */
export function loadSettings(path: string): GameSetting[] | null {
  let exists: boolean = false;
  try {
    exists = fs.accessSync(path);
  } catch (e) {
    exists = false;
  }
  if (!exists) {
    return [];
  }

  try {
    const size: number = fs.statSync(path).size;
    if (size <= 0 || size > 4 * 1024 * 1024) {
      hilog.warn(DOMAIN, TAG, 'refusing a file of %{public}d bytes', size);
      return null;
    }
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf: ArrayBuffer = new ArrayBuffer(size);
    let got: number = 0;
    try {
      got = fs.readSync(file.fd, buf);
    } finally {
      fs.closeSync(file);
    }
    return parseSettings(new Uint8Array(buf, 0, got));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read %{public}s: %{public}s', path, JSON.stringify(e));
    return null;
  }
}

/**
 * 写回。原子替换，写前自检、写后回读。
 * @return 空串 = 成功；否则是一句给人看的失败原因。
 */
export function saveSettings(ctx: common.UIAbilityContext, path: string,
                             rows: GameSetting[]): string {
  const raw: Uint8Array = serializeSettings(rows);

  /* 自检：序列化再解析必须得到同样的东西。宁可什么都不写，也不能把玩家的设置换成错的。 */
  const back: GameSetting[] | null = parseSettings(raw);
  if (back === null || back.length !== rows.length) {
    return resolveOwnString(ctx, $r('app.string.core_settings_selftest'),
      'core_settings_selftest');
  }
  for (let i = 0; i < rows.length; i++) {
    if (back[i].key !== rows[i].key || back[i].type !== rows[i].type) {
      return resolveOwnString(ctx, $r('app.string.core_settings_selftest_row', i + 1),
        'core_settings_selftest_row');
    }
  }

  const tempPath: string = `${path}.launchertmp`;
  try {
    const file: fs.File = fs.openSync(tempPath,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(file.fd, raw.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(file);
    }
  } catch (e) {
    return resolveOwnString(ctx, $r('app.string.core_settings_temp_write', JSON.stringify(e)),
      'core_settings_temp_write');
  }

  try {
    fs.renameSync(tempPath, path);
  } catch (e) {
    try {
      fs.unlinkSync(tempPath);
    } catch (ignored) {
      /* 临时文件删不掉也只是留个垃圾，不影响主文件。 */
    }
    return resolveOwnString(ctx, $r('app.string.core_settings_replace_fail', JSON.stringify(e)),
      'core_settings_replace_fail');
  }

  /* 回读校验：确认落到盘上的确实是我们写的那一串字节。 */
  try {
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf: ArrayBuffer = new ArrayBuffer(raw.length);
    let got: number = 0;
    try {
      got = fs.readSync(file.fd, buf);
    } finally {
      fs.closeSync(file);
    }
    if (got !== raw.length) {
      return resolveOwnString(ctx, $r('app.string.core_settings_readback_len', raw.length, got),
        'core_settings_readback_len');
    }
    const view: Uint8Array = new Uint8Array(buf, 0, got);
    for (let i = 0; i < raw.length; i++) {
      if (view[i] !== raw[i]) {
        return resolveOwnString(ctx, $r('app.string.core_settings_readback_byte', i),
          'core_settings_readback_byte');
      }
    }
  } catch (e) {
    return resolveOwnString(ctx, $r('app.string.core_settings_readback_err', JSON.stringify(e)),
      'core_settings_readback_err');
  }

  return '';
}
