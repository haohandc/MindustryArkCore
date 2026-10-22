//
// Created on 2026/10/17.
//
// 进程生命周期。
//  本文件被 SDL_main.h 改写了 main 的定义 —— SDL 用 dlsym 找的正是 "SDL_main"。
//    不要在这里 include 任何与 SDL 无关的重型头文件（NAPI 那套在 napi_init.c）。

#include <SDL3/SDL_main.h>

#include <dlfcn.h>       // dladdr
#include <fcntl.h>       // open / O_WRONLY
#include <pthread.h>     // pthread_self / pthread_getname_np
#include <signal.h>      // sigaction / SIGSEGV
#include <stdint.h>      // uintptr_t
#include <stdio.h>       // setvbuf / fflush
#include <stdlib.h>      // setenv
#include <sys/syscall.h> // SYS_gettid
#include <unistd.h>      // dup2 / getpid / _exit
#include <ucontext.h>    // ucontext_t
#include <hilog/log.h>

#include "globals.h"

#define MX_LOG_DOMAIN 0x0000
#define MX_LOG_TAG    "ArkLauncherPro"

static SDL_LogOutputFunction g_prev_log_output = NULL;
static void *g_prev_log_userdata = NULL;

/* SDL 的日志镜像进 hilog。镜像是为了 hdc 能直接抓 —— 文件要用 hdc file recv 拿，
 * 而 hilog 对任何签名都可读。用回调而不是在调用点包宏：SDL3 允许替换汇聚点。 */
static void SDLCALL mirror_log_to_hilog(void *userdata, int category,
                                        SDL_LogPriority priority, const char *message)
{
    /* 先保留原来的行为：万一这里出岔子，文件里仍然有那一行。 */
    if (g_prev_log_output != NULL) {
        g_prev_log_output(g_prev_log_userdata, category, priority, message);
    }

    LogLevel level;
    switch (priority) {
        case SDL_LOG_PRIORITY_VERBOSE:
        case SDL_LOG_PRIORITY_DEBUG:    level = LOG_DEBUG; break;
        case SDL_LOG_PRIORITY_WARN:     level = LOG_WARN;  break;
        case SDL_LOG_PRIORITY_ERROR:
        case SDL_LOG_PRIORITY_CRITICAL: level = LOG_ERROR; break;
        default:                        level = LOG_INFO;  break;
    }
    /* 一次调用、一个 public 字符串：hilog 对 private 字段在 release 包里会打码。 */
    OH_LOG_Print(LOG_APP, level, MX_LOG_DOMAIN, MX_LOG_TAG, "%{public}s", message);
}

static void install_hilog_mirror(void)
{
    SDL_GetLogOutputFunction(&g_prev_log_output, &g_prev_log_userdata);
    SDL_SetLogOutputFunction(mirror_log_to_hilog, NULL);
}

/* 把 stdout / stderr 落到沙箱里的两个文件。
 * JVM 与游戏往 stdout 写的东西比 SDL_Log 多得多，而那些正是崩溃前最后的证据。 */
static void redirect_io(void)
{
    char path[G_DATAROOT_CAP + 16];

    /*  必须同时判 n > 0 与 n < cap：SDL_snprintf 失败时返回负数，
     *    只看「小于容量」会把一个空路径当成合法路径去 open。 */
    int n = SDL_snprintf(path, sizeof(path), "%s/stdout.log", g_data_root);
    if (n > 0 && n < (int) sizeof(path)) {
        int fo = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fo >= 0) { dup2(fo, 1); if (fo > 2) close(fo); }
    }

    n = SDL_snprintf(path, sizeof(path), "%s/stderr.log", g_data_root);
    if (n > 0 && n < (int) sizeof(path)) {
        int fe = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fe >= 0) { dup2(fe, 2); if (fe > 2) close(fe); }
    }

    /* 不缓冲：崩溃发生在下一次 flush 之前时，缓冲区里的那一行就没了，
     * 而那恰恰是最后一行。 */
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

/* 当前线程的名字。把游戏线程上的错误与 SDL UI 事件路径上的错误区分开 ——
 * SDL 在它自己 pthread_create() 出来的线程上跑 SDL_main，不是进程主线程。 */
