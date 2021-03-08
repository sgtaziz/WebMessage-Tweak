#import <Foundation/Foundation.h>
#import <SystemConfiguration/SCNetworkReachability.h>
#import <netinet/in.h>
#import <spawn.h>
#import <MRYIPCCenter.h>
#import <UIKit/UIKit.h>
#include <HBLog.h>
#include "Tweak.h"

@interface WebMessageIPC : NSObject <NSURLSessionDelegate>
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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(SBBooted:) name:@"SBBootCompleteNotification" object:nil];
  }
  return self;
}

/// The whole purpose of this is to be able to hook onto __kIM... notifications. Though still doesn't work for __kIMChatRegistryMessageSentNotification, but it's no longer needed!
- (void)initController {
  _center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessage"];
  [_center addTarget:self action:@selector(sendText:)];
  [_center addTarget:self action:@selector(setAsRead:)];
  [_center addTarget:self action:@selector(deleteChat:)];
  [_center addTarget:self action:@selector(sendReaction:)];
  [_center addTarget:self action:@selector(setIsLocallyTyping:)];
  
  IMDaemonController* controller = [%c(IMDaemonController) sharedController];
  if ([controller connectToDaemon]) {
    WMLog(@"Connected!");
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedText:) name:@"__kIMChatMessageReceivedNotification" object:nil];
    //[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textChanged:) name:@"__kIMChatRegistryMessageSentNotification" object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedText:) name:@"__kIMChatMessageDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textChanged:) name:@"__kIMChatItemsDidChangeNotification" object:nil];
  } else {
    WMLog(@"Not connected yet :(");
  }
}

- (void)sendText:(NSDictionary *)vals {
  __block NSString* msgGUID;

  dispatch_async(dispatch_get_main_queue(), ^{
    IMDaemonController* controller = [%c(IMDaemonController) sharedController];

    if ([controller connectToDaemon]) {
      NSArray* attachments = vals[@"attachment"];
      NSString* textString = vals[@"text"];
      NSString* address = vals[@"address"];
      NSString* sub = vals[@"subject"];
      int attachmentsCount = [attachments count];

      NSAttributedString* text = [[NSAttributedString alloc] initWithString:textString];
      NSAttributedString* subject = [[NSAttributedString alloc] initWithString:sub];

      CKConversationList* list = [%c(CKConversationList) sharedConversationList];
      CKConversation* conversation = [list conversationForExistingChatWithGroupID:address];
      
      if (conversation != nil) {
        CKComposition* composition;
        
        if (attachmentsCount > 0) {
          composition = [[%c(CKComposition) alloc] initWithText:nil subject:([subject length] > 0 ? subject : nil)];
        } else {
          composition = [[%c(CKComposition) alloc] initWithText:text subject:([subject length] > 0 ? subject : nil)];
        }
        
        CKMediaObjectManager* objManager = [%c(CKMediaObjectManager) sharedInstance];

        for (NSDictionary* attachment in attachments) {
          NSString* base64Data = attachment[@"data"];
          NSString* filename = attachment[@"name"];
          
          NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Data options:0];
          id UTITypes = [NSClassFromString(@"CKImageMediaObject") UTITypes];
          CKMediaObject* object = [objManager mediaObjectWithData:data UTIType:UTITypes filename:filename transcoderUserInfo:nil];

          composition = [composition compositionByAppendingMediaObject:object];
        }
        
        if (attachmentsCount > 0 && [text length] > 0)
          composition = [composition compositionByAppendingText:text];
        
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
      WMLog(@"Failed to connect to IM daemon");
    }
  });
}

