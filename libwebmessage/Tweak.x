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
    //[_center addTarget:self action:@selector(sendReaction:)]; //TODO: Add reactions
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedText:) name:@"__kIMChatMessageReceivedNotification" object:nil];
  }
  return self;
}

- (void)sendText:(NSDictionary *)vals {
  __block NSString* msgGUID;

  dispatch_sync(dispatch_get_main_queue(), ^{
    IMDaemonController* controller = [%c(IMDaemonController) sharedController];
  
    @autoreleasepool {
      if ([controller connectToDaemon]) {
        NSArray* attachments = vals[@"attachment"];
        NSString* textString = vals[@"text"];
        NSString* address = vals[@"address"];
        NSString* sub = vals[@"subject"];

        NSAttributedString* text = [[NSAttributedString alloc] initWithString:textString];
        NSAttributedString* subject = [[NSAttributedString alloc] initWithString:sub];

        CKConversationList* list = [%c(CKConversationList) sharedConversationList];
        CKConversation* conversation = [list conversationForExistingChatWithGroupID:address];

        if (conversation != nil) {
          CKComposition* composition  = [[%c(CKComposition) alloc] initWithText:text subject:([subject length] > 0 ? subject : nil)];
          CKMediaObjectManager* objManager = [%c(CKMediaObjectManager) sharedInstance];

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
          IMAccountController *sharedAccountController = [%c(IMAccountController) sharedInstance];

          IMAccount *myAccount = [sharedAccountController activeIMessageAccount];
          if (myAccount == nil)
            myAccount = [sharedAccountController activeSMSAccount];

          __NSCFString *handleId = (__NSCFString *)address;
          IMHandle *handle = [[%c(IMHandle) alloc] initWithAccount:myAccount ID:handleId alreadyCanonical:YES];

          IMChatRegistry *registry = [%c(IMChatRegistry) sharedInstance];
          IMChat *chat = [registry chatForIMHandle:handle];

          IMMessage* message;
          if ([[[UIDevice currentDevice] systemVersion] floatValue] >= 14.0)
            message = [%c(IMMessage) instantMessageWithText:text flags:1048581 threadIdentifier:nil];
          else
            message = [%c(IMMessage) instantMessageWithText:text flags:1048581];

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
    }
  });
}

- (void)setAsRead:(NSString *)chat {
  IMDaemonController* controller = [%c(IMDaemonController) sharedController];

  if ([controller connectToDaemon]) {
    IMChat* imchat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:(__NSCFString *)chat];
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

%hook IMDaemonController
// This allows any process to communicate with imagent
- (unsigned)_capabilities {
  NSString *process = [[NSProcessInfo processInfo] processName];
  if ([process isEqualToString:@"SpringBoard"] || [process isEqualToString:@"MobileSMS"])
    return 17159;
  else
    return %orig;
}
%end

%hook NSNotificationCenter
// This doesn't hook instantly. First message isn't detected?
- (void)postNotificationName:(NSString *)notificationName object:(id)notificationSender userInfo:(NSDictionary *)userInfo {
  if ([notificationName isEqualToString:@"__kIMChatRegistryMessageSentNotification"]) {
    IMMessage *msg = [userInfo objectForKey:@"__kIMChatRegistryMessageSentMessageKey"];
    NSString* msgGUID = [msg guid];

    if ([WebMessageIPC isServerRunning]) {
      MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
      [center callExternalVoidMethod:@selector(handleReceivedTextWithCallback:) withArguments:msgGUID];
    }
  }
  
  %orig;
}
%end

%ctor {
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  if ([bundleID isEqualToString:@"com.apple.springboard"]) {
    [WebMessageIPC sharedInstance];
  }
}
