import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'ImeBridge';

/**
 * 游戏进程的输入法桥。消费 SDL 写的那三个文件。
 * 为什么需要它：本进程把 libSDL3.so 映射了两次（详见 SDL_openharmony.c 的
 * KNOWN LIMITATION 注释）。`ime_controller_ref` 是那份 .so 的静态变量，ArkTS 把
 * controller 交给了不跑游戏的那一份，所以跑游戏的那一份拿到的永远是 NULL，
 * attach() 从不被调用，系统键盘永远不出现。
 * SDL 为此留了另一条路：拿不到 controller 时写三个文件，由应用自己弹一个 ArkUI
 * 输入框。SDL 侧那一半已经实现，缺的是这一侧 —— 本文件就是那半。
 * 路径必须逐字等于 SDL_openharmonyevents.h 的三个宏。那里还写着：这些文件在
 *    应用级 filesDir，而 `ctx.filesDir` 是 HAP 级的另一个地方 —— 用错了
 *    永远不会被看到，而且不会有任何报错。
 */

/** 应用级文件目录。不是 ctx.filesDir。 */
const IME_DIR: string = '/data/storage/el2/base/files';
const IME_WANT: string = IME_DIR + '/ime_want';
const IME_CMD: string = IME_DIR + '/ime_cmd';
const IME_RECT: string = IME_DIR + '/ime_rect';

/** 轮询周期。200ms 是前身实测出来的手感。 */
const POLL_MS: number = 200;

/**
 * 玩家主动收起键盘之后的保护期。
 * 那段时间里即使 ime_want 还在也不重新弹 —— 玩家刚把它关掉，立刻又弹出来是在
 * 跟他作对。保护期过了 want 还在，说明转发的 ESC 没让游戏放开文本输入，
 * 那时记一条警告再恢复响应。
 */
const DISMISS_MS: number = 1500;

/** 输入框比游戏框高出的量。键盘避让靠它把整页推得足够多。 */
export const IME_FIELD_MARGIN_VP: number = 24;

/** 从 ime_rect 读到的矩形，单位是像素（SDL 给的就是像素）。 */
export interface ImeRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 矩形是否可用。SDL_Window 是 calloc 出来的，第一次可能是 {0,0,0,0}。 */
function rectIsUsable(r: ImeRect): boolean {
  return r.w > 0 && r.h > 0 && r.x >= 0 && r.y >= 0;
}

/**
 * 一次轮询的结论。页面照这个更新 @State。
 */
export interface ImeSnapshot {
  /** 是否该显示我们的输入框。 */
  shown: boolean;
  /** 游戏文本框的矩形，像素。无效时是上一次的有效值（或全 0）。 */
  rect: ImeRect;
}

/**
 * 桥本体。页面持有一个实例，start/stop 跟页面生命周期走。
 * 它不持有 Ability 实例，也不碰 AppStorage —— 只做文件与状态。
 *    界面怎么画、焦点给谁，是页面的事。
 */
export class ImeBridge {
  private timerId: number = -1;
  private shown: boolean = false;
  private rect: ImeRect = { x: 0, y: 0, w: 0, h: 0 };
  /** 上一次已经发给游戏的文本，用来算差量。 */
  private sentText: string = '';
  /** 玩家主动收起键盘的时间戳。0 = 没有主动收起过。 */
  private dismissedAt: number = 0;
  /** 「保护期过了但 want 还在」只警告一次，免得刷屏。 */
  private leakWarned: boolean = false;
  private onUpdate: (snap: ImeSnapshot) => void = () => {};

  /**
   * 开始轮询。先清残留 —— 上次异常退出留下的 ime_want 会让键盘一进游戏就弹。
   * 只删 want 与 cmd，不删 rect：rect 是 SDL 写的，删掉没有意义，
   *    而它下次被重新写入之前，留着旧值反而能让第一次定位更准。
   */
  start(onUpdate: (snap: ImeSnapshot) => void): void {
    this.onUpdate = onUpdate;
    this.removeFile(IME_WANT, 'ime_want');
    this.removeFile(IME_CMD, 'ime_cmd');
    this.shown = false;
    this.sentText = '';
    this.dismissedAt = 0;
    this.leakWarned = false;

    if (this.timerId !== -1) {
      clearInterval(this.timerId);
    }
    this.timerId = setInterval(() => {
      this.pollOnce();
    }, POLL_MS);
    hilog.info(DOMAIN, TAG, 'polling started (%{public}dms)', POLL_MS);
  }

  /** 停止轮询并清掉两个命令文件，免得下一局读到一个过期的 want。 */
  stop(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.removeFile(IME_WANT, 'ime_want');
    this.removeFile(IME_CMD, 'ime_cmd');
    this.shown = false;
    this.sentText = '';
    hilog.info(DOMAIN, TAG, 'polling stopped');
  }

  /** 页面读：现在该不该显示输入框。 */
  isShown(): boolean {
    return this.shown;
  }

  /** 页面读：输入框该摆在哪（像素）。 */
  currentRect(): ImeRect {
    return this.rect;
  }

  /**
   * 玩家主动收起了键盘（点空白、按返回、点完成）。
   * 不直接改 shown —— 下一次轮询会看到 want 还在，那时才由保护期决定要不要重弹。
   * 这里只记时间。
   */
  markUserDismissed(): void {
    this.dismissedAt = Date.now();
    this.shown = false;
    hilog.info(DOMAIN, TAG, 'the player dismissed the keyboard');
  }

