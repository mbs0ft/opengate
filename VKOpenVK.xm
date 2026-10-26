#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <string.h>

static NSString *kOwnerID = @"674";
static NSString *lastUploadServer = nil;
static NSString *lastUploadHash = nil;
static NSString *lastUploadPhoto = nil;
static NSString *cachedToken = nil;
static NSString *cachedInstance = nil;

NSString *regexReplace(NSString *str, NSString *pattern, NSString *replacement) {
    if (!str) return str;
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern 
                                                                           options:NSRegularExpressionCaseInsensitive 
                                                                             error:&error];
    if (error || !regex) return str;
    return [regex stringByReplacingMatchesInString:str 
                                           options:0 
                                             range:NSMakeRange(0, str.length) 
                                      withTemplate:replacement];
}

NSDictionary *injectPeerIdIfNeeded(NSDictionary *item) {
    if (![item isKindOfClass:[NSDictionary class]]) return item;
    NSMutableDictionary *newItem = [item mutableCopy];
    
    if (item[@"chat_id"] && !item[@"peer_id"]) {
        long long chatId = [item[@"chat_id"] longLongValue];
        newItem[@"peer_id"] = @(2000000000LL + chatId);
    } else if (item[@"user_id"] && !item[@"peer_id"]) {
        newItem[@"peer_id"] = item[@"user_id"];
    } else if (item[@"from_id"] && !item[@"peer_id"]) {
        newItem[@"peer_id"] = item[@"from_id"];
    }
    
    return newItem;
}

NSDictionary *injectPeerIdInHistory(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return dict;
    
    if (dict[@"items"] && [dict[@"items"] isKindOfClass:[NSArray class]]) {
        NSArray *items = dict[@"items"];
        NSMutableArray *newItems = [NSMutableArray arrayWithCapacity:items.count];
        for (id item in items) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                [newItems addObject:injectPeerIdIfNeeded(item)];
            } else {
                [newItems addObject:item];
            }
        }
        NSMutableDictionary *newDict = [dict mutableCopy];
        newDict[@"items"] = newItems;
        return newDict;
    }
    
    return dict;
}

static NSString *paramValue(NSString *url, NSString *name) {
    NSString *search = [NSString stringWithFormat:@"%@=", name];
    NSRange range = [url rangeOfString:search];
    if (range.location == NSNotFound) return nil;
    
    NSUInteger start = range.location + range.length;
    NSRange ampRange = [url rangeOfString:@"&" options:0 range:NSMakeRange(start, url.length - start)];
    NSString *value;
    if (ampRange.location == NSNotFound) {
        value = [url substringFromIndex:start];
    } else {
        value = [url substringWithRange:NSMakeRange(start, ampRange.location - start)];
    }
    return [value stringByRemovingPercentEncoding];
}

static void cacheTokenFromURL(NSString *urlStr) {
    if (cachedToken) return;
    NSString *token = paramValue(urlStr, @"access_token");
    if (token && token.length > 20) {
        cachedToken = token;
        [[NSUserDefaults standardUserDefaults] setObject:token forKey:@"opengate_cached_token"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"[OpenGate] Cached access_token (length=%lu)", (unsigned long)token.length);
    }
}

@interface UIViewController (OpenGateAdditions)
- (void)checkFirstLaunch;
- (void)showInstanceSelection;
@end

@interface OpenGateManager : NSObject
@property (nonatomic, strong) NSString *selectedInstance;
@property (nonatomic, strong) NSArray *availableInstances;
+ (instancetype)sharedManager;
- (void)saveSelectedInstance:(NSString *)instance;
- (NSString *)getSelectedInstance;
@end

@implementation OpenGateManager

+ (instancetype)sharedManager {
    static OpenGateManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.availableInstances = @[
            @"openvk.org",
            @"openvk.xyz",
            @"vepurovk.xyz",
            @"vepurovk.fun"
        ];
        [self loadSelectedInstance];
    }
    return self;
}

- (void)loadSelectedInstance {
    self.selectedInstance = [[NSUserDefaults standardUserDefaults] objectForKey:@"mbsoft.opengate.selectedInstance"] ?: @"openvk.org";
}

