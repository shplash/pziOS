// Minimal GLFW 3.4 API implementation for iOS, enough to run LWJGL 3 games (Project Zomboid).
//  - one fullscreen UIView backed by a CAMetalLayer, rendered through MetalANGLE's EGL (OpenGL ES 3 on Metal)
//  - glfwGetProcAddress resolves from gl4es (desktop GL on top of GLES) when loaded, else from EGL
//  - touches become mouse events, hardware keyboard presses become key/char events
// All 125 functions LWJGL's GLFW$Functions resolves are exported; unsupported ones return benign defaults.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <GameController/GameController.h>
#import <ImageIO/ImageIO.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define GLFW_API __attribute__((visibility("default"), used))

// ---------------------------------------------------------------- minimal EGL (resolved from MetalANGLE) ---
typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface;
typedef int EGLint;
typedef unsigned int EGLBoolean, EGLenum;
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_SURFACE ((EGLSurface)0)
#define EGL_NONE 0x3038
#define EGL_RED_SIZE 0x3024
#define EGL_GREEN_SIZE 0x3023
#define EGL_BLUE_SIZE 0x3022
#define EGL_ALPHA_SIZE 0x3021
#define EGL_DEPTH_SIZE 0x3025
#define EGL_STENCIL_SIZE 0x3026
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_SURFACE_TYPE 0x3033
#define EGL_WINDOW_BIT 0x0004
#define EGL_OPENGL_ES2_BIT 0x0004
#define EGL_OPENGL_ES3_BIT 0x0040
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_CONTEXT_CLIENT_VERSION 0x3098

static struct {
    void *lib;
    EGLDisplay (*GetDisplay)(void *);
    EGLBoolean (*Initialize)(EGLDisplay, EGLint *, EGLint *);
    EGLBoolean (*BindAPI)(EGLenum);
    EGLBoolean (*ChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
    EGLContext (*CreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
    EGLSurface (*CreateWindowSurface)(EGLDisplay, EGLConfig, void *, const EGLint *);
    EGLBoolean (*MakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
    EGLBoolean (*SwapBuffers)(EGLDisplay, EGLSurface);
    EGLBoolean (*SwapInterval)(EGLDisplay, EGLint);
    void *(*GetProcAddress)(const char *);
    EGLint (*GetError)(void);
    EGLContext (*GetCurrentContext)(void);
    EGLSurface (*GetCurrentSurface)(EGLint);
    EGLDisplay (*GetCurrentDisplay)(void);
    EGLBoolean (*Terminate)(EGLDisplay);
} egl;

static void glfwi_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void glfwi_log(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("[glfw-ios] ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
}

static int load_egl(void) {
    if (egl.lib) return 1;
    const char *names[] = {"@rpath/MetalANGLE.framework/MetalANGLE", "MetalANGLE.framework/MetalANGLE", NULL};
    for (int i = 0; names[i] && !egl.lib; i++) egl.lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!egl.lib) { glfwi_log("cannot load MetalANGLE: %s", dlerror()); return 0; }
#define L(n) *(void **)&egl.n = dlsym(egl.lib, "egl" #n); if (!egl.n) { glfwi_log("missing egl" #n); return 0; }
    L(GetDisplay) L(Initialize) L(BindAPI) L(ChooseConfig) L(CreateContext) L(CreateWindowSurface)
    L(MakeCurrent) L(SwapBuffers) L(SwapInterval) L(GetProcAddress) L(GetError)
    L(GetCurrentContext) L(GetCurrentSurface) L(GetCurrentDisplay) L(Terminate)
#undef L
    return 1;
}

// ---------------------------------------------------------------- GLFW ABI types ---
typedef struct GLFWwindow GLFWwindow;
typedef struct GLFWmonitor GLFWmonitor;
typedef struct GLFWcursor GLFWcursor;
typedef struct { int width, height, redBits, greenBits, blueBits, refreshRate; } GLFWvidmode;
typedef struct { unsigned short *red, *green, *blue; unsigned int size; } GLFWgammaramp;
typedef struct { int width, height; unsigned char *pixels; } GLFWimage;
typedef struct { unsigned char buttons[15]; float axes[6]; } GLFWgamepadstate;
typedef struct { void *allocate, *reallocate, *deallocate, *user; } GLFWallocator;

#define GLFW_PRESS 1
#define GLFW_RELEASE 0
#define GLFW_REPEAT 2
#define GLFW_CURSOR 0x33001
#define GLFW_PLATFORM_COCOA 0x00060002
#define GLFW_NO_ERROR 0

// Window attributes
#define GLFW_FOCUSED 0x20001
#define GLFW_ICONIFIED 0x20002
#define GLFW_RESIZABLE 0x20003
#define GLFW_VISIBLE 0x20004
#define GLFW_DECORATED 0x20005
#define GLFW_AUTO_ICONIFY 0x20006
#define GLFW_FLOATING 0x20007
#define GLFW_MAXIMIZED 0x20008
#define GLFW_HOVERED 0x2000B
#define GLFW_FOCUS_ON_SHOW 0x2000C
#define GLFW_CLIENT_API 0x22001
#define GLFW_CONTEXT_VERSION_MAJOR 0x22002
#define GLFW_CONTEXT_VERSION_MINOR 0x22003
#define GLFW_CONTEXT_REVISION 0x22004
#define GLFW_OPENGL_FORWARD_COMPAT 0x22006
#define GLFW_OPENGL_PROFILE 0x22008
#define GLFW_OPENGL_ANY_PROFILE 0
#define GLFW_OPENGL_API 0x30001

typedef void (*errorfun)(int, const char *);
typedef void (*posfun)(GLFWwindow *, int, int);
typedef void (*sizefun)(GLFWwindow *, int, int);
typedef void (*closefun)(GLFWwindow *);
typedef void (*focusfun)(GLFWwindow *, int);
typedef void (*keyfun)(GLFWwindow *, int, int, int, int);
typedef void (*charfun)(GLFWwindow *, unsigned int);
typedef void (*mbfun)(GLFWwindow *, int, int, int);
typedef void (*cursorposfun)(GLFWwindow *, double, double);
typedef void (*scrollfun)(GLFWwindow *, double, double);

struct GLFWwindow {
    int width, height;           // window (point) size
    int fbWidth, fbHeight;       // framebuffer (pixel) size
    float scale;
    int shouldClose;
    int inputMode[8];
    double cursorX, cursorY;
    unsigned char keys[512];
    unsigned char mouse[8];
    char *title;
    void *userPtr;
    void *view;                  // retained UIView (+1 via CFBridgingRetain)
    void *layer;
    EGLSurface surface;
    errorfun dummy;
    posfun posCb; sizefun sizeCb, fbCb; closefun closeCb; focusfun focusCb;
    keyfun keyCb; charfun charCb; mbfun mbCb; cursorposfun cursorCb; scrollfun scrollCb;
};

static GLFWwindow *g_window;
static GLFWwindow *g_current;
static errorfun g_errorCb;
static int g_lastError;
static const char *g_lastErrorDesc = "";
static int g_initialized;
static EGLDisplay g_dpy;
static EGLConfig g_cfg;
static EGLContext g_ctx;
static void *g_gl4es;
static void *gl4es_handle(void);
static void mouse_init(void);
static mach_timebase_info_data_t g_tb;
static uint64_t g_t0;
static int g_hints[64][2];
static int g_hintCount;
static pthread_mutex_t g_evMutex = PTHREAD_MUTEX_INITIALIZER;

static void set_error(int code, const char *desc) {
    g_lastError = code; g_lastErrorDesc = desc;
    if (g_errorCb) g_errorCb(code, desc);
}

// ---------------------------------------------------------------- event queue ---
typedef enum { EV_KEY, EV_CHAR, EV_MOUSEBTN, EV_CURSOR, EV_SCROLL, EV_SIZE, EV_FOCUS, EV_JOY } EvType;
typedef struct { EvType type; int a, b, c, d; double x, y; } Ev;
typedef void (*joystickfun)(int, int);
static joystickfun g_joyCb;
static void pads_init(void);
static BOOL pad_any_connected(void);
static BOOL kbm_connected(void);
static int pad_overlay_hides(void);
static void pad_config_load(void);
static Ev g_ev[4096];
static int g_evHead, g_evTail;

static void push_event(Ev e) {
    pthread_mutex_lock(&g_evMutex);
    int next = (g_evTail + 1) % 4096;
    if (next != g_evHead) { g_ev[g_evTail] = e; g_evTail = next; }
    pthread_mutex_unlock(&g_evMutex);
}

// ---------------------------------------------------------------- UIKit side ---
static int glfw_key_from_hid(UIKeyboardHIDUsage u) {
    if (u >= 0x04 && u <= 0x1D) return 65 + (int)(u - 0x04);            // A-Z
    if (u >= 0x1E && u <= 0x26) return 49 + (int)(u - 0x1E);            // 1-9
    if (u == 0x27) return 48;                                           // 0
    if (u >= 0x3A && u <= 0x45) return 290 + (int)(u - 0x3A);           // F1-F12
    switch (u) {
        case 0x28: return 257; case 0x29: return 256; case 0x2A: return 259; case 0x2B: return 258;
        case 0x2C: return 32;  case 0x2D: return 45;  case 0x2E: return 61;  case 0x2F: return 91;
        case 0x30: return 93;  case 0x31: return 92;  case 0x33: return 59;  case 0x34: return 39;
        case 0x35: return 96;  case 0x36: return 44;  case 0x37: return 46;  case 0x38: return 47;
        case 0x39: return 280; case 0x49: return 260; case 0x4A: return 268; case 0x4B: return 266;
        case 0x4C: return 261; case 0x4D: return 269; case 0x4E: return 267; case 0x4F: return 262;
        case 0x50: return 263; case 0x51: return 264; case 0x52: return 265;
        case 0xE0: return 341; case 0xE1: return 340; case 0xE2: return 342; case 0xE3: return 343;
        case 0xE4: return 345; case 0xE5: return 344; case 0xE6: return 346; case 0xE7: return 347;
    }
    return -1;
}

static float g_ptrScale = 1.0f;   // logical (game) pixels per UIKit point
static int input_log_enabled(void) { static int v = -1; if (v < 0) v = getenv("ZOMIOS_INPUT_LOG") != NULL; return v; }
static void push_key(int key, int action) { Ev e = {.type = EV_KEY, .a = key, .b = key, .c = action}; push_event(e); if (input_log_enabled()) glfwi_log("key %d action %d", key, action); }
static void push_mouse(int btn, int action) { Ev e = {.type = EV_MOUSEBTN, .a = btn, .b = action, .c = 0}; push_event(e); if (input_log_enabled()) glfwi_log("mouse button %d action %d", btn, action); }
static void push_cursor(double x, double y) { Ev e = {.type = EV_CURSOR, .x = x, .y = y}; push_event(e); }

// ---- on-screen controls -------------------------------------------------------------------------------
// kind: 0 = key, 1 = mouse button, 2 = toggle soft keyboard, 3 = toggle overlay, 4 = toggle pointer mode,
//       5 = virtual gamepad button, 6 = virtual gamepad trigger

// ---- virtual gamepad ----------------------------------------------------------------------------------
// With the launcher's Virtual Gamepad setting on, the on-screen controls drive a synthetic controller in the last joystick slot,
// so the game sees a pad instead of keyboard and mouse. It is deliberately not part of g_pads: a real controller in the same
// slot would be shadowed, and the overlay must not treat the pad it is drawing as an external controller.
#define VPAD_SLOT 0                            // joystick slot 0 while the virtual pad is on: games that only look at the first pad find it
static int g_vpadOn = -1;
static unsigned char g_vpadButtons[15];
static float g_vpadAxes[6];                    // LX, LY, RX, RY, LT, RT (triggers rest at -1, as in GLFW)
static void vpad_init(void) {
    if (g_vpadOn >= 0) return;
    g_vpadOn = [NSUserDefaults.standardUserDefaults boolForKey:@"zom.virtualPad"];
    for (int i = 0; i < 6; i++) g_vpadAxes[i] = i >= 4 ? -1.0f : 0.0f;
    if (g_vpadOn) glfwi_log("virtual gamepad: the on-screen controls drive joystick slot %d", VPAD_SLOT);
}
static int vpad_active(void) { vpad_init(); return g_vpadOn; }
static void vpad_set_button(int i, BOOL down) { if (i >= 0 && i < 15) g_vpadButtons[i] = down ? 1 : 0; }
static void vpad_set_trigger(int i, BOOL down) { if (i >= 0 && i < 2) g_vpadAxes[4 + i] = down ? 1.0f : -1.0f; }
static void vpad_set_stick(int stick, float x, float y) {
    int i = stick == 1 ? 2 : 0;
    float dz = 0.15f;
    float m = hypotf(x, y);
    if (m <= dz) { g_vpadAxes[i] = 0; g_vpadAxes[i + 1] = 0; return; }
    float k = (m - dz) / (1.0f - dz) / m;
    g_vpadAxes[i] = MAX(-1.0f, MIN(1.0f, x * k));
    g_vpadAxes[i + 1] = MAX(-1.0f, MIN(1.0f, y * k));
}

@interface ZOButton : UIView
@property (nonatomic) int kind, code;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) BOOL down;
@property (nonatomic) CGPoint norm;      // centre as a fraction of the view (from the saved layout); (0,0) = use the built-in position
// Two-thumb options, key and mouse buttons only, all off unless the touch editor turns them on:
//  dragAimOn    - dragging a finger held on the button also moves the cursor, so one thumb attacks or shoves and aims at the same time.
//  holdLockOn   - a long press keeps the button held after the finger lifts (e.g. RC for hands-free aiming); the next tap lets go.
//  fireMode     - 0 default: held while the finger is down. 1 auto: held and re-pressed repeatedly. 2 release: holding only aims,
//                 lifting the finger sends one press. A fire mode toggle (kind 7) switches its target between 0 and 2 in game.
@property (nonatomic) BOOL dragAimOn, holdLockOn;
@property (nonatomic) double holdLockDelay;             // seconds before a long-press lock engages (default 0.5)
@property (nonatomic) int fireMode;
@property (nonatomic, copy) NSString *itemId, *targetId;
@property (nonatomic, strong) NSTimer *autoTimer;
@property (nonatomic) BOOL armed, latched, dragActive;
@property (nonatomic, weak) UITouch *dragTouch;
@property (nonatomic) CGPoint dragStart, dragLast;
@property (nonatomic) NSUInteger pressToken;
+ (instancetype)buttonWithTitle:(NSString *)t kind:(int)k code:(int)c size:(CGFloat)size;
- (void)releaseLatch;
- (void)stopAuto;
@end
@interface GLFWiOSView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic) GLFWwindow *win;
@property (nonatomic, strong) NSMutableArray<UIView *> *controls;     // hidden together by the HIDE toggle
@property (nonatomic, strong) ZOButton *hideButton;
@property (nonatomic, strong) UIView *kbInput;       // hidden text-input responder, first responder only while the soft keyboard is shown
@property (nonatomic) BOOL keyboardShown, controlsHidden, padConnected;
@property (nonatomic) CFTimeInterval pressTime;
@property (nonatomic) BOOL pointerDown;
@property (nonatomic, weak) UITouch *pointerTouch;
@property (nonatomic) BOOL trackpad;                 // YES: relative virtual cursor; NO: direct touch
@property (nonatomic) CGPoint cursorPt, lastPt, startPt;
@property (nonatomic) CFTimeInterval startTime;
@property (nonatomic) BOOL moved, holding;
@property (nonatomic, strong) CAShapeLayer *cursorLayer;
@property (nonatomic, strong) ZOButton *modeButton;
@property (nonatomic) BOOL mouseActive;              // a physical mouse is connected: it drives the cursor, touch no longer moves it
- (void)mouseDelta:(CGPoint)d;
- (void)moveCursorTo:(CGPoint)p;
- (void)setMouseConnected:(BOOL)on;
- (void)toggleMode;
- (void)toggleKeyboard;
- (void)toggleControls;
- (void)releaseLatches;
- (void)cycleFireModeFrom:(ZOButton *)toggle;
- (void)cycleFireModeForTarget:(NSString *)targetId;
- (void)updateFireToggles;
- (void)updateControlVisibility;
- (void)updateCursorVisibility;
- (void)setPadConnected:(BOOL)on;
- (void)installControls;
- (BOOL)installSavedLayout;
@end

@implementation ZOButton
+ (instancetype)buttonWithTitle:(NSString *)t kind:(int)k code:(int)c size:(CGFloat)size {
    ZOButton *b = [[ZOButton alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    b.kind = k; b.code = c; b.multipleTouchEnabled = YES;
    b.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.45];
    b.layer.cornerRadius = size / 2; b.layer.borderWidth = 2; b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    b.label = [[UILabel alloc] initWithFrame:b.bounds];
    b.label.text = t; b.label.textAlignment = NSTextAlignmentCenter; b.label.textColor = UIColor.whiteColor;
    b.label.font = [UIFont boldSystemFontOfSize:size > 50 ? 15 : 12]; b.label.userInteractionEnabled = NO;
    [b addSubview:b.label];
    return b;
}
- (void)updateLook {
    if (self.armed && !self.down) self.backgroundColor = [UIColor colorWithRed:0.9 green:0.6 blue:0.2 alpha:0.6];     // armed: amber until it fires on release
    else self.backgroundColor = self.down ? [UIColor colorWithRed:0.9 green:0.3 blue:0.2 alpha:0.75] : [UIColor colorWithWhite:0.1 alpha:0.45];
    self.layer.borderWidth = self.latched ? 4 : 2;                       // a held (latched) button gets a thick gold ring
    self.layer.borderColor = (self.latched ? [UIColor colorWithRed:1 green:0.85 blue:0.3 alpha:1] : [UIColor colorWithWhite:1 alpha:0.6]).CGColor;
}
- (void)setDown:(BOOL)d {
    if (_down == d) return; _down = d;
    [self updateLook];
    GLFWiOSView *gv = (GLFWiOSView *)self.superview;
    if (self.kind == 0) push_key(self.code, d ? GLFW_PRESS : GLFW_RELEASE);
    else if (self.kind == 1) push_mouse(self.code, d ? GLFW_PRESS : GLFW_RELEASE);
    else if (self.kind == 5) { if (d) g_vpadButtons[self.code & 15] = 1; else g_vpadButtons[self.code & 15] = 0; }
    else if (self.kind == 6) vpad_set_trigger(self.code, d);
    else if (d && self.kind == 2) [gv toggleKeyboard];
    else if (d && self.kind == 3) [gv toggleControls];
    else if (d && self.kind == 4) [gv toggleMode];
    else if (d && self.kind == 7) [gv cycleFireModeFrom:self];
    if (d && self.kind == 0 && self.code == 256) [gv releaseLatches];     // ESC (menus, pause) lets go of any locked button
}
- (void)releaseLatch {
    if (!self.latched) return;
    self.latched = NO; self.down = NO; [self updateLook];
}
/// Sends a press or release without touching the look (auto mode's re-presses).
- (void)sendQuiet:(BOOL)press {
    if (self.kind == 0) push_key(self.code, press ? GLFW_PRESS : GLFW_RELEASE);
    else if (self.kind == 1) push_mouse(self.code, press ? GLFW_PRESS : GLFW_RELEASE);
}
- (void)stopAuto { [self.autoTimer invalidate]; self.autoTimer = nil; }
- (void)autoTick:(NSTimer *)tm {
    if (!self.down || self.fireMode != 1) { [self stopAuto]; return; }
    [self sendQuiet:NO];
    __weak ZOButton *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        ZOButton *s = ws; if (s && s.down && s.fireMode == 1) [s sendQuiet:YES];
    });
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.latched) { [self releaseLatch]; self.dragTouch = nil; return; }       // a tap on a held button lets go of it
    UITouch *t = ts.anyObject;
    if (!self.dragTouch) { self.dragTouch = t; self.dragStart = self.dragLast = [t locationInView:self.superview]; self.dragActive = NO; }
    NSUInteger tok = ++self.pressToken;
    if (self.fireMode == 2 && self.kind <= 1) { self.armed = YES; [self updateLook]; return; }     // release mode: nothing is sent until the finger lifts
    self.down = YES;
    if (self.fireMode == 1 && self.kind <= 1 && !self.autoTimer)
        self.autoTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(autoTick:) userInfo:nil repeats:YES];
    if (self.holdLockOn && self.kind <= 1 && self.fireMode == 0) {                  // auto and release modes don't lock
        __weak ZOButton *ws = self;
        double delay = self.holdLockDelay > 0 ? self.holdLockDelay : 0.5;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ZOButton *s = ws;
            if (!s || s.pressToken != tok || !s.down || s.dragActive || s.latched) return;
            s.latched = YES; [s updateLook];
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        });
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    UITouch *t = self.dragTouch;
    if (!t || ![ts containsObject:t] || self.kind > 1 || !self.dragAimOn) return;
    GLFWiOSView *gv = (GLFWiOSView *)self.superview;
    CGPoint p = [t locationInView:gv];
    if (!self.dragActive) {                                                         // small dead zone so a held press doesn't nudge the cursor
        if (hypot(p.x - self.dragStart.x, p.y - self.dragStart.y) < 8) return;
        self.dragActive = YES; self.dragLast = p; return;
    }
    double k = [NSUserDefaults.standardUserDefaults doubleForKey:@"zom.dragAimSens"]; if (k <= 0) k = 1.0;
    [gv moveCursorTo:CGPointMake(gv.cursorPt.x + (p.x - self.dragLast.x) * k, gv.cursorPt.y + (p.y - self.dragLast.y) * k)];
    self.dragLast = p;
}
- (void)finishTouches:(NSSet<UITouch *> *)ts cancelled:(BOOL)cancelled {
    self.pressToken++;                                                              // cancels a pending long press
    if (self.dragTouch && [ts containsObject:self.dragTouch]) { self.dragTouch = nil; self.dragActive = NO; }
    [self stopAuto];
    if (self.armed) {                                                               // fire on release: one quick press as the finger lifts
        self.armed = NO; [self updateLook];
        if (!cancelled) {
            self.down = YES;
            __weak ZOButton *ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ ws.down = NO; });
        }
        return;
    }
    if (cancelled) [self releaseLatch];
    if (self.latched) return;                                                       // finger lifted but the button stays held
    self.down = NO;
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self finishTouches:ts cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self finishTouches:ts cancelled:YES]; }
@end

