#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <objc/message.h>
#import <unistd.h>

static const uint32_t PostureUsagePage = 0xff61;
static const uint32_t PostureUsage = 0x5b;

typedef CFTypeRef (*VendorEventFactory)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, const void *, CFIndex, uint32_t);

@interface PostureServiceDelegate : NSObject
@property(copy) NSDictionary *properties;
@end

@implementation PostureServiceDelegate
- (id)propertyForKey:(NSString *)key forService:(id)service {
  return self.properties[key];
}
- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service {
  return YES;
}
- (id)copyEventMatching:(id)matching forService:(id)service {
  return nil;
}
- (BOOL)setOutputEvent:(id)event forService:(id)service {
  return YES;
}
- (void)notification:(uint32_t)type withProperty:(id)property forService:(id)service {
}
@end

static void appendHeader(NSMutableData *data, uint32_t length, uint8_t type) {
  uint8_t bytes[] = {length & 0xff, (length >> 8) & 0xff, (length >> 16) & 0xff, type};
  [data appendBytes:bytes length:sizeof bytes];
}

static void appendText(NSMutableData *data, const char *text, BOOL isKey, BOOL isLast) {
  size_t length = strlen(text) + (isKey ? 1 : 0);
  appendHeader(data, (uint32_t)length, (isKey ? 0x08 : 0x09) | (isLast ? 0x80 : 0));
  [data appendBytes:text length:length];
  uint8_t zero = 0;
  while (data.length % 4) [data appendBytes:&zero length:1];
}

static NSMutableData *controlPayload(const char *source, const char *type) {
  NSMutableData *data = [NSMutableData data];
  appendHeader(data, 0xd3, 0);
  appendHeader(data, 4, 0x81);
  appendText(data, "provider", YES, NO);
  appendText(data, "com.apple.Virtualization.VirtualMachines", NO, NO);
  appendText(data, "source", YES, NO);
  appendText(data, source, NO, NO);
  appendText(data, "type", YES, NO);
  appendText(data, type, NO, NO);
  appendText(data, "value", YES, NO);
  return data;
}

static NSData *anglePayload(double degrees) {
  NSMutableData *data = controlPayload("hinge-slider-control", "range");
  appendHeader(data, 0x3f, 0x84);
  [data appendBytes:&degrees length:sizeof degrees];
  return data;
}

static NSData *orientationPayload(const char *value) {
  NSMutableData *data = controlPayload("orientation-picker-control", "enum");
  appendText(data, value, NO, YES);
  return data;
}

static id activatedService(PostureServiceDelegate *delegate) {
  Class serviceClass = NSClassFromString(@"HIDVirtualEventService");
  if (!serviceClass) return nil;
  id service = [[serviceClass alloc] init];
  delegate.properties = @{
    @"PrimaryUsagePage" : @(PostureUsagePage),
    @"PrimaryUsage" : @(PostureUsage),
    @"DeviceUsagePairs" :
        @[ @{@"DeviceUsagePage" : @(PostureUsagePage), @"DeviceUsage" : @(PostureUsage)} ],
    @"Transport" : @"CoreDevice",
    @"Built-In" : @NO,
  };
  ((void (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("setDelegate:"), delegate);
  dispatch_queue_t queue = dispatch_queue_create("putio.harness.duo-posture", DISPATCH_QUEUE_SERIAL);
  ((void (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("setDispatchQueue:"), queue);
  ((void (*)(id, SEL))objc_msgSend)(service, sel_registerName("activate"));
  uint64_t serviceID = ((uint64_t (*)(id, SEL))objc_msgSend)(service, sel_registerName("serviceID"));
  return serviceID ? service : nil;
}

static NSData *payloadForArguments(int argc, char **argv) {
  if (argc != 3) return nil;
  if (strcmp(argv[1], "angle") == 0) {
    char *end = NULL;
    double degrees = strtod(argv[2], &end);
    if (*end != '\0' || !isfinite(degrees) || degrees < 0 || degrees > 180) return nil;
    return anglePayload(degrees);
  }
  if (strcmp(argv[1], "orientation") == 0) {
    const char *values[] = {"portrait", "pud", "landscape-left", "landscape-right"};
    for (size_t index = 0; index < sizeof values / sizeof *values; index++) {
      if (strcmp(argv[2], values[index]) == 0) return orientationPayload(values[index]);
    }
  }
  return nil;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    NSData *payload = payloadForArguments(argc, argv);
    if (!payload) {
      fprintf(stderr,
              "usage: duo-posture angle <0-180> | orientation "
              "<portrait|pud|landscape-left|landscape-right>\n");
      return 64;
    }
    if (!dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW)) {
      fprintf(stderr, "duo-posture: HID.framework did not load: %s\n", dlerror());
      return 69;
    }
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    VendorEventFactory createEvent =
        iokit ? (VendorEventFactory)dlsym(iokit, "IOHIDEventCreateVendorDefinedEvent") : NULL;
    if (!createEvent) {
      fprintf(stderr, "duo-posture: IOHIDEventCreateVendorDefinedEvent is missing\n");
      return 69;
    }
    PostureServiceDelegate *delegate = [PostureServiceDelegate new];
    id service = activatedService(delegate);
    if (!service) {
      fprintf(stderr, "duo-posture: HIDVirtualEventService did not activate\n");
      return 69;
    }
    usleep(300000);
    CFTypeRef event = createEvent(NULL, mach_absolute_time(), PostureUsagePage, PostureUsage, 0,
                                  payload.bytes, (CFIndex)payload.length, 0);
    BOOL sent = event && ((BOOL (*)(id, SEL, id))objc_msgSend)(
                             service, sel_registerName("dispatchEvent:"), (__bridge id)event);
    if (event) CFRelease(event);
    ((void (*)(id, SEL))objc_msgSend)(service, sel_registerName("cancel"));
    if (!sent) {
      fprintf(stderr, "duo-posture: the posture event was not dispatched\n");
      return 70;
    }
    return 0;
  }
}
