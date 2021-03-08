//
//  IPCSender.m
//  WebMessage
//
//  Created by Aziz Hasanain on 12/4/20. Modified from libsmserver
//

#import <Foundation/Foundation.h>
#import "IPCSender.h"

@implementation IPCSender

- (id)init {
  if (self = [super init]) {
    self.center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessage"];
  }
  
  return self;
}

- (void)sendFakeText {
  [self.center callExternalVoidMethod:@selector(sendText:) withArguments:@{ @"text": @"", @"subject": @"", @"address": @"", @"attachment": @[] }];
}

- (void)sendText:(NSString *)text withSubject:(NSString *)subject toAddress:(NSString *)address withAttachments:(NSArray *)paths {
  [self.center callExternalVoidMethod:@selector(sendText:) withArguments:@{ @"text": text, @"subject": subject, @"address": address, @"attachment": paths }];
}

- (void)sendReaction:(NSNumber *)reactionId forGuid:(NSString *)guid forChatId:(NSString *)chat_id forPart:(NSNumber *)part {
  [self.center callExternalVoidMethod:@selector(sendReaction:) withArguments:@{ @"reactionId": reactionId, @"guid": guid, @"chat_id": chat_id, @"part": part }];
}

- (void)setIsLocallyTyping:(bool)isTyping forChatId:(NSString *)chat_id {
  [self.center callExternalVoidMethod:@selector(setIsLocallyTyping:) withArguments:@{ @"chat_id": chat_id, @"typing": @(isTyping) }];
}

- (void)deleteChat:(NSString *)chat_id {
  [self.center callExternalVoidMethod:@selector(deleteChat:) withArguments:@{ @"chat": chat_id }];
}

- (void)setAsRead:(NSString *)chat_id {
  NSArray* chats = [chat_id componentsSeparatedByString:@","]; /// To allow marking multiple convos as read
  for (NSString* chat in chats) {
    [self.center callExternalVoidMethod:@selector(setAsRead:) withArguments:chat];
  }
}

@end


@implementation IPCWatcher {
  MRYIPCCenter* _center;
}

+ (instancetype)sharedInstance {
  static dispatch_once_t onceToken = 0;
  __strong static IPCWatcher* sharedInstance = nil;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  if ((self = [super init])) {
    _center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
    [_center addTarget:self action:@selector(handleReceivedTextWithCallback:)];
    [_center addTarget:self action:@selector(stopWebserver:)];
    [_center addTarget:self action:@selector(handleSetMessageAsRead:)];
    [_center addTarget:self action:@selector(handleChatRemoved:)];
    [_center addTarget:self action:@selector(handleChangeTypingIndicator:)];
  }
  return self;
}

- (void)handleReceivedTextWithCallback:(NSString *)guid {
  _setTexts(guid);
}

- (void)stopWebserver:(id)arg {
  _stopWebserver(arg);
}

- (void)handleSetMessageAsRead:(NSDictionary *)args {
  _setMessageAsRead(args);
}

- (void)handleChatRemoved:(NSString *)chat_id {
  _removeChat(chat_id);
}

- (void)handleChangeTypingIndicator:(NSDictionary *)args {
  _setTypingIndicator(args);
}

@end