// Scroll strip: a tall narrow bar. Sliding a finger up or down on it sends mouse-wheel notches at the cursor, so containers scroll
// (and the world zooms) with one thumb instead of a two-finger gesture. The notches are paced by a display link from the finger's
// speed instead of being sent in bursts per touch event, which is what makes it smooth; a quick flick can carry on for a moment
// when "Momentum" is on. From the touch editor: zom.scrollSpeed, zom.scrollSens, zom.scrollInvert and zom.scrollMomentum.
@interface ZOScrollStrip : UIView
@property (nonatomic) CGPoint norm;
@property (nonatomic, weak) UITouch *touch;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) double linkTime;
@property (nonatomic) CGFloat velocity;      // points per second
@property (nonatomic) CGFloat carry;         // wheel notches not sent yet
@property (nonatomic) CGPoint lastPoint;
@property (nonatomic) double sampleTime;
@end
@implementation ZOScrollStrip
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.45];
        self.layer.cornerRadius = f.size.width / 2; self.layer.borderWidth = 2; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
        CGFloat W = f.size.width, H = f.size.height, cx = W / 2, cy = H / 2, g = W * 0.36, a = W * 0.2, m = W * 0.45;
        UIBezierPath *p = [UIBezierPath bezierPath];
        for (int i = -1; i <= 1; i++) { [p moveToPoint:CGPointMake(cx - g / 2, cy + i * 7)]; [p addLineToPoint:CGPointMake(cx + g / 2, cy + i * 7)]; }   // grip
        [p moveToPoint:CGPointMake(cx - a, m + a)]; [p addLineToPoint:CGPointMake(cx, m)]; [p addLineToPoint:CGPointMake(cx + a, m + a)];              // up arrow
        [p moveToPoint:CGPointMake(cx - a, H - m - a)]; [p addLineToPoint:CGPointMake(cx, H - m)]; [p addLineToPoint:CGPointMake(cx + a, H - m - a)];  // down arrow
        CAShapeLayer *l = [CAShapeLayer layer]; l.path = p.CGPath; l.fillColor = nil; l.lineWidth = 2; l.lineCap = kCALineCapRound; l.lineJoin = kCALineJoinRound;
        l.strokeColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor; [self.layer addSublayer:l];
    }
    return self;
}
- (void)dealloc { [_link invalidate]; }
- (void)didMoveToWindow { if (!self.window) { [self.link invalidate]; self.link = nil; } }   // never keep a display link alive after removal

// One wheel notch per this many points of finger travel: 16 pt at Speed 1x and Sensitivity 1x. Higher either and fewer points
// of travel send the same notch, so the strip covers the same list with less movement.
static double scroll_points_per_notch(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    double speed = [d doubleForKey:@"zom.scrollSpeed"]; if (!(speed > 0)) speed = 1.0;
    double sens = [d doubleForKey:@"zom.scrollSens"]; if (!(sens > 0)) sens = 1.0;
    return MAX(3.0, 16.0 / MAX(0.05, speed * sens));
}
static BOOL scroll_momentum(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:@"zom.scrollMomentum"];
    return v ? [v boolValue] : NO;
}
static BOOL scroll_reversed(void) { return [NSUserDefaults.standardUserDefaults boolForKey:@"zom.scrollInvert"]; }

- (void)startLink {
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    self.link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.linkTime = 0;
}
- (void)stopLink {
    [self.link invalidate];
    self.link = nil; self.velocity = 0; self.carry = 0;
}
- (void)tick:(CADisplayLink *)l {
    double now = CACurrentMediaTime();
    double dt = self.linkTime > 0 ? now - self.linkTime : l.duration;
    self.linkTime = now;
    dt = MAX(1.0 / 240.0, MIN(0.05, dt));
    if (!self.touch) {                                          // released: a flick carries on for a moment, or stops dead
        self.velocity = scroll_momentum() ? self.velocity * exp(-dt * 6.0) : 0;
        if (fabs(self.velocity) < 15) self.velocity = 0;
    } else if (CACurrentMediaTime() - self.sampleTime > 0.08) { // finger held still: coast to a stop instead of running away
        self.velocity *= exp(-dt * 12.0);
        if (fabs(self.velocity) < 15) self.velocity = 0;
    }
    double ppn = scroll_points_per_notch();
    self.carry += self.velocity * dt / ppn;
    self.carry = MAX(-8, MIN(8, self.carry));                   // never queue a pile of notches
    int sent = 0;
    while (fabs(self.carry) >= 1 && sent < 4) {
        int dir = self.carry > 0 ? 1 : -1;
        self.carry -= dir; sent++;
        Ev ev = {.type = EV_SCROLL, .x = 0, .y = scroll_reversed() ? -dir : dir}; push_event(ev);
    }
    if (!self.touch && self.velocity == 0 && fabs(self.carry) < 1) [self stopLink];
}

- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.touch) return;
    self.touch = ts.anyObject;
    self.lastPoint = [self.touch locationInView:self];
    self.velocity = 0; self.carry = 0; self.sampleTime = self.touch.timestamp;
    self.backgroundColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.2 alpha:0.5];
    [self startLink];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (!self.touch || ![ts containsObject:self.touch]) return;
    CGPoint p = [self.touch locationInView:self];
    double t = self.touch.timestamp, dt = t - self.sampleTime;
    if (dt <= 0 || dt > 0.12) dt = 1.0 / 60.0;
    CGFloat v = (self.lastPoint.y - p.y) / dt;                  // a finger moving up scrolls up
    v = MAX(-6000, MIN(6000, v));
    self.velocity = self.velocity * 0.6 + v * 0.4;              // smoothed, so one jittery sample does not jump the view
    self.lastPoint = p; self.sampleTime = t;
}
- (void)finish:(NSSet<UITouch *> *)ts {
    if (!self.touch || ![ts containsObject:self.touch]) return;
    self.touch = nil;
    self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.45];
    if (!scroll_momentum() || fabs(self.velocity) < 60) self.velocity = 0;
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self finish:ts]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self finish:ts]; }
@end

// Radial menu: hold it (or start sliding) and its options fan out around it; slide toward one and let go to send it. Letting go
// near where the finger started sends nothing, and a quick tap sends the tap option if one is set. An option can be a key, a mouse
// button, or one of the overlay's own controls (hide/show, PAD/TCH, keyboard, a fire mode toggle), so HIDE and PAD can live in a
// radial. Shapes: ring, arc, column, row; "spread" scales the spacing. The launcher's editor preview uses the same maths
// (RadialGeometry in ControlsEditor.swift), so keep the two in step.
@interface ZORadialSlot : NSObject
@property (nonatomic, copy) NSString *kind, *label, *target;     // kind: none, key, mouse, hide, mode, keyboard, firemode
@property (nonatomic) int code;
@end
@implementation ZORadialSlot
@end

// Where a radial menu's options go. Writes each option's centre into pts and returns the size of one option; the whole group is then
// moved onto the screen. A thumb is matched to the option whose centre is nearest, which stays correct after that move.
static CGSize radial_layout(int shape, int n, CGPoint c, CGFloat btn, double spread, CGFloat W, CGFloat H, CGPoint *pts) {
    double s = spread <= 0 ? 1.0 : MAX(0.6, MIN(1.6, spread));
    CGSize item = shape == 2 ? CGSizeMake(104, 38) : CGSizeMake(58, 58);
    if (n <= 0) return item;
    int side = c.x > W / 2 ? -1 : 1;                                       // column and row open towards the middle of the screen
    if (shape == 1) {
        CGFloat dl = c.x, dr = W - c.x, dt = c.y, db = H - c.y, m = MIN(MIN(dl, dr), MIN(dt, db));
        double out = m == dr ? 180 : m == dl ? 0 : m == dt ? 90 : -90;      // facing away from the nearest edge
        double sign = (out == 180 || out == 90) ? -1 : 1;                   // first option at the top (or the left)
        CGFloat R = MAX(80, 64 / (2 * sin(M_PI / (2.0 * n)))) * s;
        for (int i = 0; i < n; i++) {
            double a = out - 90 * sign + sign * 180.0 * (i + 0.5) / n;
            pts[i] = CGPointMake(c.x + R * cos(a * M_PI / 180), c.y + R * sin(a * M_PI / 180));
        }
    } else if (shape == 2) {
        CGFloat gap = 6 * s, x = c.x + side * (btn / 2 + 12 + item.width / 2), total = n * item.height + (n - 1) * gap;
        for (int i = 0; i < n; i++) pts[i] = CGPointMake(x, c.y - total / 2 + item.height / 2 + i * (item.height + gap));
    } else if (shape == 3) {
        CGFloat gap = 6 * s;
        for (int i = 0; i < n; i++) pts[i] = CGPointMake(c.x + side * (btn / 2 + 8 + item.width / 2 + i * (item.width + gap)), c.y);
    } else {
        CGFloat R = (n <= 4 ? 76 : n <= 6 ? 88 : 100) * s;
        for (int i = 0; i < n; i++) {
            double a = -90.0 + 360.0 * i / n;
            pts[i] = CGPointMake(c.x + R * cos(a * M_PI / 180), c.y + R * sin(a * M_PI / 180));
        }
    }
    CGFloat m = 8, x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
    for (int i = 0; i < n; i++) {
        x0 = MIN(x0, pts[i].x - item.width / 2); x1 = MAX(x1, pts[i].x + item.width / 2);
        y0 = MIN(y0, pts[i].y - item.height / 2); y1 = MAX(y1, pts[i].y + item.height / 2);
    }
    CGFloat dx = x0 < m ? m - x0 : (x1 > W - m ? (W - m) - x1 : 0), dy = y0 < m ? m - y0 : (y1 > H - m ? (H - m) - y1 : 0);
    for (int i = 0; i < n; i++) { pts[i].x += dx; pts[i].y += dy; }
    return item;
}

