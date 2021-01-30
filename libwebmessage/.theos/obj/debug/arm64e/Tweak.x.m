#line 1 "Tweak.x"
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SCNetworkReachability.h>
#import <netinet/in.h>
#import <spawn.h>
#import <MRYIPCCenter.h>
#import <UIKit/UIKit.h>
#include <HBLog.h>
#include "Tweak.h"

@interface WebMessageIPC : NSObject
@end


#include <substrate.h>
#if defined(__clang__)
#if __has_feature(objc_arc)
#define _LOGOS_SELF_TYPE_NORMAL __unsafe_unretained
#define _LOGOS_SELF_TYPE_INIT __attribute__((ns_consumed))
#define _LOGOS_SELF_CONST const
#define _LOGOS_RETURN_RETAINED __attribute__((ns_returns_retained))
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_TYPE_INIT
#define _LOGOS_SELF_CONST
#define _LOGOS_RETURN_RETAINED
#endif
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_TYPE_INIT
#define _LOGOS_SELF_CONST
#define _LOGOS_RETURN_RETAINED
#endif

@class NSNotificationCenter; @class IMAccountController; @class IMChatRegistry; @class CKMediaObjectManager; @class IMMessage; @class CKComposition; @class IMDaemonController; @class IMHandle; @class CKConversationList; 
static unsigned (*_logos_orig$_ungrouped$IMDaemonController$_capabilities)(_LOGOS_SELF_TYPE_NORMAL IMDaemonController* _LOGOS_SELF_CONST, SEL); static unsigned _logos_method$_ungrouped$IMDaemonController$_capabilities(_LOGOS_SELF_TYPE_NORMAL IMDaemonController* _LOGOS_SELF_CONST, SEL); static void (*_logos_orig$_ungrouped$NSNotificationCenter$postNotificationName$object$userInfo$)(_LOGOS_SELF_TYPE_NORMAL NSNotificationCenter* _LOGOS_SELF_CONST, SEL, NSString *, id, NSDictionary *); static void _logos_method$_ungrouped$NSNotificationCenter$postNotificationName$object$userInfo$(_LOGOS_SELF_TYPE_NORMAL NSNotificationCenter* _LOGOS_SELF_CONST, SEL, NSString *, id, NSDictionary *); 
static __inline__ __attribute__((always_inline)) __attribute__((unused)) Class _logos_static_class_lookup$CKConversationList(void) { static Class _klass; if(!_klass) { _klass = objc_getClass("CKConversationList"); } return _klass; }static __inline__ __attribute__((always_inline)) __attribute__((unused)) Class _logos_static_class_lookup$IMDaemonController(void) { static Class _klass; if(!_klass) { _klass = objc_getClass("IMDaemonController"); } return _klass; }static __inline__ __attribute__((always_inline)) __attribute__((unused)) Class _logos_static_class_lookup$IMHandle(void) { static Class _klass; if(!_klass) { _klass = objc_getClass("IMHandle"); } return _klass; }static __inline__ __attribute__((always_inline)) __attribute__((unused)) Class _logos_static_class_lookup$IMMessage(void) { static Class _klass; if(!_klass) { _klass = objc_getClass("IMMessage"); } return _klass; }static __inline__ __attribute__((always_inline)) __attribute__((unused)) Class _logos_static_class_lookup$CKComposition(void) { static Class _klass; if(!_klass) { _klass = objc_getClass("CKComposition"); } return _klass; }static __inline__ __attribute__((always_inline)) __attribute__((unused)) Class _logos_static_class_lookup$CKMediaObjectManager(void) { static Class _klass; if(!_klass) { _klass = objc_getClass("CKMediaObjectManager"); } return _klass; }static __inline__ __attribute__((always_inline)) __attribute__((unused)) Class _logos_static_class_lookup$IMChatRegistry(void) { static Class _klass; if(!_klass) { _klass = objc_getClass("IMChatRegistry"); } return _klass; }static __inline__ __attribute__((always_inline)) __attribute__((unused)) Class _logos_static_class_lookup$IMAccountController(void) { static Class _klass; if(!_klass) { _klass = objc_getClass("IMAccountController"); } return _klass; }
#line 13 "Tweak.x"
@implementation WebMessageIPC {
  MRYIPCCenter* _center;
}

