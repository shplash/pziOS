// libGLshim: the "OpenGL library" handed to LWJGL (-Dorg.lwjgl.opengl.libname).
//
// 1. LWJGL's GL function provider looks for glXGetProcAddress / eglGetProcAddress / OSMesaGetProcAddress in that
//    library and resolves every GL function through it. gl4es_114 exports none of them, so dlsym fell through to
//    MetalANGLE's eglGetProcAddress and LWJGL called ANGLE's raw GLES entry points. Exporting eglGetProcAddress here,
//    backed by gl4es, makes LWJGL resolve everything inside gl4es.
//
// 2. We also interpose glShaderSource to rewrite the game's GLSL 1.20 into something the (strict) ANGLE ES compiler
//    accepts after gl4es converts it to ES: strip uniform initializers, drop user-defined min/max/clamp that redefine
//    builtins, and make integer literals float where the expression is float-typed.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <math.h>
#import <mach/mach_time.h>
#import <stdint.h>

extern void *gl4es_GetProcAddress(const char *name);

typedef unsigned int GLuint; typedef int GLsizei; typedef int GLint; typedef char GLchar;

static int shader_log_enabled(void) { static int v = -1; if (v < 0) v = getenv("ZOMIOS_SHADER_LOG") != NULL; return v; }

// ---------------------------------------------------------------- GLSL rewriting ---
static NSString *strip_comments(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    NSUInteger n = s.length, i = 0;
    while (i < n) {
        unichar c = [s characterAtIndex:i];
        if (c == '/' && i + 1 < n && [s characterAtIndex:i + 1] == '/') { while (i < n && [s characterAtIndex:i] != '\n') i++; continue; }
        if (c == '/' && i + 1 < n && [s characterAtIndex:i + 1] == '*') {
            i += 2; while (i + 1 < n && !([s characterAtIndex:i] == '*' && [s characterAtIndex:i + 1] == '/')) { if ([s characterAtIndex:i] == '\n') [out appendString:@"\n"]; i++; }
            i += 2; [out appendString:@" "]; continue;
        }
        [out appendFormat:@"%C", c]; i++;
    }
    return out;
}

// uniform T name = expr;   ->   uniform T name;   (the defaults are recorded and applied after linking)
typedef struct { NSString *type, *name; NSArray<NSNumber *> *values; } UniformDefault;
static NSString *strip_uniform_initializers(NSString *s, NSMutableArray<NSDictionary *> *defaults) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?m)^(\\s*uniform\\s+(?:(?:lowp|mediump|highp)\\s+)?(\\w+)\\s+(\\w+))\\s*=\\s*([^;]+);" options:0 error:nil];
    NSRegularExpression *num = [NSRegularExpression regularExpressionWithPattern:@"-?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?" options:0 error:nil];
    for (NSTextCheckingResult *r in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        NSString *type = [s substringWithRange:[r rangeAtIndex:2]], *name = [s substringWithRange:[r rangeAtIndex:3]], *expr = [s substringWithRange:[r rangeAtIndex:4]];
        NSMutableArray *vals = [NSMutableArray array];
        for (NSTextCheckingResult *m in [num matchesInString:expr options:0 range:NSMakeRange(0, expr.length)]) [vals addObject:@([[expr substringWithRange:m.range] doubleValue])];
        if ([expr rangeOfString:@"true"].location != NSNotFound) vals = [@[@1] mutableCopy];
        if ([expr rangeOfString:@"false"].location != NSNotFound) vals = [@[@0] mutableCopy];
        int n = [type hasPrefix:@"vec"] ? [[type substringFromIndex:3] intValue] : [type hasPrefix:@"ivec"] ? [[type substringFromIndex:4] intValue] : 1;
        if (vals.count == 1 && n > 1) { id v = vals[0]; while ((int)vals.count < n) [vals addObject:v]; }
        if ((int)vals.count >= n && n >= 1 && ([type isEqualToString:@"float"] || [type isEqualToString:@"int"] || [type isEqualToString:@"bool"] || [type hasPrefix:@"vec"] || [type hasPrefix:@"ivec"]))
            [defaults addObject:@{@"type": type, @"name": name, @"values": [vals subarrayWithRange:NSMakeRange(0, n)]}];
    }
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"$1;"];
}

static BOOL is_vec_or_float(NSString *t) { return [@[@"float", @"vec2", @"vec3", @"vec4"] containsObject:t]; }

static BOOL signature_is_builtin(NSString *ret, NSString *name, NSString *paramList) {
    NSArray<NSString *> *params = [paramList componentsSeparatedByString:@","];
    NSMutableArray<NSString *> *types = [NSMutableArray array];
    for (NSString *p in params) {
        NSArray *toks = [[p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *ty = toks.count ? toks.firstObject : @"";
        for (NSString *t in toks) if (is_vec_or_float(t)) { ty = t; break; }
        [types addObject:ty];
    }
    if (![name isEqualToString:@"clamp"] && types.count == 2) return [types[0] isEqualToString:ret] && ([types[1] isEqualToString:ret] || [types[1] isEqualToString:@"float"]);
    if ([name isEqualToString:@"clamp"] && types.count == 3) return [types[0] isEqualToString:ret] && (([types[1] isEqualToString:ret] && [types[2] isEqualToString:ret]) || ([types[1] isEqualToString:@"float"] && [types[2] isEqualToString:@"float"]));
    return NO;
}

// Remove user definitions and prototypes such as `float max(float a, float b) { ... }` / `vec3 clamp(vec3 a, float min, float max);`
// whose signature matches a GLSL builtin (illegal to redefine in ES).
static NSString *remove_builtin_redefinitions(NSString *s) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?m)^[ \\t]*(float|vec2|vec3|vec4)\\s+(max|min|clamp)\\s*\\(([^)]*)\\)\\s*([{;])" options:0 error:nil];
    NSMutableString *m = [s mutableCopy];
    for (int guard = 0; guard < 128; guard++) {
        BOOL removed = NO;
        for (NSTextCheckingResult *r in [re matchesInString:m options:0 range:NSMakeRange(0, m.length)]) {
            NSString *ret = [m substringWithRange:[r rangeAtIndex:1]], *name = [m substringWithRange:[r rangeAtIndex:2]];
            if (!signature_is_builtin(ret, name, [m substringWithRange:[r rangeAtIndex:3]])) continue;
            NSUInteger end = NSMaxRange(r.range);
            if ([[m substringWithRange:[r rangeAtIndex:4]] isEqualToString:@"{"]) {
                int depth = 1;
                while (end < m.length && depth > 0) { unichar c = [m characterAtIndex:end++]; if (c == '{') depth++; else if (c == '}') depth--; }
                if (depth != 0) continue;
            }
            [m replaceCharactersInRange:NSMakeRange(r.range.location, end - r.range.location) withString:@"\n"];
            removed = YES; break;
        }
        if (!removed) break;
    }
    return m;
}

static NSArray<NSString *> *regex_names(NSString *s, NSString *pattern, NSUInteger group);