static const char *thread_name(void)
{
    static char tn[64];
    if (tn[0]) {
        return tn;
    }
    if (pthread_getname_np(pthread_self(), tn, sizeof(tn)) != 0 || !tn[0]) {
        SDL_strlcpy(tn, "(unnamed)", sizeof(tn));
    }
    return tn;
}

/* 查一个地址落在 /proc/self/maps 的哪一行，把那行原样抄进 buf。
 * 单看一个地址说明不了任何事；配上它所属的区间就同时得到两样东西 —— 属于哪个库，
 * 以及那一段的权限：
 *   r-xp  代码段       —— 执行到了错的指令
 *   rw-p  数据段       —— 写坏了数据，或者把数据当函数调
 *   rwx-  无名可执行   —— JIT 生成的代码（坚盾模式禁的正是这种内存）
 *   ---p  保护页       —— 栈溢出，越过了栈的边界
 *   查不到             —— 指针算飞了，不属于任何映射
 *
 *  fopen / fgets 不是异步信号安全的，在处理器里跑有极小的概率二次崩溃。
 *    调用点因此排在「主报告已经写进 crash.txt 之后」—— 查的时候崩了，证据也已落盘。 */
static void describe_mapping(unsigned long addr, char *buf, size_t cap)
{
    buf[0] = '\0';

    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) {
        SDL_snprintf(buf, cap, "(no /proc/self/maps)");
        return;
    }

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        unsigned long lo = 0, hi = 0;
        if (sscanf(line, "%lx-%lx", &lo, &hi) == 2 && addr >= lo && addr < hi) {
            char *nl = strchr(line, '\n');
            if (nl) *nl = '\0';
            SDL_snprintf(buf, cap, "%s", line);
            fclose(f);
            return;
        }
    }

    fclose(f);
    SDL_snprintf(buf, cap, "(address is in NO mapping)");
}

/* ucontext_t 里程序计数器的字段名与寄存器布局逐架构不同：
 *   aarch64 —— uc_mcontext.pc / .sp / .pstate / .regs[31]
 *   x86_64  —— uc_mcontext.gregs[REG_RIP] / [REG_RSP]，没有单列的 pc 字段
 * 所以取值一律经这两个口子，不要在别处直接碰 uc_mcontext。 */
static unsigned long ucontext_pc(const ucontext_t *uc)
{
#if defined(__aarch64__)
    return (unsigned long) uc->uc_mcontext.pc;
#elif defined(__x86_64__)
    return (unsigned long) uc->uc_mcontext.gregs[REG_RIP];
#else
    (void) uc;
    return 0;
#endif
}

static unsigned long ucontext_sp(const ucontext_t *uc)
{
#if defined(__aarch64__)
    return (unsigned long) uc->uc_mcontext.sp;
#elif defined(__x86_64__)
    return (unsigned long) uc->uc_mcontext.gregs[REG_RSP];
#else
    (void) uc;
    return 0;
#endif
}

/* 致命信号处理器。只做一件事：把「哪里出的错」落到 crash.txt 并再抛一次。
 *
 * 报告四个东西，它们回答四个不同的问题：
 *   si_addr —— 什么被碰了（小偏移处常是 0x20 之类，说明不了是哪个库）
 *   pc      —— 错的是哪条指令，永远落在真实映射里，能答「哪个库、还是 JIT 代码」
 *   mapping —— pc 所属区间的权限与来源，见 describe_mapping()
 *   thread  —— 这条错误发生在哪条线程上
 *
 *  用 O_APPEND 写：信号可能在 stdout 可用之前就袭来，追加写保证报告不丢。
 *    代价是这个文件跨启动累积，所以 main() 每次启动先删它。 */
