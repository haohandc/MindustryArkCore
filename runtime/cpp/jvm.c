//
// Created on 2026/10/16.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".
#include <dirent.h>      // opendir / readdir / closedir
#include <dlfcn.h>       // dlopen / dlsym
#include <errno.h>
#include <fcntl.h>       // open / O_RDONLY
#include <stdbool.h>
#include <string.h>      // strerror / strcmp
#include <sys/stat.h>    // mkdir / stat
#include <unistd.h>      // read / write / close / unlink
#include "globals.h"

/* JNI_CreateJavaVM 走 dlsym 取，不链接 —— JVM 是 dlopen 出来的。
 * jni.h 只提供类型，所以签名要在这里自己写一份。 */
typedef jint (*CreateJavaVM_t)(JavaVM **pvm, void **penv, void *args);

/* JVM 可能往这些字符串里写，所以它们必须可修改，不能是字符串字面量。
 * 全部 static：只在本文件使用，且进程内只有一份。
 *  这些是定长缓冲区，拼的时候一律用 SDL_snprintf 并检查截断 ——
 *    截断后的选项在 JVM 侧表现为「某个开关没生效」，不报错。 */
static char opt_classpath[1024];   /* 补丁 jar + 游戏 jar + 三个 LWJGL + helper */
static char opt_home[512];
static char opt_tmpdir[512];
static char opt_libpath[512];
static char opt_encoding[512];
static char opt_headless[512];
static char opt_bootlib[512];
static char opt_errfile[512];
static char opt_heap[512];
static char opt_unsve[512];
static char opt_sve[512];
static char opt_osname[512];
static char opt_userhome[512];
static char opt_userdir[512];
static char opt_lwjglpath[512];
static char opt_gles[512];
static char opt_mobile[512];
static char opt_chooser[512];

/* 检查路径是否为 ELF 文件（目录内 .so 也可能是 jimage） */
static bool is_elf(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    unsigned char m[4];
    ssize_t n = read(fd, m, 4);
    close(fd);
    return n == 4 && m[0] == 0x7f && m[1] == 'E' && m[2] == 'L' && m[3] == 'F';
}

/* dlopen 辅助：把成败与失败原因各打一行。
 * 「Error loading X: (needed by Y)」对「链条哪一环断了」是含糊的，
 * 所以每个库分开问、用各自的 dlerror() 打印答案。 */
static bool try_dlopen(const char *path, const char *label)
{
    errno = 0;
    void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
    if (h) {
        SDL_Log("   OK  %-28s %s", label, path);
        return true;
    }
    SDL_Log("   NO  %-28s %s", label, path);
    SDL_Log("        dlerror: %s   errno=%d (%s)", dlerror(), errno, strerror(errno));
    return false;
}

/* 预加载 Arc 原生库并标记已加载，阻止 Arc 自身加载器重复操作。
 * Arc 会把它们从 jar 解到 java.io.tmpdir 再对副本 System.load，而副本无法 dlopen
 * （可写区不可执行，只有 bundle 可执行），所以改为启动前从这里加载。
 * 失败时不中止启动（让游戏报告更精确的错误），只有加载成功后才标记，防止半状态。 */