@interface ZORadial : UIView
@property (nonatomic) CGPoint norm;
@property (nonatomic) int shape;                        // 0 ring, 1 arc, 2 column, 3 row
@property (nonatomic) double spread;                    // spacing multiplier, 0.6-1.6
@property (nonatomic, strong) NSArray<ZORadialSlot *> *slots;
@property (nonatomic) int tapSlot;                      // -1 = a tap does nothing
@property (nonatomic, weak) UITouch *touch;
@property (nonatomic) CGPoint startPt;
@property (nonatomic) BOOL open;
@property (nonatomic) int hot;                          // highlighted option, -1 = none
@property (nonatomic) NSUInteger token;
@property (nonatomic, strong) NSMutableArray<UIView *> *ringViews;
@property (nonatomic, strong) UILabel *face;
- (BOOL)holds:(NSString *)kind;
- (void)setFaceText:(NSString *)t;
- (void)closeRing;
@end
@implementation ZORadial
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; _hot = -1; _tapSlot = -1; _spread = 1;
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.45];
        self.layer.cornerRadius = f.size.width / 2; self.layer.borderWidth = 2; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
        self.face = [[UILabel alloc] initWithFrame:self.bounds];
        self.face.textAlignment = NSTextAlignmentCenter; self.face.textColor = UIColor.whiteColor; self.face.userInteractionEnabled = NO;
        self.face.adjustsFontSizeToFitWidth = YES; self.face.minimumScaleFactor = 0.6;
        [self addSubview:self.face];
    }
    return self;
}
- (void)setFaceText:(NSString *)t {
    CGFloat w = self.bounds.size.width;
    self.face.text = t.length ? t : @"\u2261";                                            // three bars when it has no label
    self.face.font = [UIFont boldSystemFontOfSize:t.length ? (w > 50 ? 15 : 12) : w * 0.4];
}
- (BOOL)holds:(NSString *)kind { for (ZORadialSlot *s in self.slots) if ([s.kind isEqualToString:kind]) return YES; return NO; }
- (GLFWiOSView *)gv { return (GLFWiOSView *)self.superview; }
- (void)openRing {
    if (self.open || self.slots.count == 0) return;
    self.open = YES;
    GLFWiOSView *gv = self.gv; int n = (int)MIN(self.slots.count, 8);
    CGPoint pts[8];
    CGSize sz = radial_layout(self.shape, n, self.center, self.bounds.size.width, self.spread, gv.bounds.size.width, gv.bounds.size.height, pts);
    self.ringViews = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        ZORadialSlot *s = self.slots[i];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, sz.width, sz.height)];
        l.center = pts[i];
        BOOL empty = [s.kind isEqualToString:@"none"];
        l.text = s.label.length ? s.label : (empty ? @"\u2014" : @"?");
        l.textAlignment = NSTextAlignmentCenter; l.textColor = UIColor.whiteColor; l.font = [UIFont boldSystemFontOfSize:13];
        l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.55; l.userInteractionEnabled = NO;
        l.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.78]; l.layer.cornerRadius = MIN(sz.width, sz.height) / 2; l.layer.masksToBounds = YES;
        l.layer.borderWidth = 2; l.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
        if (empty) l.alpha = 0.45;
        [gv addSubview:l]; [self.ringViews addObject:l];
    }
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}
- (void)setHot:(int)h {
    if (_hot == h) return; _hot = h;
    for (NSUInteger i = 0; i < self.ringViews.count; i++) {
        UIView *v = self.ringViews[i]; BOOL on = (int)i == h;
        v.backgroundColor = on ? [UIColor colorWithRed:0.9 green:0.3 blue:0.2 alpha:0.9] : [UIColor colorWithWhite:0.1 alpha:0.78];
        v.transform = on ? CGAffineTransformMakeScale(1.12, 1.12) : CGAffineTransformIdentity;
    }
    if (h >= 0) [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
}
- (void)closeRing {
    for (UIView *v in self.ringViews) [v removeFromSuperview];
    self.ringViews = nil; self.open = NO; _hot = -1;
}
- (void)fire:(int)i {
    if (i < 0 || i >= (int)self.slots.count) return;
    ZORadialSlot *s = self.slots[i]; GLFWiOSView *gv = self.gv; NSString *k = s.kind;
    if ([k isEqualToString:@"key"] || [k isEqualToString:@"mouse"]) {                // a quick press and release
        BOOL key = [k isEqualToString:@"key"]; int c = s.code;
        if (key) push_key(c, GLFW_PRESS); else push_mouse(c, GLFW_PRESS);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (key) push_key(c, GLFW_RELEASE); else push_mouse(c, GLFW_RELEASE);
        });
        if (key && c == 256) [gv releaseLatches];
    }
    else if ([k isEqualToString:@"hide"]) [gv toggleControls];
    else if ([k isEqualToString:@"mode"]) [gv toggleMode];
    else if ([k isEqualToString:@"keyboard"]) [gv toggleKeyboard];
    else if ([k isEqualToString:@"firemode"]) [gv cycleFireModeForTarget:s.target];
    if (input_log_enabled()) glfwi_log("radial: sent %s (%d)", k.UTF8String, s.code);
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.touch) return;
    self.touch = ts.anyObject; self.startPt = [self.touch locationInView:self.gv]; self.hot = -1;
    self.backgroundColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.2 alpha:0.6];
    NSUInteger tok = ++self.token; __weak ZORadial *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{   // held: open the ring
        ZORadial *s = ws; if (s && s.token == tok && s.touch) [s openRing];
    });
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (!self.touch || ![ts containsObject:self.touch]) return;
    CGPoint p = [self.touch locationInView:self.gv];
    if (!self.open) { if (hypot(p.x - self.startPt.x, p.y - self.startPt.y) < 12) return; [self openRing]; }   // sliding opens it at once
    if (self.ringViews.count == 0) return;
    int best = -1; double bd = 26;                                                  // within 26 pt of an option's centre
    for (NSUInteger i = 0; i < self.ringViews.count; i++) {
        CGPoint q = self.ringViews[i].center; double d = hypot(p.x - q.x, p.y - q.y);
        if (d < bd) { bd = d; best = (int)i; }
    }
    self.hot = best;
}
- (void)finish:(NSSet<UITouch *> *)ts cancelled:(BOOL)cancelled {
    if (!self.touch || ![ts containsObject:self.touch]) return;
    self.touch = nil; self.token++;
    self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.45];
    BOOL wasOpen = self.open; int h = self.hot;
    [self closeRing];
    if (cancelled) return;
    [self fire:wasOpen ? h : self.tapSlot];                                        // open: the chosen option (or nothing); tap: the tap option
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self finish:ts cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self finish:ts cancelled:YES]; }
@end

// Movement stick. It still sends WASD, so the general keyboard layout of the game is untouched, but it behaves like a
// controller stick: a dead zone so a resting thumb does nothing, directions that engage and release at different points
// (hysteresis) so a thumb held between two directions does not chatter, and an optional Run or Sprint key at full push,
// the way a controller's stick runs when it is held to the edge. The touch editor writes deadZone, pushKey, pushAt and
// the arrow-key option into "zom.touchLayout" (stickDead, stickPushKey, stickPushAt, stickArrows).
@interface ZOJoystick : UIView
@property (nonatomic) BOOL up, left, down, right;
@property (nonatomic, strong) CAShapeLayer *thumb;
@property (nonatomic) CGPoint norm;
@property (nonatomic) CGFloat deadZone;          // fraction of the radius: 0.05...0.55
@property (nonatomic) int pushKey;               // GLFW key held at full push; 0 = none (Shift = run, Alt = sprint)
@property (nonatomic) CGFloat pushAt;            // 0.5...1.0 of the travel past the dead zone
@property (nonatomic) int keyUp, keyLeft, keyDown, keyRight;
@property (nonatomic) BOOL pushing;
@end
@implementation ZOJoystick
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.35];
        self.layer.cornerRadius = f.size.width / 2; self.layer.borderWidth = 2; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
        CGFloat t = f.size.width * 0.38;
        self.thumb = [CAShapeLayer layer];
        self.thumb.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-t / 2, -t / 2, t, t)].CGPath;
        self.thumb.fillColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        self.thumb.position = CGPointMake(f.size.width / 2, f.size.height / 2);
        [self.layer addSublayer:self.thumb];
        self.deadZone = 0.18; self.pushKey = 340; self.pushAt = 0.85;      // Shift at full push, like a controller's run
        self.keyUp = 87; self.keyLeft = 65; self.keyDown = 83; self.keyRight = 68;
    }
    return self;
}
- (void)set:(BOOL)v key:(int)key flag:(BOOL *)f { if (*f != v) { *f = v; push_key(key, v ? GLFW_PRESS : GLFW_RELEASE); } }
- (void)update:(UITouch *)t {
    CGFloat r = self.bounds.size.width / 2; CGPoint c = CGPointMake(r, r), p = [t locationInView:self];
    CGFloat dx = p.x - c.x, dy = p.y - c.y, len = hypot(dx, dy);
    if (len > r) { dx *= r / len; dy *= r / len; len = r; }
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.thumb.position = CGPointMake(c.x + dx, c.y + dy); [CATransaction commit];

    CGFloat mag = r > 0 ? len / r : 0;
    CGFloat dz = MAX(0.02, MIN(0.60, self.deadZone));
    CGFloat travel = mag <= dz ? 0 : (mag - dz) / MAX(0.0001, 1 - dz);        // 0 at the dead zone, 1 at the rim
    CGFloat ux = mag > 0 ? dx / r / mag : 0, uy = mag > 0 ? dy / r / mag : 0;  // unit direction
    CGFloat ax = ux * travel, ay = uy * travel;

    // Hysteresis: a direction engages at 0.18 of the travel and releases only below 0.12, so the stick starts moving with a
    // light push (about a third of the radius) but a thumb resting near the middle cannot make you drift.
    CGFloat on = 0.18, off = 0.12;
    [self set:ay < -(self.up ? off : on) key:self.keyUp flag:&_up];
    [self set:ay > (self.down ? off : on) key:self.keyDown flag:&_down];
    [self set:ax < -(self.left ? off : on) key:self.keyLeft flag:&_left];
    [self set:ax > (self.right ? off : on) key:self.keyRight flag:&_right];

    // Full push holds Run (or Sprint) until the stick comes back a little, like a controller stick at the rim.
    if (self.pushKey != 0) {
        CGFloat at = MAX(0.5, MIN(1.0, self.pushAt));
        BOOL want = travel >= (self.pushing ? at - 0.12 : at);
        if (want != self.pushing) {
            self.pushing = want;
            push_key(self.pushKey, want ? GLFW_PRESS : GLFW_RELEASE);
            if (want) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }
    }
}
- (void)reset {
    [self set:NO key:self.keyUp flag:&_up]; [self set:NO key:self.keyLeft flag:&_left];
    [self set:NO key:self.keyDown flag:&_down]; [self set:NO key:self.keyRight flag:&_right];
    if (self.pushing) { self.pushing = NO; if (self.pushKey) push_key(self.pushKey, GLFW_RELEASE); }
    CGFloat r = self.bounds.size.width / 2;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.thumb.position = CGPointMake(r, r); [CATransaction commit];
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self update:ts.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self update:ts.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self reset]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self reset]; }
@end

// Virtual gamepad stick: writes the pad's left or right axes instead of key presses.
@interface ZOVPadStick : UIView
@property (nonatomic) int stick;                   // 0 left, 1 right
@property (nonatomic, strong) CAShapeLayer *thumb;
@property (nonatomic) CGPoint norm;
@end
@implementation ZOVPadStick
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.35];
        self.layer.cornerRadius = f.size.width / 2; self.layer.borderWidth = 2; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
        CGFloat t = f.size.width * 0.38;
        self.thumb = [CAShapeLayer layer];
        self.thumb.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-t / 2, -t / 2, t, t)].CGPath;
        self.thumb.fillColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        self.thumb.position = CGPointMake(f.size.width / 2, f.size.height / 2);
        [self.layer addSublayer:self.thumb];
    }
    return self;
}
- (void)update:(UITouch *)t {
    CGFloat r = self.bounds.size.width / 2; CGPoint c = CGPointMake(r, r), p = [t locationInView:self];
    CGFloat dx = p.x - c.x, dy = p.y - c.y, len = hypot(dx, dy);
    if (len > r) { dx *= r / len; dy *= r / len; }
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.thumb.position = CGPointMake(c.x + dx, c.y + dy); [CATransaction commit];
    vpad_set_stick(self.stick, (float)(dx / r), (float)(dy / r));
}
- (void)reset {
    vpad_set_stick(self.stick, 0, 0);
    CGFloat r = self.bounds.size.width / 2;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.thumb.position = CGPointMake(r, r); [CATransaction commit];
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self update:ts.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self update:ts.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self reset]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self reset]; }
@end

// Aiming stick: while it is pushed past a small dead zone it holds the right mouse button (the game's aim stance) and puts the cursor around the
// player, in the pushed direction, so the character turns and aims that way. Pair it with ATK for firing. Letting go releases the aim.
@interface ZOAimStick : UIView
@property (nonatomic, strong) CAShapeLayer *thumb;
@property (nonatomic) CGPoint norm;
@property (nonatomic) BOOL aiming;
@property (nonatomic) BOOL attacking;      // auto mode is holding the fire button
@property (nonatomic) int attackMode;      // zom.aimAttackMode: 0 off, 1 one attack on release, 2 auto-attack while pushed
@end
@implementation ZOAimStick
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.attackMode = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"zom.aimAttackMode"];
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor colorWithRed:0.35 green:0.08 blue:0.06 alpha:0.30];
        self.layer.cornerRadius = f.size.width / 2; self.layer.borderWidth = 2; self.layer.borderColor = [UIColor colorWithRed:1 green:0.55 blue:0.5 alpha:0.55].CGColor;
        CGFloat t = f.size.width * 0.38;
        self.thumb = [CAShapeLayer layer];
        self.thumb.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-t / 2, -t / 2, t, t)].CGPath;
        self.thumb.fillColor = [UIColor colorWithRed:1 green:0.6 blue:0.55 alpha:0.6].CGColor;
        self.thumb.position = CGPointMake(f.size.width / 2, f.size.height / 2);
        [self.layer addSublayer:self.thumb];
    }
    return self;
}
- (void)update:(UITouch *)t {
    CGFloat r = self.bounds.size.width / 2; CGPoint p = [t locationInView:self];
    CGFloat dx = p.x - r, dy = p.y - r, len = hypot(dx, dy);
    if (len > r) { dx *= r / len; dy *= r / len; len = r; }
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.thumb.position = CGPointMake(r + dx, r + dy); [CATransaction commit];
    GLFWiOSView *gv = (GLFWiOSView *)self.superview;
    if (len > r * 0.25) {
        if (!self.aiming) {
            self.aiming = YES; push_mouse(1, GLFW_PRESS);
            if (self.attackMode == 2) { self.attacking = YES; push_mouse(0, GLFW_PRESS); }     // auto-attack while pushed
        }
        CGFloat reach = MIN(gv.bounds.size.width, gv.bounds.size.height) * 0.42;       // how far from the player the cursor goes at full push
        CGPoint c = CGPointMake(gv.bounds.size.width / 2, gv.bounds.size.height / 2);   // the game keeps the player at the centre of the screen
        [gv moveCursorTo:CGPointMake(c.x + dx / r * reach, c.y + dy / r * reach)];
    } else if (self.aiming) {
        self.aiming = NO; push_mouse(1, GLFW_RELEASE);
        if (self.attacking) { self.attacking = NO; push_mouse(0, GLFW_RELEASE); }
    }
}
- (void)reset {
    if (self.aiming) {
        self.aiming = NO; push_mouse(1, GLFW_RELEASE);
        if (self.attacking) { self.attacking = NO; push_mouse(0, GLFW_RELEASE); }
        else if (self.attackMode == 1) { push_mouse(0, GLFW_PRESS); push_mouse(0, GLFW_RELEASE); }   // one attack on release
    }
    CGFloat r = self.bounds.size.width / 2;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.thumb.position = CGPointMake(r, r); [CATransaction commit];
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self update:ts.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self update:ts.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self reset]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self reset]; }
@end

// Receives soft-keyboard text and turns it into GLFW key/char events. Unhandled hardware key presses pass up the responder chain to the game view.
@interface ZOKeyInput : UIView <UIKeyInput>
@end
@implementation ZOKeyInput
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        if (ch == '\n') { push_key(257, GLFW_PRESS); push_key(257, GLFW_RELEASE); continue; }
        Ev c = {.type = EV_CHAR, .a = ch}; push_event(c);
    }
}
- (void)deleteBackward { push_key(259, GLFW_PRESS); push_key(259, GLFW_RELEASE); }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeASCIICapable; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
@end