static void on_fatal_signal(int sig, siginfo_t *info, void *uctx)
{
    const char *name = "?";
    Dl_info dl;
    SDL_memset(&dl, 0, sizeof(dl));
    if (info && dladdr(info->si_addr, &dl) && dl.dli_fname) {
        name = dl.dli_fname;
    }

    char pcinfo[700];
    pcinfo[0] = '\0';
    if (uctx) {
        unsigned long faultpc = ucontext_pc((ucontext_t *)uctx);
        Dl_info pd;
        SDL_memset(&pd, 0, sizeof(pd));
        SDL_snprintf(pcinfo, sizeof(pcinfo),
                     "    pc 0x%lx in %s\n    thread %s\n",
                     faultpc,
                     (dladdr((void *)faultpc, &pd) && pd.dli_fname)
                        ? pd.dli_fname : "(no module -- JIT code?)",
                     thread_name());
    }

    char regs[1400];
    regs[0] = '\0';
    if (uctx) {
        const ucontext_t *uc = (const ucontext_t *)uctx;
        int n = SDL_snprintf(regs, sizeof(regs), "    regs:");

#if defined(__aarch64__)
        for (int i = 0; i <= 30; i++) {
            if (n > (int) sizeof(regs) - 24) break;
            n += SDL_snprintf(regs + n, sizeof(regs) - n, " x%d=%lx",
                              i, (unsigned long) uc->uc_mcontext.regs[i]);
            if (i % 4 == 3) {
                n += SDL_snprintf(regs + n, sizeof(regs) - n, "\n         ");
            }
        }
        n += SDL_snprintf(regs + n, sizeof(regs) - n,
                          "\n    sp=%lx pc=%lx pstate=%lx  pc==si_addr? %s\n",
                          ucontext_sp(uc),
                          (unsigned long) uc->uc_mcontext.pc,
                          (unsigned long) uc->uc_mcontext.pstate,
                          (ucontext_pc(uc) ==
                           (unsigned long)(uintptr_t)(info ? info->si_addr : NULL))
                              ? "YES" : "NO");
#elif defined(__x86_64__)
        /* gregs 的顺序不是 r0..r15，抄的是 x86_64 的 REG_* 常量顺序。 */
        static const char *GREG_NAMES[16] = {
            "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
            "rdi", "rsi", "rbp", "rbx", "rdx", "rax", "rcx", "rsp",
        };
        for (int i = 0; i < 16; i++) {
            if (n > (int) sizeof(regs) - 28) break;
            n += SDL_snprintf(regs + n, sizeof(regs) - n, " %s=%llx",
                              GREG_NAMES[i],
                              (unsigned long long) uc->uc_mcontext.gregs[i]);
            if (i % 4 == 3) {
                n += SDL_snprintf(regs + n, sizeof(regs) - n, "\n         ");
            }
        }
        n += SDL_snprintf(regs + n, sizeof(regs) - n,
                          "\n    sp=%llx rip=%llx eflags=%llx  pc==si_addr? %s\n",
                          (unsigned long long) ucontext_sp(uc),
                          (unsigned long long) uc->uc_mcontext.gregs[REG_RIP],
                          (unsigned long long) uc->uc_mcontext.gregs[REG_EFL],
                          (ucontext_pc(uc) ==
                           (unsigned long)(uintptr_t)(info ? info->si_addr : NULL))
                              ? "YES" : "NO");
#endif
        (void) n;
    }

    char buf[2600];
    int n = SDL_snprintf(buf, sizeof(buf),
                         "*** FATAL SIGNAL %d (code=%d) at %p  -> in %s ***\n%s%s",
                         sig, info ? info->si_code : -1,
                         info ? info->si_addr : NULL, name,
                         pcinfo, regs);

    /*  n 是「本该写入的长度」，不是实际写进去的（snprintf 语义）。
     *    截断时它大于 sizeof(buf)，直接当 write 长度就是从栈上越界读。 */
    if (n > 0) {
        if (n > (int) sizeof(buf) - 1) {
            n = (int) sizeof(buf) - 1;
        }

        char path[G_DATAROOT_CAP + 16];
        int pn = SDL_snprintf(path, sizeof(path), "%s/crash.txt", g_data_root);
        if (pn > 0 && pn < (int) sizeof(path)) {
            int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) {
                ssize_t w = write(fd, buf, (size_t) n);
                (void) w;
                close(fd);
            }
        }
        ssize_t w2 = write(2, buf, (size_t) n);
        (void) w2;
    }

    /* 映射查询排在主报告之后：它要 fopen + fgets，不是异步信号安全的，
     * 万一在这里二次崩溃，上面的报告已经落盘了。只查 pc —— si_addr 常常不属于任何映射
     * （空指针加小偏移），而 pc 一定落在真实指令上，结论最确定。 */
    if (uctx) {
        char map[600];
        describe_mapping(ucontext_pc((const ucontext_t *)uctx), map, sizeof(map));

        char tail[700];
        int tn = SDL_snprintf(tail, sizeof(tail), "    mapping: %s\n", map);
        if (tn > 0) {
            if (tn > (int) sizeof(tail) - 1) {
                tn = (int) sizeof(tail) - 1;
            }

            char path[G_DATAROOT_CAP + 16];
            int pn = SDL_snprintf(path, sizeof(path), "%s/crash.txt", g_data_root);
            if (pn > 0 && pn < (int) sizeof(path)) {
                int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
                if (fd >= 0) {
                    ssize_t w = write(fd, tail, (size_t) tn);
                    (void) w;
                    close(fd);
                }
            }
            ssize_t w2 = write(2, tail, (size_t) tn);
            (void) w2;
        }
    }

    signal(sig, SIG_DFL);
    raise(sig);
}

