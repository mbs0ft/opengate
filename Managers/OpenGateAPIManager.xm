#import <Foundation/Foundation.h>

@interface OpenGateManager : NSObject
@property (nonatomic, strong) NSString *selectedInstance;
@property (nonatomic, strong) NSArray *availableInstances;
+ (instancetype)sharedManager;
- (void)saveSelectedInstance:(NSString *)instance;
- (NSString *)getSelectedInstance;
@end

@interface OpenGateAPIManager : NSObject
+ (instancetype)sharedManager;
- (void)executeOVKMethod:(NSString *)methodName 
              parameters:(NSDictionary *)params 
         completionHandler:(void(^)(id response, NSError *error))completion;
@end

@implementation OpenGateAPIManager

+ (instancetype)sharedManager {
    static OpenGateAPIManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

- (void)executeOVKMethod:(NSString *)methodName 
              parameters:(NSDictionary *)params 
         completionHandler:(void(^)(id response, NSError *error))completion {
    
    OpenGateManager *instanceManager = [OpenGateManager sharedManager];
    NSString *instance = [instanceManager getSelectedInstance];
    
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] 
        initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/method/ovk.%@", instance, methodName]]];
    
    [request setHTTPMethod:@"POST"];
    
    NSMutableDictionary *bodyParams = [NSMutableDictionary dictionaryWithDictionary:params];
    [bodyParams setObject:@"5.90" forKey:@"v"];
    
    NSString *token = [[NSUserDefaults standardUserDefaults] objectForKey:@"VKAccessToken"];
    if (token) {
        [bodyParams setObject:token forKey:@"access_token"];
    }
    
    NSString *bodyString = [self queryStringFromDictionary:bodyParams];
    [request setHTTPBody:[bodyString dataUsingEncoding:NSUTF8StringEncoding]];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        
        NSError *jsonError = nil;
        id jsonResponse = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        completion(jsonResponse, jsonError);
    }] resume];
}

- (NSString *)queryStringFromDictionary:(NSDictionary *)dict {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *key in dict) {
        NSString *value = dict[key];
        NSString *escapedKey = [key stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *escapedValue = [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", escapedKey, escapedValue]];
    }
    return [pairs componentsJoinedByString:@"&"];
}

@end