// ProMotion hint. A bare CAMetalLayer gives the system no reason to leave the 60 Hz mode, so frames pace at 59.99 even with
// CADisableMinimumFrameDurationOnPhone set. A display link that asks for up to 120 Hz keeps the panel in its fast mode; it does no work itself.
@interface ZOFrameRateHint : NSObject
- (void)tick:(CADisplayLink *)link;
@end
@implementation ZOFrameRateHint
- (void)tick:(CADisplayLink *)link {}
@end
static void frame_rate_hint_start(void) {
    static CADisplayLink *link; static ZOFrameRateHint *target;
    if (link) return;
    target = [ZOFrameRateHint new];
    link = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
    link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    glfwi_log("frame rate hint: requesting up to 120 Hz (max display %ld Hz)", (long)UIScreen.mainScreen.maximumFramesPerSecond);
}

// FPS counter (Tools > Show FPS): a small label in the corner of the game screen, counted at the buffer swap. It is not part of
// the on-screen controls, so HIDE and the automatic hiding for a controller leave it alone.
static UILabel *g_fpsLabel;
static double g_fpsStart;
static int g_fpsFrames;
static void fps_note_frame(void) {
    if (!g_fpsLabel) return;
    double now = CACurrentMediaTime();
    if (g_fpsStart <= 0) { g_fpsStart = now; g_fpsFrames = 0; return; }
    g_fpsFrames++;
    double dt = now - g_fpsStart;
    if (dt < 0.5) return;                     // twice a second reads fine and costs nothing measurable
    double fps = g_fpsFrames / dt;
    g_fpsStart = now; g_fpsFrames = 0;
    NSString *text = [NSString stringWithFormat:@"%.0f fps · %.1f ms", fps, fps > 0 ? 1000.0 / fps : 0];
    dispatch_async(dispatch_get_main_queue(), ^{ g_fpsLabel.text = text; });     // UILabel is main-thread only
}

@implementation GLFWiOSView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)canBecomeFirstResponder { return YES; }

// ---- pointer emulation on the empty area. Trackpad mode: a drawn virtual cursor moved by relative drags;
// tap = left click, long press = hold button (drag & drop), two-finger tap = right click. Direct mode: cursor jumps to the finger.
- (void)moveCursorTo:(CGPoint)p {
    p.x = MAX(0, MIN(self.bounds.size.width - 1, p.x)); p.y = MAX(0, MIN(self.bounds.size.height - 1, p.y));
    self.cursorPt = p;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; self.cursorLayer.position = p; [CATransaction commit];
    push_cursor(p.x * g_ptrScale, p.y * g_ptrScale);
}
- (void)clickAfter:(double)delay hold:(double)hold button:(int)b {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        push_mouse(b, GLFW_PRESS);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ push_mouse(b, GLFW_RELEASE); });
    });
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.pointerTouch) return;
    UITouch *t = ts.anyObject;
    if (t.type == UITouchTypeIndirectPointer) return;      // physical mouse/trackpad clicks arrive through GCMouse instead
    self.pointerTouch = t; self.moved = NO; self.holding = NO;
    CGPoint p = [t locationInView:self];
    self.lastPt = p; self.startPt = p; self.startTime = CACurrentMediaTime();
    if (!self.trackpad) { [self moveCursorTo:p]; }
    if (input_log_enabled()) glfwi_log("touch began at %.0f,%.0f (cursor %.0f,%.0f, mode %s)", p.x, p.y, self.cursorPt.x, self.cursorPt.y, self.trackpad ? "pad" : "direct");
    __weak GLFWiOSView *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 450 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{   // long press -> hold left button
        GLFWiOSView *s = ws; if (!s || s.pointerTouch != t || s.moved || s.holding) return;
        s.holding = YES; [s moveCursorTo:s.startPt]; push_mouse(0, GLFW_PRESS);
    });
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (!self.pointerTouch || ![ts containsObject:self.pointerTouch]) return;
    CGPoint p = [self.pointerTouch locationInView:self];
    if (hypot(p.x - self.startPt.x, p.y - self.startPt.y) > 10) self.moved = YES;
    if (self.trackpad) { CGFloat k = [self padCursorSpeed]; [self moveCursorTo:CGPointMake(self.cursorPt.x + (p.x - self.lastPt.x) * k, self.cursorPt.y + (p.y - self.lastPt.y) * k)]; }
    else [self moveCursorTo:p];
    self.lastPt = p;
}
- (void)finishPointer:(UITouch *)t cancelled:(BOOL)cancelled {
    if (t != self.pointerTouch) return;
    self.pointerTouch = nil;
    if (self.holding) { self.holding = NO; push_mouse(0, GLFW_RELEASE); return; }
    BOOL tap = !cancelled && !self.moved && (CACurrentMediaTime() - self.startTime) < 0.40;
    if (input_log_enabled()) glfwi_log("touch end tap=%d moved=%d", tap, self.moved);
    if (tap) {
        // hybrid: a tap clicks where the finger is (the pointer warps there first so the game sees hover, then the press)
        [self moveCursorTo:self.startPt];
        [self clickAfter:0.09 hold:0.14 button:0];
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self finishPointer:ts.anyObject cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self finishPointer:ts.anyObject cancelled:YES]; }
- (void)twoFingerTap:(UITapGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateRecognized) [self clickAfter:0.0 hold:0.14 button:1]; }
- (void)toggleMode {
    self.trackpad = !self.trackpad;
    self.modeButton.label.text = self.trackpad ? @"PAD" : @"TCH";
    [self updateCursorVisibility];
}
- (void)mouseDelta:(CGPoint)d { [self moveCursorTo:CGPointMake(self.cursorPt.x + d.x, self.cursorPt.y + d.y)]; }
/// Touch "pad" mode cursor speed: one point of cursor per point of finger at 1.0 (launcher's Sensitivity slider, zom.mouseSens).
- (CGFloat)padCursorSpeed {
    static CGFloat speed = -1;
    if (speed < 0) {
        id pref = [NSUserDefaults.standardUserDefaults objectForKey:@"zom.mouseSens"];
        speed = pref ? [pref doubleValue] : 1.0;
        if (!(speed >= 0.2 && speed <= 4.0)) speed = 1.0;
    }
    return speed;
}
- (void)setMouseConnected:(BOOL)on {
    self.mouseActive = on;
    [self updateCursorVisibility];      // the drawn cursor stays visible while a mouse is attached, whatever the touch mode
    [NSNotificationCenter.defaultCenter postNotificationName:@"ZomIOSMouseConnected" object:@(on)];   // the host view controller captures the system pointer
}

// ---- two-finger scroll (mouse wheel)
- (void)scrolled:(UIPanGestureRecognizer *)g {
    static int twoFingerOn = -1;
    if (twoFingerOn < 0) { id pref = [NSUserDefaults.standardUserDefaults objectForKey:@"zom.twoFingerZoom"]; twoFingerOn = pref ? [pref boolValue] : 1; }
    CGPoint d = [g translationInView:self]; [g setTranslation:CGPointZero inView:self];
    if (!twoFingerOn) return;                       // the Two-Finger Zoom setting is off: empty-screen drags do nothing
    Ev e = {.type = EV_SCROLL, .x = 0, .y = -d.y / 12.0}; push_event(e);
}

// ---- soft keyboard: a separate hidden UIKeyInput view takes focus only while KB is on, so the game view (which stays first responder
// for hardware keys) never has an input view and iOS reserves no keyboard area.
- (void)toggleKeyboard {
    self.keyboardShown = !self.keyboardShown;
    if (!self.kbInput) { self.kbInput = [[ZOKeyInput alloc] initWithFrame:CGRectMake(0, 0, 1, 1)]; self.kbInput.alpha = 0.01; self.kbInput.userInteractionEnabled = NO; [self addSubview:self.kbInput]; }
    if (self.keyboardShown) [self.kbInput becomeFirstResponder];
    else { [self.kbInput resignFirstResponder]; [self becomeFirstResponder]; }
}
- (void)releaseLatches {
    for (UIView *v in self.controls) if ([v isKindOfClass:ZOButton.class]) [(ZOButton *)v releaseLatch];
}
- (ZOButton *)buttonWithItemId:(NSString *)iid {
    if (!iid.length) return nil;
    for (UIView *v in self.controls) if ([v isKindOfClass:ZOButton.class] && [((ZOButton *)v).itemId isEqualToString:iid]) return (ZOButton *)v;
    return nil;
}
- (void)cycleFireModeFrom:(ZOButton *)toggle { [self cycleFireModeForTarget:toggle.targetId]; }
- (void)cycleFireModeForTarget:(NSString *)targetId {
    ZOButton *t = [self buttonWithItemId:targetId]; if (!t || t.kind > 1) return;
    t.fireMode = t.fireMode == 2 ? 0 : 2;                 // auto counts as default: holding a button already repeats most actions
    [self updateFireToggles];
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
}
- (void)updateFireToggles {
    static NSString *const names[] = { @"DEF", @"AUTO", @"REL" };
    for (UIView *v in self.controls) {
        if (![v isKindOfClass:ZOButton.class] || ((ZOButton *)v).kind != 7) continue;
        ZOButton *t = [self buttonWithItemId:((ZOButton *)v).targetId];
        ((ZOButton *)v).label.text = t ? names[MAX(0, MIN(2, t.fireMode))] : @"—";
    }
}
- (void)toggleControls {
    self.controlsHidden = !self.controlsHidden;
    self.hideButton.label.text = self.controlsHidden ? @"SHOW" : @"HIDE";
    [self updateControlVisibility];
}
// On-screen controls disappear while a physical controller, or a keyboard and mouse together, are connected and return when unplugged (or the user hid them).
// The drawn pointer is invisible while a controller is connected; touch still moves and clicks it, you just don't see it.
- (void)updateCursorVisibility {
    self.cursorLayer.hidden = self.padConnected || (!self.trackpad && !self.mouseActive);
}
- (void)updateControlVisibility {
    [self updateCursorVisibility];
    // a controller, or a physical keyboard together with a mouse; the controller only hides the controls when the player left it that way
    BOOL away = (self.padConnected && pad_overlay_hides()) || kbm_connected();
    if (self.controlsHidden || away) {                        // a locked button must not stay held with nothing left to tap
        [self releaseLatches];
        for (UIView *v in self.controls) {                     // and a thumb left on a stick must not leave WASD (or Run) held
            if ([v isKindOfClass:ZOJoystick.class]) [(ZOJoystick *)v reset];
            else if ([v isKindOfClass:ZOVPadStick.class]) [(ZOVPadStick *)v reset];
        }
    }
    for (UIView *v in self.controls) {
        BOOL isRadial = [v isKindOfClass:ZORadial.class];
        // A radial that holds Hide/Show is the way back, so it stays on screen while the rest is hidden.
        v.hidden = (self.controlsHidden && !(isRadial && [(ZORadial *)v holds:@"hide"])) || away;
        if (isRadial && v.hidden) [(ZORadial *)v closeRing];
    }
    self.hideButton.hidden = away; self.modeButton.hidden = away;
}
- (void)setPadConnected:(BOOL)on { if (_padConnected == on) return; _padConnected = on; [self updateControlVisibility]; glfwi_log("controller %s: on-screen controls %s", on ? "connected" : "disconnected", on ? "hidden" : "shown"); }

// ---- hardware keyboard
- (void)press:(NSSet<UIPress *> *)presses action:(int)action {
    for (UIPress *p in presses) {
        UIKey *k = p.key; if (!k) continue;
        int key = glfw_key_from_hid(k.keyCode);
        if (key >= 0) push_key(key, action);
        if (action != GLFW_RELEASE && k.characters.length == 1) {
            unichar ch = [k.characters characterAtIndex:0];
            if (ch >= 32 && ch != 127 && !(ch >= 0xF700 && ch <= 0xF8FF)) { Ev c = {.type = EV_CHAR, .a = ch}; push_event(c); }
        }
    }
}
- (void)pressesBegan:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self press:p action:GLFW_PRESS]; }
- (void)pressesEnded:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self press:p action:GLFW_RELEASE]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self press:p action:GLFW_RELEASE]; }