/* 把上一场的三类证据挪到 .prev，而不是删掉。
 *
 * 为什么不是 unlink：崩溃现场往往要等到【下一次启动之后】才有人去读 —— 设备上一次崩溃
 * 之后紧接着又点了一次开始游戏，crash.txt 与 stderr/stdout 就被那次启动清空了，
 * 现场只剩下 cppcrash 转储里一份没有符号的栈。
 *
 * 为什么不用时间戳当后缀：TMP 之外的时间格式化要拉 time.h 与 localtime，
 * 而这个函数在启动最早期跑。固定后缀够用 —— 要的只是「上一场」。
 *
 *  rename 在同一文件系统内是原子的，不会留下半个文件。跨文件系统才失败，
 *    而这三份都在同一个 g_data_root 下。 */
static void rotate_evidence(void)
{
    static const char *NAMES[] = { "crash.txt", "stderr.log", "stdout.log" };
    enum { N = (int) (sizeof(NAMES) / sizeof(NAMES[0])) };

    for (int i = 0; i < N; i++) {
        char from[G_DATAROOT_CAP + 32];
        char to[G_DATAROOT_CAP + 32];

        int nf = SDL_snprintf(from, sizeof(from), "%s/%s", g_data_root, NAMES[i]);
        int nt = SDL_snprintf(to,   sizeof(to),   "%s/%s.prev", g_data_root, NAMES[i]);
        if (nf <= 0 || nf >= (int) sizeof(from) || nt <= 0 || nt >= (int) sizeof(to)) {
            continue;
        }

        if (access(from, F_OK) == 0) {
            if (rename(from, to) == 0) {
                SDL_Log(" kept the previous run's %s as %s.prev", NAMES[i], NAMES[i]);
            }
        }
    }
}

/* 只在选项文件不要求放过它们时安装。为什么成了变量：它们从最初那版起一直装、覆盖 SIGILL
 * —— 恰恰是我们正死于其上的信号；而 HotSpot 在 JNI_CreateJavaVM 期间装它自己的处理器并用
 * 链式方案（认不出就转给先前安装的），若看到我们那个在跑，说明 HotSpot 没把这次错误认作自己的。
 * SA_RESETHAND：处理器只跑一次，之后回到默认行为，避免在处理器里二次崩溃时无限递归。 */
static void install_crash_handlers(void)
{
    struct sigaction sa;
    SDL_memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_fatal_signal;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);

    const int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE };
    for (int i = 0; i < (int) (sizeof(sigs) / sizeof(sigs[0])); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
}

