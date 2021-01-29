//
//  IPCSender.h
//  WebMessage
//
//  Created by Aziz Hasanain on 12/4/20.
//

#ifndef IPCSender_h
#define IPCSender_h
#import <MRYIPCCenter.h>

@interface IPCSender : NSObject

@property (strong) MRYIPCCenter* center;

- (id)init;
- (void)sendText:(NSString *)text withSubject:(NSString *)subject toAddress:(NSString *)address withAttachments:(NSArray *)paths;
- (void)sendFakeText;
- (void)setAsRead:(NSString *)chat_id;
@end

@interface IPCWatcher : NSObject

@property (copy) void(^setTexts)(NSString *);
@property (copy) void(^stopWebserver)(id);
@property (copy) void(^setTyping)(NSString *);
+ (instancetype)sharedInstance;
- (instancetype)init;
- (void)handleReceivedTextWithCallback:(NSString *)chat_id;
//- (void)handlePartyTypingWithCallback:(NSString *)chat_id;

@end

@interface CKConversationList
+ (id)sharedConversationList;
- (id)conversationForExistingChatWithGroupID:(NSString *)arg1;
@end

@interface CKConversation
- (void)setLocalUserIsTyping:(_Bool)arg1;
@end


#endif