- (void)saveSelectedInstance:(NSString *)instance {
    self.selectedInstance = instance;
    [[NSUserDefaults standardUserDefaults] setObject:instance forKey:@"mbsoft.opengate.selectedInstance"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *)getSelectedInstance {
    return self.selectedInstance;
}

@end

NSString *rewriteURL(NSString *urlStr) {
    if (!urlStr || ![urlStr isKindOfClass:[NSString class]]) return nil;
    
    cacheTokenFromURL(urlStr);
    
    NSMutableString *newUrl = [urlStr mutableCopy];
    NSString *selectedInstance = [[OpenGateManager sharedManager] getSelectedInstance];
    cachedInstance = selectedInstance;
    
    [newUrl replaceOccurrencesOfString:@"api.vk.com" withString:selectedInstance options:0 range:NSMakeRange(0, newUrl.length)];
    [newUrl replaceOccurrencesOfString:@"oauth.vk.com" withString:selectedInstance options:0 range:NSMakeRange(0, newUrl.length)];
    [newUrl replaceOccurrencesOfString:@"vk.com" withString:selectedInstance options:0 range:NSMakeRange(0, newUrl.length)];
    [newUrl replaceOccurrencesOfString:@"vk.me" withString:selectedInstance options:0 range:NSMakeRange(0, newUrl.length)];
    
    NSString *versionFixed = regexReplace(newUrl, @"([?&]v=)5\\.\\d+", @"$15.75");
    newUrl = [versionFixed mutableCopy];
    
    [newUrl replaceOccurrencesOfString:@"method/photos.getProfileUploadServer" withString:@"method/photos.getOwnerPhotoUploadServer" options:0 range:NSMakeRange(0, newUrl.length)];
    [newUrl replaceOccurrencesOfString:@"method/photos.saveProfilePhoto" withString:@"method/photos.saveOwnerPhoto" options:0 range:NSMakeRange(0, newUrl.length)];
    
    if ([newUrl containsString:@"method/audio.setBroadcast"]) {
        if ([newUrl containsString:@"target="] && ![newUrl containsString:@"target_ids="]) {
            [newUrl replaceOccurrencesOfString:@"target=" withString:@"target_ids=" options:0 range:NSMakeRange(0, newUrl.length)];
        } else if (![newUrl containsString:@"target_ids="]) {
            [newUrl appendFormat:@"&target_ids=%@", kOwnerID];
        }
    }
    
    if ([newUrl containsString:@"method/photos.saveWallPhoto"]) {
        if (lastUploadServer && lastUploadHash && lastUploadPhoto) {
            NSURLComponents *components = [NSURLComponents componentsWithString:newUrl];
            NSMutableArray *queryItems = [NSMutableArray arrayWithArray:components.queryItems];
            
            for (int i = 0; i < queryItems.count; i++) {
                NSURLQueryItem *item = queryItems[i];
                if ([item.name isEqualToString:@"server"]) {
                    queryItems[i] = [NSURLQueryItem queryItemWithName:@"server" value:lastUploadServer];
                } else if ([item.name isEqualToString:@"hash"]) {
                    queryItems[i] = [NSURLQueryItem queryItemWithName:@"hash" value:lastUploadHash];
                } else if ([item.name isEqualToString:@"photo"]) {
                    queryItems[i] = [NSURLQueryItem queryItemWithName:@"photo" value:lastUploadPhoto];
                }
            }
            
            components.queryItems = queryItems;
            newUrl = [components.URL.absoluteString mutableCopy];
        }
    }
    
    if ([newUrl containsString:@"method/messages.getHistory"]) {
        NSString *peerId = paramValue(newUrl, @"peer_id");
        NSString *count = paramValue(newUrl, @"count");
        NSString *offset = paramValue(newUrl, @"offset");
        NSString *startMsgId = paramValue(newUrl, @"start_message_id");
        NSLog(@"[OpenGate] getHistory: peer_id=%@, count=%@, offset=%@, start_message_id=%@", 
              peerId ?: @"nil", count ?: @"nil", offset ?: @"nil", startMsgId ?: @"nil");
    }
    
    if ([newUrl containsString:@"method/execute"]) {
        NSRange qRange = [newUrl rangeOfString:@"?"];
        if (qRange.location != NSNotFound) {
            NSString *base = [newUrl substringToIndex:qRange.location + 1];
            NSString *query = [newUrl substringFromIndex:qRange.location + 1];
            NSString *decoded = [query stringByRemovingPercentEncoding];
            if (!decoded) decoded = query;
            NSString *original = decoded;
            
            decoded = regexReplace(decoded, @"API\\.internal\\.getUserNotifications\\s*\\([^)]*\\)", @"{count:0, items:[]}");
            decoded = regexReplace(decoded, @"API\\.execute\\.newsfeed\\s*\\([^)]*\\)", @"API.newsfeed.get({count:20, filters:\"post,photo\", extended:1})");
            decoded = regexReplace(decoded, @"API\\.execute\\.newsfeedUpdateTimeout\\s*\\([^)]*\\)", @"0");
            decoded = regexReplace(decoded, @"API\\.internal\\.getSituationalSuggest\\s*\\([^)]*\\)", @"{items:[]}");
            decoded = regexReplace(decoded, @"API\\.video\\.getAlbums\\s*\\([^)]*\\)", @"{count:0, items:[]}");
            decoded = regexReplace(decoded, @"API\\.video\\.getAlbumById\\s*\\([^)]*\\)", @"{count:0, items:[]}");
            decoded = regexReplace(decoded, @"API\\.account\\.getMenu\\s*\\([^)]*\\)", @"{items:[]}");
            decoded = regexReplace(decoded, @"API\\.apps\\.getFromMenu\\s*\\([^)]*\\)", @"{items:[]}");
            decoded = regexReplace(decoded, @"API\\.store\\.hasNewItems\\s*\\([^)]*\\)", @"{stickers_version_hash:\"\"}");
            decoded = regexReplace(decoded, @"API\\.store\\.markAsViewed\\s*\\([^)]*\\)", @"false");
            decoded = regexReplace(decoded, @"API\\.store\\.getProducts\\s*\\([^)]*\\)", @"{items:[]}");
            decoded = regexReplace(decoded, @"API\\.masks\\.getModel\\s*\\([^)]*\\)", @"{engines:[]}");
            decoded = regexReplace(decoded, @"API\\.masks\\.getCatalog\\s*\\([^)]*\\)", @"{items:[]}");
            decoded = regexReplace(decoded, @"API\\.fave\\.getPhotos\\s*\\([^)]*\\)", @"{count:0, items:[]}");
            decoded = regexReplace(decoded, @"API\\.stories\\.get\\s*\\([^)]*\\)", @"{count:0, items:[]}");
            decoded = regexReplace(decoded, @"API\\.stats\\.trackEvents\\s*\\([^)]*\\)", @"1");
            decoded = regexReplace(decoded, @"API\\.stats\\.benchmark\\s*\\([^)]*\\)", @"{}");
            
            if (![decoded isEqualToString:original]) {
                NSString *encoded = [decoded stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                newUrl = [[base stringByAppendingString:encoded] mutableCopy];
            }
        }
    }
    
    if (![newUrl isEqualToString:urlStr]) {
        return newUrl;
    }
    return nil;
}

%hook NSURL

+ (instancetype)URLWithString:(NSString *)URLString {
    NSString *modified = rewriteURL(URLString);
    if (modified) {
        return [%c(NSURL) URLWithString:modified];
    }
    return %orig;
}

%end

%hook NSMutableURLRequest

- (instancetype)initWithURL:(NSURL *)URL {
    NSString *urlStr = [URL absoluteString];
    NSString *modified = rewriteURL(urlStr);
    if (modified) {
        NSURL *newURL = [%c(NSURL) URLWithString:modified];
        return %orig(newURL);
    }
    return %orig;
}

- (void)setHTTPBody:(NSData *)body {
    NSURL *url = [self URL];
    NSString *urlStr = [url absoluteString];
    
    if (body && body.length > 50 && [urlStr containsString:@"/method/"]) {
        NSString *bodyStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (bodyStr) {
            cacheTokenFromURL(bodyStr);
        }
    }
    
    if (urlStr && [urlStr containsString:@"/upload/photo/"]) {
        if (body && body.length > 100) {
            const void *bytes = [body bytes];
            NSUInteger len = body.length;
            const char *search = "name=\"file1\"";
            const char *replace = "name=\"photo\"";
            size_t searchLen = 12;
            
            void *found = memmem(bytes, len, search, searchLen);
            if (found) {
                NSMutableData *newBody = [body mutableCopy];
                void *newBytes = [newBody mutableBytes];
                ptrdiff_t offset = (char *)found - (char *)bytes;
                memcpy((char *)newBytes + offset, replace, searchLen);
                %orig(newBody);
                return;
            }
        }
    }
    %orig;
}

%end

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig;
    
    if (result && [result isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)result;
        
        if (dict[@"server"] && dict[@"hash"] && dict[@"photo"]) {
            lastUploadServer = [dict[@"server"] description];
            lastUploadHash = dict[@"hash"];
            lastUploadPhoto = dict[@"photo"];
        }
        
        if (dict[@"items"] && [dict[@"items"] isKindOfClass:[NSArray class]] && !dict[@"profiles"]) {
            NSArray *items = dict[@"items"];
            if (items.count > 0) {
                NSDictionary *firstItem = items[0];
                BOOL hasUserId = firstItem[@"user_id"] != nil;
                BOOL hasChatId = firstItem[@"chat_id"] != nil;
                BOOL hasBody = firstItem[@"body"] != nil;
                BOOL hasTitle = firstItem[@"title"] != nil;
                BOOL hasReadState = firstItem[@"read_state"] != nil;
                BOOL hasOut = firstItem[@"out"] != nil;
                
                BOOL isDialogs = (hasUserId || hasChatId) && (hasBody || hasTitle || hasReadState || hasOut);
                
                if (isDialogs) {
                    NSString *token = cachedToken;
                    if (!token) {
                        token = [[NSUserDefaults standardUserDefaults] objectForKey:@"opengate_cached_token"];
                    }
                    
                    if (token && cachedInstance) {
                        NSLog(@"[OpenGate] Detected getDialogs response (%lu items), auto-loading profiles...", 
                              (unsigned long)items.count);
                        
                        NSMutableSet *userIds = [NSMutableSet set];
                        for (NSDictionary *item in items) {
                            NSNumber *userId = item[@"user_id"];
                            if (userId && [userId integerValue] > 0) {
                                [userIds addObject:userId];
                            }
                        }
                        
                        if (userIds.count > 0) {
                            NSString *idsString = [[userIds allObjects] componentsJoinedByString:@","];
                            NSString *usersUrl = [NSString stringWithFormat:
                                @"https://%@/method/users.get?user_ids=%@&fields=photo_100,online,sex&v=5.75&access_token=%@",
                                cachedInstance, idsString, token];
                            
                            __block NSData *usersData = nil;
                            __block NSError *reqError = nil;
                            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                            
                            NSURLSession *session = [NSURLSession sharedSession];
                            NSURL *url = [NSURL URLWithString:usersUrl];
                            NSURLRequest *request = [NSURLRequest requestWithURL:url];
                            
                            NSURLSessionDataTask *task = [session dataTaskWithRequest:request 
                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                    usersData = data;
                                    reqError = error;
                                    dispatch_semaphore_signal(sem);
                                }];
                            [task resume];
                            
                            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
                            
                            if (usersData && !reqError) {
                                NSDictionary *usersJson = [NSJSONSerialization JSONObjectWithData:usersData 
                                                                                       options:0 
                                                                                        error:nil];
                                if (usersJson && usersJson[@"response"] && [usersJson[@"response"] isKindOfClass:[NSArray class]]) {
                                    NSMutableDictionary *newDict = [dict mutableCopy];
                                    newDict[@"profiles"] = usersJson[@"response"];
                                    newDict[@"groups"] = @[];
                                    NSLog(@"[OpenGate] Successfully loaded %lu profiles for dialogs!", 
                                          (unsigned long)[usersJson[@"response"] count]);
                                    return injectPeerIdInHistory(newDict);
                                } else {
                                    NSLog(@"[OpenGate] Failed to parse users.get response");
                                }
                            } else {
                                NSLog(@"[OpenGate] Failed to fetch users.get: %@", reqError);
                            }
                        }
                    } else if (!token) {
                        NSLog(@"[OpenGate] No token available for getDialogs, skipping profiles");
                    }
                }
            }
            
            return injectPeerIdInHistory(dict);
        }
    }
    
    return result;
}