/* 启动链的入口。返回值即进程退出码 —— 完整码表见 start_jvm() 的注释。 */
int main(int argc, char *argv[])
{
    (void) argc;
    (void) argv;

    install_hilog_mirror();

    /* 阻止 SDL 把触摸变成鼠标事件（SDL 默认这么做）。否则每次触摸到达两次 —— 一次模拟鼠标、
     * 一次真实手指 —— 而 Arc 只理解鼠标那一半，所以点击能用却永远捏合不了（模拟鼠标永远是
     * pointer 0，捏合由第二个接触点定义）。用环境变量而不是 SDL_SetHint：本进程有两份
     * libSDL3.so 映射而只有一份分发触摸事件，环境变量两者共享。 */
    setenv("SDL_TOUCH_MOUSE_EVENTS", "0", 1);

    SDL_Log("==================================================");
    SDL_Log(" Ark Launcher Pro -- start the JVM");

    /* 沙箱路径必须先拿到 —— stdout 往哪写、java.home 装配在哪，全依赖它。 */
    int discovered = discover_paths();
    if (discovered < 0) {
        SDL_Log(" !! cannot resolve the sandbox paths -- refusing to start");
        atomic_store(&g_plan.exit_code, 7);
        atomic_store(&g_plan.stage, PLAN_STAGE_FAILED);
        return 7;
    }

    /*  必须排在 redirect_io() 之前：那边用 O_TRUNC 打开 stdout/stderr，
     *    晚一步就把上一场的证据截成空文件了。 */
    rotate_evidence();

    redirect_io();
    SDL_Log(" stdout/stderr -> %s/{stdout,stderr}.log", g_data_root);
    SDL_Log(" PID=%d TID=%ld", (int) getpid(), (long) syscall(SYS_gettid));
    SDL_Log(" jdk home    : %s", g_jdkhome);
    SDL_Log(" jdk lib dir : %s", g_jdklib);
    SDL_Log(" anchor      : %s", g_anchor);

    /* 没有计划就不启动。走到这里而 g_plan.valid 为 0，意味着 GameAbility 没有在触发 SDL
     * 之前调用 setLaunchPlan —— 那时连游戏 jar 和 user.home 都不知道，起 JVM 只会白等
     * 一次 140 MB 的模块镜像装配。 */
    if (!g_plan.valid) {
        SDL_Log(" !! no launch plan -- setLaunchPlan() was never called");
        SDL_Log("    refusing to start");
        atomic_store(&g_plan.exit_code, 8);
        atomic_store(&g_plan.stage, PLAN_STAGE_FAILED);
        return 8;
    }

    if (g_plan.dev_nohandlers) {
        SDL_Log(" ** dev_nohandlers: not installing crash handlers");
        SDL_Log("    HotSpot's own signal handling is left completely undisturbed");
    } else {
        install_crash_handlers();
    }

    SDL_Log("--------------------------------------------------");

    int rc = start_jvm();

    SDL_Log("--------------------------------------------------");
    SDL_Log(" result = %d", rc);

    /* 先写 exit_code 再写 stage：_Atomic 默认的 seq_cst 保证「看到 stage 变了，
     * 就一定看得到它之前写的 exit_code」，读者拿到的组合不会自相矛盾。 */
    atomic_store(&g_plan.exit_code, rc);
    if (rc != 0) {
        atomic_store(&g_plan.stage, PLAN_STAGE_FAILED);
    }

    /* 退出握手分两段。直接 _exit 会在 ability 还活着时结束进程，系统把这次退出归档成
     * "Cpp Crash"。所以先置 finished 告诉 ArkTS「结果出来了」：
     *   exitCode == 0  → ArkTS 立刻 ack 并 terminateSelf()
     *   exitCode != 0  → ArkTS 弹面板、等玩家点掉，然后 ack
     * 那段时间进程必须活着 —— 它一死，ArkTS 也没了，玩家什么也看不到。
     *
     * 30 秒是兜底：ArkTS 若卡死或不响应，不能让这里变成僵尸进程。
     * 300 × 100ms = 30s。 */
    atomic_store(&g_plan.finished, 1);
    SDL_Log(" finished, exit_code=%d -- waiting up to 30s for ArkTS to ack", rc);

    int waited_ms = 0;
    while (waited_ms < 30000) {
        if (atomic_load(&g_plan.exit_ack) != 0) {
            SDL_Log(" ArkTS acked after %dms; exiting", waited_ms);
            break;
        }
        SDL_Delay(100);
        waited_ms += 100;
    }

    if (atomic_load(&g_plan.exit_ack) == 0) {
        SDL_Log(" !! ArkTS did not ack within 30s; exiting anyway");
    }

    /*  用 _exit 而不是 return：从 main 返回会运行 atexit 处理器与每个静态析构函数，
     * 而那场拆除会中止（实测每次退出都是 "FATAL SIGNAL 6 ... in /lib/ld-musl-aarch64.so.1"，
     * 系统据此把每次正常退出都记成崩溃）。先 flush：_exit 不跑 stdio 清理，
     * 而日志尾部是最有用的证据。 */
    fflush(NULL);
    _exit(rc);
}
