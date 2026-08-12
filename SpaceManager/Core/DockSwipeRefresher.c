//
//  DockSwipeRefresher.c
//  SpaceManager
//
//  Forces a real Dock-managed Space transition after Mission Control's
//  accessibility hierarchy has selected a desktop. On macOS 15 and later,
//  WindowServer can update the active Space without the Dock publishing the
//  notification that repaints the compositor. The result is the exact visual
//  corruption this app must avoid: windows from two Spaces and duplicate menu
//  bar items remain visible until the user starts a trackpad Space swipe.
//
//  There is no public API for that Dock notification. These undocumented event
//  fields follow the implementation in joshuarli/iss. macOS 27 additionally
//  validates a serialized IOHID payload in field 4205, so ordinary synthetic
//  Dock-swipe events are silently discarded there. A complete switch followed
//  by the inverse switch fires the Dock pipeline while returning to the target
//  Space. The pointer is temporarily placed on the target display because Dock
//  routes the gesture to the display under the pointer.
//

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <float.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static const CGEventField kSMEventTypeField = 55;
static const CGEventField kSMGestureHIDType = 110;
static const CGEventField kSMGestureSwipeMask = 115;
static const CGEventField kSMGestureScrollY = 119;
static const CGEventField kSMGestureSwipeMotion = 123;
static const CGEventField kSMGestureSwipeProgress = 124;
static const CGEventField kSMGestureSwipePositionX = 125;
static const CGEventField kSMGestureSwipePositionY = 126;
static const CGEventField kSMGestureSwipeVelocityX = 129;
static const CGEventField kSMGestureSwipeVelocityY = 130;
static const CGEventField kSMGesturePhase = 132;
static const CGEventField kSMGesturePhaseAlias = 134;
static const CGEventField kSMScrollGestureFlagBits = 135;
static const CGEventField kSMGestureZoomDeltaY = 138;
static const CGEventField kSMGestureZoomDeltaX = 139;
static const CGEventField kSMSourceProcessAlias = 169;
static const uint16_t kSMRawIOHIDPayload = 4205;

enum { kSMEventGesture = 29, kSMEventDockControl = 30 };
enum { kSMIOHIDEventTypeDockSwipe = 23 };
enum { kSMGestureMotionHorizontal = 1 };
enum { kSMGestureBegan = 1, kSMGestureChanged = 2, kSMGestureEnded = 4 };

#pragma pack(push, 1)
typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} SMIOHIDEventBase;

typedef struct {
    SMIOHIDEventBase base;
    int32_t positionX;
    int32_t positionY;
    int32_t positionZ;
    uint32_t swipeMask;
    uint16_t gestureMotion;
    uint16_t gestureFlavor;
    int32_t swipeProgress;
} SMIOHIDFluidTouchGestureData;

typedef struct {
    SMIOHIDEventBase base;
    int32_t velocityX;
    int32_t velocityY;
    int32_t velocityZ;
} SMIOHIDVelocityEventData;

typedef struct {
    uint64_t timestamp;
    uint64_t senderID;
    uint32_t options;
    uint32_t attributeLength;
    uint32_t eventCount;
} SMIOHIDSystemQueueElementHeader;
#pragma pack(pop)

_Static_assert(sizeof(SMIOHIDEventBase) == 16, "Unexpected IOHID base layout");
_Static_assert(sizeof(SMIOHIDFluidTouchGestureData) == 40, "Unexpected IOHID gesture layout");
_Static_assert(sizeof(SMIOHIDVelocityEventData) == 28, "Unexpected IOHID velocity layout");
_Static_assert(sizeof(SMIOHIDSystemQueueElementHeader) == 28, "Unexpected IOHID queue layout");

static int32_t SMFixed1616(double value) {
    int32_t fixed = (int32_t)(value * 65536.0);
    if (fixed == 0 && value != 0.0) return value > 0.0 ? 1 : -1;
    return fixed;
}

static bool SMRequiresAugmentation(void) {
    char version[32] = {0};
    size_t size = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) != 0) return false;
    return strtol(version, NULL, 10) >= 27;
}