- (void)sendReaction:(NSDictionary *)vals {
  IMDaemonController* controller = [%c(IMDaemonController) sharedController];

  if ([controller connectToDaemon]) {
    NSString *chat_id = vals[@"chat_id"];
    NSString *guid = vals[@"guid"];
    NSNumber *part = vals[@"part"];
    long long int reaction = [vals[@"reactionId"] longLongValue];

    IMChat *chat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:chat_id];

    dispatch_async(dispatch_get_main_queue(), ^{
      [chat loadMessagesUpToGUID:guid date:nil limit:0 loadImmediately:YES];
      IMMessage *msg = [chat messageForGUID:guid];
      
      if (msg != nil) {
        IMMessageItem *item = [msg _imMessageItem];
        NSString *subject = [item subject];
        
        NSAttributedString *text = [item body];
        __block NSAttributedString *partText = text;
        __block NSRange partRange = NSMakeRange(0, [text length]);
        
        [text enumerateAttribute:@"__kIMMessagePartAttributeName" inRange:NSMakeRange(0, [text length]) options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired usingBlock:
         ^(id value, NSRange range, BOOL *stop) {
            if ([value intValue] == [part intValue]) {
//              partText = [text attributedSubstringFromRange:range];
              partRange = range;
            }
          }
        ];
        
        if (item != nil) {
          NSData* payloadData = [item payloadData];
          id msgPart;
          
          if (payloadData != nil && [payloadData length] > 0) {
            IMPluginPayload* pluginPayload = [[%c(IMPluginPayload) alloc] initWithMessageItem:item];
            
            if ([[[UIDevice currentDevice] systemVersion] floatValue] < 14.0)
              msgPart = [[%c(IMTranscriptPluginChatItem) alloc] _initWithItem:item initialPayload:pluginPayload messagePartRange:partRange parentChatHasKnownParticipants:true];
            else
              msgPart = [[%c(IMTranscriptPluginChatItem) alloc] _initWithItem:item initialPayload:pluginPayload index:0 messagePartRange:partRange parentChatHasKnownParticipants:true];
          } else {
            msgPart = [[%c(IMTextMessagePartChatItem) alloc] _initWithItem:item text:partText index:[part intValue] messagePartRange:partRange subject:subject];
          }
          
          
          NSMutableDictionary *summaryInfo = [[NSMutableDictionary alloc] init];
//          [summaryInfo addEntriesFromDictionary:[msg messageSummaryInfo]];
          summaryInfo[@"ams"] = [[partText string] stringByReplacingOccurrencesOfString:@"\ufffc" withString:@""];
          summaryInfo[@"amc"] = [summaryInfo[@"ams"] length] == 0 ? @0 : @1;
          
          if (msgPart != nil && summaryInfo != nil) {
            if ([[[UIDevice currentDevice] systemVersion] floatValue] < 14.0)
              [chat sendMessageAcknowledgment:reaction forChatItem:msgPart withMessageSummaryInfo:summaryInfo];
            else
              [chat sendMessageAcknowledgment:reaction forChatItem:msgPart withAssociatedMessageInfo:summaryInfo];
          }
        }
      }
    });
  }
}

- (void)setIsLocallyTyping:(NSDictionary *)vals {
  dispatch_async(dispatch_get_main_queue(), ^{
    IMDaemonController* controller = [%c(IMDaemonController) sharedController];

    if ([controller connectToDaemon]) {
      bool isTyping = [vals[@"typing"] isEqual:@YES];
      NSString* chat_id = vals[@"chat_id"];

      CKConversationList* list = [%c(CKConversationList) sharedConversationList];
      CKConversation* conversation = [list conversationForExistingChatWithGroupID:chat_id];
      
      if (conversation != nil) {
        [conversation setLocalUserIsTyping:isTyping];
      }
    } else {
      WMLog(@"Failed to connect to IM daemon");
    }
  });
}

- (void)setAsRead:(NSString *)chat {
  IMDaemonController* controller = [%c(IMDaemonController) sharedController];

  if ([controller connectToDaemon]) {
    IMChat* imchat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:(__NSCFString *)chat];
    [imchat markAllMessagesAsRead];
//    [imchat setLocalUserIsTyping:true];
//    [self setIsLocalTyping:@{ @"chat_id": chat, @"typing": @YES }];
  }
}

- (void)receivedText:(NSConcreteNotification *)notif {
  IMMessage *msg = [[notif userInfo] objectForKey:@"__kIMChatValueKey"];
  IMMessage *oldMsg = [[notif userInfo] objectForKey:@"__kIMChatOldValueKey"];
  
  if (msg == nil || oldMsg != nil) return; //msg is null, or its not a new text if oldMsg is not null
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

- (void)SBBooted:(NSConcreteNotification *)notif {
  [self initController];
  
  if ([WebMessageIPC isServerRunning]) {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    [settings addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:@"/User/Library/Preferences/com.sgtaziz.webmessage.plist"]];
    id defaultPort = @8180;
    BOOL useSSL = settings[@"ssl"] ? [settings[@"ssl"] boolValue] : YES;
    NSString* protocol = useSSL ? @"https" : @"http";
    
    NSString *address = [NSString stringWithFormat:@"%@://localhost:%@/stopServer?auth=%@", protocol, settings[@"port"] ?: defaultPort, settings[@"password"] ?: @""];
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
    
    [request setHTTPMethod:@"GET"];
    [request setURL:[NSURL URLWithString:address]];
    
    NSURLSessionConfiguration *defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *defaultSession = [NSURLSession sessionWithConfiguration:defaultConfigObject delegate:self delegateQueue:[NSOperationQueue mainQueue]];

    [[defaultSession dataTaskWithRequest:request completionHandler:
      ^(NSData * _Nullable data,
        NSURLResponse * _Nullable response,
        NSError * _Nullable error) {
          WMLog(@"Sent restart request", error, response);
    }] resume];
  }
}

