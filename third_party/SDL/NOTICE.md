# SDL3 — 改动说明

## 来源

- 上游：`https://github.com/libsdl-org/SDL`，`main` 分支
- 取得方式：`curl -L -o sdl.tar.gz https://codeload.github.com/libsdl-org/SDL/tar.gz/refs/heads/main`
- 取得日期：2026-09-18
- 树内自报版本：3.5.0

这不是 SDL 的正式发行版。上游的鸿蒙后端于 2026-09-15 合进 `main`，而当时最新的正式 release 是 3.4.16 —— 发行版里没有鸿蒙后端，只能从 `main` 取。本树是 `main` 在 2026-09-18 那一刻的快照，「3.5.0」是它自己报告的开发中版本号。

本仓库无法逐字节复现这棵树。取用时没有记录 commit SHA，`SDL_revision.h` 里的 `SDL_REVISION` 也是空串。今天重新下载 `main` 会得到另一棵树。

## 为什么本仓库只放 6 个文件

完整 SDL 源码树有 1,703 个文件、约 37 MB。本仓库只提供被修改过的那 6 个文件，其余请自行从上游获取。

用法：下载上游 `main`，把 `modified/` 下这 6 个文件覆盖到对应路径。

| `modified/` 下 | 覆盖到 SDL 树的 |
|---|---|
| `SDL_openharmony.c` | `src/core/openharmony/SDL_openharmony.c` |
| `SDL_openharmonyevents.c` | `src/video/openharmony/SDL_openharmonyevents.c` |
| `SDL_openharmonyevents.h` | `src/video/openharmony/SDL_openharmonyevents.h` |
| `SDL_openharmonyvideo.c` | `src/video/openharmony/SDL_openharmonyvideo.c` |
| `SDL_openharmonyvideo.h` | `src/video/openharmony/SDL_openharmonyvideo.h` |
| `SDL_openharmonywindow.c` | `src/video/openharmony/SDL_openharmonywindow.c` |

## 改动清单

全部位于鸿蒙后端目录，合计 3,033 行。

| 文件 | 行数 | 改了什么 |
|---|---:|---|
| `SDL_openharmony.c` | 1,324 | 含输入法（IME）事件相关改动 |
| `SDL_openharmonyevents.c` | 930 | 双映射桥 + 回调接管 |
| `SDL_openharmonyevents.h` | 52 | 双映射桥声明 |
| `SDL_openharmonyvideo.c` | 447 | 双映射桥 |
| `SDL_openharmonyvideo.h` | 67 | `SDL_OPENHARMONY_BRIDGE_*` 槽位定义 |
| `SDL_openharmonywindow.c` | 213 | `SDL_OpenHarmonyAdoptXComponent` |

## 为什么必须改

### 一、双映射桥

同一进程里存在两份 `libSDL3.so` 的映射：一份由 ArkTS 的 XComponent 加载，另一份由游戏侧加载。C 的静态变量在这两份映射之间不互通 —— 一边写，另一边读不到。

用三个固定槽位把 `component`、`surface`、`window` 从一个映射传给另一个：

```c
#define SDL_OPENHARMONY_BRIDGE_COMPONENT 0
#define SDL_OPENHARMONY_BRIDGE_SURFACE   1
#define SDL_OPENHARMONY_BRIDGE_WINDOW    2
#define SDL_OPENHARMONY_BRIDGE_SLOTS     3
```

定义在 `SDL_openharmonyvideo.h`。

### 二、XComponent 回调接管

XComponent 的回调必须由持有 window 与事件队列的那一份映射接管，否则触摸事件会解引用空指针。

`SDL_OpenHarmonyAdoptXComponent()` 在窗口创建后接管回调（调用点见 `SDL_openharmonywindow.c`）。接管之后，`NULL` 不再作为「未初始化」的判据（说明见 `SDL_openharmonyevents.c` 的注释）。

### 三、输入法事件

屏幕键盘的输入法事件走鸿蒙自身的文本输入通道，需要在 SDL 侧改事件处理。这部分改动在 `SDL_openharmony.c` 里。

## 许可

SDL3 采用 zlib 许可。原许可全文见上游 `LICENSE.txt`。

zlib 许可第 2 条原文：

> Altered source versions must be plainly marked as such, and must not be
> misrepresented as being the original software.

`modified/` 下这 6 个文件是修改版，不是上游原文。引用时不得描述为「原版 SDL3」。

## 已知缺口

`SDL_openharmonyvideo.h` 与 `SDL_openharmonywindow.c` 的改动，在 Ark Launcher 的 git 历史里查不到对应提交 —— 它们很可能在仓库建立之前就已改好，随初始提交一并导入。另 4 个文件对应提交 `9ab8507`。
