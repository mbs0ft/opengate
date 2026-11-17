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
static NSMutableDictionary *g_audioCache = nil;
static NSString *g_audioUserId = nil;
static BOOL g_expectSaveWallPhoto = NO;
static BOOL g_expectDialogs = NO;
static BOOL g_expectHints = NO;
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

static BOOL looksLikePhotoDict(NSDictionary *d) {
    if (!(d[@"pid"] || d[@"id"])) return NO;
    if (!d[@"owner_id"]) return NO;
    return (d[@"sizes"] || d[@"photo_604"] || d[@"album_id"]);
}

static void collectAudio(id node, NSInteger depth) {
    if (depth <= 0 || !node) return;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) collectAudio(v, depth - 1);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *d = node;
    if (d[@"artist"] && d[@"title"] && d[@"owner_id"] && d[@"id"]) {
        if (!g_audioCache) g_audioCache = [NSMutableDictionary dictionary];
        NSString *key = [NSString stringWithFormat:@"%@_%@", d[@"owner_id"], d[@"id"]];
        g_audioCache[key] = d;
    }
    for (NSString *k in d) {
        id v = d[k];
        if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) collectAudio(v, depth - 1);
    }
}

static NSDictionary *fixNotifs(NSDictionary *rd) {
    if (!rd[@"notifications"] && !rd[@"friend_requests"]) return nil;
    NSMutableDictionary *m = [rd mutableCopy];
    BOOL changed = NO;
    for (NSString *k in @[@"unreadFriendsCount", @"unreadFriendsBadgeCount", @"unreadNotificationsCount"]) {
        if (!m[k] || m[k] == [NSNull null]) {
            m[k] = @0;
            changed = YES;
        }
    }
    if ([m[@"friend_requests"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *fr = [m[@"friend_requests"] mutableCopy];
        if (!fr[@"count_unread"] || fr[@"count_unread"] == [NSNull null]) {
            fr[@"count_unread"] = @0;
            changed = YES;
        }
        m[@"friend_requests"] = fr;
    }
    if ([m[@"notifications"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *n = [m[@"notifications"] mutableCopy];
        if ([n[@"items"] isKindOfClass:[NSArray class]] && !n[@"count"]) {
            n[@"count"] = @([(NSArray *)n[@"items"] count]);
            changed = YES;
        }
        m[@"notifications"] = n;
    }
    return changed ? m : nil;
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

    if (looksLikePhotoDict(d)) {
        NSNumber *al = d[@"album_id"];
        NSNumber *aid = d[@"aid"];
        if ((al && [al integerValue] == 0) || (aid && [aid integerValue] == 0)) {
            if (!m) m = [d mutableCopy];
            m[@"album_id"] = @(-7);
            m[@"aid"] = @(-7);
        }
    }

    if ([d[@"post_source"] isKindOfClass:[NSDictionary class]] && [d[@"post_source"][@"type"] isEqualToString:@"api"]) {
        if (!m) m = [d mutableCopy];
        NSMutableDictionary *ps = [d[@"post_source"] mutableCopy];
        ps[@"type"] = @"vk";
        m[@"post_source"] = ps;
    }

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
        NSDictionary *cur = m ?: d;
        if (!cur[@"photo_130"] && [(NSArray *)image count] > 0 && [image[0] isKindOfClass:[NSDictionary class]] && image[0][@"url"]) {
            if (!m) m = [d mutableCopy];
            m[@"photo_130"] = image[0][@"url"];
            cur = m;
        }
        if (!cur[@"photo_320"] && cur[@"photo_130"]) {
            if (!m) m = [d mutableCopy];
            m[@"photo_320"] = cur[@"photo_130"];
            cur = m;
        }
        if (!cur[@"photo_640"] && cur[@"photo_320"]) {
            if (!m) m = [d mutableCopy];
            m[@"photo_640"] = cur[@"photo_320"];
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
            m[@"post_source"] = @{@"type": @"vk"};
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

    if ([newUrl containsString:@"method/audio.search"]) {
        newUrl = [regexReplace(newUrl, @"([?&])search_own=[^&]*", @"$1") mutableCopy];
        newUrl = [regexReplace(newUrl, @"([?&])auto_complete=[^&]*", @"$1") mutableCopy];
        newUrl = [regexReplace(newUrl, @"[?&]$", @"") mutableCopy];
    }

    if ([newUrl containsString:@"method/search.getHints"]) {
        g_expectHints = YES;
    }

    if ([newUrl containsString:@"method/newsfeed.getDiscover"]) {
        [newUrl replaceOccurrencesOfString:@"method/newsfeed.getDiscover" withString:@"method/newsfeed.get" options:0 range:NSMakeRange(0, newUrl.length)];
        newUrl = [regexReplace(newUrl, @"([?&])(intent|templates)=[^&]*", @"$1") mutableCopy];
        newUrl = [regexReplace(newUrl, @"[?&]$", @"") mutableCopy];
    }

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

            NSRange codeStart = [query rangeOfString:@"code="];
            if (codeStart.location != NSNotFound) {
                NSUInteger codeValueStart = codeStart.location + codeStart.length;
                NSRange ampRange = [query rangeOfString:@"&" options:0 range:NSMakeRange(codeValueStart, query.length - codeValueStart)];

                NSString *beforeCode = [query substringToIndex:codeValueStart];
                NSString *afterCode = @"";
                NSString *encodedCodeValue;

                if (ampRange.location == NSNotFound) {
                    encodedCodeValue = [query substringFromIndex:codeValueStart];
                } else {
                    encodedCodeValue = [query substringWithRange:NSMakeRange(codeValueStart, ampRange.location - codeValueStart)];
                    afterCode = [query substringFromIndex:ampRange.location];
                }

                NSString *decoded = [encodedCodeValue stringByRemovingPercentEncoding];
                if (!decoded) decoded = encodedCodeValue;
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

                decoded = regexReplace(decoded, @"audio:API\\.audio\\.getById\\(\\{audios:\"\\d+\" \\+ audio_id\\}\\)\\[0\\],", @"audio:null,");
                decoded = regexReplace(decoded, @",filters:\"[^\"]*\"", @"");
                decoded = regexReplace(decoded, @",filter:\"\"", @"");
                decoded = regexReplace(decoded, @",filter:filter", @"");

                NSError *uidErr = nil;
                NSRegularExpression *uidRe = [NSRegularExpression regularExpressionWithPattern:@"user_id\"?\\s*:\\s*(\\d+)" options:0 error:&uidErr];
                NSTextCheckingResult *uidMatch = uidRe ? [uidRe firstMatchInString:decoded options:0 range:NSMakeRange(0, decoded.length)] : nil;
                if (uidMatch && [uidMatch numberOfRanges] > 1) {
                    NSString *uid = [decoded substringWithRange:[uidMatch rangeAtIndex:1]];
                    NSString *vidStub = [NSString stringWithFormat:@"API.video.get({owner_id:%@,count:1,offset:0})", uid];
                    decoded = regexReplace(decoded, @"API\\.video\\.getAlbums\\s*\\([^)]*\\)", vidStub);
                    decoded = regexReplace(decoded, @"API\\.video\\.getAlbumById\\s*\\([^)]*\\)", vidStub);
                }

                if (isVK3()) {
                    decoded = regexReplace(decoded, @"API\\.internal\\.getUserNotifications\\s*\\([^)]*\\)", @"API.notifications.get({count:50, extended:1})");
                } else {
                    decoded = regexReplace(decoded, @"API\\.internal\\.getUserNotifications\\s*\\([^)]*\\)", @"{count:0, items:[]}");
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
                    NSMutableCharacterSet *cs = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
                    [cs removeCharactersInString:@"&="];
                    NSString *encoded = [decoded stringByAddingPercentEncodingWithAllowedCharacters:cs];
                    encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
                    encoded = [encoded stringByReplacingOccurrencesOfString:@"&&" withString:@"%26%26"];
                    newUrl = [[base stringByAppendingString:beforeCode] mutableCopy];
                    [newUrl appendString:encoded];
                    [newUrl appendString:afterCode];
                }
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
            
            NSRange ownerRange = [bodyStr rangeOfString:@"owner_id="];
            if (ownerRange.location != NSNotFound) {
                NSUInteger start = ownerRange.location + 9;
                NSRange ampRange = [bodyStr rangeOfString:@"&" options:0 range:NSMakeRange(start, bodyStr.length - start)];
                NSString *ownerId;
                if (ampRange.location == NSNotFound) {
                    ownerId = [bodyStr substringFromIndex:start];
                } else {
                    ownerId = [bodyStr substringWithRange:NSMakeRange(start, ampRange.location - start)];
                }
                ownerId = [ownerId stringByRemovingPercentEncoding];
                if (ownerId && ownerId.length > 0) {
                    g_audioUserId = ownerId;
                }
            }
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

        id err = outer[@"error"];
        if ([err isKindOfClass:[NSDictionary class]] && [err[@"error_code"] integerValue] == 3) {
            NSString *method = nil;
            for (id p in err[@"request_params"]) {
                if ([p isKindOfClass:[NSDictionary class]] && [p[@"key"] isEqualToString:@"method"]) method = p[@"value"];
            }
            if ([method isEqualToString:@"audio.getSearchTrends"] || [method isEqualToString:@"audio.getHints"]) {
                return @{@"response": @{@"items": @[], @"count": @0}};
            }
            if ([method isEqualToString:@"account.getPingUrl"]) {
                return @{@"response": @""};
            }
            if ([method isEqualToString:@"account.getCommentGroups"]) {
                return @{@"response": @NO};
            }
            if ([method isEqualToString:@"search.getTrends"]) {
                return @{@"response": @{@"count": @0, @"items": @[]}};
            }
            if ([method isEqualToString:@"newsfeed.getComments"]) {
                return @{@"response": @{@"count": @0, @"items": @[], @"profiles": @[], @"groups": @[]}};
            }
            if ([method isEqualToString:@"newsfeed.getPromotionLists"]) {
                return @{@"response": @{@"items": @[]}};
            }
        }

        id deduped = dedupeUpdates(outer);
        if (deduped) outer = deduped;

        id resp = outer[@"response"];

        if (g_expectHints && [resp isKindOfClass:[NSArray class]]) {
            g_expectHints = NO;
            return @{@"response": @{@"count": @([(NSArray *)resp count]), @"items": resp}};
        }

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

            if (g_expectDialogs && [rd[@"items"] isKindOfClass:[NSArray class]]) {
                NSArray *items = rd[@"items"];
                if (items.count > 0 && [items[0] isKindOfClass:[NSDictionary class]] && items[0][@"body"] && !items[0][@"message"]) {
                    NSMutableArray *wrapped = [NSMutableArray array];
                    for (NSDictionary *msg in items) {
                        if (msg[@"message"]) { [wrapped addObject:msg]; continue; }
                        BOOL out = [msg[@"out"] boolValue];
                        BOOL read = [msg[@"read_state"] boolValue];
                        [wrapped addObject:@{
                            @"message": msg,
                            @"unread": @((!out && !read) ? 1 : 0),
                            @"in_read": @((!out && read) ? [msg[@"id"] integerValue] : 0),
                            @"out_read": @((out && read) ? [msg[@"id"] integerValue] : 0)
                        }];
                    }
                    if (!mrd) mrd = [rd mutableCopy];
                    mrd[@"items"] = wrapped;
                    NSLog(@"[OpenGate] dialogs wrapped n=%lu", (unsigned long)wrapped.count);
                }
            }

            if (g_expectDialogs && looksLikeDialogs(rd) && !rd[@"profiles"]) {
                if (!mrd) mrd = [rd mutableCopy];
                NSMutableSet *userIds = [NSMutableSet set];
                for (id item in rd[@"items"]) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *msg = item;
                    if ([item isKindOfClass:[NSDictionary class]] && item[@"message"]) {
                        msg = item[@"message"];
                    }
                    NSNumber *uid = msg[@"user_id"];
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

            NSDictionary *nf = fixNotifs(mrd ?: rd);
            if (nf) mrd = [nf mutableCopy];

            collectAudio(mrd ?: rd, 8);

            NSDictionary *cur = mrd ?: rd;
            if (cur[@"audio_id"] && (cur[@"audio"] == nil || cur[@"audio"] == [NSNull null])) {
                NSString *audioIdStr = [cur[@"audio_id"] description];
                NSArray *parts = [audioIdStr componentsSeparatedByString:@"_"];
                
                if (parts.count == 2) {
                    NSString *ownerId = parts[0];
                    NSString *trackId = parts[1];
                    NSString *cacheKey = [NSString stringWithFormat:@"%@_%@", ownerId, trackId];
                    
                    id cached = g_audioCache[cacheKey];
                    if (cached) {
                        if (!mrd) mrd = [rd mutableCopy];
                        NSMutableDictionary *cachedCopy = [cached mutableCopy];
                        if (g_audioUserId) {
                            cachedCopy[@"owner_id"] = g_audioUserId;
                        }
                        mrd[@"audio"] = cachedCopy;
                        mrd[@"audio_id"] = @([trackId longLongValue]);
                        NSLog(@"[OpenGate] Injected cached audio %@, owner=%@, audio_id=%@", trackId, cachedCopy[@"owner_id"], mrd[@"audio_id"]);
                    }
                }
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

@interface VKPhoto : NSObject
- (void)process:(id)dict context:(id)context;
@end

%hook VKPhoto

- (void)process:(id)dict context:(id)context {
    if ([dict isKindOfClass:[NSDictionary class]]) {
        NSNumber *al = dict[@"album_id"];
        NSNumber *aid = dict[@"aid"];
        if ((al && [al integerValue] == 0) || (aid && [aid integerValue] == 0)) {
            NSMutableDictionary *m = [dict mutableCopy];
            m[@"album_id"] = @(-7);
            m[@"aid"] = @(-7);
            dict = m;
            NSLog(@"[OpenGate] VKPhoto album -> -7");
        }
    }
    %orig(dict, context);
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