static void preload_arc_natives(JNIEnv *env)
{
    static const char *keys[]  = { "arc", "arc-freetype", "arc-filedialogs" };
    static const char *files[] = { "libarcarm64.so",
                                   "libarc-freetypearm64.so",
                                   "libarc-filedialogsarm64.so" };
    const unsigned N = sizeof(keys) / sizeof(keys[0]);

    /* 通过自定义 NativeLoader 加载，避免把库注册到错误的类加载器上。
     * System.load 是 @CallerSensitive 的：经 JNI 直接调它没有调用者栈帧，
     * 库会落在 bootstrap loader 上，游戏的类看不见它的符号。 */
    jclass helper = (*env)->FindClass(env, "com/haohandc/launcher/NativeLoader");
    if (!helper) {
        SDL_Log(" !! com.haohandc.launcher.NativeLoader is not on the classpath");
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        return;
    }
    jmethodID loadm = (*env)->GetStaticMethodID(env, helper, "load",
                            "(Ljava/lang/String;)V");
    jmethodID markm = (*env)->GetStaticMethodID(env, helper, "markLoaded",
                            "(Ljava/lang/String;)V");
    if (!loadm || !markm) {
        SDL_Log(" !! NativeLoader does not have the methods this expects");
        return;
    }

    SDL_Log(" --- Arc natives, preloaded from the bundle ---");
    for (unsigned i = 0; i < N; i++) {
        char path[512];
        SDL_snprintf(path, sizeof(path), ARC_LIBS "/%s", files[i]);

        struct stat st;
        if (stat(path, &st) != 0) {
            SDL_Log("   %-30s not shipped, skipping", files[i]);
            continue;
        }

        (*env)->CallStaticVoidMethod(env, helper, loadm,
                                     (*env)->NewStringUTF(env, path));
        if ((*env)->ExceptionCheck(env)) {
            SDL_Log("   %-30s LOAD FAILED", files[i]);
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            continue;                    /* 不标记，保持一致性 */
        }

        (*env)->CallStaticVoidMethod(env, helper, markm,
                                     (*env)->NewStringUTF(env, keys[i]));
        if ((*env)->ExceptionCheck(env)) {
            SDL_Log("   %-30s loaded, but could not be marked", files[i]);
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            continue;
        }
        SDL_Log("   %-30s loaded and marked as \"%s\"", files[i], keys[i]);
    }
    SDL_Log(" --- end Arc natives ---");
}

/* 在 VM 启动后立即把 java.home 重写为沙箱路径。bundle 下的模块镜像是 jimg.so，
 * 而 java.base 硬拼 "<java.home>/lib/modules"（惰性初始化、只读一次的 static final），
 * 所以必须赶在任何类加载之前纠正 —— -Djava.home 会被 HotSpot 无条件覆盖，只能从 Java 侧重写。 */
static void override_java_home(JNIEnv *env)
{
    jclass syscls = (*env)->FindClass(env, "java/lang/System");
    if (!syscls) { SDL_Log(" !! cannot reach java/lang/System"); return; }

    jmethodID setp = (*env)->GetStaticMethodID(env, syscls, "setProperty",
                          "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    if (!setp) { SDL_Log(" !! no System.setProperty"); return; }

    jstring k = (*env)->NewStringUTF(env, "java.home");
    jstring v = (*env)->NewStringUTF(env, g_sandbox_jdk);
    jstring old = (jstring)(*env)->CallStaticObjectMethod(env, syscls, setp, k, v);

    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        SDL_Log(" !! java.home could not be rewritten");
        return;
    }
    SDL_Log(" java.home rewritten to %s", g_sandbox_jdk);
    if (old) {
        const char *cs = (*env)->GetStringUTFChars(env, old, NULL);
        if (cs) {
            SDL_Log("   (HotSpot had derived %s)", cs);
            (*env)->ReleaseStringUTFChars(env, old, cs);
        }
    }
}

/* 只加载锚 libjvm.so。它必须最先加载且 RTLD_GLOBAL —— 其它 JDK 库的裸名
 * DT_NEEDED 要靠它解析，而真正的 JVM 是经它的依赖链被拉进来的。 */
static void load_anchor_only(void)
{
    SDL_Log(" --- dlopen diagnostics ---");
    try_dlopen("libSDL3.so", "control: SDL3");
    try_dlopen(g_anchor, "anchor libjvm.so");
    SDL_Log(" --- end dlopen diagnostics ---");
}

/* 以原子方式把分发文件放到目标路径（先写临时名，写满后 rename）。
 * 目标已存在且尺寸一致则跳过 —— 首次启动要搬 140 MB 的模块镜像，只做一次。
 * 返回值是错误码，0 = 成功。 */
