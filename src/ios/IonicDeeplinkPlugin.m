#import "IonicDeeplinkPlugin.h"

#import <objc/runtime.h>
#import <Cordova/CDVAvailability.h>
#import <Cordova/CDVSceneDelegate.h>

static NSString *const kCDVContinueUserActivityNotification = @"CDVPluginContinueUserActivityNotification";
static NSURL *IonicDeeplinkPendingURL = nil;

@interface CDVSceneDelegate (IonicDeeplink)
- (void)ionicdeeplink_scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions;
- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity;
@end

@implementation CDVSceneDelegate (IonicDeeplink)

+ (void)load {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Method original = class_getInstanceMethod(self, @selector(scene:willConnectToSession:options:));
    Method swizzled = class_getInstanceMethod(self, @selector(ionicdeeplink_scene:willConnectToSession:options:));
    if (original && swizzled) {
      method_exchangeImplementations(original, swizzled);
    }
  });
}

- (void)ionicdeeplink_scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
  [self ionicdeeplink_scene:scene willConnectToSession:session options:connectionOptions];
  for (NSUserActivity *activity in connectionOptions.userActivities) {
    [self scene:scene continueUserActivity:activity];
  }
}

@end

@implementation IonicDeeplinkPlugin

+ (void)load {
  // Capture Universal Links even if the plugin instance is not created yet
  // (cold start on Cordova iOS 8+ SceneDelegate).
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(captureContinueUserActivity:)
                                               name:kCDVContinueUserActivityNotification
                                             object:nil];
}

+ (void)captureContinueUserActivity:(NSNotification *)notification {
  NSUserActivity *userActivity = [notification object];
  if (![userActivity isKindOfClass:[NSUserActivity class]]) {
    return;
  }
  if (![userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] || userActivity.webpageURL == nil) {
    return;
  }
  IonicDeeplinkPendingURL = userActivity.webpageURL;
  NSLog(@"IonicDeepLinkPlugin: captured pending Universal Link %@", IonicDeeplinkPendingURL);
}

- (void)pluginInitialize {
  _handlers = [[NSMutableArray alloc] init];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleContinueUserActivityNotification:)
                                               name:kCDVContinueUserActivityNotification
                                             object:nil];

  if (IonicDeeplinkPendingURL) {
    NSLog(@"IonicDeepLinkPlugin: consuming pending Universal Link %@", IonicDeeplinkPendingURL);
    _lastEvent = [self createResult:IonicDeeplinkPendingURL];
    [self sendToJs];
    IonicDeeplinkPendingURL = nil;
  }
}

/* ------------------------------------------------------------- */

- (void)onAppTerminate {
  _handlers = nil;
  [super onAppTerminate];
}

- (void)canOpenApp:(CDVInvokedUrlCommand *)command {
  CDVPluginResult* result = nil;

  NSString* scheme = [command.arguments objectAtIndex:0];

  if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:scheme]]) {
    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:(true)];
  } else {
    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsBool:(false)];
  }

  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)onDeepLink:(CDVInvokedUrlCommand *)command {
  [_handlers addObject:command.callbackId];
  // Try to consume any events we got before we were listening
  [self sendToJs];
}

- (void)handleOpenURL:(NSNotification *)notification {
  NSURL *url = [notification object];
  if ([url isKindOfClass:[NSURL class]]) {
    NSLog(@"IonicDeepLinkPlugin: handleOpenURL %@", url);
    [self handleLink:url];
  }
}

- (void)handleContinueUserActivityNotification:(NSNotification *)notification {
  NSUserActivity *userActivity = [notification object];
  if ([userActivity isKindOfClass:[NSUserActivity class]]) {
    [self handleContinueUserActivity:userActivity];
  }
}

- (BOOL)handleLink:(NSURL *)url {
  NSLog(@"IonicDeepLinkPlugin: Handle link (internal) %@", url);
  
  if(![self checkUrl:url]) {
    return NO;
  }

  _lastEvent = [self createResult:url];

  [self sendToJs];

  return YES;
}

- (BOOL)checkUrl:(NSURL *)url {
  if(url == nil) return NO;
    
  NSString* urlScheme = [[self.commandDelegate settings] objectForKey:@"url_scheme"];
    
  if(urlScheme == nil) return NO;
    
  NSLog(@"url scheme:%@",[url scheme]);
  NSLog(@"url host:%@",[url host]);

  if([[url scheme] isEqualToString:urlScheme]) {
    return YES;
  }
    
  NSString* deeplinkScheme = [[self.commandDelegate settings] objectForKey:@"deeplink_scheme"];
  NSString* deeplinkHost = [[self.commandDelegate settings] objectForKey:@"deeplink_host"];
    
  if(deeplinkScheme!=nil && deeplinkHost != nil) {
    if([[url scheme] isEqualToString:deeplinkScheme]&&[[url host] isEqualToString:deeplinkHost]) {
      return YES;
    }
  }
  
  return NO;
}

- (BOOL)handleContinueUserActivity:(NSUserActivity *)userActivity {

  if (![userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] || userActivity.webpageURL == nil) {
    return NO;
  }

  NSURL *url = userActivity.webpageURL;
  _lastEvent = [self createResult:url];
  NSLog(@"IonicDeepLinkPlugin: Handle continueUserActivity (internal) %@", url);

  [self sendToJs];

  return YES;
}

- (void) sendToJs {
  // Send the last event to JS if we have one
  if (_handlers.count == 0 || _lastEvent == nil) {
    return;
  }

  // Iterate our handlers and send the event
  for (id callbackID in _handlers) {
    [self.commandDelegate sendPluginResult:_lastEvent callbackId:callbackID];
  }

  // Clear out the last event
  _lastEvent = nil;
}

- (CDVPluginResult *)createResult:(NSURL *)url {
  NSDictionary* data = @{
    @"url": [url absoluteString] ?: @"",
    @"path": [url path] ?: @"",
    @"queryString": [url query] ?: @"",
    @"scheme": [url scheme] ?: @"",
    @"host": [url host] ?: @"",
    @"fragment": [url fragment] ?: @""
  };

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:data];
  [result setKeepCallbackAsBool:YES];
  return result;
}

- (void)getHardwareInfo:(CDVInvokedUrlCommand *)command {
  NSMutableDictionary *info = [[NSMutableDictionary alloc] init];


  // Removing part where advertisingIdentifier is being used to keep the functional part working.

  NSString *uuid = [[UIDevice currentDevice].identifierForVendor UUIDString];

  if(uuid && [uuid length] > 0) {
    [info setObject:uuid forKey:@"uuid"];
  }

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:info];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
