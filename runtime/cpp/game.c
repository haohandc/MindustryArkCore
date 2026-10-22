//
// Created on 2026/10/16.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include <dlfcn.h>      // dlopen / dlsym
#include <stdint.h>     // uintptr_t
#include <stdio.h>      // fopen / fread
#include <string.h>     // strlen
#include "globals.h"

/* 判定一个文件是不是可用的游戏 jar：先打得开，再看头两字节是不是 zip 的 "PK"。
 * 只查扩展名不够 —— 玩家从各种来源导进来的东西，扩展名不可信。
 * 也不解压、不读 central directory：那是 jarver 的事，这里只回答「能不能拿来起 JVM」。 */
static bool is_readable_jar(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        return false;
    }
    char magic[2] = { 0, 0 };
    bool ok = (fread(magic, 1, 2, f) == 2 && magic[0] == 'P' && magic[1] == 'K');
    fclose(f);
    return ok;
}

/* 从 g_plan 里取游戏 jar 并验证它确实是 jar。
 * 返回 false 时 start_jvm() 直接拒绝创建 JVM —— 没有游戏却起一个 VM，
 * 到头来只是白等一次 140 MB 的模块镜像装配。 */
bool resolve_game_jar(void)
{
    if (g_plan.game_jar[0] == '\0') {
        SDL_Log(" !! the launcher did not pass a game jar");
        return false;
    }
    if (!is_readable_jar(g_plan.game_jar)) {
        SDL_Log(" !! the game jar is missing or is not a jar: %s", g_plan.game_jar);
        return false;
    }
    SDL_Log("   game jar: %s", g_plan.game_jar);
    return true;
}

/* 玩家选了哪种操作方案。Mindustry 用一个 bit 决定整个输入层与 UI
 * （Vars.mobile = Core.app.isMobile() || Vars.testMobile）；游戏内的开关不碰这个 bit，
 * 只调 control.setInput —— 输入处理器变了、UI 仍然是移动端。
 * 字节码确认 Vars.mobile 只有一个写入者即 Vars.init() 那行，所以要在 Vars.init() 运行
 * 之前（JVM 启动前）就定好，只能由 ArkTS 在启动前传进来。 */
bool read_game_ui_mode(void)
{
    return g_plan.mobile != 0;
}

/* 把这次启动要用的 locale 拼成两个 JVM 选项，空串表示不设。
 *  ArkTS 已从游戏认得的那 35 个 locale ID 里选过（抄自 jar 的 locales 资产），
 *    这里只校验形状、不重做翻译 —— 两份会分叉。
 *  校验仍然必须：值要拼进 -D 字符串，不校验就等于把任意字符塞给 JVM。 */
void resolve_game_locale(char *buf_lang, size_t cap_lang,
                         char *buf_country, size_t cap_country)
{
    buf_lang[0] = '\0';
    buf_country[0] = '\0';

    const char *lang = g_plan.locale_lang;
    const char *country = g_plan.locale_country;

    if (lang[0] == '\0') {
        return;                         /* 没给 —— 全部「不设」，与从前一致 */
    }

    /* 语言只允许 [A-Za-z]，长度 2~3。游戏那 35 个 ID 一个都不需要数字、下划线、点，
     * 多出来的字符只会让「这是不是我们生成的」变得说不清。 */
    const size_t langlen = strlen(lang);
    if (langlen < 2 || langlen > 3) {
        SDL_Log("locale: rejecting '%s' (language length %d)", lang, (int) langlen);
        return;
    }
    for (const char *p = lang; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z'))) {
            SDL_Log("locale: rejecting '%s' (bad character in language)", lang);
            return;
        }
    }

    /* 地区可选，给了就必须是 [A-Za-z] 且长度恰为 2（`id_ID` 里的 ID 也在这个集合里）。 */
    if (country[0] != '\0') {
        const size_t clen = strlen(country);
        if (clen != 2) {
            SDL_Log("locale: rejecting '%s' (country length %d)", country, (int) clen);
            return;
        }
        for (const char *p = country; *p; p++) {
            if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z'))) {
                SDL_Log("locale: rejecting '%s' (bad character in country)", country);
                return;
            }
        }
    }

    /* 显式查截断返回值（SDL_snprintf 返回「本该写多少个字符」）。
     * 校验过的输入撞不到上限，这里只该在有人改了校验时响 —— 而静默截断的症状是失效。 */
    int n_lang = SDL_snprintf(buf_lang, cap_lang, "-Duser.language=%s", lang);
    int n_ctry = 0;
    if (country[0] != '\0') {
        n_ctry = SDL_snprintf(buf_country, cap_country, "-Duser.country=%s", country);
    }
    if (n_lang < 0 || (size_t) n_lang >= cap_lang ||
        (country[0] != '\0' && (n_ctry < 0 || (size_t) n_ctry >= cap_country))) {
        SDL_Log("locale: option string would be truncated -- NOT setting the locale");
        buf_lang[0] = '\0';
        buf_country[0] = '\0';
        return;
    }

    SDL_Log("locale: %s%s%s", lang,
            country[0] != '\0' ? "_" : "",
            country[0] != '\0' ? country : "");
}