// ---- layout of the overlay
// Builds the controls from the layout saved by the launcher's touch editor (UserDefaults "zom.touchLayout", JSON). NO = none saved.
- (BOOL)installSavedLayout {
    // Virtual gamepad on: the gamepad layout drives the synthetic pad; keyboard/mouse layouts stay untouched for when it is off.
    BOOL padMode = vpad_active();
    NSString *json = [NSUserDefaults.standardUserDefaults stringForKey:(padMode ? @"zom.padLayout" : @"zom.touchLayout")];
    if (!json.length && padMode) json = [NSUserDefaults.standardUserDefaults stringForKey:@"zom.touchLayout"];
    NSDictionary *lay = json.length ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    NSArray *items = [lay isKindOfClass:NSDictionary.class] ? lay[@"items"] : nil;
    if (![items isKindOfClass:NSArray.class] || items.count == 0) return NO;
    CGFloat alpha = [lay[@"opacity"] respondsToSelector:@selector(doubleValue)] ? MAX(0.05, MIN(1.0, [lay[@"opacity"] doubleValue])) : 1.0;   // 5% floor: under 1% iOS stops delivering touches
    int tag = 30;
    BOOL radialHide = NO, radialMode = NO;                // a radial holding these replaces the standalone HIDE / PAD buttons
    for (NSDictionary *it in items) {
        if (![it isKindOfClass:NSDictionary.class]) continue;
        NSString *kind = it[@"kind"]; if (![kind isKindOfClass:NSString.class]) continue;
        CGFloat size = [it[@"size"] doubleValue]; if (size < 24) size = 62;
        CGPoint norm = CGPointMake([it[@"x"] doubleValue], [it[@"y"] doubleValue]);
        if (norm.x == 0 && norm.y == 0) norm = CGPointMake(0.5, 0.5);
        NSString *label = [it[@"label"] isKindOfClass:NSString.class] ? it[@"label"] : @"";
        int code = [it[@"code"] intValue];
        if ([kind isEqualToString:@"aimstick"]) {
            ZOAimStick *a = [[ZOAimStick alloc] initWithFrame:CGRectMake(0, 0, size, size)]; a.tag = tag++; a.norm = norm; a.alpha = alpha;
            [self addSubview:a]; [self.controls addObject:a]; continue;
        }
        if ([kind isEqualToString:@"radial"]) {
            ZORadial *r = [[ZORadial alloc] initWithFrame:CGRectMake(0, 0, size, size)]; r.tag = tag++; r.norm = norm; r.alpha = alpha;
            NSMutableArray<ZORadialSlot *> *sl = [NSMutableArray array];
            NSArray *raw = [it[@"slots"] isKindOfClass:NSArray.class] ? it[@"slots"] : @[];
            for (NSDictionary *d in raw) {
                if (![d isKindOfClass:NSDictionary.class]) continue;
                ZORadialSlot *s = [ZORadialSlot new];
                s.kind = [d[@"kind"] isKindOfClass:NSString.class] ? d[@"kind"] : @"none";
                s.code = [d[@"code"] respondsToSelector:@selector(intValue)] ? [d[@"code"] intValue] : 0;
                s.label = [d[@"label"] isKindOfClass:NSString.class] ? d[@"label"] : @"";
                s.target = [d[@"target"] isKindOfClass:NSString.class] ? d[@"target"] : nil;
                [sl addObject:s]; if (sl.count == 8) break;
            }
            r.slots = sl;
            r.tapSlot = [it[@"tapSlot"] respondsToSelector:@selector(intValue)] ? [it[@"tapSlot"] intValue] : -1;
            r.shape = [it[@"radialShape"] respondsToSelector:@selector(intValue)] ? MAX(0, MIN(3, [it[@"radialShape"] intValue])) : 0;
            r.spread = [it[@"radialSpread"] respondsToSelector:@selector(doubleValue)] ? MAX(0.6, MIN(1.6, [it[@"radialSpread"] doubleValue])) : 1.0;
            [r setFaceText:label];
            if ([r holds:@"hide"]) radialHide = YES;
            if ([r holds:@"mode"]) radialMode = YES;
            [self addSubview:r]; [self.controls addObject:r]; continue;
        }
        if ([kind isEqualToString:@"scroll"]) {           // drawn 0.6 x 2.2 times its size, so "size" scales it like the other controls
            ZOScrollStrip *sc = [[ZOScrollStrip alloc] initWithFrame:CGRectMake(0, 0, size * 0.6, size * 2.2)];
            sc.tag = tag++; sc.norm = norm; sc.alpha = alpha;
            [self addSubview:sc]; [self.controls addObject:sc]; continue;
        }
        if ([kind isEqualToString:@"stick"]) {
            ZOJoystick *j = [[ZOJoystick alloc] initWithFrame:CGRectMake(0, 0, size, size)]; j.tag = tag++; j.norm = norm; j.alpha = alpha;
            id dz = it[@"stickDead"], pk = it[@"stickPushKey"], pa = it[@"stickPushAt"], ks = it[@"stickArrows"];
            j.deadZone = [dz respondsToSelector:@selector(doubleValue)] ? MAX(0.05, MIN(0.55, [dz doubleValue])) : 0.18;
            j.pushKey = [pk respondsToSelector:@selector(intValue)] ? [pk intValue] : 340;      // Shift: run at full push
            j.pushAt = [pa respondsToSelector:@selector(doubleValue)] ? MAX(0.5, MIN(1.0, [pa doubleValue])) : 0.85;
            if ([ks respondsToSelector:@selector(boolValue)] && [ks boolValue]) { j.keyUp = 265; j.keyLeft = 263; j.keyDown = 264; j.keyRight = 262; }
            [self addSubview:j]; [self.controls addObject:j]; continue;
        }
        if ([kind isEqualToString:@"padstick"]) {
            ZOVPadStick *s = [[ZOVPadStick alloc] initWithFrame:CGRectMake(0, 0, size, size)];
            s.tag = tag++; s.norm = norm; s.alpha = alpha; s.stick = code == 1 ? 1 : 0;
            [self addSubview:s]; [self.controls addObject:s]; continue;
        }
        if ([kind isEqualToString:@"padbtn"] || [kind isEqualToString:@"padtrig"]) {
            BOOL trig = [kind isEqualToString:@"padtrig"];
            ZOButton *pb = [ZOButton buttonWithTitle:label kind:(trig ? 6 : 5) code:code size:size];
            pb.norm = norm; pb.alpha = alpha; pb.tag = tag++;
            [self addSubview:pb]; [self.controls addObject:pb]; continue;
        }
        int k = [kind isEqualToString:@"key"] ? 0 : [kind isEqualToString:@"mouse"] ? 1 : [kind isEqualToString:@"keyboard"] ? 2 : [kind isEqualToString:@"hide"] ? 3 : [kind isEqualToString:@"mode"] ? 4 : [kind isEqualToString:@"firemode"] ? 7 : -1;
        if (k < 0) continue;
        ZOButton *b = [ZOButton buttonWithTitle:label kind:k code:code size:size]; b.norm = norm; b.alpha = alpha; b.tag = tag++;
        b.itemId = [it[@"id"] isKindOfClass:NSString.class] ? it[@"id"] : nil;
        if (k <= 1) {                                                          // key and mouse buttons only: the per-button two-thumb options
            id da = it[@"dragAim"], fm = it[@"fireMode"], hl = it[@"holdLock"], ht = it[@"holdLockTime"];
            b.holdLockDelay = [ht respondsToSelector:@selector(doubleValue)] ? MAX(0.1, MIN(3.0, [ht doubleValue])) : 0.5;
            b.dragAimOn = [da respondsToSelector:@selector(boolValue)] && [da boolValue];
            b.holdLockOn = [hl respondsToSelector:@selector(boolValue)] && [hl boolValue];
            b.fireMode = [fm respondsToSelector:@selector(intValue)] ? MAX(0, MIN(2, [fm intValue])) : 0;
        }
        if (k == 7) b.targetId = [it[@"target"] isKindOfClass:NSString.class] ? it[@"target"] : nil;
        [self addSubview:b];
        if (k == 3) { self.hideButton = b; b.tag = 19; }
        else if (k == 4) { self.modeButton = b; b.tag = 20; }
        else [self.controls addObject:b];
    }
    if (!self.hideButton && !radialHide) { self.hideButton = [ZOButton buttonWithTitle:@"HIDE" kind:3 code:0 size:44]; self.hideButton.tag = 19; [self addSubview:self.hideButton]; }   // never lose these two
    if (!self.modeButton && !radialMode) { self.modeButton = [ZOButton buttonWithTitle:@"PAD" kind:4 code:0 size:44]; self.modeButton.tag = 20; [self addSubview:self.modeButton]; }
    [self updateFireToggles];
    glfwi_log("touch layout: %lu saved controls", (unsigned long)items.count);
    return YES;
}
// The two-finger scroll (mouse wheel) and two-finger tap (right click) only count fingers on empty screen. A finger on the joystick or on an action
// button must not count, or holding the stick with one thumb and a button with the other reads as a zoom gesture.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *v = touch.view; v && v != self; v = v.superview)
        if ([v isKindOfClass:ZOButton.class] || [v isKindOfClass:ZOJoystick.class] || [v isKindOfClass:ZOAimStick.class] || [v isKindOfClass:ZOVPadStick.class] || [v isKindOfClass:ZOScrollStrip.class] || [v isKindOfClass:ZORadial.class]) return NO;
    return YES;
}
- (void)installControls {
    self.multipleTouchEnabled = YES;
    // Two-finger zoom (Settings > Controls) can be turned off, because it also fires with a thumb on the stick and one on a button;
    // the scroll strip does the same job with one thumb.
    {
        id tfz = [NSUserDefaults.standardUserDefaults objectForKey:@"zom.twoFingerZoom"];
        if (!tfz || [tfz boolValue]) {
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrolled:)];
            pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2; pan.cancelsTouchesInView = YES;
            pan.delegate = self;
            [self addGestureRecognizer:pan];
        } else glfwi_log("two-finger zoom: off");
    }
    UITapGestureRecognizer *two = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerTap:)];
    two.delegate = self;
    two.numberOfTouchesRequired = 2; [self addGestureRecognizer:two];
    self.trackpad = YES;
    self.cursorLayer = [CAShapeLayer layer];
    { UIBezierPath *a = [UIBezierPath bezierPath]; [a moveToPoint:CGPointMake(0, 0)]; [a addLineToPoint:CGPointMake(0, 20)]; [a addLineToPoint:CGPointMake(5, 15.5)];
      [a addLineToPoint:CGPointMake(8.5, 23)]; [a addLineToPoint:CGPointMake(11.5, 21.7)]; [a addLineToPoint:CGPointMake(8.2, 14.3)]; [a addLineToPoint:CGPointMake(14.5, 14.3)]; [a closePath];
      self.cursorLayer.path = a.CGPath; self.cursorLayer.fillColor = UIColor.whiteColor.CGColor; self.cursorLayer.strokeColor = UIColor.blackColor.CGColor; self.cursorLayer.lineWidth = 1.5;
      self.cursorLayer.anchorPoint = CGPointZero; self.cursorLayer.zPosition = 1000; self.cursorLayer.bounds = CGRectMake(0, 0, 16, 24); }
    [self.layer addSublayer:self.cursorLayer];
    [self moveCursorTo:CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2)];
    self.controls = [NSMutableArray array];
    // The FPS label goes in before the saved layout, which can be missing on a fresh install.
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"zom.fpsCounter"]) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, 122, 22)];
        l.text = @"— fps";
        l.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
        l.textColor = UIColor.whiteColor;
        l.textAlignment = NSTextAlignmentCenter;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        l.layer.cornerRadius = 6; l.layer.masksToBounds = YES;
        l.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        l.userInteractionEnabled = NO;
        [self addSubview:l];
        g_fpsLabel = l;
        glfwi_log("fps counter: drawing the frame rate in the top-left corner");
    }
    if ([self installSavedLayout]) { _padConnected = pad_any_connected(); [self updateControlVisibility]; [self setNeedsLayout]; return; }
    ZOJoystick *js = [[ZOJoystick alloc] initWithFrame:CGRectMake(0, 0, 130, 130)]; js.tag = 1; [self addSubview:js]; [self.controls addObject:js];
    struct { const char *t; int kind, code; int tag; } defs[] = {
        {"ATK", 1, 0, 10}, {"AIM", 1, 1, 11}, {"E", 0, 69, 12}, {"RUN", 0, 340, 13}, {"SPC", 0, 32, 14},
        {"CTRL", 0, 341, 15}, {"TAB", 0, 258, 16}, {"ESC", 0, 256, 17}, {"KB", 2, 0, 18},
    };
    for (size_t i = 0; i < sizeof defs / sizeof defs[0]; i++) {
        BOOL small = defs[i].tag >= 16;
        ZOButton *b = [ZOButton buttonWithTitle:[NSString stringWithUTF8String:defs[i].t] kind:defs[i].kind code:defs[i].code size:small ? 44 : 62];
        b.tag = defs[i].tag; [self addSubview:b]; [self.controls addObject:b];
    }
    self.hideButton = [ZOButton buttonWithTitle:@"HIDE" kind:3 code:0 size:44]; self.hideButton.tag = 19; [self addSubview:self.hideButton];
    self.modeButton = [ZOButton buttonWithTitle:@"PAD" kind:4 code:0 size:44]; self.modeButton.tag = 20; [self addSubview:self.modeButton];
    _padConnected = pad_any_connected(); [self updateControlVisibility];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets in = self.safeAreaInsets; CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat L = MAX(in.left, 20), R = MAX(in.right, 20), B = MAX(in.bottom, 14), T = MAX(in.top, 10);
    for (UIView *v in self.subviews) {
        CGPoint np = CGPointZero;
        if ([v isKindOfClass:ZOButton.class]) np = ((ZOButton *)v).norm; else if ([v isKindOfClass:ZOJoystick.class]) np = ((ZOJoystick *)v).norm; else if ([v isKindOfClass:ZOAimStick.class]) np = ((ZOAimStick *)v).norm; else if ([v isKindOfClass:ZOVPadStick.class]) np = ((ZOVPadStick *)v).norm; else if ([v isKindOfClass:ZOScrollStrip.class]) np = ((ZOScrollStrip *)v).norm; else if ([v isKindOfClass:ZORadial.class]) np = ((ZORadial *)v).norm;
        if (np.x != 0 || np.y != 0) {      // saved layout: used exactly where the editor showed it
            v.center = CGPointMake(np.x * W, np.y * H);      // no clamping here, or controls would move after the fact
            continue;
        }
        switch (v.tag) {
            case 1:  v.center = CGPointMake(L + 70, H - B - 70); break;                       // joystick
            case 10: v.center = CGPointMake(W - R - 40, H - B - 44); break;                    // ATK
            case 11: v.center = CGPointMake(W - R - 112, H - B - 36); break;                   // AIM
            case 12: v.center = CGPointMake(W - R - 40, H - B - 116); break;                   // E
            case 13: v.center = CGPointMake(W - R - 112, H - B - 108); break;                  // RUN
            case 14: v.center = CGPointMake(W - R - 184, H - B - 44); break;                   // SPC
            case 15: v.center = CGPointMake(W - R - 184, H - B - 116); break;                  // CTRL
            case 16: v.center = CGPointMake(W - R - 28 - 3 * 52, T + 26); break;              // TAB
            case 17: v.center = CGPointMake(W - R - 28 - 2 * 52, T + 26); break;              // ESC
            case 18: v.center = CGPointMake(W - R - 28 - 1 * 52, T + 26); break;              // KB
            case 19: v.center = CGPointMake(W - R - 28, T + 26); break;                        // HIDE
            case 20: v.center = CGPointMake(W - R - 28 - 4 * 52, T + 26); break;              // PAD/TCH
        }
    }
}
@end

static UIWindow *find_key_window(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
        UIWindow *f = ((UIWindowScene *)s).windows.firstObject; if (f) return f;
    }
    return nil;
}

static void run_on_main(dispatch_block_t b) {
    if ([NSThread isMainThread]) b(); else dispatch_sync(dispatch_get_main_queue(), b);
}

static float render_scale(void) {
    const char *e = getenv("ZOMIOS_SCALE");
    float s = e ? (float)atof(e) : 2.0f;
    return s > 0.25f && s <= 4.0f ? s : 2.0f;
}

// ---------------------------------------------------------------- init / terminate ---
GLFW_API int glfwInit(void) {
    if (g_initialized) return 1;
    // gl4es's load-time constructor probes the GPU with its own temporary EGL context on the shared display and then
    // tears the display down. Load it now, before we create our display/context, so that probe cannot destroy ours.
    gl4es_handle();
    mach_timebase_info(&g_tb); g_t0 = mach_absolute_time();
    pads_init();
    mouse_init();
    g_initialized = 1;
    return 1;
}
GLFW_API void glfwTerminate(void) { g_initialized = 0; }
GLFW_API void glfwInitHint(int hint, int value) {}
GLFW_API void glfwInitAllocator(const GLFWallocator *a) {}
GLFW_API void glfwGetVersion(int *major, int *minor, int *rev) { if (major) *major = 3; if (minor) *minor = 4; if (rev) *rev = 0; }
GLFW_API const char *glfwGetVersionString(void) { return "3.4.0 iOS (zomios)"; }
GLFW_API int glfwGetError(const char **desc) { int e = g_lastError; if (desc) *desc = g_lastErrorDesc; g_lastError = 0; return e; }
GLFW_API errorfun glfwSetErrorCallback(errorfun cb) { errorfun o = g_errorCb; g_errorCb = cb; return o; }
GLFW_API int glfwGetPlatform(void) { return GLFW_PLATFORM_COCOA; }
GLFW_API int glfwPlatformSupported(int platform) { return platform == GLFW_PLATFORM_COCOA; }

// ---------------------------------------------------------------- monitors ---
// Developer option: pretend the screen has another aspect ratio (ZOMIOS_ASPECT = width / height, e.g. 1.3333 for an iPad Pro 13"), so the game's
// UI can be checked for that shape on any device. Zero when off.
static float sim_aspect(void) {
    const char *e = getenv("ZOMIOS_ASPECT"); float a = e ? (float)atof(e) : 0;
    return (a >= 1.0f && a <= 3.0f) ? a : 0;
}
static GLFWvidmode g_vidmode;
static void fill_vidmode(void) {
    __block CGSize sz = CGSizeMake(956, 440);
    run_on_main(^{
        CGRect bd = UIScreen.mainScreen.bounds;
        sz = CGSizeMake(MAX(bd.size.width, bd.size.height), MIN(bd.size.width, bd.size.height));
    });
    const char *hs = getenv("ZOMIOS_HEIGHT"); float targetH = hs ? (float)atof(hs) : 720.0f;
    if (targetH < 360 || targetH > 2160) targetH = 720;
    float f = targetH / (float)sz.height;
    float sa = sim_aspect(); int vw = (int)lroundf(sa > 0 ? targetH * sa : sz.width * f);
    g_vidmode = (GLFWvidmode){vw, (int)lroundf(targetH), 8, 8, 8, 60};   // same logical size as the window
}
GLFW_API GLFWmonitor **glfwGetMonitors(int *count) { static GLFWmonitor *m[1] = {(GLFWmonitor *)0x1}; if (count) *count = 1; return m; }
GLFW_API GLFWmonitor *glfwGetPrimaryMonitor(void) { return (GLFWmonitor *)0x1; }
GLFW_API void glfwGetMonitorPos(GLFWmonitor *m, int *x, int *y) { if (x) *x = 0; if (y) *y = 0; }
GLFW_API void glfwGetMonitorWorkarea(GLFWmonitor *m, int *x, int *y, int *w, int *h) {
    fill_vidmode(); if (x) *x = 0; if (y) *y = 0; if (w) *w = g_vidmode.width; if (h) *h = g_vidmode.height;
}
GLFW_API void glfwGetMonitorPhysicalSize(GLFWmonitor *m, int *w, int *h) { if (w) *w = 140; if (h) *h = 65; }
GLFW_API void glfwGetMonitorContentScale(GLFWmonitor *m, float *x, float *y) { if (x) *x = 1.0f; if (y) *y = 1.0f; }
GLFW_API const char *glfwGetMonitorName(GLFWmonitor *m) { return "iOS Display"; }
GLFW_API void glfwSetMonitorUserPointer(GLFWmonitor *m, void *p) {}
GLFW_API void *glfwGetMonitorUserPointer(GLFWmonitor *m) { return NULL; }
GLFW_API void *glfwSetMonitorCallback(void *cb) { return NULL; }
GLFW_API const GLFWvidmode *glfwGetVideoModes(GLFWmonitor *m, int *count) { fill_vidmode(); if (count) *count = 1; return &g_vidmode; }
GLFW_API const GLFWvidmode *glfwGetVideoMode(GLFWmonitor *m) { fill_vidmode(); return &g_vidmode; }
GLFW_API void glfwSetGamma(GLFWmonitor *m, float g) {}
GLFW_API const GLFWgammaramp *glfwGetGammaRamp(GLFWmonitor *m) { return NULL; }
GLFW_API void glfwSetGammaRamp(GLFWmonitor *m, const GLFWgammaramp *r) {}

