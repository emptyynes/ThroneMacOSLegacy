/* Compatibility shim for running the Qt 6.4 Throne build on macOS 10.13.
 *
 * Qt 6.4 is built against a 10.14 floor: it references a handful of AppKit/Security
 * symbols and selectors that simply do not exist on High Sierra. This dylib supplies
 * them, implemented on top of the APIs 10.13 does have, and is injected into the GUI
 * process (never into the setuid core - macOS strips DYLD_* for those).
 *
 * Build with compat/build-shim.sh.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <Security/Security.h>
#include <spawn.h>
#include <stdlib.h>

#pragma mark - Missing symbols (bound with two-level namespace, hence flat-namespace injection)

/* QtCore: dark-mode appearance name, AppKit 10.14. */
NSString *const NSAppearanceNameDarkAqua = @"NSAppearanceNameDarkAqua";

/* QtCore: libsystem_secinit, 10.14+. A no-op preserves 10.13 posix_spawn semantics. */
void responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim) {
    (void)attrs;
    (void)disclaim;
}

/* Apple clang stack probe (libSystem 10.15+). Called with the frame size in %rax;
 * walks the pages below %rsp so oversized frames hit the guard page instead of
 * skipping over it. Note the four-underscore Mach-O name: __asm__() takes the
 * assembler symbol literally, without adding the C underscore. */
__attribute__((naked, used)) void chkstk_darwin_entry(void) __asm__("____chkstk_darwin");
void chkstk_darwin_entry(void) {
    __asm__ __volatile__("movq  %rax, %r11\n\t"
                         "negq  %r11\n\t"
                         "andq  $-4096, %r11\n\t"
                         "jz    2f\n\t"
                         "1:\n\t"
                         "cmpl  $0, (%rsp,%r11,1)\n\t"
                         "subq  $-4096, %r11\n\t"
                         "jle   1b\n\t"
                         "2:\n\t"
                         "ret\n\t");
}

/* libobjc helpers that dlsym cannot see on 10.13. */
id objc_alloc_init(Class cls) {
    return [[cls alloc] init];
}

BOOL objc_opt_respondsToSelector(id obj, SEL sel) {
    return obj ? [obj respondsToSelector:sel] : NO;
}

Class objc_opt_class(id obj) {
    return obj ? object_getClass(obj) : (Class)0;
}

BOOL objc_opt_isKindOfClass(id obj, Class cls) {
    return obj ? [obj isKindOfClass:cls] : NO;
}

/* C11 aligned_alloc, libSystem 10.15+. */
void *aligned_alloc(size_t alignment, size_t size) {
    void *p = NULL;
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) return NULL;
    if (posix_memalign(&p, alignment, size) != 0) return NULL;
    return p;
}

#pragma mark - Security 10.15 fallback

/* SecTrustCopyCertificateChain: rebuild the chain from the pre-10.15 accessors. */
CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust) {
    if (trust == NULL) return NULL;
    CFIndex count = SecTrustGetCertificateCount(trust);
    if (count <= 0) return NULL;
    CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, count,
                                                   &kCFTypeArrayCallBacks);
    if (chain == NULL) return NULL;
    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
        if (cert != NULL) CFArrayAppendValue(chain, cert);
    }
    return chain;
}

#pragma mark - AppKit 10.14 selectors

/* Dark-mode era semantic colours, mapped onto their closest 10.13 ancestors. */
@implementation NSColor (ThroneLegacy)
+ (NSColor *)selectedContentBackgroundColor {
    return [self alternateSelectedControlColor];
}
+ (NSColor *)unemphasizedSelectedContentBackgroundColor {
    return [self selectedTextBackgroundColor];
}
+ (NSColor *)unemphasizedSelectedTextBackgroundColor {
    return [self selectedTextBackgroundColor];
}
+ (NSColor *)unemphasizedSelectedTextColor {
    return [self selectedTextColor];
}
+ (NSColor *)separatorColor {
    return [self gridColor];
}
+ (NSColor *)controlAccentColor {
    return [self systemBlueColor];
}
+ (NSArray *)alternatingContentBackgroundColors {
    return [NSArray arrayWithObjects:[self controlBackgroundColor],
                                     [self windowBackgroundColor], nil];
}
@end

/* -effectiveAppearance (10.14): report the current appearance, which on 10.13 is Aqua. */
@implementation NSApplication (ThroneLegacy)
- (NSAppearance *)effectiveAppearance {
    return [NSAppearance currentAppearance];
}
@end

@implementation NSWindow (ThroneLegacy)
- (NSAppearance *)effectiveAppearance {
    return [NSAppearance currentAppearance];
}
@end

@implementation NSView (ThroneLegacy)
- (NSAppearance *)effectiveAppearance {
    return [NSAppearance currentAppearance];
}
@end

/* -bestMatchFromAppearancesWithNames: (10.14). High Sierra only has Aqua, and Qt uses
 * the result to decide between light and dark palettes. */
@implementation NSAppearance (ThroneLegacy)
- (NSAppearanceName)bestMatchFromAppearancesWithNames:(NSArray *)names {
    if ([names containsObject:NSAppearanceNameAqua]) return NSAppearanceNameAqua;
    return [names count] ? [names objectAtIndex:0] : nil;
}
@end