/* 把游戏的 SDL 瞄准系统的 GLES 库。
 * Arc 的 SDL 后端从不索要 ES profile（只设 CORE/COMPATIBILITY），而 SDL 的 OpenHarmony
 * 驱动只有在 profile 是 ES 且主版本 > 1 时才加载 libGLESv3.so；本平台只定义了
 * DEFAULT_OGL_ES2，所以这些 profile 下什么都不加载，窗口创建报
 * "Could not initialize OpenGL / GLES library"。
 * SDL_HINT_OPENGL_LIBRARY 在那之前被检查，是唯一不必改 Arc 的杠杆。 */
bool configure_game_sdl(void)
{
    /* 用 g_libroot（dladdr 算出来的真实目录）作为保险：BUNDLE_LIBS 是编译期猜的，
     * 万一 libIsolation 变了或安装路径不同，它会静默指错地方 —— dlopen 返回 NULL，
     * 日志只有一行，游戏照样起，只是 GLES hint 没设上、窗口创建失败，归因很难。 */
    char sdlpath[G_LIBROOT_CAP + 16];
    if (SDL_snprintf(sdlpath, sizeof(sdlpath), "%s/libSDL3.so", g_libroot) >= (int) sizeof(sdlpath)) {
        SDL_Log(" !! %s/libSDL3.so would be truncated", g_libroot);
        return false;
    }

    /* bundle 里不止一个 libSDL3.so，两份都带同一个 SONAME —— 按 SONAME 解析的 loader
     * 返回先加载的那份（这里是启动器自己的），在另一个映射上设 hint 会像生效了其实什么都没变。
     * SDL_GetHint 地址相同 = 同一实例。 */
    void *h = dlopen(sdlpath, RTLD_LAZY | RTLD_GLOBAL);
    SDL_Log(" --- configuring SDL ---");
    SDL_Log("   launcher's SDL_GetHint = %p", (void *)(uintptr_t)&SDL_GetHint);
    if (!h) {
        SDL_Log(" !! cannot dlopen %s: %s", sdlpath, dlerror());
    } else {
        void *other = dlsym(h, "SDL_GetHint");
        SDL_Log("   %s", sdlpath);
        SDL_Log("     its SDL_GetHint      = %p  %s", other,
                other == (void *)(uintptr_t)&SDL_GetHint
                    ? "SAME instance as the launcher's"
                    : "DIFFERENT instance");
    }

    /* 两条路都走（直接调用 = 启动器自己的 SDL，句柄路 = 该路径实际解析到的）：两边都设没代价，
     * 免得必须先答对「是不是同一个实例」。priority 2 是 SDL_HINT_OVERRIDE，最高级。 */
    struct { const char *k, *v; } hints[] = {
        { "SDL_OPENGL_LIBRARY", "/system/lib64/libGLESv3.so" },
        { "SDL_EGL_LIBRARY",    "/system/lib64/libEGL.so"    },
    };
    typedef bool (*set_prio_t)(const char *, const char *, int);
    set_prio_t viaHandle = h ? (set_prio_t)dlsym(h, "SDL_SetHintWithPriority")
                             : NULL;

    for (unsigned i = 0; i < sizeof(hints) / sizeof(hints[0]); i++) {
        /* 是 bool，不是 SDL_bool：SDL3 改名后旧名字展开成刻意未声明的标识符。 */
        bool direct = SDL_SetHintWithPriority(hints[i].k, hints[i].v,
                                              SDL_HINT_OVERRIDE);
        bool via = viaHandle ? viaHandle(hints[i].k, hints[i].v, 2) : false;
        SDL_Log("   %-20s = %-30s direct=%s handle=%s -> now reads '%s'",
                hints[i].k, hints[i].v, direct ? "ok" : "REFUSED",
                via ? "ok" : "-", SDL_GetHint(hints[i].k));
    }

    /* 让每个实例去做游戏 SDL 内部会做的那个加载：hint 在两份副本上都设了也读回了，
     * 游戏仍报同样失败就说明 hint 在这里不要紧。真正的问题是【这个】实例能不能加载
     * 系统 GLES —— 经不同路径加载的库可能落在不同的 linker 命名空间里。 */
    typedef void *(*loadobj_t)(const char *);
    typedef const char *(*geterr_t)(void);
    static const char *GL = "/system/lib64/libGLESv3.so";

    SDL_Log("   launcher's SDL_LoadObject(\"%s\") = %p  err='%s'",
            GL, SDL_LoadObject(GL), SDL_GetError());

    if (h) {
        loadobj_t lo = (loadobj_t)dlsym(h, "SDL_LoadObject");
        geterr_t  ge = (geterr_t)dlsym(h, "SDL_GetError");
        if (lo) {
            void *r = lo(GL);
            SDL_Log("   game's     SDL_LoadObject(\"%s\") = %p  err='%s'",
                    GL, r, ge ? ge() : "?");
        } else {
            SDL_Log("   !! the game's SDL has no SDL_LoadObject");
        }
    }
    SDL_Log(" --- end SDL configuration ---");
    return true;
}