static int materialise(const char *src, const char *dst)
{
    struct stat sb;
    if (stat(src, &sb) != 0) {
        SDL_Log(" !! not shipped: %s (%s)", src, strerror(errno));
        return 1;
    }

    struct stat sd;
    if (stat(dst, &sd) == 0 && sd.st_size == sb.st_size) {
        SDL_Log("   %-46s already in place (%lld bytes)",
                dst, (long long)sd.st_size);
        return 0;
    }

    SDL_Log("   %-46s materialising %lld bytes", dst, (long long)sb.st_size);

    char tmp[512];
    if (SDL_snprintf(tmp, sizeof(tmp), "%s.part", dst) >= (int) sizeof(tmp)) {
        SDL_Log(" !! temporary name for %s would be truncated", dst);
        return 2;
    }

    int in = open(src, O_RDONLY);
    if (in < 0) {
        SDL_Log(" !! open %s: %s", src, strerror(errno));
        return 3;
    }
    int out = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
        SDL_Log(" !! create %s: %s", tmp, strerror(errno));
        close(in);
        return 4;
    }

    static char buf[1 << 20];
    long long total = 0;
    int rc = 0;
    for (;;) {
        ssize_t n = read(in, buf, sizeof(buf));
        if (n == 0) break;
        if (n < 0) { SDL_Log(" !! read: %s", strerror(errno)); rc = 5; break; }
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w <= 0) { SDL_Log(" !! write: %s", strerror(errno)); rc = 6; break; }
            off += w;
        }
        if (rc) break;
        total += n;
    }
    fsync(out);
    close(out);
    close(in);

    if (!rc && total != sb.st_size) {
        SDL_Log(" !! short copy: %lld of %lld", total, (long long)sb.st_size);
        rc = 7;
    }
    if (rc) {
        unlink(tmp);
        return rc;
    }
    if (rename(tmp, dst) != 0) {
        SDL_Log(" !! rename %s: %s", tmp, strerror(errno));
        unlink(tmp);
        return 8;
    }
    return 0;
}

/* 递归复制目录树到沙箱，逐个文件名去掉末尾的 ".so"。
 * 分发时每个文件都加了 .so（hvigor 只搬文件名含 .so 的东西），这里把它剥回来。
 *  只剥末尾那一个 ".so"，一处剥、一处加，两头对称。
 * 返回值是错误码，0 = 全部成功。 */
static int copy_tree_strip_so(const char *src, const char *dst)
{
    DIR *d = opendir(src);
    if (!d) {
        SDL_Log(" !! opendir %s: %s", src, strerror(errno));
        return 1;
    }
    if (mkdir(dst, 0755) != 0 && errno != EEXIST) {
        SDL_Log(" !! mkdir %s: %s", dst, strerror(errno));
        closedir(d);
        return 2;
    }

    int rc = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;

        char s[1400], t[1400];
        SDL_snprintf(s, sizeof(s), "%s/%s", src, e->d_name);

        struct stat sb;
        if (stat(s, &sb) != 0) {
            SDL_Log(" !! stat %s: %s", s, strerror(errno));
            rc = 3;
            continue;
        }

        if (S_ISDIR(sb.st_mode)) {
            SDL_snprintf(t, sizeof(t), "%s/%s", dst, e->d_name);
            if (copy_tree_strip_so(s, t) != 0) rc = 4;
            continue;
        }

        size_t n = strlen(e->d_name);
        size_t keep = (n > 3 && strcmp(e->d_name + n - 3, ".so") == 0) ? n - 3 : n;
        if (keep == 0) continue;

        char base[600];
        if (keep >= sizeof(base)) {
            SDL_Log(" !! name too long: %s", e->d_name);
            rc = 5;
            continue;
        }
        memcpy(base, e->d_name, keep);
        base[keep] = '\0';

        SDL_snprintf(t, sizeof(t), "%s/%s", dst, base);
        if (materialise(s, t) != 0) rc = 6;
    }
    closedir(d);
    return rc;
}

/* 构建 java.home 指向的沙箱目录，包含 lib/modules 与 lib/tzdb.dat。
 * 返回值是错误码：0 = 模块镜像到位，非 0 = 第几步失败。 */
