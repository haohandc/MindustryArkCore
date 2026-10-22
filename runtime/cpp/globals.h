//
// Created on 2026/10/16.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#ifndef ARKLAUNCHERPRO_GLOBALS_H
#define ARKLAUNCHERPRO_GLOBALS_H

#include <js_native_api_types.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdatomic.h>
#include "jni/jni.h"
#include <SDL3/SDL.h>      // SDL_strlcpy / SDL_strrchr / SDL_Log / SDL_snprintf / SDL_memset

/* ======================================================================
 * 一、HAP 原生库区（编译期常量）
 *
 * libIsolation 保持缺省 false 时，全部 HAP 的 native 库平铺在应用级
 * /data/storage/el1/bundle/libs/arm64/。ABI 目录名有两套：HAP 内是
 * arm64-v8a，设备上是 arm64，写错无声。
 * 只有 HAP 的 lib 区可执行，可写沙箱不可执行，故整棵 JDK 必须住在这里。
 * ====================================================================== */
#define BUNDLE_LIBS   "/data/storage/el1/bundle/libs/arm64"

/* HotSpot 从 libjvm.so 的位置剥三层分量推 java.home，所以要 <java.home>/lib/modules。
 * 真正的 JVM 嵌在 <java.home>/lib/server/ 下，SONAME 已清空、只能经锚库触达。 */
#define JDK_HOME      BUNDLE_LIBS "/jdk"
#define JDK_LIB       JDK_HOME "/lib"
#define JDK_LIBM      JDK_LIB "/server/libjvm_real.so"

/* 镜像与时钟库：hvigor 只搬文件名含 ".so" 的东西，故模块镜像叫 jimg.so、
 * tzdb.dat 叫 tzdb.so。落地时由 prepare_java_home() 改回真名。 */
#define MODULE_IMAGE  JDK_LIB "/jimg.so"
#define TZDB_IMAGE    JDK_LIB "/tzdb.so"

/* <java.home> 还必须有的 conf/ 与 lib/security/，每文件加 .so 后缀分发，
 * 拷贝时剥掉。少了 java.security，任何类都加载不了。 */
#define JDK_HOME_TREE BUNDLE_LIBS "/jdk-conf"

/* classpath 三件：补丁 jar 排最前（先命中者赢），helper 只为让 System.load
 * 从 Java 侧被调用，游戏 jar 由玩家导入、路径在 g_plan.game_jar。 */
#define PATCH_JAR     BUNDLE_LIBS "/patchjar/arcpatch.so"
#define HELPER_JAR    BUNDLE_LIBS "/launcher/helper.so"

/* Arc 的 natives 在这里分发，启动前由 native 加载并告诉 Arc 已加载 ——
 * 沙箱里的副本无法 dlopen。 */
#define ARC_LIBS      BUNDLE_LIBS "/arc"

/* LWJGL_LIBS 是真 ELF，必须在可执行区；LWJGL_JARS 不是 ELF，改 .so 只为过
 * hvigor 的过滤。libSDL3.so 不放这两个目录：一个进程两份 SDL3 会有两个事件队列。 */
#define LWJGL_LIBS    BUNDLE_LIBS "/lwjgl"
#define LWJGL_JARS    BUNDLE_LIBS "/lwjgl-jars"

/* ======================================================================
 * 二、运行期路径缓冲区（定义在 paths.c，discover_paths() 写入一次）
 * ====================================================================== */
#define G_LIBROOT_CAP    1024
#define G_JDKHOME_CAP    1200
#define G_JDKLIB_CAP     1400
#define G_ANCHOR_CAP     1400
#define G_DATAROOT_CAP    512
#define G_TMPDIR_CAP      512
#define G_EXITMARK_CAP    600
#define G_SANDBOXJDK_CAP  600

/* HAP 侧：由 dladdr 取本库真实位置后逐层拼出，落不到时回退 BUNDLE_LIBS。 */
extern char g_libroot[];      // <bundle>/libs/arm64
extern char g_jdkhome[];      // <g_libroot>/jdk        —— 只读，不往这里写
extern char g_jdklib[];       // <g_jdkhome>/lib
extern char g_anchor[];       // <g_libroot>/libjvm.so  —— 必须最先 dlopen 且 RTLD_GLOBAL

/* 沙箱侧：全部来自平台 API，不硬编码。data_root 是【应用级】filesDir，
 * 不是模块级的 /data/storage/el2/base/haps/<模块>/files。 */
extern char g_data_root[];    // 应用级 filesDir
extern char g_tmp_dir[];      // 应用级 tempDir，给 -Djava.io.tmpdir
extern char g_exit_marker[];  // <g_data_root>/native_exit
extern char g_sandbox_jdk[];  // <g_data_root>/jdk —— 运行期装配的 java.home

/* ======================================================================
 * 三、LaunchPlan —— ArkTS 与 native 之间唯一的数据通道
 *
 * 写入顺序承重：GameAbility 先调 setLaunchPlan()，返回之后再触发 SDL 启动；
 * SDL 起新线程调 main()。线程创建构成 happens-before，故 main() 读到的
 * 一定是写完的 g_plan，不需要额外同步。
 * ====================================================================== */
#define PLAN_GAMEJAR_CAP   512
#define PLAN_MODSDIR_CAP   512
#define PLAN_USERHOME_CAP  512
#define PLAN_LOCALE_CAP     16

/* 启动器自己有多少条 JVM 选项，在 ArkTS 传来的追加项之前。
 * 它同时是数组上界与索引基点，漏改一处会静默丢选项。 */
