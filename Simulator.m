//
//   
//  Sim
//
//  Created by ProbablyInteractive on 7/28/09.
//  Copyright 2009 Probably Interactive. All rights reserved.
//

#import "Simulator.h"
#import <QTKit/QTKit.h>

#include <sys/param.h>
#include <objc/runtime.h>

#define WaxLog(format, args...) \
    fprintf(stderr, "%s\n", [[NSString stringWithFormat:(format), ## args] UTF8String])

@implementation Simulator

@synthesize session=_session;

- (id)initWithAppPath:(NSString *)appPath sdk:(NSString *)sdk family:(NSString *)family video:(NSString *)videoPath env:(NSDictionary *)env args:(NSArray *)args;
{
    self = [super init];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![appPath isAbsolutePath]) {        
        appPath = [[fileManager currentDirectoryPath] stringByAppendingPathComponent:appPath];
    }   
    
    _appPath = [appPath retain];

    if (![fileManager fileExistsAtPath:_appPath]) {
        WaxLog(@"App path '%@' does not exist!", _appPath);
        exit(EXIT_FAILURE);
    }

    if (!sdk) _sdk = [[DTiPhoneSimulatorSystemRoot defaultRoot] retain];
    else {
        _sdk = [[DTiPhoneSimulatorSystemRoot rootWithSDKVersion:sdk] retain];
    }
    
    if (!_sdk) {
        WaxLog(@"Unknown sdk '%@'", sdk);
        WaxLog(@"Available sdks are...");
        for (id root in [DTiPhoneSimulatorSystemRoot knownRoots]) {
            WaxLog(@"  %@", [root sdkVersion]);
        }
        
        exit(EXIT_FAILURE);
    }
	
	if ([family isEqualToString: @"ipad"]) {
		_family = [NSNumber numberWithInt: 2];
	} else {
		_family = [NSNumber numberWithInt: 1];
	}
	
	_env = [env retain];
	_args = [args retain];
    _videoPath = [videoPath retain];

    return self;
}

+ (NSArray *)availableSDKs {
    NSMutableArray *sdks = [NSMutableArray array];
    for (id root in [DTiPhoneSimulatorSystemRoot knownRoots]) {
        [sdks addObject:[root sdkVersion]];
    }
    
    return sdks;
}

- (int)launch {
    WaxLog(@"Launching '%@' on'%@'", _appPath, [_sdk sdkDisplayName]);
    
    DTiPhoneSimulatorApplicationSpecifier *appSpec = [DTiPhoneSimulatorApplicationSpecifier specifierWithApplicationPath:_appPath];
    if (!appSpec) {
        WaxLog(@"Could not load application specifier for '%@'", _appPath);
        return EXIT_FAILURE;
    }
    
    DTiPhoneSimulatorSystemRoot *sdkRoot = _sdk;
    
    DTiPhoneSimulatorSessionConfig *config = [[DTiPhoneSimulatorSessionConfig alloc] init];
    [config setApplicationToSimulateOnStart:appSpec];
    [config setSimulatedSystemRoot:sdkRoot];
	[config setSimulatedDeviceFamily:_family];
    [config setSimulatedApplicationShouldWaitForDebugger:NO];    
    [config setSimulatedApplicationLaunchArgs:_args];
    [config setSimulatedApplicationLaunchEnvironment:_env];
    [config setLocalizedClientName:@"WaxSim"];

    // Make the simulator output to the current STDERR
	// We mix them together to avoid buffering issues on STDOUT
    char path[MAXPATHLEN];

    fcntl(STDERR_FILENO, F_GETPATH, &path);
    [config setSimulatedApplicationStdOutPath:[NSString stringWithUTF8String:path]];
    [config setSimulatedApplicationStdErrPath:[NSString stringWithUTF8String:path]];
    
    _session = [[DTiPhoneSimulatorSession alloc] init];
    [_session setDelegate:self];
    
    NSError *error;
    if (![_session requestStartWithConfig:config timeout:30 error:&error]) {
        WaxLog(@"Could not start simulator session: %@", [error localizedDescription]);
        return EXIT_FAILURE;
    }
    
    return EXIT_SUCCESS;
}

- (void)end {
    [_session requestEndWithTimeout:0];
}

- (void)addScreenshotToMovie;
{
    if (!_windowID || !_movie) {
        return;
    }
    
    NSTimeInterval interval = [NSDate timeIntervalSinceReferenceDate];
    QTTime duration = QTMakeTimeWithTimeInterval(interval - _lastInterval);
    _lastInterval = interval;
    
    CGImageRef imageRef = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, _windowID, kCGWindowImageDefault);
    NSImage *image = [[NSImage alloc] initWithCGImage:imageRef size:NSZeroSize];
    
    if ([image size].width > 5.0f) {
        NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:@"mp4v", QTAddImageCodecType, [NSNumber numberWithLong:codecLowQuality], QTAddImageCodecQuality, nil];
        [_movie addImage:image forDuration:duration withAttributes:attributes];
    }
    [image release];
    CGImageRelease(imageRef);
}

// DTiPhoneSimulatorSession Delegate
// ---------------------------------
- (void)session:(DTiPhoneSimulatorSession *)session didStart:(BOOL)started withError:(NSError *)error {
    if (!started) {
        WaxLog(@"Session failed to start. %@", [error localizedDescription]);
        exit(EXIT_FAILURE);
    }
    
    if (!_videoPath) {
        return;
    }
    
    WaxLog(@"Getting window list");
    NSArray *windowList = (NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *info in windowList) {
        if ([[info objectForKey:(NSString *)kCGWindowOwnerName] isEqualToString:@"iOS Simulator"] && ![[info objectForKey:(NSString *)kCGWindowName] isEqualToString:@""]) {
            _windowID = [[info objectForKey:(NSString *)kCGWindowNumber] unsignedIntValue];
        }
    }
    [windowList release];
    if (_windowID) {
        _movie = [[QTMovie alloc] initToWritableFile:_videoPath error:NULL];
        _lastInterval = [NSDate timeIntervalSinceReferenceDate];;
        [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 target:self selector:@selector(addScreenshotToMovie) userInfo:nil repeats:YES];
    }
}

- (void)session:(DTiPhoneSimulatorSession *)session didEndWithError:(NSError *)error {
    if (_movie) {
        NSDictionary *attributes = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:QTMovieFlatten];
        NSError *error = nil;
        BOOL success = [_movie updateMovieFile];
        [_movie release];
        //[_movie writeToFile:_videoPath withAttributes:attributes error:&error];
        if (!success) {
            WaxLog(@"Failed to write movie: %@", error);
        }
        [_movie release];
    }
    if (error) {
        WaxLog(@"Session ended with error. %@", [error localizedDescription]);
        if ([error code] != 2) exit(EXIT_FAILURE); // if it is a timeout error, that's cool. We are probably rebooting
    } else {
        exit(EXIT_SUCCESS);
    }
}

@end