static int prepare_java_home(void)
{
    if (mkdir(g_sandbox_jdk, 0755) != 0 && errno != EEXIST) {
        SDL_Log(" !! mkdir %s failed: %s", g_sandbox_jdk, strerror(errno));
        return 1;
    }

    char libdir[G_SANDBOXJDK_CAP + 8];
    if (SDL_snprintf(libdir, sizeof(libdir), "%s/lib", g_sandbox_jdk) >= (int) sizeof(libdir)) {
        SDL_Log(" !! %s/lib would be truncated", g_sandbox_jdk);
        return 2;
    }
    if (mkdir(libdir, 0755) != 0 && errno != EEXIST) {
        SDL_Log(" !! mkdir %s failed: %s", libdir, strerror(errno));
        return 2;
    }

    char modules[G_SANDBOXJDK_CAP + 32];
    char tzdb[G_SANDBOXJDK_CAP + 32];
    SDL_snprintf(modules, sizeof(modules), "%s/lib/modules", g_sandbox_jdk);
    SDL_snprintf(tzdb,    sizeof(tzdb),    "%s/lib/tzdb.dat", g_sandbox_jdk);

    if (materialise(MODULE_IMAGE, modules) != 0) return 3;
    if (materialise(TZDB_IMAGE,   tzdb)    != 0) return 4;

    SDL_Log(" java.home tree, from %s:", JDK_HOME_TREE);
    if (copy_tree_strip_so(JDK_HOME_TREE, g_sandbox_jdk) != 0) {
        SDL_Log(" !! the java.home tree did not copy completely");
        SDL_Log(" !! run scripts/prep_jdkconf.py, then rebuild");
        SDL_Log(" !! without conf/security/java.security no class can be");
        SDL_Log(" !! defined at runtime -- mod loading dies inside defineClass");
    }
    return 0;
}



/* 启动链主干。返回值是 main() 的退出码：
 *   1 锚库 dlopen 失败
 *   2 找不到 JNI_CreateJavaVM
 *   3 补丁 jar 不在包里
 *   4 补丁 jar 不是合法 jar
 *   5 没有游戏 jar
 *   6 JVM 创建失败
 *   9~12 游戏入口没起来（由 launch_game 返回，原样透传）
 *   0 成功（含 dev_nogame 那种「只起 JVM 就停」）
 * 分档 C：编排重写。前身的 14 处探针调用全部去掉，取值全部改读 g_plan。 */