static uint8_t *SMGenerateIOHIDPayload(CGEventRef event, size_t *outLength) {
    int64_t phase = CGEventGetIntegerValueField(event, kSMGesturePhase);
    double velocityX = CGEventGetDoubleValueField(event, kSMGestureSwipeVelocityX);
    double velocityY = CGEventGetDoubleValueField(event, kSMGestureSwipeVelocityY);
    bool includeVelocity = velocityX != 0.0 || velocityY != 0.0 || phase == kSMGestureEnded;
    size_t length = sizeof(SMIOHIDSystemQueueElementHeader)
                  + sizeof(SMIOHIDFluidTouchGestureData)
                  + (includeVelocity ? sizeof(SMIOHIDVelocityEventData) : 0);
    uint8_t *payload = calloc(1, length);
    if (!payload) return NULL;

    SMIOHIDSystemQueueElementHeader *header = (SMIOHIDSystemQueueElementHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp ? timestamp : mach_absolute_time();
    header->eventCount = includeVelocity ? 2 : 1;

    SMIOHIDFluidTouchGestureData *fluid = (SMIOHIDFluidTouchGestureData *)(
        payload + sizeof(SMIOHIDSystemQueueElementHeader));
    fluid->base.size = sizeof(SMIOHIDFluidTouchGestureData);
    fluid->base.type = kSMIOHIDEventTypeDockSwipe;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->positionX = SMFixed1616(CGEventGetDoubleValueField(event, kSMGestureSwipePositionX));
    fluid->positionY = SMFixed1616(CGEventGetDoubleValueField(event, kSMGestureSwipePositionY));
    fluid->swipeMask = (uint32_t)CGEventGetIntegerValueField(event, kSMGestureSwipeMask);
    fluid->gestureMotion = (uint16_t)CGEventGetIntegerValueField(event, kSMGestureSwipeMotion);
    fluid->gestureFlavor = 3;
    fluid->swipeProgress = SMFixed1616(
        CGEventGetDoubleValueField(event, kSMGestureSwipeProgress));

    if (includeVelocity) {
        SMIOHIDVelocityEventData *velocity = (SMIOHIDVelocityEventData *)(
            payload + sizeof(SMIOHIDSystemQueueElementHeader)
                    + sizeof(SMIOHIDFluidTouchGestureData));
        velocity->base.size = sizeof(SMIOHIDVelocityEventData);
        velocity->base.type = 9;
        velocity->base.depth = 1;
        velocity->velocityX = SMFixed1616(velocityX);
        velocity->velocityY = SMFixed1616(velocityY);
    }

    *outLength = length;
    return payload;
}

static CGEventRef SMAugmentDockEvent(CGEventRef event) {
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) return NULL;
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex originalLength = CFDataGetLength(data);
    if (originalLength < 4 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != 2) {
        CFRelease(data);
        return NULL;
    }

    size_t payloadLength = 0;
    uint8_t *payload = SMGenerateIOHIDPayload(event, &payloadLength);
    if (!payload) {
        CFRelease(data);
        return NULL;
    }

    size_t newLength = (size_t)originalLength + 4 + payloadLength;
    uint8_t *newBytes = malloc(newLength);
    if (!newBytes) {
        free(payload);
        CFRelease(data);
        return NULL;
    }
    memcpy(newBytes, bytes, (size_t)originalLength);
    newBytes[originalLength] = (uint8_t)(payloadLength >> 8);
    newBytes[originalLength + 1] = (uint8_t)payloadLength;
    newBytes[originalLength + 2] = (uint8_t)(kSMRawIOHIDPayload >> 8);
    newBytes[originalLength + 3] = (uint8_t)kSMRawIOHIDPayload;
    memcpy(newBytes + originalLength + 4, payload, payloadLength);
    free(payload);
    CFRelease(data);

    CFDataRef augmentedData = CFDataCreate(kCFAllocatorDefault, newBytes, (CFIndex)newLength);
    free(newBytes);
    if (!augmentedData) return NULL;
    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, augmentedData);
    CFRelease(augmentedData);
    return result;
}

