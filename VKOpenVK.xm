#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <string.h>

static NSString *kOwnerID = @"674";
static NSString *lastUploadServer = nil;
static NSString *lastUploadHash = nil;
static NSString *lastUploadPhoto = nil;
static NSString *cachedToken = nil;
static NSString *cachedInstance = nil;
static NSString *g_lastPhotoId = nil;
static NSString *g_lastPhotoOwnerId = nil;
static NSDictionary *g_savedWallPhotoDict = nil;
static BOOL g_expectSaveWallPhoto = NO;
static BOOL g_expectDialogs = NO;
static BOOL g_isVK3 = NO;
static BOOL g_versionChecked = NO;

@interface NSObject (OpenGateWallFix)
- (id)mutableAttachments;
- (id)domain;
- (void)setDomain:(id)domain;
- (void)setOid:(id)oid;
- (void)setIid:(id)iid;
- (void)setIden:(id)iden;
- (void)setVariants:(id)variants;
- (void)setCan_edit:(BOOL)flag;
- (void)setHidden:(BOOL)flag;
- (void)setHasPhotoSizes:(BOOL)flag;
@end

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

static BOOL isVK3(void) {
    if (!g_versionChecked) {
        g_versionChecked = YES;
        NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        g_isVK3 = [v hasPrefix:@"3."];
        NSLog(@"[OpenGate] App version: %@, isVK3: %d", v, g_isVK3);
    }
    return g_isVK3;
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

static id normalizeNode(id node, NSInteger depth) {
    if (depth <= 0 || !node) return node;

    if ([node isKindOfClass:[NSArray class]]) {
        NSArray *arr = node;
        NSMutableArray *out = nil;
        for (NSUInteger i = 0; i < arr.count; i++) {
            id fixed = normalizeNode(arr[i], depth - 1);
            if (fixed != arr[i]) {
                if (!out) out = [NSMutableArray arrayWithArray:arr];
                out[i] = fixed;
            }
        }
        return out ?: node;
    }

    if (![node isKindOfClass:[NSDictionary class]]) return node;
    NSDictionary *d = node;
    NSMutableDictionary *m = nil;

    id sizes = d[@"sizes"];
    if ([sizes isKindOfClass:[NSArray class]] && !d[@"photo_604"] && (d[@"id"] || d[@"pid"]) && (d[@"owner_id"] || d[@"user_id"])) {
        for (id s in sizes) {
            if (![s isKindOfClass:[NSDictionary class]]) continue;
            NSString *t = [s[@"type"] description];
            NSString *u = s[@"url"] ?: s[@"src"];
            if (!t || !u) continue;
            if ([t isEqualToString:@"s"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_75"] = u;
                m[@"src_small"] = u;
            }
            if ([t isEqualToString:@"m"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_130"] = u;
            }
            if ([t isEqualToString:@"x"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_604"] = u;
                m[@"src"] = u;
                m[@"src_big"] = u;
            }
            if ([t isEqualToString:@"y"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_807"] = u;
                m[@"src_xbig"] = u;
            }
            if ([t isEqualToString:@"z"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_1280"] = u;
                m[@"src_xxbig"] = u;
            }
            if ([t isEqualToString:@"w"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_2560"] = u;
                m[@"src_xxxbig"] = u;
            }
        }
    }

    id image = d[@"image"];
    if ([image isKindOfClass:[NSArray class]] && (d[@"player"] || d[@"duration"])) {
        for (id s in image) {
            if (![s isKindOfClass:[NSDictionary class]]) continue;
            NSString *u = s[@"url"];
            NSInteger w = [s[@"width"] integerValue];
            if (!u) continue;
            if (w <= 130 && !d[@"photo_130"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_130"] = u;
            }
            if (w > 130 && w <= 320 && !d[@"photo_320"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_320"] = u;
            }
            if (w > 320 && w <= 640 && !d[@"photo_640"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_640"] = u;
            }
            if (w > 640 && !d[@"photo_807"]) {
                if (!m) m = [d mutableCopy];
                m[@"photo_807"] = u;
            }
        }
    }

    if (d[@"post_type"] || (d[@"from_id"] && d[@"date"] && d[@"id"] && (d[@"text"] || d[@"attachments"] || d[@"copy_history"]))) {
        if (!d[@"likes"]) {
            if (!m) m = [d mutableCopy];
            m[@"likes"] = @{@"count": @0, @"user_likes": @0, @"can_like": @1, @"can_publish": @1};
        }
        if (!d[@"comments"]) {
            if (!m) m = [d mutableCopy];
            m[@"comments"] = @{@"count": @0, @"can_post": @1};
        }
        if (!d[@"reposts"]) {
            if (!m) m = [d mutableCopy];
            m[@"reposts"] = @{@"count": @0, @"user_reposted": @0};
        }
        if (!d[@"post_source"]) {
            if (!m) m = [d mutableCopy];
            m[@"post_source"] = @{@"type": @"api"};
        }
        if (!d[@"attachments"]) {
            if (!m) m = [d mutableCopy];
            m[@"attachments"] = @[];
        }
    }

    if (d[@"body"] && d[@"date"] && !d[@"peer_id"] && (d[@"user_id"] || d[@"chat_id"] || d[@"from_id"])) {
        long long pid = 0;
        if (d[@"chat_id"]) pid = 2000000000LL + [d[@"chat_id"] longLongValue];
        else if (d[@"user_id"]) pid = [d[@"user_id"] longLongValue];
        else pid = [d[@"from_id"] longLongValue];
        if (pid != 0) {
            if (!m) m = [d mutableCopy];
            m[@"peer_id"] = @(pid);
        }
    }

    NSDictionary *base = m ?: d;
    NSMutableDictionary *out2 = m;
    for (NSString *k in base) {
        id v = base[k];
        if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) {
            id fixed = normalizeNode(v, depth - 1);
            if (fixed != v) {
                if (!out2) out2 = [base mutableCopy];
                out2[k] = fixed;
            }
        }
    }
    return out2 ?: node;
}

static BOOL looksLikeDialogs(NSDictionary *rd) {
    id items = rd[@"items"];
    if (![items isKindOfClass:[NSArray class]] || [(NSArray *)items count] == 0) return NO;
    id first = [(NSArray *)items objectAtIndex:0];
    if (![first isKindOfClass:[NSDictionary class]]) return NO;
    BOOL msgLike = (first[@"body"] || first[@"title"] || first[@"read_state"] || first[@"out"] != nil);
    BOOL peerLike = (first[@"user_id"] || first[@"chat_id"] || first[@"from_id"]);
    return msgLike && peerLike && !first[@"post_type"];
}

static NSArray *fetchProfilesForIds(NSSet *ids) {
    NSString *token = cachedToken ?: [[NSUserDefaults standardUserDefaults] objectForKey:@"opengate_cached_token"];
    if (!token || !cachedInstance || ids.count == 0) return nil;
    NSString *idsString = [[ids allObjects] componentsJoinedByString:@","];
    NSString *url = [NSString stringWithFormat:@"https://%@/method/users.get?user_ids=%@&fields=photo_100,online,sex&v=5.75&access_token=%@", cachedInstance, idsString, token];
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];
    __block NSData *respData = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        respData = data;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
    if (!respData) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
    id resp = json[@"response"];
    if ([resp isKindOfClass:[NSArray class]]) return resp;
    return nil;
}

static id dedupeUpdates(NSDictionary *outer) {
    id updates = outer[@"updates"];
    if (![updates isKindOfClass:[NSArray class]]) return nil;
    static NSMutableSet *seen = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ seen = [NSMutableSet set]; });
    NSMutableArray *kept = [NSMutableArray array];
    BOOL changed = NO;
    for (id ev in updates) {
        if ([ev isKindOfClass:[NSArray class]] && [(NSArray *)ev count] > 1 && [[ev[0] description] isEqualToString:@"messages_new"]) {
            NSString *mid = [ev[1] description];
            @synchronized (seen) {
                if ([seen containsObject:mid]) { changed = YES; continue; }
                [seen addObject:mid];
                if (seen.count > 3000) { [seen removeAllObjects]; [seen addObject:mid]; }
            }
        }
        [kept addObject:ev];
    }
    if (!changed) return nil;
    NSLog(@"[OpenGate] Longpoll dedupe: dropped duplicates, kept %lu", (unsigned long)kept.count);
    NSMutableDictionary *copy = [outer mutableCopy];
    copy[@"updates"] = kept;
    return copy;
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
    [newUrl replaceOccurrencesOfString:@"method/messages.getConversations" withString:@"method/messages.getDialogs" options:0 range:NSMakeRange(0, newUrl.length)];

    if ([newUrl containsString:@"method/audio.setBroadcast"]) {
        if ([newUrl containsString:@"target="] && ![newUrl containsString:@"target_ids="]) {
            [newUrl replaceOccurrencesOfString:@"target=" withString:@"target_ids=" options:0 range:NSMakeRange(0, newUrl.length)];
        } else if (![newUrl containsString:@"target_ids="]) {
            [newUrl appendFormat:@"&target_ids=%@", kOwnerID];
        }
    }

    if ([newUrl containsString:@"method/photos.saveWallPhoto"]) {
        g_expectSaveWallPhoto = YES;
        if (lastUploadServer && lastUploadHash && lastUploadPhoto) {
            NSURLComponents *components = [NSURLComponents componentsWithString:newUrl];
            NSMutableArray *queryItems = [NSMutableArray arrayWithArray:components.queryItems];
            for (NSUInteger i = 0; i < queryItems.count; i++) {
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

    if ([newUrl containsString:@"method/messages.getDialogs"]) {
        g_expectDialogs = YES;
    }

    if ([newUrl containsString:@"method/execute"]) {
        NSRange qRange = [newUrl rangeOfString:@"?"];
        if (qRange.location != NSNotFound) {
            NSString *base = [newUrl substringToIndex:qRange.location + 1];
            NSString *query = [newUrl substringFromIndex:qRange.location + 1];
            NSString *decoded = [query stringByRemovingPercentEncoding];
            if (!decoded) decoded = query;
            NSString *original = decoded;

            decoded = regexReplace(decoded, @"API\\.execute\\.newsfeed\\s*\\([^)]*\\)", @"API.newsfeed.get({count:20, filters:\"post,photo\", extended:1})");
            decoded = regexReplace(decoded, @"API\\.execute\\.newsfeedUpdateTimeout\\s*\\([^)]*\\)", @"0");
            decoded = regexReplace(decoded, @"API\\.internal\\.getSituationalSuggest\\s*\\([^)]*\\)", @"{items:[]}");
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

            if (isVK3()) {
                decoded = regexReplace(decoded, @"API\\.internal\\.getUserNotifications\\s*\\([^)]*\\)", @"API.notifications.get({count:50, extended:1})");
            } else {
                decoded = regexReplace(decoded, @"API\\.internal\\.getUserNotifications\\s*\\([^)]*\\)", @"{count:0, items:[]}");
                decoded = regexReplace(decoded, @"API\\.video\\.getAlbums\\s*\\([^)]*\\)", @"{count:0, items:[]}");
                decoded = regexReplace(decoded, @"API\\.video\\.getAlbumById\\s*\\([^)]*\\)", @"{count:0, items:[]}");
            }

            if (g_lastPhotoId && g_lastPhotoOwnerId) {
                NSRegularExpression *wallRe = [NSRegularExpression regularExpressionWithPattern:@"API\\.wall\\.post\\((\\{[^}]*\\})\\)" options:0 error:nil];
                NSTextCheckingResult *wallMatch = [wallRe firstMatchInString:decoded options:0 range:NSMakeRange(0, decoded.length)];
                if (wallMatch && [wallMatch numberOfRanges] > 1) {
                    NSRange jsonRange = [wallMatch rangeAtIndex:1];
                    NSString *wallJson = [decoded substringWithRange:jsonRange];
                    if (![wallJson containsString:@"attachments"]) {
                        NSString *tail = [NSString stringWithFormat:@",\"attachments\":\"photo%@_%@\"}", g_lastPhotoOwnerId, g_lastPhotoId];
                        NSString *newJson = [wallJson stringByReplacingCharactersInRange:NSMakeRange(wallJson.length - 1, 1) withString:tail];
                        decoded = [decoded stringByReplacingCharactersInRange:jsonRange withString:newJson];
                        NSLog(@"[OpenGate] Injected attachments into wall.post: photo%@_%@", g_lastPhotoOwnerId, g_lastPhotoId);
                        g_lastPhotoId = nil;
                        g_lastPhotoOwnerId = nil;
                    }
                }
            }

            if (![decoded isEqualToString:original]) {
                NSString *encoded = [decoded stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
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

%hook NSURLRequest

- (instancetype)initWithURL:(NSURL *)URL {
    NSString *urlStr = [URL absoluteString];
    NSString *modified = rewriteURL(urlStr);
    if (modified) {
        NSURL *newURL = [NSURL URLWithString:modified];
        return %orig(newURL);
    }
    return %orig;
}

%end

%hook NSMutableURLRequest

- (instancetype)initWithURL:(NSURL *)URL cachePolicy:(NSURLRequestCachePolicy)cachePolicy timeoutInterval:(NSTimeInterval)timeoutInterval {
    NSString *urlStr = [URL absoluteString];
    
    if ([urlStr containsString:@"method/execute"] && 
        [urlStr containsString:@"wall.post"] && 
        ![urlStr containsString:@"attachments"]) {
        
        if (g_lastPhotoId && g_lastPhotoOwnerId) {
            NSString *modified = rewriteURL(urlStr);
            if (modified && [modified containsString:@"attachments"]) {
                NSURL *newURL = [NSURL URLWithString:modified];
                return %orig(newURL, cachePolicy, timeoutInterval);
            }
        }
        
        NSLog(@"[OpenGate] >>> Blocked wall.post without attachments <<<");
        NSURL *fakeURL = [NSURL URLWithString:@"https://openvk.org/method/dummy"];
        return %orig(fakeURL, cachePolicy, timeoutInterval);
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

%hook NSHTTPURLResponse

- (NSInteger)statusCode {
    NSInteger code = %orig;
    if (code == 202) {
        NSString *urlStr = [[self URL] absoluteString];
        if ([urlStr containsString:@"/upload/photo/"]) {
            return 200;
        }
    }
    return code;
}

%end

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig;
    if (!result || ![result isKindOfClass:[NSDictionary class]]) return result;

    @try {
        NSDictionary *outer = result;

        if (outer[@"server"] && outer[@"hash"] && outer[@"photo"]) {
            lastUploadServer = [outer[@"server"] description];
            lastUploadHash = outer[@"hash"];
            lastUploadPhoto = outer[@"photo"];
        }

        id deduped = dedupeUpdates(outer);
        if (deduped) outer = deduped;

        id resp = outer[@"response"];

        if (g_expectSaveWallPhoto && [resp isKindOfClass:[NSArray class]]) {
            NSArray *arr = resp;
            if (arr.count > 0 && [arr[0] isKindOfClass:[NSDictionary class]] && arr[0][@"pid"] && arr[0][@"owner_id"]) {
                g_lastPhotoId = [(arr[0][@"id"] ?: arr[0][@"pid"]) description];
                g_lastPhotoOwnerId = [arr[0][@"owner_id"] description];
                g_expectSaveWallPhoto = NO;
                NSLog(@"[OpenGate] saveWallPhoto converted, photo=%@_%@", g_lastPhotoOwnerId, g_lastPhotoId);
                return @{ @"response": arr[0] };
            }
        }

        if ([resp isKindOfClass:[NSDictionary class]]) {
            NSDictionary *rd = resp;
            NSMutableDictionary *mrd = nil;

            if (rd[@"items"] && !rd[@"count"]) {
                mrd = [rd mutableCopy];
                mrd[@"count"] = @([(NSArray *)rd[@"items"] count]);
            }

            if (g_expectDialogs && looksLikeDialogs(rd) && !rd[@"profiles"]) {
                if (!mrd) mrd = [rd mutableCopy];
                NSMutableSet *userIds = [NSMutableSet set];
                for (id item in rd[@"items"]) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSNumber *uid = item[@"user_id"];
                    if (uid && [uid integerValue] > 0) [userIds addObject:[uid description]];
                }
                NSArray *profiles = fetchProfilesForIds(userIds);
                if (profiles) {
                    mrd[@"profiles"] = profiles;
                    mrd[@"groups"] = @[];
                    NSLog(@"[OpenGate] Injected %lu profiles into dialogs", (unsigned long)profiles.count);
                }
                g_expectDialogs = NO;
            }

            id normalized = normalizeNode(mrd ?: rd, 8);

            if (normalized != rd || mrd) {
                NSMutableDictionary *newOuter = [outer mutableCopy];
                newOuter[@"response"] = normalized;
                return newOuter;
            }
            if (deduped) return outer;
            return result;
        }

        id normalizedOuter = normalizeNode(outer, 6);
        if (normalizedOuter != outer) return normalizedOuter;
        if (deduped) return outer;
    } @catch (NSException *e) {
        NSLog(@"[OpenGate] JSON patch exception: %@", e);
    }

    return result;
}

+ (id)JSONObjectWithStream:(NSInputStream *)stream options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig;
    if (result && [result isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = result;
        if (dict[@"server"] && dict[@"hash"] && dict[@"photo"]) {
            lastUploadServer = [dict[@"server"] description];
            lastUploadHash = dict[@"hash"];
            lastUploadPhoto = dict[@"photo"];
        }
    }
    return result;
}

%end

@interface WallPhotoUploadContext : NSObject
- (BOOL)handleResultServerData:(id)serverData uploadData:(id)uploadData saveData:(id)saveData;
@end

@interface WallPostEditContext : NSObject
- (void)complete;
@end

%hook WallPhotoUploadContext

- (BOOL)handleResultServerData:(id)serverData uploadData:(id)uploadData saveData:(id)saveData {
    NSDictionary *photoDict = nil;
    
    if ([saveData isKindOfClass:[NSArray class]] && [(NSArray *)saveData count] > 0) {
        id first = [(NSArray *)saveData objectAtIndex:0];
        if ([first isKindOfClass:[NSDictionary class]]) {
            photoDict = first;
        }
    } else if ([saveData isKindOfClass:[NSDictionary class]]) {
        photoDict = saveData;
    }
    
    if (photoDict && photoDict[@"owner_id"] && (photoDict[@"id"] || photoDict[@"pid"])) {
        g_savedWallPhotoDict = photoDict;
        NSLog(@"[OpenGate] Saved wall photo dict: owner=%@, id=%@", photoDict[@"owner_id"], photoDict[@"id"] ?: photoDict[@"pid"]);
    }
    
    %orig;
    return YES;
}

%end

%hook WallPostEditContext

- (void)complete {
    if (g_savedWallPhotoDict) {
        @try {
            id container = [self valueForKey:@"_attachmentsContainer"];
            if (container) {
                id mutableAtt = [container mutableAttachments];
                if ([mutableAtt respondsToSelector:@selector(count)] && [mutableAtt count] > 0) {
                    id editAtt = [mutableAtt objectAtIndex:0];
                    id identity = [[%c(VKIdentity) alloc] init];
                    [identity setOid:g_savedWallPhotoDict[@"owner_id"]];
                    [identity setIid:g_savedWallPhotoDict[@"id"]];
                    id photo = [[%c(VKPhoto) alloc] init];
                    [photo setIden:identity];
                    [photo setVariants:[NSMutableDictionary dictionary]];
                    [photo setCan_edit:YES];
                    [photo setHidden:NO];
                    [photo setHasPhotoSizes:YES];
                    if ([editAtt respondsToSelector:@selector(setDomain:)]) {
                        [editAtt setDomain:photo];
                    }
                }
            }
        } @catch (NSException *e) {
        }
        g_savedWallPhotoDict = nil;
    }
    %orig;
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
        NSLog(@"[OpenGate] Tweak loaded, first launch");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showInstanceSelection];
        });
    }
}

%new
- (void)showInstanceSelection {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"OpenGate v0.3-alpha"
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