int start_jvm(void)
{
    /* 确定要加载的游戏 jar。没有游戏则不创建 VM —— 若走到这里说明绕过了界面
     * （如 `aa start` 直接拉起），明确失败比留下一个无用的 VM 更可取。 */
    if (!resolve_game_jar()) {
        SDL_Log(" !! no game jar: the launcher passed none and the package ships none");
        SDL_Log("    refusing to create the JVM");
        return 5;
    }

    int modok = prepare_java_home();
    load_anchor_only();

    /* 使用 RTLD_LAZY 而非 RTLD_NOW：libjvm.so 有未定义强符号 __cxa_thread_atexit，
     * 本平台无任何模块提供此符号，RTLD_NOW 永不可能成功。懒绑定要到首次调用才解析。 */
    SDL_Log(" dlopen(%s)", g_anchor);
    void *h = dlopen(g_anchor, RTLD_LAZY | RTLD_GLOBAL);
    if (!h) {
        SDL_Log(" !! RTLD_LAZY failed: %s", dlerror());
        SDL_Log("    retrying with RTLD_NOW ...");
        h = dlopen(g_anchor, RTLD_NOW | RTLD_GLOBAL);
        if (!h) SDL_Log("    RTLD_NOW also failed: %s", dlerror());
    }
    if (!h) return 1;
    SDL_Log("   -> handle = %p", h);

    CreateJavaVM_t create = (CreateJavaVM_t)dlsym(h, "JNI_CreateJavaVM");
    if (!create) {
        SDL_Log(" !! JNI_CreateJavaVM not found: %s", dlerror());
        return 2;
    }
    SDL_Log("   -> JNI_CreateJavaVM = %p", (void *)create);

    /* 补丁 jar 必须存在且可读。缺了它游戏会用上游 SDL2 后端，失败表象与「补丁」
     * 毫无关系，几乎无法归因，所以宁可当场中止。 */
    {
        struct stat st_patch;
        if (stat(PATCH_JAR, &st_patch) != 0) {
            SDL_Log(" !! the Arc patch jar is not in the package: %s", PATCH_JAR);
            SDL_Log("    build it with: python scripts/make_patch_jar.py");
            return 3;
        }
        FILE *f_patch = fopen(PATCH_JAR, "rb");
        char magic[2] = { 0, 0 };
        if (!f_patch || fread(magic, 1, 2, f_patch) != 2 || magic[0] != 'P' || magic[1] != 'K') {
            if (f_patch) fclose(f_patch);
            SDL_Log(" !! the Arc patch jar is not a readable jar: %s", PATCH_JAR);
            SDL_Log("    build it with: python scripts/make_patch_jar.py");
            return 4;
        }
        fclose(f_patch);
        SDL_Log("   patch jar: %s (%ld bytes) OK", PATCH_JAR, (long)st_patch.st_size);
    }

    /* classpath：补丁 jar 必须最前（JVM 按顺序解析类、先命中者赢）；
     * 第二个是玩家导入的游戏 jar；后面固定追加 LWJGL 三个 jar 与 helper。 */
    SDL_snprintf(opt_classpath, sizeof(opt_classpath),
                 "-Djava.class.path=%s:%s:%s/lwjgl.so:%s/lwjgl-opengl.so:%s/lwjgl-sdl.so:%s",
                 PATCH_JAR, g_plan.game_jar,
                 LWJGL_JARS, LWJGL_JARS, LWJGL_JARS, HELPER_JAR);

    /* bundle 库目录放在最前：bundle 内有两份 libSDL3.so，XComponent 加载顶层那份，
     * LWJGL 加载另一份会导致窗口创建失败，必须优先用 bundle 顶层路径。 */
    SDL_snprintf(opt_lwjglpath, sizeof(opt_lwjglpath),
                 "-Dorg.lwjgl.librarypath=%s:%s", BUNDLE_LIBS, LWJGL_LIBS);

    /* java.home 必须指向沙箱里的拷贝，否则模块镜像找不到。
     * VM 启动后再 setProperty 已来不及，所以两处都要设：这里一次、override_java_home 一次。 */
    SDL_snprintf(opt_home,      sizeof(opt_home),      "-Djava.home=%s", g_sandbox_jdk);
    SDL_snprintf(opt_tmpdir,    sizeof(opt_tmpdir),    "-Djava.io.tmpdir=%s", g_tmp_dir);
    SDL_snprintf(opt_libpath,   sizeof(opt_libpath),   "-Djava.library.path=%s/server:%s", g_jdklib, g_jdklib);
    SDL_strlcpy(opt_encoding,   "-Dfile.encoding=UTF-8", sizeof(opt_encoding));
    SDL_strlcpy(opt_headless,   "-Djava.awt.headless=true", sizeof(opt_headless));
    SDL_snprintf(opt_bootlib,   sizeof(opt_bootlib), "-Dsun.boot.library.path=%s:%s/server", g_jdklib, g_jdklib);
    SDL_snprintf(opt_errfile,   sizeof(opt_errfile), "-XX:ErrorFile=%s/hs_err_%%p.log", g_data_root);
    SDL_strlcpy(opt_heap,       "-Xmx512m", sizeof(opt_heap));

    /* 禁用 ARM SVE：否则 JVM 在 JNI_CreateJavaVM 期间 SIGILL 崩溃。
     * 必须先解锁诊断选项。 */
    SDL_strlcpy(opt_unsve,  "-XX:+UnlockDiagnosticVMOptions", sizeof(opt_unsve));
    SDL_strlcpy(opt_sve,    "-XX:UseSVE=0", sizeof(opt_sve));

    /* os.name 必须是 Linux：LWJGL 与 Arc 每次 native 查找都依据它，
     * 真实值会让游戏去找不存在的 HarmonyOS natives。 */
    SDL_strlcpy(opt_osname,   "-Dos.name=Linux", sizeof(opt_osname));

    /* user.home 由 ArkTS 算好传进来：不隔离 = 数据根本身，隔离 = <根>/instances/<键>/sets/default。
     * resolve_user_home 只做校验与建目录，不做决策。 */
    {
        char home[PLAN_USERHOME_CAP];
        resolve_user_home(home, sizeof(home));
        SDL_snprintf(opt_userhome, sizeof(opt_userhome), "-Duser.home=%s", home);
    }

    /* user.dir 不随隔离走，是进程工作目录。 */
    SDL_snprintf(opt_userdir,  sizeof(opt_userdir),  "-Duser.dir=%s",  g_data_root);
    SDL_strlcpy(opt_gles, "-Darc.sdl.glEs=true", sizeof(opt_gles));

    /* 操作方案：Mindustry 用 Vars.mobile 一个 bit 决定整个输入层与 UI。
     * 该值必须在 Vars.init() 之前定好，所以只能启动前传进来。 */
    SDL_snprintf(opt_mobile, sizeof(opt_mobile), "-Darc.sdl.mobile=%s",
                 read_game_ui_mode() ? "true" : "false");

    /* 游戏语言：ArkTS 已从游戏认得的那 35 个 locale ID 里选过，这里只校验形状。 */
    char opt_language[64];
    char opt_country[64];
    resolve_game_locale(opt_language, sizeof(opt_language),
                        opt_country,  sizeof(opt_country));

    /* arc.sdl.chooserPath：游戏的文件浏览器根植在 user.home 推出来的外部存储路径上，
     * 而 user.home 是本应用沙箱 —— 玩家放不了文件的地方。所以有 mods 目录就指过去，
     * 没有就不设这个属性（传空字符串会让回退失效，不设更好）。 */
    if (g_plan.mods_dir[0] != '\0') {
        SDL_snprintf(opt_chooser, sizeof(opt_chooser), "-Darc.sdl.chooserPath=%s", g_plan.mods_dir);
        SDL_Log(" file browser will open at: %s", g_plan.mods_dir);
    } else {
        opt_chooser[0] = '\0';
        SDL_Log(" no mods dir in the plan -- the browser will open in the sandbox");
    }

    JavaVMOption options[BASE_OPTS + MAX_EXTRA_OPTS];
    options[0].optionString = opt_classpath;  options[0].extraInfo = NULL;
    options[1].optionString = opt_home;       options[1].extraInfo = NULL;
    options[2].optionString = opt_tmpdir;     options[2].extraInfo = NULL;
    options[3].optionString = opt_libpath;    options[3].extraInfo = NULL;
    options[4].optionString = opt_encoding;   options[4].extraInfo = NULL;
    options[5].optionString = opt_headless;   options[5].extraInfo = NULL;
    options[6].optionString = opt_bootlib;    options[6].extraInfo = NULL;
    options[7].optionString = opt_errfile;    options[7].extraInfo = NULL;
    options[8].optionString = opt_heap;       options[8].extraInfo = NULL;
    options[9].optionString = opt_unsve;      options[9].extraInfo = NULL;
    options[10].optionString = opt_sve;       options[10].extraInfo = NULL;
    options[11].optionString = opt_osname;    options[11].extraInfo = NULL;
    options[12].optionString = opt_userhome;  options[12].extraInfo = NULL;
    options[13].optionString = opt_userdir;   options[13].extraInfo = NULL;
    options[14].optionString = opt_lwjglpath; options[14].extraInfo = NULL;
    options[15].optionString = opt_gles;      options[15].extraInfo = NULL;
    options[16].optionString = opt_mobile;    options[16].extraInfo = NULL;
    options[17].optionString = (opt_chooser[0] != '\0') ? opt_chooser : NULL;
    options[17].extraInfo = NULL;
    /* 语言追加在末尾（18、19），不改变前面的下标，最小模式因此不会错位。 */
    options[18].optionString = (opt_language[0] != '\0') ? opt_language : NULL;
    options[18].extraInfo = NULL;
    options[19].optionString = (opt_country[0] != '\0') ? opt_country : NULL;
    options[19].extraInfo = NULL;

    /* 追加项来自 ArkTS 传进来的 plan，排在 BASE_OPTS 之后。 */
    const int nExtra = g_plan.extra_count;
    for (int i = 0; i < nExtra; i++) {
        options[BASE_OPTS + i].optionString = g_plan.extra_opts[i];
        options[BASE_OPTS + i].extraInfo = NULL;
    }

    int nOpts;
    if (g_plan.dev_minimal) {
        SDL_Log(" ** MINIMAL option set requested: classpath/tmpdir/Xmx only **");
        JavaVMOption kept[3 + MAX_EXTRA_OPTS];
        kept[0] = options[0];
        kept[1] = options[2];
        kept[2] = options[8];
        for (int i = 0; i < nExtra; i++) kept[3 + i] = options[BASE_OPTS + i];
        nOpts = 3 + nExtra;
        for (int i = 0; i < nOpts; i++) options[i] = kept[i];
    } else {
        nOpts = BASE_OPTS + nExtra;
    }

    /* 可执行内存不可用时强制 -Xint。判决来自 features/execenv 的启动前探测
     * （execmem 是闸门），这里只执行，不自己测。dev_noexec 表示忽略探测结果。 */
    const bool incapable = g_plan.dev_noexec || !g_plan.exec_mem_ok;
    if (incapable) {
        int already = 0;
        for (int i = 0; i < nOpts; i++) {
            if (options[i].optionString != NULL
                && SDL_strcmp(options[i].optionString, "-Xint") == 0) {
                already = 1;
                break;
            }
        }
        if (already) {
            SDL_Log(" executable memory unavailable and -Xint is already set");
        } else if (nOpts < BASE_OPTS + MAX_EXTRA_OPTS) {
            static char forced_xint[] = "-Xint";
            options[nOpts++].optionString = forced_xint;
            SDL_Log(" !! executable memory unavailable -- FORCING -Xint");
        } else {
            SDL_Log(" !! executable memory unavailable and NO ROOM to add -Xint");
        }
    } else {
        SDL_Log(" executable memory works -- JIT kept");
    }
    if (g_plan.dev_noexec) {
        SDL_Log(" NOTE: dev_noexec was set, the probe result is ignored");
    }

    /* 丢掉 NULL 选项，保持计数准确。 */
    {
        int kept = 0;
        for (int i = 0; i < nOpts; i++) {
            if (options[i].optionString != NULL) options[kept++] = options[i];
        }
        if (kept != nOpts) SDL_Log(" %d option(s) left unset and not passed", nOpts - kept);
        nOpts = kept;
    }

    JavaVMInitArgs args;
    SDL_memset(&args, 0, sizeof(args));
    args.version = JNI_VERSION_1_8;
    args.nOptions = nOpts;
    args.options = options;

    /* 先严格模式，让 JVM 明确报告未知选项；不成功再宽松，保证一个坏 flag 不会让启动器挂掉。 */
    args.ignoreUnrecognized = JNI_FALSE;

    SDL_Log(" calling JNI_CreateJavaVM (strict) ...");
    for (int i = 0; i < args.nOptions; i++) SDL_Log("   opt: %s", options[i].optionString);

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint rc = create(&vm, (void **)&env, &args);
    SDL_Log(" JNI_CreateJavaVM (strict) returned %d", (int)rc);

    if (rc != JNI_OK && nOpts > BASE_OPTS) {
        SDL_Log(" !! strict mode refused the options; extras were:");
        for (int i = BASE_OPTS; i < nOpts; i++) SDL_Log("      %s", options[i].optionString);
        SDL_Log("    retrying lenient ...");
        args.ignoreUnrecognized = JNI_TRUE;
        rc = create(&vm, (void **)&env, &args);
        SDL_Log(" JNI_CreateJavaVM (lenient) returned %d", (int)rc);
    }

    if (rc != JNI_OK || !env) {
        SDL_Log(" !! JVM creation failed (rc=%d)", (int)rc);
        return 6;
    }

    /*  立刻置 stage。JNI_CreateJavaVM 是唯一一种「失败时进程当场停死、什么都不留下」
     * 的调用（没有日志行、没有 faultlog、没有返回码）。ArkTS 看到 stage 仍是 NONE
     * 而进程没了，就是它发生过 —— 这是唯一能识别那种失败的办法。 */
    atomic_store(&g_plan.stage, PLAN_STAGE_JVM);
    SDL_Log(" *** JVM CREATED *** vm=%p env=%p", (void *)vm, (void *)env);

    /* 仅当模块镜像就位时才覆盖 java.home，否则会掩盖真实错误。 */
    if (modok == 0) {
        override_java_home(env);
    } else {
        SDL_Log(" !! java.home left alone: the module image is not in place");
    }

    /* 从 native 调 System.out.println，验证 JVM 基本可用。 */
    jclass syscls = (*env)->FindClass(env, "java/lang/System");
    jfieldID outId = (*env)->GetStaticFieldID(env, syscls, "out", "Ljava/io/PrintStream;");
    jobject out = (*env)->GetStaticObjectField(env, syscls, outId);
    jclass pscls = (*env)->FindClass(env, "java/io/PrintStream");
    jmethodID println = (*env)->GetMethodID(env, pscls, "println", "(Ljava/lang/String;)V");
    (*env)->CallVoidMethod(env, out, println,
        (*env)->NewStringUTF(env, "*** HELLO FROM THE JVM ***"));

    /* 取 VM 内部指标：当前时间、可用核数、最大堆（验证 -Xmx 是否真的生效）。 */
    jmethodID curTime = (*env)->GetStaticMethodID(env, syscls, "currentTimeMillis", "()J");
    jlong ms = (*env)->CallStaticLongMethod(env, syscls, curTime);
    jclass rtcls = (*env)->FindClass(env, "java/lang/Runtime");
    jmethodID getRt = (*env)->GetStaticMethodID(env, rtcls, "getRuntime", "()Ljava/lang/Runtime;");
    jobject rt = (*env)->CallStaticObjectMethod(env, rtcls, getRt);
    jmethodID avail = (*env)->GetMethodID(env, rtcls, "availableProcessors", "()I");
    jint cpus = (*env)->CallIntMethod(env, rt, avail);
    jmethodID maxmem = (*env)->GetMethodID(env, rtcls, "maxMemory", "()J");
    jlong maxheap = (*env)->CallLongMethod(env, rt, maxmem);

    SDL_Log(" currentTimeMillis = %lld", (long long)ms);
    SDL_Log(" availableProcessors = %d", (int)cpus);
    SDL_Log(" runtime maxMemory = %lld bytes (%.0f MB)  <- reflects -Xmx",
            (long long)maxheap, (double)maxheap / (1024.0 * 1024.0));
    SDL_Log(" *** JAVA IS RUNNING ON HARMONYOS ***");

    if ((*env)->ExceptionCheck(env)) {
        SDL_Log(" !! a Java exception is pending");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }

    /* 以上检查是 JVM 健康的廉价验证，通过后才启动游戏。
     * dev_nogame 可跳过启动，便于单独回归「JVM 起得来」这一步。 */
    if (g_plan.dev_nogame) {
        SDL_Log(" ** dev_nogame requested: stopping before the game is launched **");
        return 0;
    }

    preload_arc_natives(env);
    configure_game_sdl();

    /* 原样透传 launch_game 的返回码 —— 它非零意味着「这个 jar 起不来游戏」，
     * 与 0 是两件事，不能被吞掉。 */
    return launch_game(env);
}
