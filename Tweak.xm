#import <Foundation/Foundation.h>

%ctor {
    NSLog(@"[OpenGate] Tweak loaded! Version 0.3-alpha");

    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"mbsoft.opengate.enabled"] == nil) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"mbsoft.opengate.enabled"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}