// ---------------------------------------------------------------- windows ---
GLFW_API void glfwDefaultWindowHints(void) { g_hintCount = 0; }
GLFW_API void glfwWindowHint(int hint, int value) {
    for (int i = 0; i < g_hintCount; i++) if (g_hints[i][0] == hint) { g_hints[i][1] = value; return; }
    if (g_hintCount < 64) { g_hints[g_hintCount][0] = hint; g_hints[g_hintCount][1] = value; g_hintCount++; }
}
GLFW_API void glfwWindowHintString(int hint, const char *value) {}

static int hint_value(int hint, int def) {
    for (int i = 0; i < g_hintCount; i++) if (g_hints[i][0] == hint) return g_hints[i][1];
    return def;
}

GLFW_API GLFWwindow *glfwCreateWindow(int width, int height, const char *title, GLFWmonitor *monitor, GLFWwindow *share) {
    if (!g_initialized) { set_error(0x10001, "GLFW not initialized"); return NULL; }
    if (g_window) { set_error(0x10008, "only one window is supported on iOS"); return NULL; }
    if (!load_egl()) { set_error(0x10008, "MetalANGLE unavailable"); return NULL; }

    GLFWwindow *w = calloc(1, sizeof *w);
    w->title = strdup(title ? title : "");
    w->scale = render_scale();
    w->inputMode[0] = 0x34001;

    __block int ok = 1;
    run_on_main(^{
        UIWindow *uw = find_key_window();
        if (!uw) { ok = 0; return; }
        CGRect b = uw.bounds;
        GLFWiOSView *v = [[GLFWiOSView alloc] initWithFrame:b];
        v.win = w; v.backgroundColor = UIColor.blackColor;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        CAMetalLayer *ml = (CAMetalLayer *)v.layer;
        // The game runs at a logical resolution (default height 720) instead of the raw point size: its UI is laid out for
        // roughly 720p or more, and a smaller screen pushes dialogs off-screen. The layer is scaled to the display by the compositor.
        const char *hs = getenv("ZOMIOS_HEIGHT"); float targetH = hs ? (float)atof(hs) : 720.0f;
        if (targetH < 360 || targetH > 2160) targetH = 720;
        g_ptrScale = targetH / (float)b.size.height;
        int lw = (int)lroundf(b.size.width * g_ptrScale), lh = (int)lroundf(targetH);
        float sa = sim_aspect();
        if (sa > 0) {
            // Simulated aspect: the view gets the logical size as its bounds (so touches, controls and the drawable are all in game pixels,
            // scale 1) and is then stretched over the screen with a transform.
            lw = (int)lroundf(targetH * sa); g_ptrScale = 1.0f;
            v.autoresizingMask = UIViewAutoresizingNone;
            v.bounds = CGRectMake(0, 0, lw, lh); v.center = CGPointMake(b.size.width / 2, b.size.height / 2);
            v.transform = CGAffineTransformMakeScale(b.size.width / lw, b.size.height / lh);
            glfwi_log("simulated aspect %.3f: logical %dx%d stretched over %.0fx%.0f pt", sa, lw, lh, b.size.width, b.size.height);
        }
        w->scale = 1.0f;
        // MetalANGLE sizes the drawable as bounds * contentsScale, so make the scale equal the logical/point ratio; otherwise the
        // drawable is the full native size and the game's logical-size image lands in its bottom-left corner.
        v.contentScaleFactor = g_ptrScale;
        ml.contentsScale = g_ptrScale;
        ml.drawableSize = CGSizeMake(lw, lh);
        ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
        frame_rate_hint_start();
        ml.opaque = YES;
        UIView *root = uw.rootViewController.view ?: uw;
        [root addSubview:v];
        [v installControls]; if (GCMouse.mice.count > 0) [v setMouseConnected:YES];
        [v becomeFirstResponder];
        w->view = (void *)CFBridgingRetain(v);
        w->layer = (__bridge void *)ml;
        w->width = lw; w->height = lh;
        w->fbWidth = lw; w->fbHeight = lh;
        UIApplication.sharedApplication.idleTimerDisabled = YES;
    });
    if (!ok) { set_error(0x10008, "no UIWindow available"); free(w); return NULL; }

    if (!g_dpy) {
        g_dpy = egl.GetDisplay(NULL);
        EGLint maj, min;
        if (!egl.Initialize(g_dpy, &maj, &min)) { set_error(0x10008, "eglInitialize failed"); return NULL; }
        egl.BindAPI(EGL_OPENGL_ES_API);
        EGLint cfgAttr[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                            EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8, EGL_NONE};
        EGLint n = 0;
        if (!egl.ChooseConfig(g_dpy, cfgAttr, &g_cfg, 1, &n) || n < 1) {
            cfgAttr[1] = EGL_OPENGL_ES2_BIT; cfgAttr[13] = 16;
            if (!egl.ChooseConfig(g_dpy, cfgAttr, &g_cfg, 1, &n) || n < 1) { set_error(0x10008, "eglChooseConfig failed"); return NULL; }
        }
        EGLint ctxAttr[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        g_ctx = egl.CreateContext(g_dpy, g_cfg, EGL_NO_CONTEXT, ctxAttr);
        if (!g_ctx) { ctxAttr[1] = 2; g_ctx = egl.CreateContext(g_dpy, g_cfg, EGL_NO_CONTEXT, ctxAttr); }
        if (!g_ctx) { set_error(0x10008, "eglCreateContext failed"); return NULL; }
    }
    w->surface = egl.CreateWindowSurface(g_dpy, g_cfg, w->layer, NULL);
    if (!w->surface) { glfwi_log("eglCreateWindowSurface failed: 0x%x", egl.GetError()); set_error(0x10008, "eglCreateWindowSurface failed"); return NULL; }

    g_window = w;
    glfwi_log("window created: logical %dx%d (pointer scale %.3f)", w->width, w->height, g_ptrScale);
    return w;
}
GLFW_API void glfwDestroyWindow(GLFWwindow *w) { if (w == g_window) g_window = NULL; if (w == g_current) g_current = NULL; }
GLFW_API int glfwWindowShouldClose(GLFWwindow *w) { return w ? w->shouldClose : 1; }
GLFW_API void glfwSetWindowShouldClose(GLFWwindow *w, int v) { if (w) w->shouldClose = v; }
GLFW_API const char *glfwGetWindowTitle(GLFWwindow *w) { return w ? w->title : ""; }
GLFW_API void glfwSetWindowTitle(GLFWwindow *w, const char *t) { if (w) { free(w->title); w->title = strdup(t ? t : ""); } }
GLFW_API void glfwSetWindowIcon(GLFWwindow *w, int count, const GLFWimage *images) {}
GLFW_API void glfwGetWindowPos(GLFWwindow *w, int *x, int *y) { if (x) *x = 0; if (y) *y = 0; }
GLFW_API void glfwSetWindowPos(GLFWwindow *w, int x, int y) {}
GLFW_API void glfwGetWindowSize(GLFWwindow *w, int *x, int *y) { if (x) *x = w->width; if (y) *y = w->height; }
GLFW_API void glfwSetWindowSizeLimits(GLFWwindow *w, int a, int b, int c, int d) {}
GLFW_API void glfwSetWindowAspectRatio(GLFWwindow *w, int n, int d) {}
GLFW_API void glfwSetWindowSize(GLFWwindow *w, int x, int y) {}
GLFW_API void glfwGetFramebufferSize(GLFWwindow *w, int *x, int *y) { if (x) *x = w->fbWidth; if (y) *y = w->fbHeight; }
GLFW_API void glfwGetWindowFrameSize(GLFWwindow *w, int *l, int *t, int *r, int *b) { if (l) *l = 0; if (t) *t = 0; if (r) *r = 0; if (b) *b = 0; }
GLFW_API void glfwGetWindowContentScale(GLFWwindow *w, float *x, float *y) { if (x) *x = w->scale; if (y) *y = w->scale; }
GLFW_API float glfwGetWindowOpacity(GLFWwindow *w) { return 1.0f; }
GLFW_API void glfwSetWindowOpacity(GLFWwindow *w, float o) {}
GLFW_API void glfwIconifyWindow(GLFWwindow *w) {}
GLFW_API void glfwRestoreWindow(GLFWwindow *w) {}
GLFW_API void glfwMaximizeWindow(GLFWwindow *w) {}
GLFW_API void glfwShowWindow(GLFWwindow *w) {}
GLFW_API void glfwHideWindow(GLFWwindow *w) {}
GLFW_API void glfwFocusWindow(GLFWwindow *w) {}
GLFW_API void glfwRequestWindowAttention(GLFWwindow *w) {}
GLFW_API GLFWmonitor *glfwGetWindowMonitor(GLFWwindow *w) { return (GLFWmonitor *)0x1; }
GLFW_API void glfwSetWindowMonitor(GLFWwindow *w, GLFWmonitor *m, int x, int y, int ww, int h, int r) {}
GLFW_API int glfwGetWindowAttrib(GLFWwindow *w, int attrib) {
    switch (attrib) {
        case GLFW_FOCUSED: case GLFW_VISIBLE: case GLFW_HOVERED: case GLFW_FOCUS_ON_SHOW: return 1;
        case GLFW_ICONIFIED: case GLFW_RESIZABLE: case GLFW_DECORATED: case GLFW_FLOATING: case GLFW_MAXIMIZED:
        case GLFW_OPENGL_FORWARD_COMPAT: return 0;
        case GLFW_AUTO_ICONIFY: return 1;
        case GLFW_CLIENT_API: return GLFW_OPENGL_API;
        case GLFW_CONTEXT_VERSION_MAJOR: return hint_value(attrib, 2);
        case GLFW_CONTEXT_VERSION_MINOR: return hint_value(attrib, 1);
        case GLFW_CONTEXT_REVISION: return 0;
        case GLFW_OPENGL_PROFILE: return GLFW_OPENGL_ANY_PROFILE;
    }
    return 0;
}
GLFW_API void glfwSetWindowAttrib(GLFWwindow *w, int a, int v) {}
GLFW_API void glfwSetWindowUserPointer(GLFWwindow *w, void *p) { if (w) w->userPtr = p; }
GLFW_API void *glfwGetWindowUserPointer(GLFWwindow *w) { return w ? w->userPtr : NULL; }

#define SETCB(name, type, field) GLFW_API type name(GLFWwindow *w, type cb) { if (!w) return NULL; type o = w->field; w->field = cb; return o; }
SETCB(glfwSetWindowPosCallback, posfun, posCb)
SETCB(glfwSetWindowSizeCallback, sizefun, sizeCb)
SETCB(glfwSetWindowCloseCallback, closefun, closeCb)
SETCB(glfwSetWindowFocusCallback, focusfun, focusCb)
SETCB(glfwSetFramebufferSizeCallback, sizefun, fbCb)
SETCB(glfwSetKeyCallback, keyfun, keyCb)
SETCB(glfwSetCharCallback, charfun, charCb)
SETCB(glfwSetMouseButtonCallback, mbfun, mbCb)
SETCB(glfwSetCursorPosCallback, cursorposfun, cursorCb)
SETCB(glfwSetScrollCallback, scrollfun, scrollCb)
#define NOPCB(name) GLFW_API void *name(GLFWwindow *w, void *cb) { return NULL; }
NOPCB(glfwSetWindowIconifyCallback) NOPCB(glfwSetWindowMaximizeCallback) NOPCB(glfwSetWindowRefreshCallback)
NOPCB(glfwSetWindowContentScaleCallback) NOPCB(glfwSetCharModsCallback) NOPCB(glfwSetDropCallback)
NOPCB(glfwSetCursorEnterCallback) NOPCB(glfwSetPreeditCallback) NOPCB(glfwSetIMEStatusCallback)
NOPCB(glfwSetPreeditCandidateCallback)

// ---------------------------------------------------------------- events ---
GLFW_API void glfwPollEvents(void) {
    for (;;) {
        Ev e; int have = 0;
        pthread_mutex_lock(&g_evMutex);
        if (g_evHead != g_evTail) { e = g_ev[g_evHead]; g_evHead = (g_evHead + 1) % 4096; have = 1; }
        pthread_mutex_unlock(&g_evMutex);
        if (!have) break;
        if (e.type == EV_JOY) { if (g_joyCb) g_joyCb(e.a, e.b); continue; }
        GLFWwindow *w = g_window; if (!w) continue;
        switch (e.type) {
            case EV_KEY:
                if (e.a >= 0 && e.a < 512) w->keys[e.a] = e.c != GLFW_RELEASE;
                if (w->keyCb) w->keyCb(w, e.a, e.b, e.c, e.d); break;
            case EV_CHAR: if (w->charCb) w->charCb(w, (unsigned)e.a); break;
            case EV_MOUSEBTN:
                if (e.a >= 0 && e.a < 8) w->mouse[e.a] = e.b == GLFW_PRESS;
                if (w->mbCb) w->mbCb(w, e.a, e.b, e.c); break;
            case EV_CURSOR:
                w->cursorX = e.x; w->cursorY = e.y;
                if (w->cursorCb) w->cursorCb(w, e.x, e.y); break;
            case EV_SCROLL: if (w->scrollCb) w->scrollCb(w, e.x, e.y); break;
            default: break;
        }
    }
}
GLFW_API void glfwWaitEvents(void) { usleep(2000); glfwPollEvents(); }
GLFW_API void glfwWaitEventsTimeout(double t) { usleep((useconds_t)(MIN(t, 0.01) * 1e6)); glfwPollEvents(); }
GLFW_API void glfwPostEmptyEvent(void) {}

// ---------------------------------------------------------------- input ---
GLFW_API int glfwGetInputMode(GLFWwindow *w, int mode) { return (w && mode >= 0x33001 && mode <= 0x33008) ? w->inputMode[mode - 0x33001] : 0; }
GLFW_API void glfwSetInputMode(GLFWwindow *w, int mode, int value) { if (w && mode >= 0x33001 && mode <= 0x33008) w->inputMode[mode - 0x33001] = value; }
GLFW_API int glfwRawMouseMotionSupported(void) { return 0; }
GLFW_API const char *glfwGetKeyName(int key, int scancode) { return NULL; }
GLFW_API int glfwGetKeyScancode(int key) { return key; }
GLFW_API int glfwGetKey(GLFWwindow *w, int key) { return (w && key >= 0 && key < 512) ? w->keys[key] : 0; }
GLFW_API int glfwGetMouseButton(GLFWwindow *w, int b) { return (w && b >= 0 && b < 8) ? w->mouse[b] : 0; }
GLFW_API void glfwGetCursorPos(GLFWwindow *w, double *x, double *y) { if (x) *x = w ? w->cursorX : 0; if (y) *y = w ? w->cursorY : 0; }
GLFW_API void glfwSetCursorPos(GLFWwindow *w, double x, double y) { if (w) { w->cursorX = x; w->cursorY = y; } }
GLFW_API GLFWcursor *glfwCreateCursor(const GLFWimage *i, int x, int y) { return (GLFWcursor *)0x1; }
GLFW_API GLFWcursor *glfwCreateStandardCursor(int shape) { return (GLFWcursor *)0x1; }
GLFW_API void glfwDestroyCursor(GLFWcursor *c) {}
GLFW_API void glfwSetCursor(GLFWwindow *w, GLFWcursor *c) {}
GLFW_API void glfwSetClipboardString(GLFWwindow *w, const char *s) {
    NSString *str = s ? [NSString stringWithUTF8String:s] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{ UIPasteboard.generalPasteboard.string = str; });
}
GLFW_API const char *glfwGetClipboardString(GLFWwindow *w) {
    static char *buf; __block NSString *s = nil;
    run_on_main(^{ s = UIPasteboard.generalPasteboard.string; });
    free(buf); buf = strdup(s ? s.UTF8String : ""); return buf;
}
GLFW_API void glfwGetPreeditCursorRectangle(GLFWwindow *w, int *x, int *y, int *ww, int *h) { if (x) *x = 0; if (y) *y = 0; if (ww) *ww = 0; if (h) *h = 0; }
GLFW_API void glfwSetPreeditCursorRectangle(GLFWwindow *w, int x, int y, int ww, int h) {}
GLFW_API void glfwResetPreeditText(GLFWwindow *w) {}
GLFW_API unsigned int glfwGetPreeditCandidate(GLFWwindow *w, int i, int *a, int *b) { return 0; }

