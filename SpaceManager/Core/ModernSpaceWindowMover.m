//
//  ModernSpaceWindowMover.m
//  SpaceManager
//
//  Uses the bridged SkyLight operation required by current macOS releases.
//  Mach-O symbol lookup adapted from yabai (MIT License).
//

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static const char *kSkyLightPath =
    "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
static const char *kPerformOperationSymbol =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";

typedef int64_t (*SMPerformWindowOperation)(void *operation);

static struct mach_header_64 *SMFindImageHeader(const char *targetPath, intptr_t *slide) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *imagePath = _dyld_get_image_name(index);
        if (imagePath && strcmp(imagePath, targetPath) == 0) {
            *slide = _dyld_get_image_vmaddr_slide(index);
            return (struct mach_header_64 *)_dyld_get_image_header(index);
        }
    }
    return NULL;
}

static struct segment_command_64 *SMFindLinkeditSegment(struct mach_header_64 *header) {
    uintptr_t offset = sizeof(struct mach_header_64);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        struct load_command *command = (struct load_command *)((uint8_t *)header + offset);
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                return segment;
            }
        }
        offset += command->cmdsize;
    }
    return NULL;
}

static struct symtab_command *SMFindSymbolTable(struct mach_header_64 *header) {
    uintptr_t offset = sizeof(struct mach_header_64);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        struct load_command *command = (struct load_command *)((uint8_t *)header + offset);
        if (command->cmd == LC_SYMTAB) {
            return (struct symtab_command *)command;
        }
        offset += command->cmdsize;
    }
    return NULL;
}

static void *SMFindSkyLightSymbol(const char *symbol) {
    intptr_t slide = 0;
    struct mach_header_64 *header = SMFindImageHeader(kSkyLightPath, &slide);
    if (!header) return NULL;

    struct segment_command_64 *linkedit = SMFindLinkeditSegment(header);
    struct symtab_command *symtab = SMFindSymbolTable(header);
    if (!linkedit || !symtab) return NULL;

    uintptr_t linkeditBase = (uintptr_t)(linkedit->vmaddr - linkedit->fileoff) + slide;
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const struct nlist_64 *symbols =
        (const struct nlist_64 *)(linkeditBase + symtab->symoff);

    for (uint32_t index = 0; index < symtab->nsyms; index++) {
        const char *name = strings + symbols[index].n_un.n_strx;
        if (strcmp(name, symbol) == 0) {
            return (void *)(symbols[index].n_value + slide);
        }
    }
    return NULL;
}

int SMMoveWindowsToManagedSpaceModern(CFArrayRef windowIDs, uint64_t spaceID) {
    static SMPerformWindowOperation performOperation = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        performOperation = (SMPerformWindowOperation)SMFindSkyLightSymbol(kPerformOperationSymbol);
    });

    if (!performOperation) return 0;

    Class operationClass = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    if (!operationClass) return 0;

    SEL allocate = sel_registerName("alloc");
    SEL initialize = sel_registerName("initWithWindows:spaceID:");
    id allocated = ((id (*)(id, SEL))objc_msgSend)(operationClass, allocate);
    id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(
        allocated,
        initialize,
        (__bridge id)windowIDs,
        spaceID);
    if (!operation) return 0;

    performOperation((__bridge void *)operation);
    return 1;
}