// Integer literal -> float literal in statements that involve no integer-typed names, so `(clip*2)-1` becomes `(clip*2.0)-1.0`.
static NSString *floatify_int_literals(NSString *s) {
    NSMutableSet<NSString *> *intNames = [NSMutableSet set];
    NSRegularExpression *decl = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:int|ivec[234]|bool|bvec[234])\\s+([A-Za-z_]\\w*(?:\\s*,\\s*[A-Za-z_]\\w*)*)" options:0 error:nil];
    for (NSTextCheckingResult *r in [decl matchesInString:s options:0 range:NSMakeRange(0, s.length)])
        for (NSString *n in [[s substringWithRange:[r rangeAtIndex:1]] componentsSeparatedByString:@","]) [intNames addObject:[n stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    for (NSString *n in regex_names(s, @"^[ \\t]*#define[ \\t]+(\\w+)[ \\t]+-?\\d+[ \\t]*$", 1)) [intNames addObject:n];
    NSRegularExpression *ident = [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z_]\\w*" options:0 error:nil];
    NSRegularExpression *lit = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\w.])(?<![eE][+-])(\\d+)(?![\\w.])" options:0 error:nil];

    NSMutableString *out = [NSMutableString string];
    NSUInteger n = s.length, i = 0, start = 0; int paren = 0;
    NSMutableString *chunk = [NSMutableString string];
    (void)start;
    void (^flush)(void) = ^{
        NSString *c = [chunk copy];
        BOOL skip = NO;
        NSSet<NSString *> *intWords = [NSSet setWithObjects:@"int", @"ivec2", @"ivec3", @"ivec4", @"bool", @"bvec2", @"bvec3", @"bvec4", @"for", @"while", nil];
        for (NSTextCheckingResult *r in [ident matchesInString:c options:0 range:NSMakeRange(0, c.length)]) {
            NSString *w = [c substringWithRange:r.range];
            if (r.range.location > 0 && [c characterAtIndex:r.range.location - 1] == '.') continue;   // swizzle / member access, not a variable
            if ([intNames containsObject:w] || [intWords containsObject:w]) { skip = YES; break; }
        }
        // `[const] float x = <expr using int constants>;` : GLSL 1.20 converts implicitly, ES does not -> wrap int names and floatify literals
        static NSRegularExpression *floatDecl; static dispatch_once_t fdOnce;
        dispatch_once(&fdOnce, ^{ floatDecl = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(?:const\\s+)?(?:highp\\s+|mediump\\s+|lowp\\s+)?float\\s+\\w+\\s*=" options:0 error:nil]; });
        if (skip && [floatDecl numberOfMatchesInString:c options:0 range:NSMakeRange(0, c.length)] > 0 && [c rangeOfString:@"("].location != NSNotFound) {
            NSRange eq = [c rangeOfString:@"="]; NSString *head = [c substringToIndex:NSMaxRange(eq)], *rhs = [c substringFromIndex:NSMaxRange(eq)];
            NSMutableString *out2 = [NSMutableString string]; NSUInteger last = 0;
            for (NSTextCheckingResult *r in [ident matchesInString:rhs options:0 range:NSMakeRange(0, rhs.length)]) {
                NSString *w = [rhs substringWithRange:r.range];
                BOOL member = r.range.location > 0 && [rhs characterAtIndex:r.range.location - 1] == '.';
                NSUInteger after = NSMaxRange(r.range); while (after < rhs.length && [rhs characterAtIndex:after] == ' ') after++;
                BOOL call = after < rhs.length && [rhs characterAtIndex:after] == '(';
                if (!member && !call && [intNames containsObject:w]) { [out2 appendString:[rhs substringWithRange:NSMakeRange(last, r.range.location - last)]]; [out2 appendFormat:@"float(%@)", w]; last = NSMaxRange(r.range); }
            }
            [out2 appendString:[rhs substringFromIndex:last]];
            NSString *rhs2 = [lit stringByReplacingMatchesInString:out2 options:0 range:NSMakeRange(0, out2.length) withTemplate:@"$1.0"];
            [out appendString:head]; [out appendString:rhs2]; [chunk setString:@""];
            return;
        }
        if (skip || [chunk rangeOfString:@"["].location != NSNotFound) {
            if (!skip) {
                // convert only outside [...] when the statement is otherwise float-only
                NSMutableString *res = [NSMutableString string]; NSMutableString *seg = [NSMutableString string]; int depth = 0;
                for (NSUInteger k = 0; k < c.length; k++) {
                    unichar ch = [c characterAtIndex:k];
                    if (ch == '[') { if (depth == 0) { [res appendString:[lit stringByReplacingMatchesInString:seg options:0 range:NSMakeRange(0, seg.length) withTemplate:@"$1.0"]]; seg = [NSMutableString string]; } depth++; [res appendFormat:@"%C", ch]; }
                    else if (ch == ']') { depth--; [res appendFormat:@"%C", ch]; }
                    else if (depth > 0) [res appendFormat:@"%C", ch]; else [seg appendFormat:@"%C", ch];
                }
                [res appendString:[lit stringByReplacingMatchesInString:seg options:0 range:NSMakeRange(0, seg.length) withTemplate:@"$1.0"]];
                [out appendString:res];
            } else [out appendString:c];
        } else {
            [out appendString:[lit stringByReplacingMatchesInString:c options:0 range:NSMakeRange(0, c.length) withTemplate:@"$1.0"]];
        }
        [chunk setString:@""];
    };

    while (i < n) {
        unichar c = [s characterAtIndex:i];
        // preprocessor line: pass through untouched
        if (c == '#' && chunk.length == 0 || (c == '#' && [[chunk stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] == 0)) {
            [out appendString:chunk]; [chunk setString:@""];
            while (i < n && [s characterAtIndex:i] != '\n') [out appendFormat:@"%C", [s characterAtIndex:i++]];
            continue;
        }
        [chunk appendFormat:@"%C", c];
        if (c == '(') paren++; else if (c == ')') paren--;
        if (paren <= 0 && (c == ';' || c == '{' || c == '}')) { flush(); paren = 0; }
        i++;
    }
    flush();
    return out;
}

// `uniform sampler2D texture;` is legal in GLSL 1.20 but `texture` is a builtin function in ES3 (and gl4es macros texture2D to it).
static NSString *rename_texture_sampler(NSString *s) {
    NSRegularExpression *decl = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:sampler[123]D\\w*|samplerCube)\\s+texture\\b" options:0 error:nil];
    if ([decl numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] == 0) return s;
    NSRegularExpression *tok = [NSRegularExpression regularExpressionWithPattern:@"(?<![\\w.#])texture\\b(?!\\s*\\()" options:0 error:nil];
    return [tok stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"texture_u"];
}


// ---- helpers shared by the passes below ----
static NSArray<NSString *> *regex_names(NSString *s, NSString *pattern, NSUInteger group) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSMutableArray *out = [NSMutableArray array];
    for (NSTextCheckingResult *r in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) [out addObject:[s substringWithRange:[r rangeAtIndex:group]]];
    return out;
}
static BOOL has_main(NSString *s) {
    return [[NSRegularExpression regularExpressionWithPattern:@"\\bvoid\\s+main\\s*\\(" options:0 error:nil] numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
}

// GLSL 1.20 allows `float width = someUniform;` at global scope; ES 1.00 needs constant initializers. Move such assignments into main().
static NSString *relocate_global_initializers(NSString *s) {
    if (!has_main(s)) return s;
    NSMutableSet<NSString *> *dyn = [NSMutableSet setWithArray:regex_names(s, @"^\\s*(?:uniform|varying|attribute)\\s+(?:\\w+\\s+)*?(\\w+)\\s*(?:\\[[^\\]]*\\])?\\s*;", 1)];
    if (!dyn.count) return s;
    NSRegularExpression *declRe = [NSRegularExpression regularExpressionWithPattern:@"^(\\s*)(float|int|bool|vec[234]|ivec[234]|bvec[234]|mat[234])\\s+(\\w+)\\s*=\\s*([^;]+)$" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSRegularExpression *identRe = [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z_]\\w*" options:0 error:nil];
    NSMutableString *out = [NSMutableString string]; NSMutableString *assigns = [NSMutableString string];
    NSUInteger n = s.length, i = 0, stmtStart = 0; int depth = 0; BOOL inPre = NO;
    while (i < n) {
        unichar c = [s characterAtIndex:i];
        if (depth == 0 && (c == '#') && [[s substringWithRange:NSMakeRange(stmtStart, i - stmtStart)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) inPre = YES;
        if (inPre) { if (c == '\n') { [out appendString:[s substringWithRange:NSMakeRange(stmtStart, i + 1 - stmtStart)]]; stmtStart = i + 1; inPre = NO; } i++; continue; }
        if (c == '{') depth++;
        if (c == '}') { depth--; if (depth == 0) { [out appendString:[s substringWithRange:NSMakeRange(stmtStart, i + 1 - stmtStart)]]; stmtStart = i + 1; i++; continue; } }
        if (c == ';' && depth == 0) {
            NSString *stmt = [s substringWithRange:NSMakeRange(stmtStart, i - stmtStart)];
            NSTextCheckingResult *m = [declRe firstMatchInString:stmt options:0 range:NSMakeRange(0, stmt.length)];
            BOOL moved = NO;
            if (m && [stmt rangeOfString:@"const"].location == NSNotFound) {
                NSString *rhs = [stmt substringWithRange:[m rangeAtIndex:4]];
                BOOL dynamic = NO;
                for (NSTextCheckingResult *r in [identRe matchesInString:rhs options:0 range:NSMakeRange(0, rhs.length)]) if ([dyn containsObject:[rhs substringWithRange:r.range]]) { dynamic = YES; break; }
                if (dynamic) {
                    NSString *name = [stmt substringWithRange:[m rangeAtIndex:3]];
                    [out appendFormat:@"%@%@ %@;", [stmt substringWithRange:[m rangeAtIndex:1]], [stmt substringWithRange:[m rangeAtIndex:2]], name];
                    [assigns appendFormat:@"%@ = %@;\n", name, rhs];
                    [dyn addObject:name]; moved = YES;
                }
            }
            if (!moved) [out appendFormat:@"%@;", stmt];
            stmtStart = i + 1;
        }
        i++;
    }
    [out appendString:[s substringFromIndex:stmtStart]];
    if (!assigns.length) return s;
    NSRegularExpression *mainRe = [NSRegularExpression regularExpressionWithPattern:@"\\bvoid\\s+main\\s*\\(\\s*(?:void)?\\s*\\)\\s*\\{" options:0 error:nil];
    NSTextCheckingResult *mm = [mainRe firstMatchInString:out options:0 range:NSMakeRange(0, out.length)];
    if (!mm) return s;
    [out insertString:[@"\n" stringByAppendingString:assigns] atIndex:NSMaxRange(mm.range)];
    return out;
}

// Merged-library shaders: ES forbids duplicate prototypes and needs declaration-before-use. Rebuild one canonical prototype per defined function.
static NSString *canonicalize_prototypes(NSString *s) {
    NSSet<NSString *> *kw = [NSSet setWithObjects:@"if", @"for", @"while", @"switch", @"return", @"else", @"main", nil];
    NSRegularExpression *defRe = [NSRegularExpression regularExpressionWithPattern:@"(?m)^[ \\t]*((?:(?:highp|mediump|lowp)\\s+)?\\w+)\\s+(\\w+)\\s*\\(([^)]*)\\)\\s*\\{" options:0 error:nil];
    NSMutableSet<NSString *> *defined = [NSMutableSet set]; NSMutableArray<NSString *> *protos = [NSMutableArray array]; NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSTextCheckingResult *r in [defRe matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        NSString *ret = [s substringWithRange:[r rangeAtIndex:1]], *name = [s substringWithRange:[r rangeAtIndex:2]], *par = [[s substringWithRange:[r rangeAtIndex:3]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([kw containsObject:name] || [kw containsObject:ret]) continue;
        [defined addObject:name];
        NSString *proto = [NSString stringWithFormat:@"%@ %@(%@);", ret, name, par];
        if (![seen containsObject:proto]) { [seen addObject:proto]; [protos addObject:proto]; }
    }
    if (!defined.count) return s;
    NSRegularExpression *protoRe = [NSRegularExpression regularExpressionWithPattern:@"(?m)^[ \\t]*((?:(?:highp|mediump|lowp)\\s+)?\\w+)\\s+(\\w+)\\s*\\([^)]*\\)\\s*;[ \\t]*\\n?" options:0 error:nil];
    NSMutableString *m = [s mutableCopy];
    for (NSTextCheckingResult *r in [[protoRe matchesInString:m options:0 range:NSMakeRange(0, m.length)] reverseObjectEnumerator]) {
        NSString *ret = [m substringWithRange:[r rangeAtIndex:1]], *name = [m substringWithRange:[r rangeAtIndex:2]];
        if ([kw containsObject:ret]) continue;
        if ([defined containsObject:name]) [m replaceCharactersInRange:r.range withString:@""];
    }
    return [NSString stringWithFormat:@"%@\n%@", [protos componentsJoinedByString:@"\n"], m];
}
// Prototypes in `s` whose function is not defined anywhere in `s` (the shader needs a library shader to link).
static BOOL has_unresolved_prototypes(NSString *s) {
    NSSet<NSString *> *kw = [NSSet setWithObjects:@"if", @"for", @"while", @"switch", @"return", @"else", @"main", nil];
    NSArray *defs = regex_names(s, @"^[ \\t]*(?:(?:highp|mediump|lowp)\\s+)?\\w+\\s+(\\w+)\\s*\\([^)]*\\)\\s*\\{", 1);
    NSSet *defined = [NSSet setWithArray:defs];
    NSRegularExpression *protoRe = [NSRegularExpression regularExpressionWithPattern:@"(?m)^[ \\t]*((?:(?:highp|mediump|lowp)\\s+)?\\w+)\\s+(\\w+)\\s*\\([^)]*\\)\\s*;" options:0 error:nil];
    for (NSTextCheckingResult *r in [protoRe matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        NSString *ret = [s substringWithRange:[r rangeAtIndex:1]], *name = [s substringWithRange:[r rangeAtIndex:2]];
        if ([kw containsObject:ret] || [kw containsObject:name]) continue;
        if (![defined containsObject:name]) return YES;
    }
    return NO;
}

static NSString *fix_shader(NSString *src, NSMutableArray<NSDictionary *> *defaults) {
    NSString *s = strip_comments(src);
    s = rename_texture_sampler(s);
    s = strip_uniform_initializers(s, defaults);
    s = remove_builtin_redefinitions(s);
    s = floatify_int_literals(s);
    s = relocate_global_initializers(s);
    return s;
}

// ---------------------------------------------------------------- GL entry points ---
typedef void (*ShaderSourceFn)(GLuint, GLsizei, const GLchar *const *, const GLint *);
typedef void (*AttachFn)(GLuint, GLuint);
typedef void (*LinkFn)(GLuint);
typedef GLint (*GetUniformLocationFn)(GLuint, const GLchar *);
typedef void (*UseProgramFn)(GLuint);
typedef void (*GetIntegervFn)(unsigned, GLint *);
typedef void (*Uniform1iFn)(GLint, GLint);
typedef void (*Uniform1fFn)(GLint, float);
typedef void (*Uniform2fFn)(GLint, float, float);
typedef void (*Uniform3fFn)(GLint, float, float, float);
typedef void (*Uniform4fFn)(GLint, float, float, float, float);
typedef void (*Uniform2iFn)(GLint, GLint, GLint);
typedef void (*Uniform3iFn)(GLint, GLint, GLint, GLint);
typedef void (*Uniform4iFn)(GLint, GLint, GLint, GLint, GLint);

#define GLFN(type, name) static type name; if (!name) name = (type)gl4es_GetProcAddress(#name)

typedef GLuint (*CreateShaderFn)(unsigned);
typedef void (*CompileFn)(GLuint);
typedef void (*DetachFn)(GLuint, GLuint);
typedef void (*GetShaderivFn)(GLuint, unsigned, GLint *);
typedef void (*GetShaderInfoLogFn)(GLuint, GLsizei, GLsizei *, GLchar *);
typedef void (*GetProgramivFn)(GLuint, unsigned, GLint *);
typedef GLint (*GetAttribLocationFn)(GLuint, const GLchar *);
typedef void (*GetProgramInfoLogFn)(GLuint, GLsizei, GLsizei *, GLchar *);

static NSMutableDictionary<NSNumber *, NSArray<NSDictionary *> *> *g_shaderDefaults;   // shader id -> uniform defaults
static NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *g_programShaders; // program id -> shader ids (as attached by the game)
static NSMutableDictionary<NSNumber *, NSNumber *> *g_shaderType;                       // shader id -> GL type
static NSMutableDictionary<NSNumber *, NSString *> *g_shaderSource;                     // shader id -> rewritten source
static NSMutableSet<NSNumber *> *g_libraryShaders;                                      // shaders without main(): merged at link time
static NSMutableSet<NSNumber *> *g_deferredShaders;                                     // mains that call library functions: compiled at link time
static NSMutableSet<NSNumber *> *g_skinnedPrograms;
// Pairs of (program, location) that only the driver knows. There are a handful of them, so a plain scan is much cheaper than
// building an NSString for a set lookup on every bone-palette upload (which happens once per character, per frame).
static struct { GLuint program; GLint loc; } g_driverLocTab[64];
static int g_driverLocN;
static GLuint g_apiProgram;                       // program most recently bound through the API layer
static GLuint g_esProg;                           // program most recently bound at the ES layer
static float *g_palData; static int g_palCount; static unsigned g_palVersion;   // latest bone palette uploaded by the game (column-major)
static NSLock *g_lock;
static void ensure_state(void) { static dispatch_once_t once; dispatch_once(&once, ^{
    g_shaderDefaults = [NSMutableDictionary dictionary]; g_programShaders = [NSMutableDictionary dictionary];
    g_shaderType = [NSMutableDictionary dictionary]; g_shaderSource = [NSMutableDictionary dictionary]; g_libraryShaders = [NSMutableSet set]; g_deferredShaders = [NSMutableSet set]; g_skinnedPrograms = [NSMutableSet set]; g_lock = [NSLock new]; }); }
static BOOL driver_loc_known(GLuint program, GLint loc) {
    for (int i = 0; i < g_driverLocN; i++) if (g_driverLocTab[i].program == program && g_driverLocTab[i].loc == loc) return YES;
    return NO;
}
static void driver_loc_add(GLuint program, GLint loc) {
    if (g_driverLocN >= (int)(sizeof g_driverLocTab / sizeof g_driverLocTab[0])) return;
    if (driver_loc_known(program, loc)) return;
    g_driverLocTab[g_driverLocN].program = program;
    g_driverLocTab[g_driverLocN].loc = loc;
    g_driverLocN++;
}
static BOOL is_library(GLuint sh) { ensure_state(); [g_lock lock]; BOOL r = [g_libraryShaders containsObject:@(sh)]; [g_lock unlock]; return r; }
static BOOL is_deferred(GLuint sh) { ensure_state(); [g_lock lock]; BOOL r = [g_deferredShaders containsObject:@(sh)]; [g_lock unlock]; return r; }

static GLuint shim_glCreateShader(unsigned type) {
    GLFN(CreateShaderFn, glCreateShader); ensure_state();
    GLuint id = glCreateShader(type);
    [g_lock lock]; g_shaderType[@(id)] = @(type); [g_libraryShaders removeObject:@(id)]; [g_deferredShaders removeObject:@(id)]; [g_lock unlock];
    return id;
}

static void shim_glShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {
    GLFN(ShaderSourceFn, glShaderSource);
    ensure_state();
    NSMutableString *joined = [NSMutableString string];
    for (GLsizei i = 0; i < count; i++) {
        if (!strings[i]) continue;
        NSString *part = (lengths && lengths[i] >= 0) ? [[NSString alloc] initWithBytes:strings[i] length:lengths[i] encoding:NSUTF8StringEncoding] : [NSString stringWithUTF8String:strings[i]];
        if (part) [joined appendString:part];
    }
    NSMutableArray<NSDictionary *> *defaults = [NSMutableArray array];
    NSString *fixed = fix_shader(joined, defaults);
    BOOL hasMain = has_main(fixed);
    BOOL needsLibs = hasMain && has_unresolved_prototypes(fixed);
    [g_lock lock];
    if (defaults.count) g_shaderDefaults[@(shader)] = defaults; else [g_shaderDefaults removeObjectForKey:@(shader)];
    g_shaderSource[@(shader)] = fixed;
    if (hasMain) [g_libraryShaders removeObject:@(shader)]; else [g_libraryShaders addObject:@(shader)];
    if (needsLibs) [g_deferredShaders addObject:@(shader)]; else [g_deferredShaders removeObject:@(shader)];
    [g_lock unlock];
    if (shader_log_enabled()) fprintf(stderr, "[glshim] shader %u: %lu -> %lu chars, %lu uniform defaults%s\n", shader, (unsigned long)joined.length, (unsigned long)fixed.length, (unsigned long)defaults.count, hasMain ? (needsLibs ? " [needs libs: compile deferred]" : "") : " [library: merged at link]");
    const GLchar *p = fixed.UTF8String; GLint len = (GLint)strlen(p);
    glShaderSource(shader, 1, &p, &len);
}

static void shim_glCompileShader(GLuint shader) {
    GLFN(CompileFn, glCompileShader);
    if (is_library(shader) || is_deferred(shader)) return;      // compiled as part of the merged main shader at link time
    glCompileShader(shader);
}
static void shim_glGetShaderiv(GLuint shader, unsigned pname, GLint *params) {
    GLFN(GetShaderivFn, glGetShaderiv);
    if ((is_library(shader) || is_deferred(shader)) && (pname == 0x8B81 || pname == 0x8B84)) { *params = pname == 0x8B81 ? 1 : 0; return; }   // COMPILE_STATUS / INFO_LOG_LENGTH
    glGetShaderiv(shader, pname, params);
}
static void shim_glGetShaderInfoLog(GLuint shader, GLsizei max, GLsizei *len, GLchar *log) {
    GLFN(GetShaderInfoLogFn, glGetShaderInfoLog);
    if (is_library(shader) || is_deferred(shader)) { if (len) *len = 0; if (max > 0) log[0] = 0; return; }
    glGetShaderInfoLog(shader, max, len, log);
}

static void shim_glAttachShader(GLuint program, GLuint shader) {
    GLFN(AttachFn, glAttachShader);
    ensure_state();
    [g_lock lock];
    NSMutableArray *list = g_programShaders[@(program)]; if (!list) g_programShaders[@(program)] = list = [NSMutableArray array];
    if (![list containsObject:@(shader)]) [list addObject:@(shader)];
    [g_lock unlock];
    if (is_library(shader)) return;      // never attached for real: its code is merged into the main shader
    glAttachShader(program, shader);
}
static void shim_glDetachShader(GLuint program, GLuint shader) {
    GLFN(DetachFn, glDetachShader);
    ensure_state();
    [g_lock lock]; [g_programShaders[@(program)] removeObject:@(shader)]; [g_lock unlock];
    if (is_library(shader)) return;
    glDetachShader(program, shader);
}

// Prepend the program's library shaders (same stage) to each main shader and recompile it as a single unit.
static void merge_libraries(GLuint program) {
    GLFN(ShaderSourceFn, glShaderSource); GLFN(CompileFn, glCompileShader); GLFN(GetShaderivFn, glGetShaderiv);
    NSRegularExpression *ver = [NSRegularExpression regularExpressionWithPattern:@"(?m)^[ \\t]*#version[^\\n]*\\n?" options:0 error:nil];
    NSArray<NSNumber *> *ids; [g_lock lock]; ids = [g_programShaders[@(program)] copy]; [g_lock unlock];
    for (NSNumber *mainId in ids) {
        GLuint mid = mainId.unsignedIntValue;
        if (is_library(mid)) continue;
        NSMutableString *libs = [NSMutableString string]; int nlibs = 0;
        [g_lock lock];
        NSNumber *type = g_shaderType[mainId]; NSString *mainSrc = g_shaderSource[mainId];
        for (NSNumber *other in ids) if ([g_libraryShaders containsObject:other] && [g_shaderType[other] isEqual:type] && g_shaderSource[other]) {
            NSString *src = g_shaderSource[other];
            src = [ver stringByReplacingMatchesInString:src options:0 range:NSMakeRange(0, src.length) withTemplate:@""];
            [libs appendString:src]; [libs appendString:@"\n"]; nlibs++;
        }
        BOOL deferred = [g_deferredShaders containsObject:mainId];
        [g_lock unlock];
        if (!mainSrc || (!nlibs && !deferred)) continue;
        NSTextCheckingResult *vm = [ver firstMatchInString:mainSrc options:0 range:NSMakeRange(0, mainSrc.length)];
        NSString *verLine = vm ? [mainSrc substringWithRange:vm.range] : @"";
        NSString *rest = vm ? [mainSrc stringByReplacingCharactersInRange:vm.range withString:@""] : mainSrc;
        // libraries first, then the main shader; one canonical prototype per function, global initializers moved into main()
        NSString *combined = canonicalize_prototypes([NSString stringWithFormat:@"%@\n%@", libs, rest]);
        combined = relocate_global_initializers(combined);
        NSString *merged = [verLine stringByAppendingString:combined];
        const GLchar *p = merged.UTF8String; GLint len = (GLint)strlen(p);
        glShaderSource(mid, 1, &p, &len);
        [g_lock lock]; [g_deferredShaders removeObject:mainId]; [g_lock unlock];   // from now on behave like a normal compiled shader
        glCompileShader(mid);
        GLint ok = 0; glGetShaderiv(mid, 0x8B81, &ok);
        if (shader_log_enabled()) fprintf(stderr, "[glshim] program %u: merged %d library shader(s) into shader %u -> compile %s\n", program, nlibs, mid, ok ? "OK" : "FAILED");
    }
}

static void shim_glLinkProgram(GLuint program) {
    GLFN(LinkFn, glLinkProgram); GLFN(GetUniformLocationFn, glGetUniformLocation); GLFN(UseProgramFn, glUseProgram); GLFN(GetIntegervFn, glGetIntegerv);
    GLFN(Uniform1iFn, glUniform1i); GLFN(Uniform1fFn, glUniform1f); GLFN(Uniform2fFn, glUniform2f); GLFN(Uniform3fFn, glUniform3f); GLFN(Uniform4fFn, glUniform4f);
    GLFN(Uniform2iFn, glUniform2i); GLFN(Uniform3iFn, glUniform3i); GLFN(Uniform4iFn, glUniform4i);
    ensure_state();
    merge_libraries(program);
    glLinkProgram(program);
    if (shader_log_enabled()) {
        GLFN(GetProgramivFn, glGetProgramiv); GLFN(GetProgramInfoLogFn, glGetProgramInfoLog);
        GLint ok = 0; glGetProgramiv(program, 0x8B82 /* LINK_STATUS */, &ok);
        NSMutableString *desc = [NSMutableString string];
        [g_lock lock];
        for (NSNumber *sh in g_programShaders[@(program)]) {
            NSString *src = g_shaderSource[sh] ?: @"";
            NSString *hint = [src rangeOfString:@"MatrixPalette"].location != NSNotFound || [src rangeOfString:@"Bones"].location != NSNotFound ? @" skinned" : @"";
            [desc appendFormat:@" %@(%@%@%@)", sh, [g_shaderType[sh] intValue] == 0x8B31 ? @"vert" : @"frag", [g_libraryShaders containsObject:sh] ? @",lib" : @"", hint];
        }
        [g_lock unlock];
        if (!ok) { char logbuf[1024] = {0}; glGetProgramInfoLog(program, sizeof logbuf - 1, NULL, logbuf); fprintf(stderr, "[glshim] LINK FAILED program %u shaders:%s | %s\n", program, desc.UTF8String, logbuf); }
        else fprintf(stderr, "[glshim] program %u linked OK, shaders:%s\n", program, desc.UTF8String);
        BOOL skinnedProg = NO;
        [g_lock lock];
        for (NSNumber *sh in g_programShaders[@(program)]) if ([g_shaderSource[sh] rangeOfString:@"boneWeights"].location != NSNotFound) skinnedProg = YES;
        [g_lock unlock];
        if (skinnedProg && ok) {
            GLFN(GetAttribLocationFn, glGetAttribLocation);
            const char *names[] = {"vertex", "normal", "boneWeights", "boneIndices", "uv"};
            NSMutableString *locs = [NSMutableString string];
            for (int i = 0; i < 5; i++) [locs appendFormat:@" %s=%d", names[i], glGetAttribLocation(program, names[i])];
            [g_lock lock]; [g_skinnedPrograms addObject:@(program)]; [g_lock unlock];
            fprintf(stderr, "[glshim] skinned program %u attribute locations (game expects vertex=0 normal=1 boneWeights=2 boneIndices=3 uv=4):%s\n", program, locs.UTF8String);
        }
    }
    NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
    [g_lock lock];
    for (NSNumber *sh in g_programShaders[@(program)]) { NSArray *d = g_shaderDefaults[sh]; if (d) [all addObjectsFromArray:d]; }
    [g_lock unlock];
    if (!all.count) return;
    GLint prev = 0; glGetIntegerv(0x8B8D /* GL_CURRENT_PROGRAM */, &prev);
    glUseProgram(program);
    int applied = 0;
    for (NSDictionary *d in all) {
        GLint loc = glGetUniformLocation(program, [d[@"name"] UTF8String]);
        if (loc < 0) continue;
        NSString *t = d[@"type"]; NSArray<NSNumber *> *v = d[@"values"];
        if ([t isEqualToString:@"float"]) glUniform1f(loc, v[0].floatValue);
        else if ([t isEqualToString:@"vec2"]) glUniform2f(loc, v[0].floatValue, v[1].floatValue);
        else if ([t isEqualToString:@"vec3"]) glUniform3f(loc, v[0].floatValue, v[1].floatValue, v[2].floatValue);
        else if ([t isEqualToString:@"vec4"]) glUniform4f(loc, v[0].floatValue, v[1].floatValue, v[2].floatValue, v[3].floatValue);
        else if ([t isEqualToString:@"int"] || [t isEqualToString:@"bool"]) glUniform1i(loc, v[0].intValue);
        else if ([t isEqualToString:@"ivec2"]) glUniform2i(loc, v[0].intValue, v[1].intValue);
        else if ([t isEqualToString:@"ivec3"]) glUniform3i(loc, v[0].intValue, v[1].intValue, v[2].intValue);
        else if ([t isEqualToString:@"ivec4"]) glUniform4i(loc, v[0].intValue, v[1].intValue, v[2].intValue, v[3].intValue);
        else continue;
        applied++;
    }
    glUseProgram((GLuint)prev);
    if (shader_log_enabled()) fprintf(stderr, "[glshim] program %u linked: applied %d/%lu uniform defaults\n", program, applied, (unsigned long)all.count);
}

static void *angle_proc(const char *name);
typedef void (*UniformMatrix4fvFn2)(GLint, GLsizei, unsigned char, const float *);
static void shim_glUniformMatrix4fv(GLint loc, GLsizei count, unsigned char transpose, const float *v) {
    GLFN(UniformMatrix4fvFn2, glUniformMatrix4fv);
    static int big;
    ensure_state();
    BOOL direct = NO;
    if (count > 1 && loc >= 0) { [g_lock lock]; direct = driver_loc_known(g_apiProgram, loc); [g_lock unlock]; }
    if (direct) {
        // gl4es' GoUniformMatrix4fv copies into a small stack buffer when transposing (overflow for a 35-bone palette) and does not know
        // this uniform at all, so it never replays it into the program variant it really draws with. Cache the palette (column-major) here;
        // it is uploaded to whichever ES program is bound right before each draw (apply_palette). The buffer is reused: this runs once per
        // character per frame, and a malloc/free pair there is pure overhead.
        static float *palBuf; static size_t palCap;
        size_t need = (size_t)count * 16;
        [g_lock lock];
        if (need > palCap) { float *t = realloc(palBuf, need * sizeof(float)); if (t) { palBuf = t; palCap = need; } }
        float *t = palBuf;
        if (t && need <= palCap) {
            for (GLsizei m = 0; m < count; m++) for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++)
                t[m * 16 + c * 4 + r] = transpose ? v[m * 16 + r * 4 + c] : v[m * 16 + c * 4 + r];
            g_palData = t; g_palCount = count; g_palVersion++;
            [g_lock unlock];
            if (shader_log_enabled() && big < 4) { big++; double sum = 0; for (int i = 0; i < count * 16; i++) sum += fabs(t[i]); fprintf(stderr, "[glshim] palette cached (api prog=%u loc=%d count=%d transpose=%d) sum|v|=%.2f version=%u\n", g_apiProgram, loc, count, transpose, sum, g_palVersion); }
            return;
        }
        [g_lock unlock];
    }
    if (shader_log_enabled() && count >= 8 && big < 10) { big++; double sum = 0; for (int i = 0; i < count * 16 && i < 16 * 64; i++) sum += fabs(v[i]); fprintf(stderr, "[glshim] API glUniformMatrix4fv (via gl4es) loc=%d count=%d transpose=%d sum|v|=%.2f\n", loc, count, transpose, sum); }
    glUniformMatrix4fv(loc, count, transpose, v);
}

typedef GLint (*GetUniformLocFn)(GLuint, const GLchar *);
static void *angle_proc(const char *name);
static GLint shim_glGetUniformLocation(GLuint program, const GLchar *name) {
    GLFN(GetUniformLocFn, glGetUniformLocation);
    GLint r;
    if (name && strcmp(name, "texture") == 0) { r = glGetUniformLocation(program, "texture_u"); if (r >= 0) return r; }   // see rename_texture_sampler
    r = glGetUniformLocation(program, name);
    // ES names array uniforms "name[0]"; a driver may refuse the bare name that desktop GL accepts, which silently drops every upload
    BOOL retried = NO;
    if (r < 0 && name && !strchr(name, '[')) {
        char buf[256]; snprintf(buf, sizeof buf, "%s[0]", name);
        GLint r2 = glGetUniformLocation(program, buf);
        if (r2 >= 0) { r = r2; retried = YES; }
    }
    // gl4es' own lookup can return -1 for array uniforms the driver does know (every upload to -1 is then silently dropped).
    // Ask the driver directly; locations are passed through unchanged for user programs.
    if (r < 0 && name) {
        static GetUniformLocFn esLoc; if (!esLoc) esLoc = (GetUniformLocFn)angle_proc("glGetUniformLocation");
        if (esLoc) {
            GLint e = esLoc(program, name);
            if (e < 0 && !strchr(name, '[')) { char buf[256]; snprintf(buf, sizeof buf, "%s[0]", name); e = esLoc(program, buf); }
            if (e >= 0) { [g_lock lock]; driver_loc_add(program, e); [g_lock unlock]; if (shader_log_enabled()) fprintf(stderr, "[glshim] glGetUniformLocation(program %u, \"%s\") gl4es=-1, driver=%d -> using driver location\n", program, name, e); return e; }
        }
    }
    if (shader_log_enabled() && name && strstr(name, "Palette")) fprintf(stderr, "[glshim] glGetUniformLocation(program %u, \"%s\") = %d%s\n", program, name, r, retried ? " (found as name[0])" : "");
    return r;
}

// ---------------------------------------------------------------- GLES level (what gl4es hands to ANGLE) ---
// gl4es resolves every GLES function through gles_getProcAddress; we provide it so we can repair the final ES source.
extern void set_getprocaddress(void *(*)(const char *));
static void *g_angle;
static void *angle_proc(const char *name) {
    if (!g_angle) g_angle = dlopen("@rpath/MetalANGLE.framework/MetalANGLE", RTLD_NOW | RTLD_NOLOAD);
    static void *(*eglGPA)(const char *); if (!eglGPA && g_angle) eglGPA = dlsym(g_angle, "eglGetProcAddress");
    void *p = eglGPA ? eglGPA(name) : NULL;
    if (!p && g_angle) p = dlsym(g_angle, name);
    return p;
}
static NSString *fix_es_source(NSString *s, int shader) {
    BOOL usesG = [s rangeOfString:@"g_FragColor"].location != NSNotFound;
    static NSRegularExpression *outDecl; static dispatch_once_t once;
    dispatch_once(&once, ^{ outDecl = [NSRegularExpression regularExpressionWithPattern:@"(?<![A-Za-z_])out\\s+[^;\\n]*\\bg_FragColor\\b" options:0 error:nil]; });
    BOOL definesG = [s rangeOfString:@"#define g_FragColor"].location != NSNotFound
                 || [outDecl numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
    if (usesG && !definesG) {
        // gl4es' alpha-test wrapper writes g_FragColor, which the ES 1.00 path never defines
        NSRange v = [s rangeOfString:@"#version"];
        NSUInteger at = 0;
        if (v.location != NSNotFound) { NSRange nl = [s rangeOfString:@"\n" options:0 range:NSMakeRange(v.location, s.length - v.location)]; at = nl.location != NSNotFound ? NSMaxRange(nl) : s.length; }
        s = [s stringByReplacingCharactersInRange:NSMakeRange(at, 0) withString:@"#define g_FragColor gl_FragColor\n"];
        if (shader_log_enabled()) { static int n; if (n++ < 3) fprintf(stderr, "[glshim] ES shader %d: defined g_FragColor (%d fixed so far)\n", shader, n); }
    }
    // gl4es' alpha-test / blend / clip-plane wrapper renames main() to _gl4es_main() and gl_FragColor to _gl4es_FragColor, declaring the new variable just
    // above main. A game shader that writes gl_FragColor in a helper defined earlier (or one the wrapper failed to declare) then fails with "undeclared
    // identifier" on every use, and gl4es retries it for every draw. Declare the variable at the top, after the preprocessor and precision lines.
    if ([s rangeOfString:@"_gl4es_FragColor"].location != NSNotFound) {
        static NSString *const decl = @"lowp vec4 _gl4es_FragColor;\n";
        NSRange d = [s rangeOfString:decl], u = [s rangeOfString:@"_gl4es_FragColor"];
        if (d.location == NSNotFound || u.location < d.location) {
            NSMutableString *m = [s mutableCopy];
            if (d.location != NSNotFound) [m deleteCharactersInRange:d];
            NSUInteger pos = 0, n = m.length;
            while (pos < n) {
                NSRange nl = [m rangeOfString:@"\n" options:0 range:NSMakeRange(pos, n - pos)];
                NSUInteger end = nl.location == NSNotFound ? n : NSMaxRange(nl);
                NSString *line = [[m substringWithRange:NSMakeRange(pos, end - pos)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (line.length == 0 || [line hasPrefix:@"#"] || [line hasPrefix:@"//"] || [line hasPrefix:@"precision "]) pos = end; else break;
            }
            [m insertString:decl atIndex:pos];
            { static int logged; if (logged++ < 2) {
                fprintf(stderr, "[glshim] ES shader %d: moved the _gl4es_FragColor declaration to the top (%s)\n", shader, d.location == NSNotFound ? "it was missing" : "it came after its first use");
            } }
            s = m;
        }
    }
    // gl4es always emits `#define mod(a,b) (int(a) - int(b) * int(a/b))`, which turns every float mod() (and its own injected
    // mod(float,int) overloads) into integer arithmetic that ES rejects. Float mod is a builtin in ES, so drop the macro.
    NSRange macro = [s rangeOfString:@"#define mod(a,b) (int(a) - int(b) * int(a/b))"];
    if (macro.location != NSNotFound) {
        NSMutableString *m = [s mutableCopy]; [m replaceCharactersInRange:macro withString:@""]; s = m;
    }
    // The blur/outline shader leans on GLSL 1.20's implicit int->float conversions (ivec2 * vec2, float * int uniform), which ES rejects.
    static NSString *const fixes[][2] = {
        { @"(pixel + ivec2(x, y)) * pixelStep", @"vec2(pixel + ivec2(x, y)) * pixelStep" },
        { @"(BASE_OPACITY * opacityScale)", @"(BASE_OPACITY * float(opacityScale))" },
    };
    for (size_t i = 0; i < sizeof(fixes) / sizeof(fixes[0]); i++)
        if ([s rangeOfString:fixes[i][0]].location != NSNotFound) s = [s stringByReplacingOccurrencesOfString:fixes[i][0] withString:fixes[i][1]];
    return s;
}
static void es_glShaderSource(GLuint shader, GLsizei count, const GLchar *const *strings, const GLint *lengths) {
    static ShaderSourceFn real; if (!real) real = (ShaderSourceFn)angle_proc("glShaderSource");
    NSMutableString *joined = [NSMutableString string];
    for (GLsizei i = 0; i < count; i++) {
        if (!strings[i]) continue;
        NSString *part = (lengths && lengths[i] >= 0) ? [[NSString alloc] initWithBytes:strings[i] length:lengths[i] encoding:NSUTF8StringEncoding] : [NSString stringWithUTF8String:strings[i]];
        if (part) [joined appendString:part];
    }
    NSString *fixed = fix_es_source(joined, (int)shader);
    if (shader_log_enabled() && [fixed rangeOfString:@"boneWeights"].location != NSNotFound) {
        static int dumped; if (dumped++ < 3) {
            NSString *dir = [NSString stringWithFormat:@"%s/shots", getenv("HOME") ?: "/tmp"]; [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [fixed writeToFile:[dir stringByAppendingFormat:@"/es_skinned_%u.glsl", shader] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fprintf(stderr, "[glshim] dumped ES source of skinned shader %u\n", shader);
        }
    }
    const GLchar *p = fixed.UTF8String; GLint len = (GLint)strlen(p);
    real(shader, 1, &p, &len);
}

// ---- ES-level trace of the first few draws made with a skinned (character) program ----
typedef void (*DrawElementsFn)(unsigned, GLsizei, unsigned, const void *);
typedef void (*DrawArraysFn)(unsigned, GLint, GLsizei);
typedef void (*UniformMatrix4fvFn)(GLint, GLsizei, unsigned char, const float *);
typedef void (*GetVAivFn)(GLuint, unsigned, GLint *);
typedef unsigned char (*IsEnabledFn)(unsigned);
typedef unsigned (*GetErrorFn)(void);
typedef void (*GetBooleanvFn)(unsigned, unsigned char *);

static int g_traceBudget = 12, g_matrixBudget = 6;
#define ESFN(type, name) static type name; if (!name) name = (type)angle_proc(#name)

// Per-program state in plain C tables: these are read on every program switch and on every draw. Asking an NSDictionary there
// meant an NSNumber allocation plus hashing per call, which is steady work on a busy frame.
static unsigned char *g_esSkinnedTab;          // 0 unknown, 1 not skinned, 2 skinned (gl4es' program ids differ from the driver's)
static size_t g_esSkinnedTabN;
static unsigned *g_palAppliedTab;              // palette version already uploaded to that program
static size_t g_palAppliedTabN;

static unsigned char es_skinned_state(GLuint p) { return p < g_esSkinnedTabN ? g_esSkinnedTab[p] : 0; }
static void es_set_skinned_state(GLuint p, unsigned char v) {
    if (p >= g_esSkinnedTabN) {
        size_t n = g_esSkinnedTabN ? g_esSkinnedTabN : 256;
        while (n <= p) n *= 2;
        unsigned char *t = realloc(g_esSkinnedTab, n);
        if (!t) return;
        memset(t + g_esSkinnedTabN, 0, n - g_esSkinnedTabN);
        g_esSkinnedTab = t; g_esSkinnedTabN = n;
    }
    g_esSkinnedTab[p] = v;
}
static unsigned pal_applied(GLuint p) { return p < g_palAppliedTabN ? g_palAppliedTab[p] : 0; }
static void set_pal_applied(GLuint p, unsigned v) {
    if (p >= g_palAppliedTabN) {
        size_t n = g_palAppliedTabN ? g_palAppliedTabN : 256;
        while (n <= p) n *= 2;
        unsigned *t = realloc(g_palAppliedTab, n * sizeof(unsigned));
        if (!t) return;
        memset(t + g_palAppliedTabN, 0, (n - g_palAppliedTabN) * sizeof(unsigned));
        g_palAppliedTab = t; g_palAppliedTabN = n;
    }
    g_palAppliedTab[p] = v;
}
static BOOL es_prog_is_skinned(void) { return es_skinned_state(g_esProg) == 2; }
// ---- ask ANGLE (KHR_debug) why it rejects a call
static int g_dbgBudget = 40;
static void es_debug_cb(unsigned source, unsigned type, unsigned id, unsigned severity, int length, const char *message, const void *user) {
    if (g_dbgBudget <= 0) return;
    if (type == 0x8250 || type == 0x8251) return;     // other / push-pop group noise
    g_dbgBudget--;
    fprintf(stderr, "[glshim] KHR_debug src=0x%x type=0x%x id=%u sev=0x%x: %.*s\n", source, type, id, severity, length > 0 && length < 700 ? length : 700, message);
}
static void install_es_debug(void) {
    static int done; if (done || !shader_log_enabled()) return; done = 1;
    typedef void (*CbFn)(unsigned, unsigned, unsigned, unsigned, int, const char *, const void *);
    typedef void (*SetCbFn)(CbFn, const void *);
    typedef void (*EnableFn)(unsigned);
    SetCbFn setcb = (SetCbFn)angle_proc("glDebugMessageCallbackKHR"); if (!setcb) setcb = (SetCbFn)angle_proc("glDebugMessageCallback");
    EnableFn en = (EnableFn)angle_proc("glEnable");
    if (setcb && en) { setcb(es_debug_cb, NULL); en(0x92E0); en(0x8242); fprintf(stderr, "[glshim] KHR_debug output enabled\n"); }
    else fprintf(stderr, "[glshim] KHR_debug not available (callback=%p)\n", (void *)setcb);
}
static void es_glUseProgram(GLuint p) {
    install_es_debug();
    ESFN(UseProgramFn, glUseProgram); ESFN(GetUniformLocationFn, glGetUniformLocation);
    glUseProgram(p); g_esProg = p;
    if (!p) return;
    if (es_skinned_state(p)) return;                 // 1 = known not skinned, 2 = known skinned
    BOOL sk = glGetUniformLocation(p, "MatrixPalette[0]") >= 0 || glGetUniformLocation(p, "MatrixPalette") >= 0;
    es_set_skinned_state(p, sk ? 2 : 1);
    if (shader_log_enabled() && sk) fprintf(stderr, "[glshim] ES program %u is skinned (has MatrixPalette)\n", p);
}

static void trace_skinned_draw(const char *kind, unsigned mode, GLsizei count, unsigned type, const void *indices) {
    if (!shader_log_enabled() || g_traceBudget <= 0 || !es_prog_is_skinned()) return;
    g_traceBudget--;
    ESFN(GetIntegervFn, glGetIntegerv); ESFN(GetVAivFn, glGetVertexAttribiv); ESFN(IsEnabledFn, glIsEnabled); ESFN(GetErrorFn, glGetError); ESFN(GetBooleanvFn, glGetBooleanv);
    GLint fb = 0, vp[4] = {0}, ab = 0, eb = 0, df = 0, cf = 0, ff = 0;
    glGetIntegerv(0x8CA6, &fb); glGetIntegerv(0x0BA2, vp); glGetIntegerv(0x8894, &ab); glGetIntegerv(0x8895, &eb);
    glGetIntegerv(0x0B74, &df); glGetIntegerv(0x0B45, &cf); glGetIntegerv(0x0B46, &ff);
    unsigned char cm[4] = {0}, dm = 0; glGetBooleanv(0x0C23, cm); glGetBooleanv(0x0B72, &dm);
    unsigned err = glGetError();
    fprintf(stderr, "[glshim] DRAW %s prog=%u mode=0x%x count=%d type=0x%x idx=%p | fbo=%d viewport=%d,%d,%d,%d arrayBuf=%d elemBuf=%d | depth=%d func=0x%x dmask=%d cull=%d face=0x%x blend=%d scissor=%d cmask=%d%d%d%d | err=0x%x\n",
            kind, g_esProg, mode, count, type, indices, fb, vp[0], vp[1], vp[2], vp[3], ab, eb,
            glIsEnabled(0x0B71), df, dm, glIsEnabled(0x0B44), cf, glIsEnabled(0x0BE2), glIsEnabled(0x0C11), cm[0], cm[1], cm[2], cm[3], err);
    for (GLuint i = 0; i < 5; i++) {
        GLint en = 0, sz = 0, ty = 0, st = 0, bb = 0;
        glGetVertexAttribiv(i, 0x8622, &en); glGetVertexAttribiv(i, 0x8623, &sz); glGetVertexAttribiv(i, 0x8625, &ty); glGetVertexAttribiv(i, 0x8624, &st); glGetVertexAttribiv(i, 0x889F, &bb);
        fprintf(stderr, "[glshim]    attrib %u: enabled=%d size=%d type=0x%x stride=%d buffer=%d\n", i, en, sz, ty, st, bb);
    }
}

// Upload the cached bone palette to the ES program that is really bound (gl4es draws with its own variant of the game's program).
// Runs before every draw, so it keeps no Objective-C objects and no per-call allocation: the copy buffer is reused and grows only
// when the palette does.
static void apply_palette(void) {
    if (!g_palData || !g_esProg) return;
    if (!es_prog_is_skinned()) return;
    static float *buf; static size_t bufCap;
    static GetUniformLocationFn esLoc; static UniformMatrix4fvFn esU;
    if (!esLoc) esLoc = (GetUniformLocationFn)angle_proc("glGetUniformLocation");
    if (!esU) esU = (UniformMatrix4fvFn)angle_proc("glUniformMatrix4fv");
    if (!esLoc || !esU) return;
    if (pal_applied(g_esProg) == g_palVersion) return;      // this program already has the current palette
    GLint loc = esLoc(g_esProg, "MatrixPalette"); if (loc < 0) loc = esLoc(g_esProg, "MatrixPalette[0]");
    if (loc < 0) return;
    ensure_state();
    [g_lock lock];
    unsigned want = g_palVersion;
    int n = g_palCount;
    size_t need = (size_t)n * 16;
    if (need > bufCap) { float *t = realloc(buf, need * sizeof(float)); if (t) { buf = t; bufCap = need; } }
    if (!buf || need > bufCap || !g_palData) { [g_lock unlock]; return; }
    memcpy(buf, g_palData, need * sizeof(float));
    set_pal_applied(g_esProg, want);
    [g_lock unlock];
    esU(loc, n, 0, buf);
    if (shader_log_enabled()) { static int logged; if (logged++ < 6) fprintf(stderr, "[glshim] applied palette v%u to ES program %u loc=%d count=%d\n", want, g_esProg, loc, n); }
}

// Trace draws into off-screen framebuffers (render-to-texture: how the game builds tinted clothing/skin textures).
typedef unsigned (*CheckFBStatusFn)(unsigned);
static int g_fboTraceBudget = 30;
static unsigned g_preDrawErr;
static void predraw_drain(void) {
    if (!shader_log_enabled() || g_fboTraceBudget <= 0) { g_preDrawErr = 0; return; }
    ESFN(GetIntegervFn, glGetIntegerv); ESFN(GetErrorFn, glGetError);
    GLint fb = 0; glGetIntegerv(0x8CA6, &fb);
    g_preDrawErr = 0;
    if (!fb) return;
    unsigned e; int n = 0; while ((e = glGetError()) != 0 && n++ < 8) g_preDrawErr = e;   // errors left over from earlier calls
}
static void trace_fbo_draw(const char *kind, unsigned mode, GLsizei count, unsigned type, const void *indices) {
    if (!shader_log_enabled() || g_fboTraceBudget <= 0) return;
    ESFN(GetIntegervFn, glGetIntegerv); ESFN(GetErrorFn, glGetError); ESFN(CheckFBStatusFn, glCheckFramebufferStatus);
    ESFN(GetVAivFn, glGetVertexAttribiv);
    GLint fb = 0; glGetIntegerv(0x8CA6, &fb);
    if (!fb) return;
    g_fboTraceBudget--;
    GLint vp[4] = {0}; glGetIntegerv(0x0BA2, vp);
    unsigned st = glCheckFramebufferStatus(0x8D40);
    unsigned err = glGetError();
    GLint prog = 0, tex = 0, ab = 0, eb = 0; glGetIntegerv(0x8B8D, &prog); glGetIntegerv(0x8069, &tex); glGetIntegerv(0x8894, &ab); glGetIntegerv(0x8895, &eb);
    fprintf(stderr, "[glshim] FBO-DRAW %s fbo=%d prog=%u(cur=%d skinned=%d) mode=0x%x count=%d viewport=%d,%d,%d,%d fbstatus=0x%x%s | preDrawErr=0x%x errAfterDraw=0x%x | tex2D(unit)=%d arrayBuf=%d elemBuf=%d\n",
            kind, fb, g_esProg, prog, es_prog_is_skinned(), mode, count, vp[0], vp[1], vp[2], vp[3], st, st == 0x8CD5 ? "(complete)" : "(NOT COMPLETE)", g_preDrawErr, err, tex, ab, eb);
    for (GLuint i = 0; i < 4; i++) {
        GLint en = 0, sz = 0, bb = 0; glGetVertexAttribiv(i, 0x8622, &en); glGetVertexAttribiv(i, 0x8623, &sz); glGetVertexAttribiv(i, 0x889F, &bb);
        if (en) fprintf(stderr, "[glshim]    attrib %u enabled size=%d buffer=%d\n", i, sz, bb);
    }
    // destination details: what the draw renders into, and which textures could form a feedback loop
    typedef void (*GetFBAttachFn)(unsigned, unsigned, unsigned, GLint *);
    typedef void (*ActiveTexFn)(unsigned);
    typedef unsigned char (*IsEnabledFn2)(unsigned);
    ESFN(GetFBAttachFn, glGetFramebufferAttachmentParameteriv); ESFN(ActiveTexFn, glActiveTexture); ESFN(IsEnabledFn2, glIsEnabled);
    GLint objType = 0, objName = 0, compType = 0, enc = 0, rs = 0, gs = 0, bs = 0, as = 0, db0 = 0, rb = 0, activeTex = 0, bl = 0, blsrc = 0, bldst = 0;
    glGetFramebufferAttachmentParameteriv(0x8D40, 0x8CE0, 0x8CD0, &objType); glGetFramebufferAttachmentParameteriv(0x8D40, 0x8CE0, 0x8CD1, &objName);
    glGetFramebufferAttachmentParameteriv(0x8D40, 0x8CE0, 0x8211, &compType); glGetFramebufferAttachmentParameteriv(0x8D40, 0x8CE0, 0x8210, &enc);
    glGetFramebufferAttachmentParameteriv(0x8D40, 0x8CE0, 0x8212, &rs); glGetFramebufferAttachmentParameteriv(0x8D40, 0x8CE0, 0x8213, &gs);
    glGetFramebufferAttachmentParameteriv(0x8D40, 0x8CE0, 0x8214, &bs); glGetFramebufferAttachmentParameteriv(0x8D40, 0x8CE0, 0x8215, &as);
    glGetIntegerv(0x8825, &db0); glGetIntegerv(0x0C02, &rb); glGetIntegerv(0x84E0, &activeTex);
    glGetIntegerv(0x0BE1, &blsrc); glGetIntegerv(0x0BE0, &bldst);
    GLint texu[4] = {0}; for (GLuint u = 0; u < 4; u++) { glActiveTexture(0x84C0 + u); glGetIntegerv(0x8069, &texu[u]); } glActiveTexture((unsigned)activeTex);
    {
        typedef void (*GetBufParamFn)(unsigned, unsigned, GLint *);
        typedef void (*GetVAPtrFn)(GLuint, unsigned, void **);
        typedef void *(*MapRangeFn)(unsigned, long, long, unsigned);
        typedef unsigned char (*UnmapFn)(unsigned);
        ESFN(GetBufParamFn, glGetBufferParameteriv); ESFN(GetVAPtrFn, glGetVertexAttribPointerv); ESFN(MapRangeFn, glMapBufferRange); ESFN(UnmapFn, glUnmapBuffer);
        GLint abSize = 0, ebSize = 0; glGetBufferParameteriv(0x8892, 0x8764, &abSize); glGetBufferParameteriv(0x8893, 0x8764, &ebSize);
        int isz = type == 0x1401 ? 1 : type == 0x1403 ? 2 : type == 0x1405 ? 4 : 0;
        unsigned maxIdx = 0; BOOL haveIdx = NO;
        if (isz && indices != NULL) { /* offsets only matter when an element buffer is bound (it is) */ }
        if (isz && ebSize > 0) {
            long off = (long)(uintptr_t)indices, len = (long)count * isz;
            if (off + len <= ebSize) {
                unsigned char *m = (unsigned char *)glMapBufferRange(0x8893, off, len, 0x0001 /* MAP_READ_BIT */);
                if (m) { for (int i = 0; i < count; i++) { unsigned v = isz == 1 ? m[i] : isz == 2 ? ((unsigned short *)m)[i] : ((unsigned *)m)[i]; if (v > maxIdx) maxIdx = v; } haveIdx = YES; glUnmapBuffer(0x8893); }
            }
        }
        fprintf(stderr, "[glshim]    BUFFERS: indexType=0x%x idxOffset=%ld count=%d elemBufSize=%d (need %ld) arrayBufSize=%d maxIndex=%s%u\n", type, (long)(uintptr_t)indices, count, ebSize, (long)(uintptr_t)indices + (long)count * isz, abSize, haveIdx ? "" : "?", maxIdx);
        for (GLuint i = 0; i < 4; i++) {
            GLint en = 0, st = 0, ty = 0, nm = 0, sz = 0; void *ptr = NULL;
            glGetVertexAttribiv(i, 0x8622, &en); if (!en) continue;
            glGetVertexAttribiv(i, 0x8624, &st); glGetVertexAttribiv(i, 0x8625, &ty); glGetVertexAttribiv(i, 0x886A, &nm); glGetVertexAttribiv(i, 0x8623, &sz); glGetVertexAttribPointerv(i, 0x8645, &ptr);
            long tsz = ty == 0x1406 ? 4 : ty == 0x1401 || ty == 0x1400 ? 1 : 2;
            long needEnd = (long)(uintptr_t)ptr + (long)st * (long)maxIdx + (long)sz * tsz;
            fprintf(stderr, "[glshim]      attrib %u: offset=%ld stride=%d size=%d type=0x%x normalized=%d -> needs bytes up to %ld of %d%s\n", i, (long)(uintptr_t)ptr, st, sz, ty, nm, needEnd, abSize, needEnd > abSize ? "  <-- TOO SMALL" : "");
        }
    }
    fprintf(stderr, "[glshim]    DEST: attachment0 type=0x%x name=%d compType=0x%x sRGB=0x%x bits=%d,%d,%d,%d | drawBuffer0=0x%x readBuffer=0x%x blend=%d(src=0x%x dst=0x%x) | texUnits[0..3]=%d,%d,%d,%d activeUnit=0x%x\n",
            objType, objName, compType, enc, rs, gs, bs, as, db0, rb, glIsEnabled(0x0BE2), blsrc, bldst, texu[0], texu[1], texu[2], texu[3], activeTex);
}
typedef void (*GenBuffersFn)(GLsizei, GLuint *);
typedef void (*BindBufferFn)(unsigned, GLuint);
typedef void (*BufferDataFn)(unsigned, long, const void *, unsigned);
static void es_glDrawElements(unsigned mode, GLsizei count, unsigned type, const void *indices) {
    ESFN(DrawElementsFn, glDrawElements);
    // gl4es sometimes issues a client-memory index draw while an element-array buffer is still bound. With a buffer bound `indices` is a byte
    // offset, so the driver sees a ~64-bit "offset" into a tiny buffer ("Insufficient buffer size") and the draw (and everything it composes) is lost.
    // Detect a CPU pointer, upload the indices to a scratch buffer, draw from offset 0 and restore the binding gl4es expects.
    if ((uintptr_t)indices > 0x10000000UL && count > 0) {
        ESFN(GetIntegervFn, glGetIntegerv); ESFN(GenBuffersFn, glGenBuffers); ESFN(BindBufferFn, glBindBuffer); ESFN(BufferDataFn, glBufferData);
        GLint eb = 0; glGetIntegerv(0x8895, &eb);
        if (eb) {
            static GLuint scratch; if (!scratch) glGenBuffers(1, &scratch);
            long isz = type == 0x1401 ? 1 : type == 0x1403 ? 2 : 4;
            glBindBuffer(0x8893, scratch); glBufferData(0x8893, (long)count * isz, indices, 0x88E0 /* STREAM_DRAW */);
            apply_palette(); predraw_drain();
            glDrawElements(mode, count, type, (const void *)0);
            glBindBuffer(0x8893, (GLuint)eb);
            static int fixed; if (shader_log_enabled() && fixed++ < 5) fprintf(stderr, "[glshim] fixed client-pointer glDrawElements with element buffer %d bound (count=%d type=0x%x)\n", eb, count, type);
            trace_skinned_draw("elements", mode, count, type, (const void *)0); trace_fbo_draw("elements", mode, count, type, (const void *)0);
            return;
        }
    }
    apply_palette(); predraw_drain(); glDrawElements(mode, count, type, indices); trace_skinned_draw("elements", mode, count, type, indices); trace_fbo_draw("elements", mode, count, type, indices);
}
static void es_glDrawArrays(unsigned mode, GLint first, GLsizei count) {
    ESFN(DrawArraysFn, glDrawArrays); apply_palette(); predraw_drain(); glDrawArrays(mode, first, count); trace_skinned_draw("arrays", mode, count, 0, NULL); trace_fbo_draw("arrays", mode, count, 0, NULL);
}
static void es_glUniformMatrix4fv(GLint loc, GLsizei count, unsigned char transpose, const float *v) {
    ESFN(UniformMatrix4fvFn, glUniformMatrix4fv); glUniformMatrix4fv(loc, count, transpose, v);
    static int seen, bigSeen;
    if (!shader_log_enabled()) return;
    double sum = 0; for (int i = 0; i < count * 16 && i < 16 * 64; i++) sum += fabs(v[i]);
    if (count >= 8 && bigSeen < 8) {
        bigSeen++;
        fprintf(stderr, "[glshim] UniformMatrix4fv BIG prog=%u(skinned=%d) loc=%d count=%d transpose=%d sum|v|=%.2f first=[%.3f %.3f %.3f %.3f | %.3f %.3f %.3f %.3f | ...]\n", g_esProg, es_prog_is_skinned(), loc, count, transpose, sum, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
    } else if (seen < 14 && es_prog_is_skinned()) {
        seen++;
        fprintf(stderr, "[glshim] UniformMatrix4fv prog=%u loc=%d count=%d transpose=%d sum|v|=%.2f\n", g_esProg, loc, count, transpose, sum);
    }
}


// ---------------------------------------------------------------- ASTC texture compression (experiment) ---
// Large static RGBA8 textures (the world/tree/overlay atlas pages) are compressed to ASTC at upload: 4x4 blocks = 8 bits/texel, a quarter of RGBA8,
// with essentially no visible loss for pixel art. Render targets (no pixel data), small textures, mip chains and anything the game updates piecemeal
// are left alone. Controlled by ZOMIOS_ASTC=<minimum dimension> (0/unset = off), ZOMIOS_ASTC_BLOCK (4,5,6,8), ZOMIOS_ASTC_QUALITY.
extern size_t zo_astc_size(unsigned w, unsigned h, unsigned block);
extern int zo_astc_compress(const uint8_t *pixels, unsigned w, unsigned h, int bgra, unsigned block, float quality, uint8_t *out);
typedef void (*TexImage2DFn)(unsigned, GLint, GLint, GLsizei, GLsizei, GLint, unsigned, unsigned, const void *);
typedef void (*CompressedTexImage2DFn)(unsigned, GLint, unsigned, GLsizei, GLsizei, GLint, GLsizei, const void *);
typedef void (*TexSubImage2DFn)(unsigned, GLint, GLint, GLint, GLsizei, GLsizei, unsigned, unsigned, const void *);
typedef void (*BindTextureFn)(unsigned, GLuint);
typedef void (*ActiveTextureFn)(unsigned);
typedef void (*DeleteTexturesFn)(GLsizei, const GLuint *);
typedef void (*TexParameteriFn)(unsigned, unsigned, GLint);
typedef void (*TexParameterfFn)(unsigned, unsigned, float);
typedef void (*GenerateMipmapFn)(unsigned);
typedef void (*FramebufferTexture2DFn)(unsigned, unsigned, unsigned, GLuint, GLint);
typedef void (*CopyTexSubImage2DFn)(unsigned, GLint, GLint, GLint, GLint, GLint, GLsizei, GLsizei);
typedef void (*GetTexParameterivFn)(unsigned, unsigned, GLint *);
typedef const unsigned char *(*GetStringFn)(unsigned);

static int g_astcMin = -1; static unsigned g_astcBlock = 4; static float g_astcQuality = 10.0f; static int g_astcSupported = -1;
static unsigned g_unit; static GLuint g_bound2D[32];
static NSMutableSet<NSNumber *> *g_astcTex;
static double g_astcSavedMB, g_astcTime; static int g_astcCount, g_astcSkipLog, g_astcDropLog;


// ---- persistent ASTC cache: compressed blobs keyed by a 128-bit hash of the source pixels (+ format/block/quality). Skips the ~50 ms/texture encode on every launch after the first.
static int g_astcCacheOn = -1; static NSString *g_astcCacheDir; static dispatch_queue_t g_astcWriteQ;
static int g_astcHits, g_astcMisses; static double g_astcReadTime, g_astcHashTime;
static void hash128(const uint8_t *p, size_t n, uint64_t seed, uint64_t out[2]) {
    uint64_t h1 = seed ^ 0x9E3779B97F4A7C15ULL, h2 = (seed + 0xC2B2AE3D27D4EB4FULL) * 0x165667B19E3779F9ULL; size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        uint64_t a, b; memcpy(&a, p + i, 8); memcpy(&b, p + i + 8, 8);
        h1 = (h1 ^ a) * 0x9FB21C651E98DF25ULL; h1 ^= h1 >> 29; h1 += b;
        h2 = (h2 ^ b) * 0xC2B2AE3D27D4EB4FULL; h2 ^= h2 >> 32; h2 += a * 0x165667B19E3779F9ULL;
    }
    uint64_t tail = 0; for (; i < n; i++) tail = (tail << 8) | p[i];
    h1 ^= tail; h2 += tail * 0x9FB21C651E98DF25ULL; h1 ^= (uint64_t)n; h2 ^= (uint64_t)n << 1;
    h1 ^= h1 >> 32; h1 *= 0xD6E8FEB86659FD93ULL; h1 ^= h1 >> 32; h2 ^= h2 >> 29; h2 *= 0x94D049BB133111EBULL; h2 ^= h2 >> 32;
    out[0] = h1 ^ (h2 >> 7); out[1] = h2 ^ (h1 << 5);
}
typedef struct { char magic[4]; uint32_t w, h, block, len; } AstcCacheHeader;
static void astc_cache_init(void) {
    if (g_astcCacheOn >= 0) return;
    const char *off = getenv("ZOMIOS_ASTC_CACHE"); const char *dir = getenv("ZOMIOS_CACHE_DIR");
    g_astcCacheOn = !(off && atoi(off) == 0) && dir != NULL;
    if (g_astcCacheOn) {
        g_astcCacheDir = [NSString stringWithUTF8String:dir];
        [[NSFileManager defaultManager] createDirectoryAtPath:g_astcCacheDir withIntermediateDirectories:YES attributes:nil error:nil];
        g_astcWriteQ = dispatch_queue_create("zomios.astc.cache.write", DISPATCH_QUEUE_SERIAL);
    }
    fprintf(stderr, "[glshim] ASTC disk cache %s%s%s\n", g_astcCacheOn ? "ON: " : "OFF", g_astcCacheOn ? dir : "", g_astcCacheOn ? "" : (dir ? " (disabled)" : " (no cache dir)"));
}
static NSString *astc_cache_path(const uint64_t key[2], unsigned block) { return [g_astcCacheDir stringByAppendingFormat:@"/%016llx%016llx_%u.astc", (unsigned long long)key[0], (unsigned long long)key[1], block]; }
static BOOL astc_cache_read(const uint64_t key[2], unsigned w, unsigned h, unsigned block, size_t len, uint8_t *out) {
    FILE *f = fopen(astc_cache_path(key, block).fileSystemRepresentation, "rb"); if (!f) return NO;
    AstcCacheHeader hd; BOOL ok = fread(&hd, sizeof hd, 1, f) == 1 && memcmp(hd.magic, "ZAS1", 4) == 0 && hd.w == w && hd.h == h && hd.block == block && hd.len == len && fread(out, 1, len, f) == len;
    fclose(f); return ok;
}
static void astc_cache_write_async(const uint64_t key[2], unsigned w, unsigned h, unsigned block, const uint8_t *blob, size_t len) {
    NSData *d = [NSData dataWithBytes:blob length:len]; NSString *path = astc_cache_path(key, block);
    dispatch_async(g_astcWriteQ, ^{
        NSString *tmp = [path stringByAppendingString:@".tmp"]; FILE *f = fopen(tmp.fileSystemRepresentation, "wb"); if (!f) return;
        AstcCacheHeader hd = {{'Z', 'A', 'S', '1'}, w, h, block, (uint32_t)len};
        BOOL ok = fwrite(&hd, sizeof hd, 1, f) == 1 && fwrite(d.bytes, 1, len, f) == len; fclose(f);
        if (ok) rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation); else unlink(tmp.fileSystemRepresentation);
    });
}

static void astc_init(void) {
    if (g_astcMin >= 0) return;
    const char *e = getenv("ZOMIOS_ASTC"); g_astcMin = e ? atoi(e) : 0;
    const char *b = getenv("ZOMIOS_ASTC_BLOCK"); if (b) { int v = atoi(b); if (v == 4 || v == 5 || v == 6 || v == 8) g_astcBlock = (unsigned)v; }
    const char *q = getenv("ZOMIOS_ASTC_QUALITY"); if (q) g_astcQuality = (float)atof(q);
    g_astcTex = [NSMutableSet set];
    if (g_astcMin > 0) astc_cache_init();
    if (g_astcMin > 0) fprintf(stderr, "[glshim] ASTC compression enabled: min dimension %d, block %ux%u, quality %.0f\n", g_astcMin, g_astcBlock, g_astcBlock, g_astcQuality);
}
static BOOL astc_in_set(GLuint t) { if (!t || g_astcMin <= 0) return NO; ensure_state(); [g_lock lock]; BOOL r = [g_astcTex containsObject:@(t)]; [g_lock unlock]; return r; }
static BOOL astc_supported(void) {
    if (g_astcSupported >= 0) return g_astcSupported;
    ESFN(GetStringFn, glGetString);
    const char *ext = (const char *)glGetString(0x1F03);
    g_astcSupported = ext && strstr(ext, "GL_KHR_texture_compression_astc_ldr") != NULL;
    fprintf(stderr, "[glshim] ASTC LDR texture compression %s by the driver\n", g_astcSupported ? "ADVERTISED" : "NOT advertised");
    return g_astcSupported;
}
static unsigned astc_enum(unsigned block) { return block == 4 ? 0x93B0 : block == 5 ? 0x93B2 : block == 6 ? 0x93B4 : 0x93B7; }

static void es_glActiveTexture(unsigned unit) { ESFN(ActiveTextureFn, glActiveTexture); glActiveTexture(unit); if (unit >= 0x84C0 && unit < 0x84C0 + 32) g_unit = unit - 0x84C0; }
static void es_glBindTexture(unsigned target, GLuint tex) { ESFN(BindTextureFn, glBindTexture); glBindTexture(target, tex); if (target == 0x0DE1) g_bound2D[g_unit] = tex; }
static void gpu_forget(GLuint tex); static int g_gpuOn;
static void es_glDeleteTextures(GLsizei n, const GLuint *ids) {
    ESFN(DeleteTexturesFn, glDeleteTextures);
    if (g_astcTex && n > 0 && ids) { ensure_state(); [g_lock lock]; for (GLsizei i = 0; i < n; i++) [g_astcTex removeObject:@(ids[i])]; [g_lock unlock]; }
    if (g_gpuOn > 0 && n > 0 && ids) { [g_lock lock]; for (GLsizei i = 0; i < n; i++) gpu_forget(ids[i]); [g_lock unlock]; }
    glDeleteTextures(n, ids);
}
static void es_glTexImage2D_impl(unsigned target, GLint level, GLint ifmt, GLsizei w, GLsizei h, GLint border, unsigned format, unsigned type, const void *px) {
    ESFN(TexImage2DFn, glTexImage2D); astc_init();
    GLuint tex = g_bound2D[g_unit];
    if (g_astcMin > 0 && target == 0x0DE1 && tex) {
        BOOL isC = astc_in_set(tex);
        if (isC && level > 0) { if (g_astcDropLog++ < 5) fprintf(stderr, "[glshim] ASTC: dropped mip level %d upload for compressed texture %u\n", level, tex); return; }
        if (isC && level == 0) { [g_lock lock]; [g_astcTex removeObject:@(tex)]; [g_lock unlock]; }   // redefined: starts over
        BOOL big = w >= g_astcMin && h >= g_astcMin;
        BOOL fmtOK = (format == 0x1908 || format == 0x80E1) && (ifmt == 0x1908 || ifmt == 0x8058 || ifmt == 0x80E1) && type == 0x1401;
        if (level == 0 && big && px && border == 0 && fmtOK && astc_supported()) {
            static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
            double t0 = (double)mach_absolute_time();
            size_t len = zo_astc_size((unsigned)w, (unsigned)h, g_astcBlock);
            uint8_t *out = malloc(len);
            uint64_t key[2] = {0, 0}; BOOL cached = NO, ok = NO;
            if (out && g_astcCacheOn) {
                double h0 = (double)mach_absolute_time();
                hash128((const uint8_t *)px, (size_t)w * h * 4, ((uint64_t)g_astcBlock << 40) ^ ((uint64_t)(g_astcQuality * 16) << 16) ^ (format == 0x80E1) ^ 0x5A5A0001ULL, key);
                g_astcHashTime += ((double)mach_absolute_time() - h0) * tb.numer / tb.denom / 1e9;
                double r0 = (double)mach_absolute_time();
                cached = astc_cache_read(key, (unsigned)w, (unsigned)h, g_astcBlock, len, out);
                g_astcReadTime += ((double)mach_absolute_time() - r0) * tb.numer / tb.denom / 1e9;
            }
            if (cached) { ok = YES; g_astcHits++; }
            else if (out) { ok = zo_astc_compress((const uint8_t *)px, (unsigned)w, (unsigned)h, format == 0x80E1, g_astcBlock, g_astcQuality, out); if (ok) { g_astcMisses++; if (g_astcCacheOn) astc_cache_write_async(key, (unsigned)w, (unsigned)h, g_astcBlock, out, len); } }
            if (out && ok) {
                double ms = ((double)mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
                ESFN(CompressedTexImage2DFn, glCompressedTexImage2D); ESFN(GetTexParameterivFn, glGetTexParameteriv); ESFN(TexParameteriFn, glTexParameteri);
                glCompressedTexImage2D(target, 0, astc_enum(g_astcBlock), w, h, 0, (GLsizei)len, out);
                GLint mf = 0; glGetTexParameteriv(target, 0x2801, &mf);
                if (mf >= 0x2700 && mf <= 0x2703) glTexParameteri(target, 0x2801, (mf == 0x2700 || mf == 0x2702) ? 0x2600 : 0x2601);   // no mip chain exists
                [g_lock lock]; [g_astcTex addObject:@(tex)]; [g_lock unlock];
                double rawMB = (double)w * h * 4 / 1048576.0, newMB = (double)len / 1048576.0;
                g_astcSavedMB += rawMB - newMB; if (!cached) g_astcTime += ms / 1000.0; g_astcCount++;
                if (g_astcCount <= 8 || g_astcCount % 100 == 0)
                    fprintf(stderr, "[glshim] ASTC #%d tex %u: %dx%d %s %.2f -> %.2f MB in %.0f ms (%s) | %d cached, %d encoded, saved %.0f MB, encode %.1f s, hash %.1f s, cache read %.1f s\n", g_astcCount, tex, w, h, format == 0x80E1 ? "BGRA" : "RGBA", rawMB, newMB, ms, cached ? "cache hit" : "encoded", g_astcHits, g_astcMisses, g_astcSavedMB, g_astcTime, g_astcHashTime, g_astcReadTime);
                free(out); return;
            }
            free(out);
        } else if (big && level == 0 && g_astcSkipLog < 16) {
            g_astcSkipLog++;
            fprintf(stderr, "[glshim] ASTC skip tex %u: %dx%d ifmt=0x%x fmt=0x%x type=0x%x data=%s border=%d\n", tex, w, h, ifmt, format, type, px ? "yes" : "none(render target?)", border);
        }
    }
    glTexImage2D(target, level, ifmt, w, h, border, format, type, px);
}
// ---- GPU memory accounting (ZOMIOS_GPULOG=1): what the game's textures add up to, split into uploaded data, ASTC-compressed, and textures made without
// data (render targets and storage that is filled later). Printed every 15 s with the most common render target sizes.
static NSMutableDictionary<NSNumber *, NSNumber *> *g_gpuBytes, *g_gpuKind; static double g_gpuTot[3]; static int g_gpuCnt[3], g_gpuOn = -1; static double g_gpuLast;
static struct { int w, h, n; } g_rtHist[64]; static int g_rtHistN;
static struct { int w, h, n; } g_upHist[128]; static int g_upHistN;      // sizes of textures uploaded with data (created, not live)
static void gpu_forget(GLuint tex) {      // caller holds g_lock
    NSNumber *b = g_gpuBytes[@(tex)]; if (!b) return; int k = [g_gpuKind[@(tex)] intValue];
    g_gpuTot[k] -= b.doubleValue; g_gpuCnt[k]--; [g_gpuBytes removeObjectForKey:@(tex)]; [g_gpuKind removeObjectForKey:@(tex)];
}
static void gpu_account(GLuint tex, GLint level, GLsizei w, GLsizei h, const void *px) {
    if (g_gpuOn < 0) { const char *e = getenv("ZOMIOS_GPULOG"); g_gpuOn = e && atoi(e) > 0; }
    if (!g_gpuOn || !tex) return;
    BOOL isC = astc_in_set(tex);      // takes g_lock itself, so ask before holding it
    ensure_state(); [g_lock lock];
    if (!g_gpuBytes) { g_gpuBytes = [NSMutableDictionary new]; g_gpuKind = [NSMutableDictionary new]; }
    if (level == 0) {
        gpu_forget(tex);
        int k = isC ? 1 : (px ? 0 : 2); double b = isC ? (double)zo_astc_size((unsigned)w, (unsigned)h, g_astcBlock) : (double)w * h * 4;
        g_gpuBytes[@(tex)] = @(b); g_gpuKind[@(tex)] = @(k); g_gpuTot[k] += b; g_gpuCnt[k]++;
        if (k == 0) { int i = 0; for (; i < g_upHistN; i++) if (g_upHist[i].w == w && g_upHist[i].h == h) break; if (i == g_upHistN && g_upHistN < 128) g_upHistN++; if (i < 128) { g_upHist[i].w = w; g_upHist[i].h = h; g_upHist[i].n++; } }
        if (k == 2) { int i = 0; for (; i < g_rtHistN; i++) if (g_rtHist[i].w == w && g_rtHist[i].h == h) break; if (i == g_rtHistN && g_rtHistN < 64) g_rtHistN++; if (i < 64) { g_rtHist[i].w = w; g_rtHist[i].h = h; g_rtHist[i].n++; } }
    } else if (!isC && g_gpuBytes[@(tex)]) { double b = (double)w * h * 4; int k = [g_gpuKind[@(tex)] intValue]; g_gpuBytes[@(tex)] = @([g_gpuBytes[@(tex)] doubleValue] + b); g_gpuTot[k] += b; }
    double now = (double)mach_absolute_time(); static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    double sec = now * tb.numer / tb.denom / 1e9;
    if (sec - g_gpuLast > 15) {
        g_gpuLast = sec; char line[1400]; int n = snprintf(line, sizeof line, "[glshim] GPU textures: uploaded data %.0f MB (%d), ASTC %.0f MB (%d), no-data/render targets %.0f MB (%d) | no-data sizes:",
            g_gpuTot[0] / 1048576, g_gpuCnt[0], g_gpuTot[1] / 1048576, g_gpuCnt[1], g_gpuTot[2] / 1048576, g_gpuCnt[2]);
        int used[64] = {0};
        for (int t = 0; t < 6; t++) { int best = -1; double bv = 0; for (int i = 0; i < g_rtHistN; i++) { double v = (double)g_rtHist[i].w * g_rtHist[i].h * g_rtHist[i].n; if (!used[i] && v > bv) { bv = v; best = i; } }
            if (best < 0) break; used[best] = 1; n += snprintf(line + n, sizeof line - n, " %dx%d(%d created)", g_rtHist[best].w, g_rtHist[best].h, g_rtHist[best].n); }
        n += snprintf(line + n, sizeof line - n, " | uploaded sizes by total bytes:");
        int used2[128] = {0};
        for (int t = 0; t < 8; t++) { int best = -1; double bv = 0; for (int i = 0; i < g_upHistN; i++) { double v = (double)g_upHist[i].w * g_upHist[i].h * g_upHist[i].n; if (!used2[i] && v > bv) { bv = v; best = i; } }
            if (best < 0) break; used2[best] = 1; n += snprintf(line + n, sizeof line - n, " %dx%d(%d, %.0f MB)", g_upHist[best].w, g_upHist[best].h, g_upHist[best].n, bv * 4 / 1048576); }
        fprintf(stderr, "%s\n", line);
    }
    [g_lock unlock];
}
static void es_glTexImage2D(unsigned target, GLint level, GLint ifmt, GLsizei w, GLsizei h, GLint border, unsigned format, unsigned type, const void *px) {
    es_glTexImage2D_impl(target, level, ifmt, w, h, border, format, type, px);
    if (target == 0x0DE1) gpu_account(g_bound2D[g_unit], level, w, h, px);
}
static void es_glTexSubImage2D(unsigned target, GLint level, GLint x, GLint y, GLsizei w, GLsizei h, unsigned format, unsigned type, const void *px) {
    ESFN(TexSubImage2DFn, glTexSubImage2D);
    if (target == 0x0DE1 && astc_in_set(g_bound2D[g_unit])) { if (g_astcDropLog++ < 8) fprintf(stderr, "[glshim] ASTC: DROPPED glTexSubImage2D on compressed texture %u (%dx%d at %d,%d) -- this texture is updated in place\n", g_bound2D[g_unit], w, h, x, y); return; }
    glTexSubImage2D(target, level, x, y, w, h, format, type, px);
}
static void es_glCopyTexSubImage2D(unsigned target, GLint level, GLint xo, GLint yo, GLint x, GLint y, GLsizei w, GLsizei h) {
    ESFN(CopyTexSubImage2DFn, glCopyTexSubImage2D);
    if (target == 0x0DE1 && astc_in_set(g_bound2D[g_unit])) { if (g_astcDropLog++ < 8) fprintf(stderr, "[glshim] ASTC: DROPPED glCopyTexSubImage2D on compressed texture %u\n", g_bound2D[g_unit]); return; }
    glCopyTexSubImage2D(target, level, xo, yo, x, y, w, h);
}
static void es_glGenerateMipmap(unsigned target) {
    ESFN(GenerateMipmapFn, glGenerateMipmap);
    if (target == 0x0DE1 && astc_in_set(g_bound2D[g_unit])) { if (g_astcDropLog++ < 8) fprintf(stderr, "[glshim] ASTC: skipped glGenerateMipmap on compressed texture %u\n", g_bound2D[g_unit]); return; }
    glGenerateMipmap(target);
}
static void es_glFramebufferTexture2D(unsigned target, unsigned attachment, unsigned textarget, GLuint texture, GLint level) {
    ESFN(FramebufferTexture2DFn, glFramebufferTexture2D);
    if (astc_in_set(texture)) fprintf(stderr, "[glshim] ASTC: WARNING compressed texture %u attached to a framebuffer (render target)\n", texture);
    glFramebufferTexture2D(target, attachment, textarget, texture, level);
}
static void es_glTexParameteri(unsigned target, unsigned pname, GLint param) {
    ESFN(TexParameteriFn, glTexParameteri);
    if (target == 0x0DE1 && pname == 0x2801 && param >= 0x2700 && param <= 0x2703 && astc_in_set(g_bound2D[g_unit])) param = (param == 0x2700 || param == 0x2702) ? 0x2600 : 0x2601;
    glTexParameteri(target, pname, param);
}
static void es_glTexParameterf(unsigned target, unsigned pname, float param) {
    ESFN(TexParameterfFn, glTexParameterf);
    int ip = (int)param;
    if (target == 0x0DE1 && pname == 0x2801 && ip >= 0x2700 && ip <= 0x2703 && astc_in_set(g_bound2D[g_unit])) param = (ip == 0x2700 || ip == 0x2702) ? 0x2600 : 0x2601;
    glTexParameterf(target, pname, param);
}

static void *shim_gles_proc(const char *name) {
    if (name && strcmp(name, "glShaderSource") == 0) return (void *)es_glShaderSource;
    if (name && strcmp(name, "glTexImage2D") == 0) return (void *)es_glTexImage2D;
    if (name && strcmp(name, "glTexSubImage2D") == 0) return (void *)es_glTexSubImage2D;
    if (name && strcmp(name, "glCopyTexSubImage2D") == 0) return (void *)es_glCopyTexSubImage2D;
    if (name && strcmp(name, "glBindTexture") == 0) return (void *)es_glBindTexture;
    if (name && strcmp(name, "glActiveTexture") == 0) return (void *)es_glActiveTexture;
    if (name && strcmp(name, "glDeleteTextures") == 0) return (void *)es_glDeleteTextures;
    if (name && strcmp(name, "glGenerateMipmap") == 0) return (void *)es_glGenerateMipmap;
    if (name && strcmp(name, "glFramebufferTexture2D") == 0) return (void *)es_glFramebufferTexture2D;
    if (name && strcmp(name, "glTexParameteri") == 0) return (void *)es_glTexParameteri;
    if (name && strcmp(name, "glTexParameterf") == 0) return (void *)es_glTexParameterf;
    if (name && strcmp(name, "glUseProgram") == 0) return (void *)es_glUseProgram;
    if (name && strcmp(name, "glDrawElements") == 0) return (void *)es_glDrawElements;
    if (name && strcmp(name, "glDrawArrays") == 0) return (void *)es_glDrawArrays;
    if (name && strcmp(name, "glUniformMatrix4fv") == 0) return (void *)es_glUniformMatrix4fv;
    return angle_proc(name);
}
__attribute__((constructor)) static void shim_init(void) { set_getprocaddress(shim_gles_proc); }


typedef void (*GetUniformfvFn)(GLuint, GLint, float *);
typedef void (*UseProgramFn2)(GLuint);
static void shim_glUseProgram(GLuint program) {
    GLFN(UseProgramFn2, glUseProgram); GLFN(GetUniformfvFn, glGetUniformfv); GLFN(GetUniformLocationFn, glGetUniformLocation);
    glUseProgram(program);
    g_apiProgram = program;
    if (!shader_log_enabled() || !program) return;
    static int logged;
    ensure_state();
    [g_lock lock]; BOOL sk = [g_skinnedPrograms containsObject:@(program)]; [g_lock unlock];
    if (sk && logged < 6) {
        logged++;
        float fs = -1, uv[2] = {-1, -1}, td = -1, hm = -1;
        GLint l;
        if ((l = glGetUniformLocation(program, "FinalScale")) >= 0) glGetUniformfv(program, l, &fs);
        if ((l = glGetUniformLocation(program, "UVScale")) >= 0) glGetUniformfv(program, l, uv);
        if ((l = glGetUniformLocation(program, "targetDepth")) >= 0) glGetUniformfv(program, l, &td);
        if ((l = glGetUniformLocation(program, "HighResDepthMultiplier")) >= 0) glGetUniformfv(program, l, &hm);
        fprintf(stderr, "[glshim] USE skinned program %u: FinalScale=%g UVScale=(%g,%g) targetDepth=%g HighResDepthMultiplier=%g\n", program, fs, uv[0], uv[1], td, hm);
    }
}

__attribute__((visibility("default"), used))
void *eglGetProcAddress(const char *name) {
    if (name) {
        if (strcmp(name, "glShaderSource") == 0 || strcmp(name, "glShaderSourceARB") == 0) return (void *)shim_glShaderSource;
        if (strcmp(name, "glAttachShader") == 0) return (void *)shim_glAttachShader;
        if (strcmp(name, "glDetachShader") == 0) return (void *)shim_glDetachShader;
        if (strcmp(name, "glCreateShader") == 0) return (void *)shim_glCreateShader;
        if (strcmp(name, "glCompileShader") == 0) return (void *)shim_glCompileShader;
        if (strcmp(name, "glGetShaderiv") == 0) return (void *)shim_glGetShaderiv;
        if (strcmp(name, "glGetShaderInfoLog") == 0) return (void *)shim_glGetShaderInfoLog;
        if (strcmp(name, "glLinkProgram") == 0) return (void *)shim_glLinkProgram;
        if (strcmp(name, "glUseProgram") == 0) return (void *)shim_glUseProgram;
        if (strcmp(name, "glGetUniformLocation") == 0) return (void *)shim_glGetUniformLocation;
        if (strcmp(name, "glUniformMatrix4fv") == 0) return (void *)shim_glUniformMatrix4fv;
    }
    return gl4es_GetProcAddress(name);
}