// ---------------------------------------------------------------- physical mouse (GameController framework) ---
// GCMouse reports relative motion, buttons and scroll. The system pointer is captured by the host view controller, so the view's
// own cursor (the same one touch "pad" mode draws) follows the deltas and the buttons become GLFW mouse buttons 0/1/2/3+.
static GLFWiOSView *mouse_view(void) { GLFWwindow *w = g_window; return w ? (__bridge GLFWiOSView *)w->view : nil; }
static BOOL kbm_connected(void) { return [GCKeyboard coalescedKeyboard] != nil && GCMouse.mice.count > 0; }
static void kbm_refresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ GLFWiOSView *v = mouse_view(); [v updateControlVisibility]; glfwi_log("keyboard+mouse %s: on-screen controls %s", kbm_connected() ? "connected" : "not both connected", kbm_connected() ? "hidden" : "shown (unless a controller is)"); });
}
static float g_mouseSens = 1.0f;
static void mouse_connected(GCMouse *m) {
    GCMouseInput *in = m.mouseInput; if (!in) return;
    glfwi_log("mouse connected: \"%s\"", (m.vendorName ?: @"(unnamed)").UTF8String);
    in.mouseMovedHandler = ^(GCMouseInput *i, float dx, float dy) {
        float sx = dx * g_mouseSens, sy = -dy * g_mouseSens;       // GameController reports +y as up
        dispatch_async(dispatch_get_main_queue(), ^{ [mouse_view() mouseDelta:CGPointMake(sx, sy)]; });
    };
    void (^bind)(GCControllerButtonInput *, int) = ^(GCControllerButtonInput *b, int code) {
        if (!b) return;
        b.pressedChangedHandler = ^(GCControllerButtonInput *bb, float v, BOOL pressed) { push_mouse(code, pressed ? GLFW_PRESS : GLFW_RELEASE); };
    };
    bind(in.leftButton, 0); bind(in.rightButton, 1); bind(in.middleButton, 2);
    NSArray<GCControllerButtonInput *> *aux = in.auxiliaryButtons;
    for (NSUInteger i = 0; i < aux.count && i < 5; i++) bind(aux[i], 3 + (int)i);
    in.scroll.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        if (y == 0 && x == 0) return;
        Ev e = {.type = EV_SCROLL, .x = x, .y = y}; push_event(e);
    };
    dispatch_async(dispatch_get_main_queue(), ^{ [mouse_view() setMouseConnected:YES]; });
}
static void mouse_disconnected(GCMouse *m) {
    glfwi_log("mouse disconnected");
    dispatch_async(dispatch_get_main_queue(), ^{ if (GCMouse.mice.count == 0) [mouse_view() setMouseConnected:NO]; });
}
static void mouse_init(void) {
    static int done; if (done) return; done = 1;
    const char *e = getenv("ZOMIOS_MOUSE_SENS"); if (e && atof(e) > 0) g_mouseSens = (float)atof(e);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { mouse_connected(n.object); kbm_refresh(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { mouse_disconnected(n.object); kbm_refresh(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { kbm_refresh(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { kbm_refresh(); }];
        for (GCMouse *m in GCMouse.mice) mouse_connected(m);
    });
}

// ---- DualSense / DualShock 4 touchpad as a mouse: finger slide moves the cursor, tap or press = left click, press with two fingers = right click.
// The pad reports absolute -1..1 positions and (0,0) when no finger is down, so motion is the difference between consecutive samples.
static float g_padSens = 500.0f;                  // view points per full pad width unit
static int g_padDown, g_padClicked; static float g_padLastX, g_padLastY, g_padStartX, g_padStartY, g_padTravel; static CFTimeInterval g_padStartT; static int g_padSecond;
static void touchpad_click(int button, double hold) {
    push_mouse(button, GLFW_PRESS);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ push_mouse(button, GLFW_RELEASE); });
}
static void touchpad_bind(GCController *c) {
    GCControllerDirectionPad *prim = nil, *sec = nil; GCControllerButtonInput *btn = nil;
    GCExtendedGamepad *g = c.extendedGamepad;
    if ([g isKindOfClass:GCDualSenseGamepad.class]) { GCDualSenseGamepad *d = (GCDualSenseGamepad *)g; prim = d.touchpadPrimary; sec = d.touchpadSecondary; btn = d.touchpadButton; }
    else if ([g isKindOfClass:GCDualShockGamepad.class]) { GCDualShockGamepad *d = (GCDualShockGamepad *)g; prim = d.touchpadPrimary; sec = d.touchpadSecondary; btn = d.touchpadButton; }
    if (!prim) return;
    const char *e = getenv("ZOMIOS_TOUCHPAD_SENS"); if (e && atof(e) > 0) g_padSens = (float)atof(e);
    glfwi_log("touchpad mouse enabled for \"%s\"", (c.vendorName ?: @"(unnamed)").UTF8String);
    prim.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
        BOOL touching = x != 0 || y != 0;
        if (!touching) {
            if (g_padDown) {
                g_padDown = 0;
                if (!g_padClicked && CACurrentMediaTime() - g_padStartT < 0.25 && g_padTravel < 0.08) touchpad_click(0, 0.06);    // tap
            }
            return;
        }
        if (!g_padDown) { g_padDown = 1; g_padClicked = 0; g_padLastX = g_padStartX = x; g_padLastY = g_padStartY = y; g_padStartT = CACurrentMediaTime(); g_padTravel = 0; dispatch_async(dispatch_get_main_queue(), ^{ [mouse_view() setMouseConnected:YES]; }); return; }
        float dx = (x - g_padLastX) * g_padSens, dy = -(y - g_padLastY) * g_padSens;
        g_padTravel += fabsf(x - g_padLastX) + fabsf(y - g_padLastY); g_padLastX = x; g_padLastY = y;
        dispatch_async(dispatch_get_main_queue(), ^{ [mouse_view() mouseDelta:CGPointMake(dx, dy)]; });
    };
    if (sec) sec.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) { g_padSecond = x != 0 || y != 0; };
    if (btn) btn.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { if (pressed) g_padClicked = 1; push_mouse(g_padSecond ? 1 : 0, pressed ? GLFW_PRESS : GLFW_RELEASE); };
}

// ---------------------------------------------------------------- joysticks / gamepads (GameController framework) ---
// Any extended gamepad (Xbox, PlayStation, MFi...) is exposed both as a standard GLFW gamepad and as a raw joystick with
// 6 axes (LX, LY, RX, RY, LT, RT), 15 buttons and one hat (the d-pad), using GLFW's standard gamepad ordering.
#define GLFW_JOYSTICK_LAST 15
static NSMutableArray *g_pads;                 // slot -> GCController or NSNull
static pthread_mutex_t g_padMutex = PTHREAD_MUTEX_INITIALIZER;
static int g_padsReady;

static int pad_slot_of(GCController *c) { for (NSUInteger i = 0; i < g_pads.count; i++) if (g_pads[i] == c) return (int)i; return -1; }
static BOOL pad_any_connected(void) {
    BOOL any = NO;
    pthread_mutex_lock(&g_padMutex);
    for (NSUInteger i = 0; i < g_pads.count; i++) if (g_pads[i] != (id)NSNull.null) { any = YES; break; }
    pthread_mutex_unlock(&g_padMutex);
    return any;
}
static void pad_connected(GCController *c) {
    pthread_mutex_lock(&g_padMutex);
    int slot = pad_slot_of(c);
    if (slot < 0) {
        NSUInteger first = vpad_active() ? 1 : 0;              // slot 0 is the virtual gamepad while it is on
        for (NSUInteger i = first; i <= GLFW_JOYSTICK_LAST; i++)
            if (g_pads[i] == (id)NSNull.null) { g_pads[i] = c; slot = (int)i; break; }
    }
    pthread_mutex_unlock(&g_padMutex);
    if (slot < 0) return;
    touchpad_bind(c);
    dispatch_async(dispatch_get_main_queue(), ^{ [mouse_view() setPadConnected:pad_any_connected()]; });
    glfwi_log("controller connected: slot %d \"%s\" extendedGamepad=%d", slot, (c.vendorName ?: @"(unnamed)").UTF8String, c.extendedGamepad != nil);
    Ev e = {.type = EV_JOY, .a = slot, .b = 0x00040001 /* GLFW_CONNECTED */}; push_event(e);
}
static void pad_disconnected(GCController *c) {
    pthread_mutex_lock(&g_padMutex);
    int slot = pad_slot_of(c); if (slot >= 0) g_pads[slot] = NSNull.null;
    pthread_mutex_unlock(&g_padMutex);
    if (slot < 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [mouse_view() setPadConnected:pad_any_connected()]; });
    glfwi_log("controller disconnected: slot %d", slot);
    Ev e = {.type = EV_JOY, .a = slot, .b = 0x00040002 /* GLFW_DISCONNECTED */}; push_event(e);
}
static void pads_init(void) {
    if (g_padsReady) return; g_padsReady = 1;
    pad_config_load();          // read the launcher's mapping on the main thread, before the render thread reads pad state
    vpad_init();
    g_pads = [NSMutableArray array]; for (int i = 0; i <= GLFW_JOYSTICK_LAST; i++) [g_pads addObject:NSNull.null];
    for (GCController *c in GCController.controllers) pad_connected(c);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { pad_connected(n.object); }];
        [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { pad_disconnected(n.object); }];
        for (GCController *c in GCController.controllers) pad_connected(c);        // picks up anything that appeared meanwhile
    });
}
static GCController *pad_for(int jid) {
    if (jid < 0 || jid > GLFW_JOYSTICK_LAST || !g_pads) return nil;
    pthread_mutex_lock(&g_padMutex); id c = g_pads[jid]; pthread_mutex_unlock(&g_padMutex);
    return c == (id)NSNull.null ? nil : c;
}
// ---------------------------------------------------------------- controller configuration ---

// The launcher's Settings > Controls > Controller screen (HostApp/Sources/ControllerSettings.swift) hands its choices over at
// launch as JSON in ZOMIOS_PAD_CONFIG, the same way the other settings travel:
//   {"overlay":true,"deadzone":0.15,"buttons":[15 physical indices],"axes":[6 physical indices]}
// Physical button indices use GLFW's order (0 A ... 14 d-pad left) plus 15 and 16 for the two triggers, so a face button can
// be told to act as LT or RT. Physical axis indices are GLFW's (0 LX, 1 LY, 2 RX, 3 RY, 4 LT, 5 RT). Anything missing or out
// of range falls back to the standard mapping, and no variable at all means stock behaviour.
typedef struct { int overlay; float deadzone; int buttons[15]; int axes[6]; } ZOPadConfig;
static ZOPadConfig g_padCfg = { 1, 0.0f,
    { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 },
    { 0, 1, 2, 3, 4, 5 } };
static int g_padCfgLoaded;

static void pad_config_load(void) {
    if (g_padCfgLoaded) return;
    g_padCfgLoaded = 1;
    const char *json = getenv("ZOMIOS_PAD_CONFIG");
    if (!json || !*json) return;
    NSData *d = [NSData dataWithBytes:json length:strlen(json)];
    NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![o isKindOfClass:NSDictionary.class]) { glfwi_log("controller: ignoring an unreadable ZOMIOS_PAD_CONFIG"); return; }
    if ([o[@"overlay"] isKindOfClass:NSNumber.class]) g_padCfg.overlay = [o[@"overlay"] boolValue] ? 1 : 0;
    if ([o[@"deadzone"] isKindOfClass:NSNumber.class]) g_padCfg.deadzone = MAX(0.0f, MIN(0.95f, [o[@"deadzone"] floatValue]));
    NSArray *b = o[@"buttons"], *a = o[@"axes"];
    if ([b isKindOfClass:NSArray.class]) for (NSUInteger i = 0; i < 15 && i < b.count; i++) { int v = [b[i] intValue]; if (v >= 0 && v <= 16) g_padCfg.buttons[i] = v; }
    if ([a isKindOfClass:NSArray.class]) for (NSUInteger i = 0; i < 6 && i < a.count; i++) { int v = [a[i] intValue]; if (v >= 0 && v <= 5) g_padCfg.axes[i] = v; }
    glfwi_log("controller: remap loaded (deadzone %.2f, on-screen controls %s while a pad is connected)",
              g_padCfg.deadzone, g_padCfg.overlay ? "hidden" : "kept");
}

// Whether the on-screen controls should disappear while a controller is connected. On unless the player turned it off, which
// suits holding the controller in one hand and using the touch buttons with the other.
static int pad_overlay_hides(void) { pad_config_load(); return g_padCfg.overlay; }

// Radial deadzone with a rescale, so a stick still leaves 0 smoothly and reaches full deflection at the edge instead of jumping
// from nothing to the deadzone value.
static void pad_deadzone(float *x, float *y, float dz) {
    if (dz <= 0) return;
    float m = hypotf(*x, *y);
    if (m <= dz) { *x = 0; *y = 0; return; }
    float k = (m - dz) / (1.0f - dz) / m;
    *x *= k; *y *= k;
}

static void pad_read(GCController *c, unsigned char buttons[15], float axes[6]) {
    memset(buttons, 0, 15); for (int i = 0; i < 6; i++) axes[i] = 0;
    axes[4] = axes[5] = -1.0f;                                                    // triggers rest at -1 in GLFW
    GCExtendedGamepad *g = c.extendedGamepad; if (!g) return;
    pad_config_load();
    unsigned char phys[17]; float pax[6];
    phys[0] = g.buttonA.pressed; phys[1] = g.buttonB.pressed; phys[2] = g.buttonX.pressed; phys[3] = g.buttonY.pressed;
    phys[4] = g.leftShoulder.pressed; phys[5] = g.rightShoulder.pressed;
    phys[6] = g.buttonOptions ? g.buttonOptions.pressed : 0;                      // BACK
    phys[7] = g.buttonMenu.pressed;                                               // START
    phys[8] = g.buttonHome ? g.buttonHome.pressed : 0;                            // GUIDE
    phys[9] = g.leftThumbstickButton ? g.leftThumbstickButton.pressed : 0; phys[10] = g.rightThumbstickButton ? g.rightThumbstickButton.pressed : 0;
    phys[11] = g.dpad.up.pressed; phys[12] = g.dpad.right.pressed; phys[13] = g.dpad.down.pressed; phys[14] = g.dpad.left.pressed;
    phys[15] = g.leftTrigger.value > 0.5f; phys[16] = g.rightTrigger.value > 0.5f;  // the triggers as buttons
    pax[0] = g.leftThumbstick.xAxis.value; pax[1] = -g.leftThumbstick.yAxis.value;   // GLFW: +Y is down
    pax[2] = g.rightThumbstick.xAxis.value; pax[3] = -g.rightThumbstick.yAxis.value;
    pad_deadzone(&pax[0], &pax[1], g_padCfg.deadzone);
    pad_deadzone(&pax[2], &pax[3], g_padCfg.deadzone);
    pax[4] = g.leftTrigger.value * 2.0f - 1.0f; pax[5] = g.rightTrigger.value * 2.0f - 1.0f;
    for (int i = 0; i < 15; i++) buttons[i] = phys[g_padCfg.buttons[i]];
    for (int i = 0; i < 6; i++) axes[i] = MAX(-1.0f, MIN(1.0f, pax[g_padCfg.axes[i]]));
}
static unsigned char g_padButtons[GLFW_JOYSTICK_LAST + 1][15]; static float g_padAxes[GLFW_JOYSTICK_LAST + 1][6]; static unsigned char g_padHat[GLFW_JOYSTICK_LAST + 1][1];
static char g_padGuid[GLFW_JOYSTICK_LAST + 1][33]; static char g_padName[GLFW_JOYSTICK_LAST + 1][128];