+ (instancetype)sharedInstance {
  static dispatch_once_t onceToken = 0;
  __strong static WebMessageIPC* sharedInstance = nil;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  if ((self = [super init])) {
    _center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessage"];
    [_center addTarget:self action:@selector(sendText:)];
    [_center addTarget:self action:@selector(setAsRead:)];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedText:) name:@"__kIMChatMessageReceivedNotification" object:nil];
  }
  return self;
}

- (void)sendText:(NSDictionary *)vals {
  __block NSString* msgGUID;

  dispatch_async(dispatch_get_main_queue(), ^{
    IMDaemonController* controller = [_logos_static_class_lookup$IMDaemonController() sharedController];

    if ([controller connectToDaemon]) {
      NSArray* attachments = vals[@"attachment"];
      NSString* textString = vals[@"text"];
      NSString* address = vals[@"address"];
      NSString* sub = vals[@"subject"];

      NSAttributedString* text = [[NSAttributedString alloc] initWithString:textString];
      NSAttributedString* subject = [[NSAttributedString alloc] initWithString:sub];

      CKConversationList* list = [_logos_static_class_lookup$CKConversationList() sharedConversationList];
      CKConversation* conversation = [list conversationForExistingChatWithGroupID:address];

      if (conversation != nil) {
        CKComposition* composition  = [[_logos_static_class_lookup$CKComposition() alloc] initWithText:text subject:([subject length] > 0 ? subject : nil)];
        CKMediaObjectManager* objManager = [_logos_static_class_lookup$CKMediaObjectManager() sharedInstance];

        for (NSDictionary* attachment in attachments) {
          NSString* base64Data = attachment[@"data"];
          NSString* filename = attachment[@"name"];
          
          NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Data options:0];
          id UTITypes = [NSClassFromString(@"CKImageMediaObject") UTITypes];
          CKMediaObject* object = [objManager mediaObjectWithData:data UTIType:UTITypes filename:filename transcoderUserInfo:nil];

          composition = [composition compositionByAppendingMediaObject:object];
        }

        id message = [conversation messageWithComposition:composition];

        [conversation sendMessage:message newComposition:YES];

        msgGUID = [(IMMessage *)message guid];

      } else {
        IMAccountController *sharedAccountController = [_logos_static_class_lookup$IMAccountController() sharedInstance];

        IMAccount *myAccount = [sharedAccountController activeIMessageAccount];
        if (myAccount == nil)
          myAccount = [sharedAccountController activeSMSAccount];

        __NSCFString *handleId = (__NSCFString *)address;
        IMHandle *handle = [[_logos_static_class_lookup$IMHandle() alloc] initWithAccount:myAccount ID:handleId alreadyCanonical:YES];

        IMChatRegistry *registry = [_logos_static_class_lookup$IMChatRegistry() sharedInstance];
        IMChat *chat = [registry chatForIMHandle:handle];

        IMMessage* message;
        if ([[[UIDevice currentDevice] systemVersion] floatValue] >= 14.0)
          message = [_logos_static_class_lookup$IMMessage() instantMessageWithText:text flags:1048581 threadIdentifier:nil];
        else
          message = [_logos_static_class_lookup$IMMessage() instantMessageWithText:text flags:1048581];

        [chat sendMessage:message];

        msgGUID = [(IMMessage *)message guid];
      }
        
      if ([WebMessageIPC isServerRunning]) {
        MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
        [center callExternalVoidMethod:@selector(handleReceivedTextWithCallback:) withArguments:msgGUID];
      }
    } else {
      WMLog(@"Failed to connect to daemon");
    }
  });
}

- (void)setAsRead:(NSString *)chat {
  IMDaemonController* controller = [_logos_static_class_lookup$IMDaemonController() sharedController];

  if ([controller connectToDaemon]) {
    IMChat* imchat = [[_logos_static_class_lookup$IMChatRegistry() sharedInstance] existingChatWithChatIdentifier:(__NSCFString *)chat];
    [imchat markAllMessagesAsRead];
  }
}