- (void)textChanged:(NSConcreteNotification *)notif {
  IMChat* imchat = [notif object];
  IMMessage* message = [imchat lastSentMessage];
  
  if ([[imchat guid] containsString:@"iMessage"] && ([message isRead] || [message isDelivered]) && [message isFromMe]) {
    IMHandle* handle = [message subject];
    NSString* handleID = [handle ID];
    NSDate* dateRead = [message timeRead];
    NSDate* dateDelivered = [message timeDelivered];
    NSString* guid = [message guid];
    
    if (handleID != nil && [WebMessageIPC isServerRunning]) {
      MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
      NSDictionary* args = @{ @"chatId": handleID, @"guid": guid, @"read": @([dateRead timeIntervalSince1970] * 1000.0), @"delivered": @([dateDelivered timeIntervalSince1970] * 1000.0) };
      [center callExternalVoidMethod:@selector(handleSetMessageAsRead:) withArguments:args];
    }
  }
}

- (void)deleteChat:(NSDictionary *)vals {
  IMDaemonController* controller = [%c(IMDaemonController) sharedController];

  if ([controller connectToDaemon]) {
    NSString *chat_id = [vals objectForKey:@"chat"];
    IMChat* imchat = [[%c(IMChatRegistry) sharedInstance] existingChatWithChatIdentifier:(__NSCFString *)chat_id];

    if (imchat != nil) {
      [imchat remove];
    }
  } else {
    WMLog(@"Failed to connect to IM daemon");
  }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
}

@end

%hook IMMessageItem
- (bool)isCancelTypingMessage {
  bool orig = %orig;

  if (orig) {
    __block NSString* sender = [self sender];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      if ([WebMessageIPC isServerRunning] && sender != nil) {
        MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
        [center callExternalVoidMethod:@selector(handleChangeTypingIndicator:) withArguments:@{ @"chat_id": sender, @"typing": @NO }];
      }
    });
  }

  return orig;
}

- (bool)isIncomingTypingMessage {
  bool orig = %orig;
  
  if (orig) {
    __block NSString* sender = [self sender];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      if ([WebMessageIPC isServerRunning] && sender != nil) {
        MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
        [center callExternalVoidMethod:@selector(handleChangeTypingIndicator:) withArguments:@{ @"chat_id": sender, @"typing": @YES }];
      }
    });
  }
  
  return orig;
}
%end

%hook IMChat
- (void)remove {
  NSString *chat_id = [self chatIdentifier];
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([WebMessageIPC isServerRunning]) {
      MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
      [center callExternalVoidMethod:@selector(handleChatRemoved:) withArguments:chat_id];
    }
  });
  %orig;
}
%end

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

/// Not needed anymore since we have the new way to hook texts
//%hook NSNotificationCenter
//// This doesn't hook until first text is sent. Also causes crashes with some setups
//- (void)postNotificationName:(NSString *)notificationName object:(id)notificationSender userInfo:(NSDictionary *)userInfo {
//  NSDictionary *settings = [NSMutableDictionary dictionaryWithContentsOfFile:@"/User/Library/Preferences/com.sgtaziz.webmessage.plist"];
//  BOOL enableHook = settings[@"sendnotificationhook"] ? [settings[@"sendnotificationhook"] boolValue] : YES;
//
//  if (enableHook && [notificationName isEqualToString:@"__kIMChatRegistryMessageSentNotification"]) {
//    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
//      IMMessage *msg = [userInfo objectForKey:@"__kIMChatRegistryMessageSentMessageKey"];
//      NSString* msgGUID = [msg guid];
//
//      if ([WebMessageIPC isServerRunning]) {
//        MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
//        [center callExternalVoidMethod:@selector(handleReceivedTextWithCallback:) withArguments:msgGUID];
//      }
//    });
//  }
//
//  %orig;
//}
//%end

%ctor {
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  
  if ([bundleID isEqualToString:@"com.apple.springboard"]) {
    [WebMessageIPC sharedInstance];
  }
}