GLFW_API int glfwJoystickPresent(int j) { if (j == VPAD_SLOT) return vpad_active(); return pad_for(j) != nil; }
GLFW_API const float *glfwGetJoystickAxes(int j, int *c) {
    if (j == VPAD_SLOT) { if (c) *c = vpad_active() ? 6 : 0; return vpad_active() ? g_vpadAxes : NULL; }
    GCController *p = pad_for(j); if (!p) { if (c) *c = 0; return NULL; }
    unsigned char b[15]; pad_read(p, b, g_padAxes[j]); if (c) *c = 6; return g_padAxes[j];
}
GLFW_API const unsigned char *glfwGetJoystickButtons(int j, int *c) {
    if (j == VPAD_SLOT) { if (c) *c = vpad_active() ? 15 : 0; return vpad_active() ? g_vpadButtons : NULL; }
    GCController *p = pad_for(j); if (!p) { if (c) *c = 0; return NULL; }
    float a[6]; pad_read(p, g_padButtons[j], a); if (c) *c = 15; return g_padButtons[j];
}
GLFW_API const unsigned char *glfwGetJoystickHats(int j, int *c) {
    if (j == VPAD_SLOT) {
        static unsigned char hat[1];
        hat[0] = (unsigned char)((g_vpadButtons[11] ? 1 : 0) | (g_vpadButtons[12] ? 2 : 0) | (g_vpadButtons[13] ? 4 : 0) | (g_vpadButtons[14] ? 8 : 0));
        if (c) *c = vpad_active() ? 1 : 0; return vpad_active() ? hat : NULL;
    }
    GCController *p = pad_for(j); if (!p) { if (c) *c = 0; return NULL; }
    unsigned char b[15]; float a[6]; pad_read(p, b, a);
    g_padHat[j][0] = (b[11] ? 1 : 0) | (b[12] ? 2 : 0) | (b[13] ? 4 : 0) | (b[14] ? 8 : 0);   // UP RIGHT DOWN LEFT
    if (c) *c = 1; return g_padHat[j];
}
GLFW_API const char *glfwGetJoystickName(int j) {
    if (j == VPAD_SLOT) return vpad_active() ? "pziOS Virtual Gamepad" : NULL;
    GCController *p = pad_for(j); if (!p) return NULL;
    strlcpy(g_padName[j], (p.vendorName ?: @"Game Controller").UTF8String, sizeof g_padName[j]); return g_padName[j];
}
GLFW_API const char *glfwGetJoystickGUID(int j) {
    if (j == VPAD_SLOT) return vpad_active() ? "0300005e000000000000000000000000" : NULL;
    GCController *p = pad_for(j); if (!p) return NULL;
    NSUInteger h = [(p.vendorName ?: @"Game Controller") hash];
    snprintf(g_padGuid[j], sizeof g_padGuid[j], "030000%02x%08lx0000%04x0000000000", 0x5e, (unsigned long)h & 0xffffffffUL, (unsigned)(j & 0xffff));
    g_padGuid[j][32] = 0; return g_padGuid[j];
}
GLFW_API void glfwSetJoystickUserPointer(int j, void *p) {}
GLFW_API void *glfwGetJoystickUserPointer(int j) { return NULL; }
GLFW_API int glfwJoystickIsGamepad(int j) { if (j == VPAD_SLOT) return vpad_active(); GCController *p = pad_for(j); return p && p.extendedGamepad != nil; }
GLFW_API int glfwUpdateGamepadMappings(const char *s) { return 1; }
GLFW_API const char *glfwGetGamepadName(int j) { return glfwJoystickIsGamepad(j) ? glfwGetJoystickName(j) : NULL; }
GLFW_API int glfwGetGamepadState(int j, GLFWgamepadstate *st) {
    if (j == VPAD_SLOT) {
        if (!vpad_active()) return 0;
        memcpy(st->buttons, g_vpadButtons, 15);
        memcpy(st->axes, g_vpadAxes, sizeof g_vpadAxes);
        return 1;
    }
    GCController *p = pad_for(j); if (!p || !p.extendedGamepad) return 0;
    pad_read(p, st->buttons, st->axes);
    if (input_log_enabled()) { static int n; static unsigned char last[15]; if (memcmp(last, st->buttons, 15) != 0 && n++ < 40) { memcpy(last, st->buttons, 15); glfwi_log("gamepad %d buttons changed: A%d B%d X%d Y%d LB%d RB%d start%d | LX=%.2f LY=%.2f", j, st->buttons[0], st->buttons[1], st->buttons[2], st->buttons[3], st->buttons[4], st->buttons[5], st->buttons[7], st->axes[0], st->axes[1]); } }
    return 1;
}
GLFW_API joystickfun glfwSetJoystickCallback(joystickfun cb) { pads_init(); joystickfun o = g_joyCb; g_joyCb = cb; if (cb && vpad_active()) { Ev e = {.type = EV_JOY, .a = VPAD_SLOT, .b = 0x00040001 /* GLFW_CONNECTED */}; push_event(e); } return o; }

// ---------------------------------------------------------------- time ---
GLFW_API double glfwGetTime(void) { return (double)(mach_absolute_time() - g_t0) * g_tb.numer / g_tb.denom / 1e9; }
GLFW_API void glfwSetTime(double t) { g_t0 = mach_absolute_time() - (uint64_t)(t * 1e9 * g_tb.denom / g_tb.numer); }
GLFW_API uint64_t glfwGetTimerValue(void) { return mach_absolute_time(); }
GLFW_API uint64_t glfwGetTimerFrequency(void) { return (uint64_t)(1e9 * g_tb.denom / g_tb.numer); }

static void prime_gl4es(void);
static void log_gl4es_images(const char *when) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && (strstr(n, "gl4es") || strstr(n, "libglfw"))) glfwi_log("[%s] image %u: %p %s", when, i, _dyld_get_image_header(i), n);
    }
}
// ---------------------------------------------------------------- context ---
static pthread_t g_owner; static int g_hasOwner;
static void thread_label(char *out, size_t n) { char nm[64] = ""; pthread_getname_np(pthread_self(), nm, sizeof nm); snprintf(out, n, "%p/%s", (void *)pthread_self(), nm); }

GLFW_API void glfwMakeContextCurrent(GLFWwindow *w) {
    char me[96]; thread_label(me, sizeof me);
    if (!w) {
        if (egl.MakeCurrent) egl.MakeCurrent(g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_hasOwner && pthread_equal(g_owner, pthread_self())) g_hasOwner = 0;
        if (g_current) glfwi_log("context released by %s", me);
        g_current = NULL;
        return;
    }
    // GLFW contexts live on one thread at a time; the game hands it over (release on A, make current on B), possibly racing.
    int ok = 0; EGLint err = 0;
    for (int i = 0; i < 300; i++) {
        EGLContext curC = egl.GetCurrentContext(); EGLSurface curS = egl.GetCurrentSurface(0x3059); EGLDisplay curD = egl.GetCurrentDisplay();
        if (egl.MakeCurrent(g_dpy, w->surface, w->surface, g_ctx)) { ok = 1; break; }
        err = egl.GetError();
        if (i == 0) {
            EGLint maj = 0, min = 0; EGLBoolean reinit = egl.Initialize(g_dpy, &maj, &min);
            glfwi_log("eglMakeCurrent failed on %s: 0x%x | cur ctx=%p surf=%p dpy=%p | ours ctx=%p surf=%p dpy=%p | eglInitialize->%u (err 0x%x)",
                      me, err, curC, curS, curD, g_ctx, w->surface, g_dpy, reinit, egl.GetError());
        }
        usleep(10000);
    }
    if (!ok) { glfwi_log("eglMakeCurrent GAVE UP on %s: 0x%x", me, err); return; }
    g_owner = pthread_self(); g_hasOwner = 1;
    // Log the hand-over only when it moves to another thread (plus the first few). Some builds renew the context on every frame, and an
    // unbuffered stderr line per frame is a write() syscall and a log append per frame for nothing.
    {
        static int made; static pthread_t lastOwner;
        if (made < 4 || !pthread_equal(lastOwner, g_owner)) { made++; lastOwner = g_owner; glfwi_log("context made current on %s", me); }
    }
    g_current = w;
    prime_gl4es();
}
GLFW_API GLFWwindow *glfwGetCurrentContext(void) { return g_current; }
static void maybe_screenshot(GLFWwindow *w) {
    static double interval = -1, last = 0; static int count, frames;
    if (interval < 0) { const char *e = getenv("ZOMIOS_AUTOSHOT"); interval = e ? atof(e) : 0; }
    if (interval <= 0 || !w) return;
    if (++frames < 60) return;
    double now = (double)(mach_absolute_time()) * g_tb.numer / g_tb.denom / 1e9;
    if (last == 0) last = now;
    if (now - last < interval) return;
    last = now;
    void *h = gl4es_handle(); if (!h) return;
    void (*readPixels)(int, int, int, int, unsigned, unsigned, void *) = dlsym(h, "glReadPixels");
    void (*bindFB)(unsigned, unsigned) = dlsym(h, "glBindFramebuffer");
    if (!readPixels) return;
    int W = w->fbWidth, H = w->fbHeight;
    unsigned char *px = malloc((size_t)W * H * 4), *flip = malloc((size_t)W * H * 4);
    if (!px || !flip) { free(px); free(flip); return; }
    (void)bindFB;
    readPixels(0, 0, W, H, 0x1908 /* RGBA */, 0x1401 /* UNSIGNED_BYTE */, px);
    for (int y = 0; y < H; y++) memcpy(flip + (size_t)y * W * 4, px + (size_t)(H - 1 - y) * W * 4, (size_t)W * 4);
    for (size_t i = 3; i < (size_t)W * H * 4; i += 4) flip[i] = 255;
    NSString *dir = [NSString stringWithFormat:@"%s/shots", getenv("HOME") ?: "/tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingFormat:@"/shot_%03d.png", ++count];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(flip, W, H, 8, (size_t)W * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (dst && img) { CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst); glfwi_log("screenshot %s (%dx%d)", path.UTF8String, W, H); }
    // also what is actually on the display: snapshot the UIKit window (game layer + pointer + controls)
    NSString *glass = [dir stringByAppendingFormat:@"/glass_%03d.png", count];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *uw = find_key_window(); if (!uw) return;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:uw.bounds.size];
        UIImage *im = [r imageWithActions:^(UIGraphicsImageRendererContext *c) { [uw drawViewHierarchyInRect:uw.bounds afterScreenUpdates:NO]; }];
        [UIImagePNGRepresentation(im) writeToFile:glass atomically:YES];
        UIView *gv = nil; for (UIView *sv in uw.rootViewController.view.subviews) if ([sv isKindOfClass:NSClassFromString(@"GLFWiOSView")]) gv = sv;
        CAMetalLayer *ml = (CAMetalLayer *)gv.layer;
        glfwi_log("glass %s window=%.0fx%.0f view frame=%@ layer bounds=%@ drawable=%.0fx%.0f contentsGravity=%@ contentsScale=%.1f", glass.UTF8String, uw.bounds.size.width, uw.bounds.size.height, NSStringFromCGRect(gv.frame), NSStringFromCGRect(ml.bounds), ml.drawableSize.width, ml.drawableSize.height, ml.contentsGravity, ml.contentsScale);
    });
    if (dst) CFRelease(dst); if (img) CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs); free(px); free(flip);
}
// The render thread is a plain Java thread with no autorelease pool, so the Objective-C objects MetalANGLE and the system frameworks autorelease
// while drawing are never freed. With ZOMIOS_FRAMEPOOL=1 each frame is wrapped in a pool that is drained at the buffer swap.
extern void *objc_autoreleasePoolPush(void); extern void objc_autoreleasePoolPop(void *);
GLFW_API void glfwSwapBuffers(GLFWwindow *w) {
    static int n; static __thread void *pool; static int usePool = -1;
    if (n++ == 0) { log_gl4es_images("first swap"); const char *e = getenv("ZOMIOS_FRAMEPOOL"); usePool = e && atoi(e) > 0; glfwi_log("per-frame autorelease pool %s", usePool ? "on" : "off"); }
    maybe_screenshot(w); if (w) egl.SwapBuffers(g_dpy, w->surface);
    if (g_fpsLabel) fps_note_frame();
    if (usePool > 0) { if (pool) objc_autoreleasePoolPop(pool); pool = objc_autoreleasePoolPush(); }
}
GLFW_API void glfwSwapInterval(int i) { if (egl.SwapInterval) egl.SwapInterval(g_dpy, i); }
GLFW_API int glfwExtensionSupported(const char *e) { return 0; }

// gl4es is loaded by LWJGL from the same directory as this library; find it without relying on @rpath matching.
static void *gl4es_handle(void) {
    if (g_gl4es) return g_gl4es;
    Dl_info info;
    if (dladdr((void *)&glfwInit, &info) && info.dli_fname) {
        char path[1024]; strlcpy(path, info.dli_fname, sizeof path);
        char *slash = strrchr(path, '/');
        if (slash) { strlcpy(slash + 1, "libgl4es_114.dylib", sizeof path - (slash + 1 - path)); g_gl4es = dlopen(path, RTLD_NOW | RTLD_NOLOAD); if (!g_gl4es) g_gl4es = dlopen(path, RTLD_NOW | RTLD_GLOBAL); }
    }
    if (!g_gl4es) glfwi_log("gl4es not found next to libglfw");
    return g_gl4es;
}

GLFW_API void *glfwGetProcAddress(const char *name) {
    void *h = gl4es_handle();
    void *p = h ? dlsym(h, name) : NULL;
    const char *src = "gl4es";
    if (!p && egl.GetProcAddress) { p = egl.GetProcAddress(name); src = "egl"; }
    static int n;
    if (n < 12 || strcmp(name, "glGetString") == 0 || strcmp(name, "glGetError") == 0)
        { n++; glfwi_log("glfwGetProcAddress(%s) = %p [%s]", name, p, p ? src : "none"); }
    return p;
}

// After the first eglMakeCurrent, run gl4es's lazy init (first glGetString) and clear any stale GLES errors,
// otherwise LWJGL's GL.createCapabilities sees a non-zero glGetError and reports "no OpenGL context current".
static void prime_gl4es(void) {
    static int done;
    if (done) return; done = 1;
    void *h = gl4es_handle(); if (!h) return;
    const unsigned char *(*getString)(unsigned) = dlsym(h, "glGetString");
    unsigned (*getError)(void) = dlsym(h, "glGetError");
    if (!getString || !getError) { glfwi_log("gl4es missing glGetString/glGetError"); return; }
    // Replay LWJGL's GL.createCapabilities probe so we can see which step reports an error.
    void (*getIntegerv)(unsigned, int *) = dlsym(h, "glGetIntegerv");
    unsigned e0 = getError();
    int major = -1, minor = -1;
    if (getIntegerv) { getIntegerv(0x821B, &major); }
    unsigned e1 = getError();
    if (getIntegerv && e1 == 0) { getIntegerv(0x821C, &minor); }
    const unsigned char *v = getString(0x1F02);
    unsigned e2 = getError();
    glfwi_log("probe: err0=0x%x major=%d(err1=0x%x) minor=%d version=%s err2=0x%x", e0, major, e1, minor, v ? (const char *)v : "(null)", e2);
    const unsigned char *vend = getString(0x1F00), *rend = getString(0x1F01);
    log_gl4es_images("prime");
    glfwi_log("handle=%p GetString=%p GetError=%p", h, getString, getError);
    glfwi_log("GL_VENDOR=%s GL_RENDERER=%s", vend ? (const char *)vend : "(null)", rend ? (const char *)rend : "(null)");
    for (int i = 0; i < 16; i++) { unsigned e = getError(); if (!e) break; glfwi_log("cleared GL error 0x%x", e); }
}