  /**
   * 把输入框的当前文本发给游戏。
   * 发的是差量不是全文。游戏侧收到的是一串按键事件，不是「设置文本」——
   *    所以「abcd」变成「abc」必须发一个退格，而不是重发。
   * 中文组字期间 IME 会反复给出中间结果（拼音串），每一次都按差量发出去，
   *    所以游戏框里会短暂出现拼音字母，组字完成时被替换成汉字。这与前身一致。
   */
  sendDelta(next: string): void {
    /* 换行由 onSubmit 处理；文本里混进的回车会让游戏多开一行。 */
    const clean: string = next.replace(/[\r\n]/g, '');
    const prev: string = this.sentText;
    if (clean === prev) {
      return;
    }

    let cmds: string = '';
    if (clean.startsWith(prev)) {
      /* 追加。 */
      cmds = 'T' + clean.substring(prev.length) + '\n';
    } else if (prev.startsWith(clean)) {
      /* 删除末尾若干个字符。 */
      cmds = 'B' + (prev.length - clean.length) + '\n';
    } else {
      /* 整段变了（组字完成、粘贴）。先删光再重发。 */
      if (prev.length > 0) {
        cmds += 'B' + prev.length + '\n';
      }
      cmds += 'T' + clean + '\n';
    }

    this.appendCmd(cmds);
    this.sentText = clean;
  }

  /**
   * 把 ESC 转给游戏。
   * 为什么必须这么做：我们的 ArkUI 输入框拿到焦点时，返回键会被系统当成 Back，
   * 游戏根本看不到它 —— 于是它的对话框关不掉，会一直要文本，键盘也就一直弹。
   * 把 ESC 从这条缝里塞回去，后面的链条会自己解开：游戏关对话框 → 放开文本输入
   * → ime_want 消失 → 我们收键盘。
   */
  sendEscape(): void {
    this.appendCmd('E\n');
    hilog.info(DOMAIN, TAG, 'forwarded ESC to the game');
  }

  /* ---------------- 内部 ---------------- */

  private pollOnce(): void {
    const want: boolean = this.fileExists(IME_WANT);

    if (!want) {
      if (this.shown) {
        this.shown = false;
        hilog.info(DOMAIN, TAG, 'the game no longer wants text; hiding');
        this.publish();
      }
      this.dismissedAt = 0;
      this.leakWarned = false;
      this.sentText = '';
      return;
    }

    /* 玩家刚关掉，先别急着弹回去。 */
    if (this.dismissedAt !== 0 && Date.now() < this.dismissedAt + DISMISS_MS) {
      return;
    }
    if (this.dismissedAt !== 0) {
      if (!this.leakWarned) {
        this.leakWarned = true;
        hilog.warn(DOMAIN, TAG,
          'the game still wants text after the keyboard was dismissed -- the forwarded ESC did not release it');
      }
      this.dismissedAt = 0;
    }

    this.readRect();

    if (!this.shown) {
      this.shown = true;
      /* 新的一次输入，差量从零开始 —— 否则会把上一次的残留当成本次的已输入内容。 */
      this.sentText = '';
      hilog.info(DOMAIN, TAG, 'the game wants text; showing the field at %{public}d,%{public}d %{public}dx%{public}d',
        this.rect.x, this.rect.y, this.rect.w, this.rect.h);
      this.publish();
    }
  }

  private publish(): void {
    const snap: ImeSnapshot = { shown: this.shown, rect: this.rect };
    this.onUpdate(snap);
  }

  /** 读 ime_rect。无效数据不覆盖上一次的值。 */
  private readRect(): void {
    let text: string = '';
    try {
      text = fs.readTextSync(IME_RECT);
    } catch (e) {
      /* 文件还没被写出来，正常。 */
      return;
    }

    const parts: string[] = text.trim().split(' ');
    if (parts.length !== 4) {
      return;
    }

    const x: number = Number.parseInt(parts[0], 10);
    const y: number = Number.parseInt(parts[1], 10);
    const w: number = Number.parseInt(parts[2], 10);
    const h: number = Number.parseInt(parts[3], 10);
    if (!Number.isFinite(x) || !Number.isFinite(y)
        || !Number.isFinite(w) || !Number.isFinite(h)) {
      return;
    }

    const next: ImeRect = { x: x, y: y, w: w, h: h };
    if (!rectIsUsable(next)) {
      /* 第一次聚焦时 SDL 可能还没算出框，保留旧值。 */
      return;
    }

    if (next.x === this.rect.x && next.y === this.rect.y
        && next.w === this.rect.w && next.h === this.rect.h) {
      return;
    }
    this.rect = next;
  }

  /** 追加一条（或多条）命令。SDL 按行解析，所以每条都必须以 \n 结尾。 */
  private appendCmd(text: string): void {
    try {
      const f: fs.File = fs.openSync(IME_CMD,
        fs.OpenMode.CREATE | fs.OpenMode.APPEND | fs.OpenMode.READ_WRITE);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'could not append a command: %{public}s', JSON.stringify(e));
    }
  }

  private fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private removeFile(path: string, label: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
        hilog.info(DOMAIN, TAG, 'cleared a stale %{public}s', label);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'could not clear %{public}s: %{public}s', label, JSON.stringify(e));
    }
  }
}