static CGEventRef SMMakeDockEvent(int phase, bool right, bool augmented) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NULL;
    CGEventSetIntegerValueField(event, kSMEventTypeField, kSMEventDockControl);
    CGEventSetIntegerValueField(event, kSMGestureHIDType, kSMIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(event, kSMGesturePhase, phase);
    CGEventSetIntegerValueField(event, kSMGestureSwipeMotion, kSMGestureMotionHorizontal);

    if (augmented) {
        CGEventSetDoubleValueField(event, kSMGestureSwipeProgress, right ? -1.0 : 1.0);
        CGEventSetIntegerValueField(event, kSMGesturePhaseAlias, phase);
        CGEventSetDoubleValueField(event, kSMGestureZoomDeltaY, 3.0);
        CGEventSetDoubleValueField(event, kSMSourceProcessAlias, (double)mach_absolute_time());
        CGEventSetDoubleValueField(event, kSMGestureSwipePositionX, 0.1);
        if (phase == kSMGestureEnded) {
            CGEventSetDoubleValueField(event, kSMGestureSwipeVelocityX, right ? -9999.0 : 9999.0);
        }
    } else {
        float direction = right ? FLT_TRUE_MIN : -FLT_TRUE_MIN;
        int32_t flagBits = 0;
        memcpy(&flagBits, &direction, sizeof(flagBits));
        CGEventSetIntegerValueField(event, kSMScrollGestureFlagBits, flagBits);
        CGEventSetDoubleValueField(event, kSMGestureScrollY, 0);
        CGEventSetDoubleValueField(event, kSMGestureZoomDeltaX, FLT_TRUE_MIN);
        if (phase == kSMGestureEnded) {
            CGEventSetDoubleValueField(event, kSMGestureSwipeVelocityX, right ? 400.0 : -400.0);
            CGEventSetDoubleValueField(event, kSMGestureSwipeVelocityY, 0);
        }
    }
    return event;
}

static bool SMPostPair(CGEventRef dockEvent) {
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) {
        CFRelease(dockEvent);
        return false;
    }
    CGEventSetIntegerValueField(companion, kSMEventTypeField, kSMEventGesture);
    CGEventPost(kCGSessionEventTap, dockEvent);
    CGEventPost(kCGSessionEventTap, companion);
    CFRelease(dockEvent);
    CFRelease(companion);
    return true;
}

static bool SMPostSwitch(bool right, bool augmented) {
    const int phases[] = { kSMGestureBegan, kSMGestureChanged, kSMGestureEnded };
    CGEventRef events[3] = { NULL, NULL, NULL };
    for (int index = 0; index < 3; index++) {
        CGEventRef event = SMMakeDockEvent(phases[index], right, augmented);
        if (!event) goto failure;
        if (augmented) {
            events[index] = SMAugmentDockEvent(event);
            CFRelease(event);
        } else {
            events[index] = event;
        }
        if (!events[index]) goto failure;
    }
    for (int index = 0; index < 3; index++) {
        if (!SMPostPair(events[index])) {
            events[index] = NULL;
            for (int remainder = index + 1; remainder < 3; remainder++) CFRelease(events[remainder]);
            return false;
        }
        events[index] = NULL;
    }
    return true;

failure:
    for (int index = 0; index < 3; index++) if (events[index]) CFRelease(events[index]);
    return false;
}

bool SMRefreshSpaceCompositor(CGDirectDisplayID displayID, bool firstSwitchRight) {
    if (!CGPreflightPostEventAccess()) return false;
    CGEventRef pointerEvent = CGEventCreate(NULL);
    if (!pointerEvent) return false;
    CGPoint originalLocation = CGEventGetLocation(pointerEvent);
    CFRelease(pointerEvent);

    CGRect bounds = CGDisplayBounds(displayID);
    if (CGRectIsEmpty(bounds)) return false;
    CGPoint displayCenter = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    if (CGWarpMouseCursorPosition(displayCenter) != kCGErrorSuccess) return false;
    usleep(40000);

    bool augmented = SMRequiresAugmentation();
    bool firstPosted = SMPostSwitch(firstSwitchRight, augmented);
    usleep(80000);
    bool secondPosted = firstPosted && SMPostSwitch(!firstSwitchRight, augmented);
    usleep(40000);
    CGWarpMouseCursorPosition(originalLocation);
    return firstPosted && secondPosted;
}