/* 以反射方式调用游戏的入口点。通过条件是【游戏自己的】代码运行了（可观测为它自己在
 * stdout 上的输出）—— 窗口明确不属于这一步，所以 main() 开始之后的一次 SDL 或 GL
 * 失败仍算「它启动了」，作为独立结果返回。入口点经 JNI 调而不是把 main class 交给
 * 启动器，因为没有启动器：这个就是。调用发生在 SDL 为 SDL_main 创建的线程上并阻塞到游戏返回。
 * 返回值：0 正常返回 / 9 主类不在 classpath / 10 类里没有 main /
 *         11 参数数组建不出来 / 12 启动期抛了异常。
 *  从 9 起，是为了不与 start_jvm 的 1~6 撞车 —— 两者最终都进同一个 exit_code。 */
int launch_game(JNIEnv *env)
{
    static const char *MAIN_CLASS = "mindustry/desktop/DesktopLauncher";
    static const char *MAIN_DESC  = "([Ljava/lang/String;)V";

    SDL_Log(" --- step 4: launching the game ---");
    SDL_Log(" game jar: %s", g_plan.game_jar);

    jclass cls = (*env)->FindClass(env, MAIN_CLASS);
    if (!cls) {
        SDL_Log(" !! %s is NOT on the classpath", MAIN_CLASS);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return 9;
    }
    SDL_Log("   -> class found");

    jmethodID mid = (*env)->GetStaticMethodID(env, cls, "main", MAIN_DESC);
    if (!mid) {
        SDL_Log(" !! the class has no main([Ljava/lang/String;)V");
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return 10;
    }

    /* 一个空的 String[] —— 游戏自己提供它的默认值 */
    jclass strcls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray argv = (*env)->NewObjectArray(env, 0, strcls, NULL);
    if (!argv) {
        SDL_Log(" !! could not build the argument array");
        return 11;
    }

    /*  到这里游戏的入口方法确实存在 —— 那个 jar 是个能跑的游戏，所以置 GAME。
     *  位置是重点，必须在【拿到 main 之后、调用它之前】：上面三个失败路径各自 return，
     *    全都意味着「这个 jar 不是游戏」，stage 必须留在 JVM 那一档。
     *    走到这里之后的任何失败都不再是「选错了 jar」。 */
    atomic_store(&g_plan.stage, PLAN_STAGE_GAME);

    SDL_Log("   -> calling %s.main(new String[0]) ...", MAIN_CLASS);
    (*env)->CallStaticVoidMethod(env, cls, mid, argv);

    /* 走到这一行意味着 main() 返回了：要么干净退出，要么是启动内部的一次失败。
     * 此处仍有未决异常能把两者区分开，所以报出来而不是两边都靠猜。 */
    if ((*env)->ExceptionCheck(env)) {
        SDL_Log(" !! the game threw while starting up:");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return 12;
    }
    SDL_Log("   -> main() returned normally");
    SDL_Log(" *** the game entry point ran ***");
    return 0;
}
