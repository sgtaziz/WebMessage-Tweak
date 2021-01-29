#include "saWebMessageRootListController.h"

@implementation saWebMessageRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    
//    PSSpecifier *specifier = [self specifierForID:@"IPTextCell"];
//    [specifier setProperty:@"" forKey:@"label"];
//    [specifier setProperty:@"dwa" forKey:@"placeholder"];
    
    NSString* title = [NSString stringWithFormat:@"IP Address: %@", [self getIPAddress]];
    
    PSSpecifier* groupCellSpecifier = [PSSpecifier preferenceSpecifierNamed:title
      target:self
      set:@selector(setPreferenceValue:specifier:)
      get:@selector(readPreferenceValue:)
      detail:Nil
      cell:PSGroupCell
      edit:Nil];
    
//    [_specifiers addObject:groupCellSpecifier];
    [self insertContiguousSpecifiers:@[groupCellSpecifier] afterSpecifierID:@"ssl"];
	}

	return _specifiers;
}

- (void)stopDaemon {
  [self daemonStop];
  
  UIAlertController * alert = [UIAlertController
    alertControllerWithTitle:@"WebMessage"
    message:@"WebMessage is restarting. This might take a few seconds."
    preferredStyle:UIAlertControllerStyleAlert];
  
  UIAlertAction* ok = [UIAlertAction
    actionWithTitle:@"OK"
    style:UIAlertActionStyleDefault
    handler:^(UIAlertAction * action)
    {
      [alert dismissViewControllerAnimated:YES completion:nil];
    }];
  
  [alert addAction:ok];
   
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)daemonStop {
  MRYIPCCenter *center = [MRYIPCCenter centerNamed:@"com.sgtaziz.webmessagelistener"];
  [center callExternalVoidMethod:@selector(stopWebserver:) withArguments:nil];
}

- (NSString*)getIPAddress {
  NSString *address = @"error";
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = 0;

  // retrieve the current interfaces - returns 0 on success
  success = getifaddrs(&interfaces);
  if (success == 0) {
    // Loop through linked list of interfaces
    temp_addr = interfaces;
    while(temp_addr != NULL) {
      if(temp_addr->ifa_addr->sa_family == AF_INET) {
        // Check if interface is en0 which is the wifi connection on the iPhone
        if([[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
          // Get NSString from C String
          address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
        }
      }

      temp_addr = temp_addr->ifa_next;
    }
  }
  
  // Free memory
  freeifaddrs(interfaces);
  return address;
}

- (id)readPreferenceValue:(PSSpecifier*)specifier {
  NSString *path = [NSString stringWithFormat:@"/User/Library/Preferences/%@.plist", specifier.properties[@"defaults"]];
  NSMutableDictionary *settings = [NSMutableDictionary dictionary];
  [settings addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:path]];
  return (settings[specifier.properties[@"id"]]) ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {
  NSString* perfValue = [NSString stringWithFormat:@"%@", value];
  
  NSString *path = [NSString stringWithFormat:@"/User/Library/Preferences/%@.plist", specifier.properties[@"defaults"]];
  NSMutableDictionary *settings = [NSMutableDictionary dictionary];
  [settings addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:path]];
  id defaultPort = @8180;
  
  if ([specifier.properties[@"id"] isEqual:@"port"] && ![self isPort:value]) {
    perfValue = settings[@"port"] ?: defaultPort;
  }
  
  [settings setObject:perfValue forKey:specifier.properties[@"id"]];
  [settings writeToFile:path atomically:YES];
  
  CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.sgtaziz.webmessage.settingschanged"), NULL, NULL, YES);
  
  [self daemonStop];
  
  if ([specifier.properties[@"id"] isEqual:@"port"] && ![self isPort:value]) {
    [self loadView];
  }
}

- (BOOL)isPort: (NSString*)text {
  NSString* regex = @"([0-9]{1,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])";
  NSPredicate *portTest = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", regex];
  
  return [portTest evaluateWithObject:text];
}
@end