#define BASE_OPTS           20
#define MAX_EXTRA_OPTS      32
#define EXTRA_OPT_CAP      256

/* g_plan.stage 的取值。ArkTS 轮询 getLaunchResult 判断走到哪一步。 */
#define PLAN_STAGE_NONE      0   /* 还没启动 */
#define PLAN_STAGE_JVM       1   /* JNI_CreateJavaVM 已返回成功 */
#define PLAN_STAGE_GAME      2   /* 游戏入口方法已调起 */
#define PLAN_STAGE_FAILED    3   /* 启动失败，看 exit_code */

typedef struct {
    /* ---------- 输入：ArkTS 写，native 只读 ---------- */

    /* 玩家导入的游戏 jar 绝对路径。空串 = 没有游戏可启动。 */
    char game_jar[PLAN_GAMEJAR_CAP];

    /* 玩家选定的 mods 目录。空串 = 用 <user_home>/.local/share/Mindustry/mods。 */
    char mods_dir[PLAN_MODSDIR_CAP];

    /* 本次的 -Duser.home。不隔离 = 数据根本身；隔离 = <数据根>/instances/<键>/sets/default。
     * 路径与键的字符集由 ArkTS 组装并校验，native 只确认绝对路径、不含 ".."、建得出来。 */
    char user_home[PLAN_USERHOME_CAP];

    /* 游戏语言的两段值，空串 = 不设 -Duser.language / -Duser.country。
     * ArkTS 已从游戏认得的那 35 个 locale ID 里选过，native 只校验形状。 */
    char locale_lang[PLAN_LOCALE_CAP];
    char locale_country[PLAN_LOCALE_CAP];

    /* 1 = 移动端操作，0 = 桌面端。Mindustry 用 Vars.mobile 一个 bit 决定输入层与 UI，
     * 且该值必须在 Vars.init() 之前定好，所以只能启动前传进来。 */
    int mobile;

    /* 1 = 坚盾探测通过（匿名 RWX 页可 mmap）。0 时拒绝启动游戏。 */
    int exec_mem_ok;

    /* 开发开关，正常启动全是 0。 */
    int dev_nogame;       /* 只起 JVM，不进游戏 */
    int dev_nohandlers;   /* 不装崩溃信号处理器 */
    int dev_minimal;      /* 最小选项集 */
    int dev_noexec;       /* 跳过坚盾判定 */

    /* 追加到 JVM 选项表末尾的字符串，每条最长 EXTRA_OPT_CAP-1 字节。 */
    char extra_opts[MAX_EXTRA_OPTS][EXTRA_OPT_CAP];
    int  extra_count;

    /* ---------- 输出：native 写，getLaunchResult 读 ----------
     *
     * 以下两个字段跨线程：main() 在 SDL 线程写，getLaunchResult 在 ArkTS 线程读。
     * 用 _Atomic 而不是 volatile —— 这里依赖的不只是「每次都真读真写」，还有
     * 「看到 stage 变了，就一定看得到它之前写的 exit_code」。volatile 不建立这条，
     * _Atomic 默认的 seq_cst 建立。访问一律走 atomic_store / atomic_load。
     * stage 停在 NONE 而进程消失 = 卡死在 JNI_CreateJavaVM，那是不留任何证据
     * （日志、faultlog、返回码都没有）的唯一一种失败，只能靠这一对值识别。 */
    atomic_int stage;
    atomic_int exit_code;

    /* 1 = start_jvm() 已返回，exit_code 有效，native 正在等 ArkTS 处理。
     * 为什么需要：直接 _exit 会在 ability 还活着时结束进程，系统把这次退出归档成
     * "Cpp Crash"（killId=2004）；先让框架把 ability 带下去才是正常结束。
     * 前身为此写一个 native_exit 文件给 ArkTS 轮询 —— 双 HAP 下 native 与 ArkTS 在同一进程，
     * 一个原子标志就够，不落盘。 */
    atomic_int finished;

    /* 1 = ArkTS 处理完毕，native 可以 _exit。
     * 为什么不是「finished 一置位就退出」：exit_code 非零时 ArkTS 要弹面板、
     *    等玩家读完点掉。那段时间进程必须活着 —— 它一死，ArkTS 也没了。
     *    main() 等它最多 30 秒，超时自行退出，避免 ArkTS 卡死变成僵尸进程。 */
    atomic_int exit_ack;

    /* 1 = ArkTS 已把必填字段填好，可以启动。 */
    int valid;
} LaunchPlan;

extern LaunchPlan g_plan;

/* ======================================================================
 * 四、跨文件函数
 * 非全局函数一律为 static。
 * ====================================================================== */

/* paths.c —— 启动最早期跑一次，后面所有路径都依赖它 */
int  discover_paths(void);                 /* 三态 1/0/-1，留 int */
void resolve_user_home(char *buf, size_t cap);

/* jvm.c */
int  start_jvm(void);                      /* 退出码，留 int */

/* game.c —— start_jvm 里按序调用 */
bool resolve_game_jar(void);
bool read_game_ui_mode(void);
void resolve_game_locale(char *buf_lang, size_t cap_lang,
                         char *buf_country, size_t cap_country);
bool configure_game_sdl(void);
int  launch_game(JNIEnv *env);             /* 五个退出码，留 int */

/* plan.c —— 由 napi_init.c 的 NAPI 模块注册取地址 */
napi_value set_launch_plan(napi_env env, napi_callback_info info);
napi_value get_launch_result(napi_env env, napi_callback_info info);
napi_value ack_exit(napi_env env, napi_callback_info info);

#endif //ARKLAUNCHERPRO_GLOBALS_H
