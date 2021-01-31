#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#include <HBLog.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#import <MRYIPCCenter.h>
#import <spawn.h>

@interface saWebMessageRootListController : PSListController
  @property (nonatomic, retain) NSMutableDictionary *savedSpecifiers;
@end