- (void)receivedText:(NSConcreteNotification *)notif {
  IMMessage *msg = [[notif userInfo] objectForKey:@"__kIMChatValueKey"];
  NSString* guid = [msg guid];

  if ([WebMessageIPC isServerRunning]) {
    MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
    [center callExternalVoidMethod:@selector(handleReceivedTextWithCallback:) withArguments:guid];
  }
}

+ (BOOL)isServerRunning {
  NSMutableDictionary *settings = [NSMutableDictionary dictionary];
  [settings addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:@"/User/Library/Preferences/com.sgtaziz.webmessage.plist"]];
  id defaultPort = @8180;
  
  NSString *address = [NSString stringWithFormat:@"localhost:%@", settings[@"port"] ?: defaultPort];
  
  SCNetworkReachabilityFlags flags = 0;
  SCNetworkReachabilityRef netReachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [address UTF8String]);
  BOOL retrievedFlags = NO;

  if (netReachability) {
    retrievedFlags = SCNetworkReachabilityGetFlags(netReachability, &flags);
    CFRelease(netReachability);
  }
  
  if (!retrievedFlags || !flags) {
    return NO;
  }
  
  return YES;
}

@end



static unsigned _logos_method$_ungrouped$IMDaemonController$_capabilities(_LOGOS_SELF_TYPE_NORMAL IMDaemonController* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd) {
  NSString *process = [[NSProcessInfo processInfo] processName];
  if ([process isEqualToString:@"SpringBoard"] || [process isEqualToString:@"MobileSMS"])
    return 17159;
  else
    return _logos_orig$_ungrouped$IMDaemonController$_capabilities(self, _cmd);
}




static void _logos_method$_ungrouped$NSNotificationCenter$postNotificationName$object$userInfo$(_LOGOS_SELF_TYPE_NORMAL NSNotificationCenter* _LOGOS_SELF_CONST __unused self, SEL __unused _cmd, NSString * notificationName, id notificationSender, NSDictionary * userInfo) {
  if ([notificationName isEqualToString:@"__kIMChatRegistryMessageSentNotification"]) {
    IMMessage *msg = [userInfo objectForKey:@"__kIMChatRegistryMessageSentMessageKey"];
    NSString* msgGUID = [msg guid];

    if ([WebMessageIPC isServerRunning]) {
      MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
      [center callExternalVoidMethod:@selector(handleReceivedTextWithCallback:) withArguments:msgGUID];
    }
  }
  
  _logos_orig$_ungrouped$NSNotificationCenter$postNotificationName$object$userInfo$(self, _cmd, notificationName, notificationSender, userInfo);
}


static __attribute__((constructor)) void _logosLocalCtor_992005e9(int __unused argc, char __unused **argv, char __unused **envp) {
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  if ([bundleID isEqualToString:@"com.apple.springboard"]) {
    [WebMessageIPC sharedInstance];
  }
}
static __attribute__((constructor)) void _logosLocalInit() {
{Class _logos_class$_ungrouped$IMDaemonController = objc_getClass("IMDaemonController"); { MSHookMessageEx(_logos_class$_ungrouped$IMDaemonController, @selector(_capabilities), (IMP)&_logos_method$_ungrouped$IMDaemonController$_capabilities, (IMP*)&_logos_orig$_ungrouped$IMDaemonController$_capabilities);}Class _logos_class$_ungrouped$NSNotificationCenter = objc_getClass("NSNotificationCenter"); { MSHookMessageEx(_logos_class$_ungrouped$NSNotificationCenter, @selector(postNotificationName:object:userInfo:), (IMP)&_logos_method$_ungrouped$NSNotificationCenter$postNotificationName$object$userInfo$, (IMP*)&_logos_orig$_ungrouped$NSNotificationCenter$postNotificationName$object$userInfo$);}} }
#line 188 "Tweak.x"