+ (id)JSONObjectWithStream:(NSInputStream *)stream options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig;
    
    if (result && [result isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)result;
        
        if (dict[@"server"] && dict[@"hash"] && dict[@"photo"]) {
            lastUploadServer = [dict[@"server"] description];
            lastUploadHash = dict[@"hash"];
            lastUploadPhoto = dict[@"photo"];
        }
        
        if (dict[@"items"] && (dict[@"count"] || dict[@"unread"] != nil)) {
            return injectPeerIdInHistory(dict);
        }
    }
    
    return result;
}

%end

%hook UIViewController

- (void)viewDidLoad {
    %orig;
    
    NSString *className = NSStringFromClass([self class]);
    if ([className isEqualToString:@"VKMainViewController"] || [className containsString:@"Main"]) {
        [self checkFirstLaunch];
    }
}

%new
- (void)checkFirstLaunch {
    if (![[NSUserDefaults standardUserDefaults] objectForKey:@"mbsoft.opengate.firstLaunchDone"]) {
        NSLog(@"[OpenGate] Tweak loaded! Version 0.1 alpha");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showInstanceSelection];
        });
    }
}

%new
- (void)showInstanceSelection {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"OpenGate v0.2-alpha"
                                                                   message:@"Выберите сервер OpenVK:"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    OpenGateManager *manager = [OpenGateManager sharedManager];
    
    for (NSString *instance in manager.availableInstances) {
        [alert addAction:[UIAlertAction actionWithTitle:instance
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [manager saveSelectedInstance:action.title];
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"mbsoft.opengate.firstLaunchDone"];
        }]];
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

%end