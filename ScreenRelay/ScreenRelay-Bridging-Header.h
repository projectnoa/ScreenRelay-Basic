//
//  ScreenRelay-Bridging-Header.h
//  ScreenRelay
//
//  Declarations for CoreGraphics' private virtual display API. These classes
//  ship in CoreGraphics.framework (macOS 10.14+) and are what DeskPad,
//  BetterDisplay and Chromium use to create software displays that the
//  window server treats like a physically attached monitor.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject

@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);

- (instancetype)init;
- (void)setDispatchQueue:(dispatch_queue_t)queue;

@end

@interface CGVirtualDisplayMode : NSObject

@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;

- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;

@end

@interface CGVirtualDisplaySettings : NSObject

@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;

- (instancetype)init;

@end

@interface CGVirtualDisplay : NSObject

@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;

- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@end

NS_ASSUME_NONNULL_END
