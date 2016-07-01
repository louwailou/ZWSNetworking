//
//  ZWSAPIBaseManager.m
//  Pods
//
//  Created by LOFT.LIFE.ZHENG on 16/5/13.
//
//

#import "ZWSAPIBaseManager.h"
#import "ZWSCache.h"
#import "ZWSLogger.h"
#import "ZWSAppContext.h"
#import "ZWSApiProxy.h"
#import "ZWSNetworking.h"
#import "ZWSServiceFactory.h"

#define ZWSCallAPI(REQUEST_METHOD, REQUEST_ID)                                                   \
{                                                                                               \
__weak typeof(self) weakSelf = self;                                                        \
REQUEST_ID = [[ZWSAPIProxy sharedInstance] call##REQUEST_METHOD##WithParams:apiParams serviceIdentifier:self.child.serviceType methodName:self.child.methodName success:^(ZWSURLResponse *response) { \
__strong typeof(weakSelf) strongSelf = weakSelf;                                        \
[strongSelf successedOnCallingAPI:response];                                            \
} fail:^(ZWSURLResponse *response) {                                                        \
__strong typeof(weakSelf) strongSelf = weakSelf;                                        \
[strongSelf failedOnCallingAPI:response withErrorType:ZWSAPIManagerErrorTypeDefault];    \
}];                                                                                         \
[self.requestIdList addObject:@(REQUEST_ID)];                                               \
}

NSString * const kBSUserTokenInvalidNotification = @"kBSUserTokenInvalidNotification";
NSString * const kBSUserTokenIllegalNotification = @"kBSUserTokenIllegalNotification";
NSString * const kBSUserTokenNotificationUserInfoKeyRequestToContinue = @"kBSUserTokenNotificationUserInfoKeyRequestToContinue";
NSString * const kBSUserTokenNotificationUserInfoKeyManagerToContinue = @"kBSUserTokenNotificationUserInfoKeyManagerToContinue";


@interface ZWSAPIBaseManager ()

@property (nonatomic, strong, readwrite) id fetchedRawData;
@property (nonatomic, assign, readwrite) BOOL isLoading;
@property (nonatomic, assign) BOOL isNativeDataEmpty;

@property (nonatomic, copy, readwrite) NSString *errorMessage;
@property (nonatomic, readwrite) ZWSAPIManagerErrorType errorType;
@property (nonatomic, strong) NSMutableArray *requestIdList;
@property (nonatomic, strong) ZWSCache *cache;

@end

@implementation ZWSAPIBaseManager

#pragma mark - life cycle
- (instancetype)init
{
    self = [super init];
    if (self) {
        _delegate       = nil;
        _validator      = nil;
        _paramSource    = nil;
        _fetchedRawData = nil;
        _errorMessage   = nil;
        
        _errorType = ZWSAPIManagerErrorTypeDefault;
        
        if ([self conformsToProtocol:@protocol(ZWSAPIManager)]) {
            self.child = (id <ZWSAPIManager>)self;
        } else {
            NSException *exception = [[NSException alloc] init];
            @throw exception;
        }
    }
    return self;
}

- (void)dealloc
{
    [self cancelAllRequests];
    self.requestIdList = nil;
}

#pragma mark - public methods
- (void)cancelAllRequests
{
    [[ZWSAPIProxy sharedInstance] cancelRequestWithRequestIDList:self.requestIdList];
    [self.requestIdList removeAllObjects];
}

- (void)cancelRequestWithRequestId:(NSInteger)requestID
{
    [self removeRequestIdWithRequestID:requestID];
    [[ZWSAPIProxy sharedInstance] cancelRequestWithRequestID:@(requestID)];
}

- (id)fetchDataWithReformer:(id<ZWSAPIManagerDataReformer>)reformer
{
    id resultData = nil;
    if ([reformer respondsToSelector:@selector(manager:reformData:)]) {
        resultData = [reformer manager:self reformData:self.fetchedRawData];
    } else {
        resultData = [self.fetchedRawData mutableCopy];
    }
    return resultData;
}

#pragma mark - calling api
- (NSInteger)loadData
{
    NSDictionary *params = [self.paramSource paramsForApi:self];
    NSInteger requestId = [self loadDataWithParams:params];
    return requestId;
}

- (NSInteger)loadDataWithParams:(NSDictionary *)params
{
    NSInteger requestId = 0;
    NSDictionary *apiParams = [self reformParams:params];
    if ([self shouldCallAPIWithParams:apiParams]) {
        if ([self.validator manager:self isCorrectWithParamsData:apiParams]) {
            
            if ([self shouldLoadFromNative]) {
                [self loadDataFromNative];
            }
            
            // 先检查一下是否有缓存
            if ([self shouldCache] && [self hasCacheWithParams:apiParams]) {
                return 0;
            }
            
            // 实际的网络请求
            if ([self isReachable]) {
                self.isLoading = YES;
                switch (self.child.requestType)
                {
                    case ZWSAPIManagerRequestTypeGet:
                        ZWSCallAPI(GET, requestId);
                        break;
                    case ZWSAPIManagerRequestTypePost:
                        ZWSCallAPI(POST, requestId);
                        break;
                    case ZWSAPIManagerRequestTypePut:
                        ZWSCallAPI(PUT, requestId);
                        break;
                    case ZWSAPIManagerRequestTypeDelete:
                        ZWSCallAPI(DELETE, requestId);
                        break;
                    default:
                        break;
                }
                
                NSMutableDictionary *params = [apiParams mutableCopy];
                params[kZWSAPIBaseManagerRequestID] = @(requestId);
                [self afterCallingAPIWithParams:params];
                return requestId;
                
            } else {
                [self failedOnCallingAPI:nil withErrorType:ZWSAPIManagerErrorTypeNoNetWork];
                return requestId;
            }
        } else {
            [self failedOnCallingAPI:nil withErrorType:ZWSAPIManagerErrorTypeParamsError];
            return requestId;
        }
    }
    return requestId;
}

#pragma mark - api callbacks
- (void)successedOnCallingAPI:(ZWSURLResponse *)response
{
    self.isLoading = NO;
    self.response = response;
    
    if ([self shouldLoadFromNative]) {
        if (response.isCache == NO) {
            [[NSUserDefaults standardUserDefaults] setObject:response.responseData forKey:[self.child methodName]];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    }
    
    if (response.content) {
        self.fetchedRawData = [response.content copy];
    } else {
        self.fetchedRawData = [response.responseData copy];
    }
    [self removeRequestIdWithRequestID:response.requestId];
    if ([self.validator manager:self isCorrectWithCallbackData:response.content]) {
        
        if ([self shouldCache] && !response.isCache) {
            [self.cache saveCacheWithData:response.responseData serviceIdentifier:self.child.serviceType methodName:self.child.methodName requestParams:response.requestParams];
        }
        
        if ([self beforePerformSuccessWithResponse:response]) {
            if ([self shouldLoadFromNative]) {
                if (response.isCache == YES) {
                    [self.delegate managerCallAPIDidSuccess:self];
                }
                if (self.isNativeDataEmpty) {
                    [self.delegate managerCallAPIDidSuccess:self];
                }
            } else {
                [self.delegate managerCallAPIDidSuccess:self];
            }
        }
        [self afterPerformSuccessWithResponse:response];
    } else {
        [self failedOnCallingAPI:response withErrorType:ZWSAPIManagerErrorTypeNoContent];
    }
}

- (void)failedOnCallingAPI:(ZWSURLResponse *)response withErrorType:(ZWSAPIManagerErrorType)errorType
{
    self.isLoading = NO;
    self.response = response;
    if ([response.content[@"id"] isEqualToString:@"expired_access_token"]) {
        // token 失效
        [[NSNotificationCenter defaultCenter] postNotificationName:kBSUserTokenInvalidNotification
                                                            object:nil
                                                          userInfo:@{
                                                                     kBSUserTokenNotificationUserInfoKeyRequestToContinue:[response.request mutableCopy],
                                                                     kBSUserTokenNotificationUserInfoKeyManagerToContinue:self
                                                                     }];
    } else if ([response.content[@"id"] isEqualToString:@"illegal_access_token"]) {
        // token 无效，重新登录
        [[NSNotificationCenter defaultCenter] postNotificationName:kBSUserTokenIllegalNotification
                                                            object:nil
                                                          userInfo:@{
                                                                     kBSUserTokenNotificationUserInfoKeyRequestToContinue:[response.request mutableCopy],
                                                                     kBSUserTokenNotificationUserInfoKeyManagerToContinue:self
                                                                     }];
    } else if ([response.content[@"id"] isEqualToString:@"no_permission_for_this_api"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kBSUserTokenIllegalNotification
                                                            object:nil
                                                          userInfo:@{
                                                                     kBSUserTokenNotificationUserInfoKeyRequestToContinue:[response.request mutableCopy],
                                                                     kBSUserTokenNotificationUserInfoKeyManagerToContinue:self
                                                                     }];
    } else {
        // 其他错误
        self.errorType = errorType;
        [self removeRequestIdWithRequestID:response.requestId];
        if ([self beforePerformFailWithResponse:response]) {
            [self.delegate managerCallAPIDidFailed:self];
        }
        [self afterPerformFailWithResponse:response];
    }
}

#pragma mark - method for interceptor

/*
 拦截器的功能可以由子类通过继承实现，也可以由其它对象实现,两种做法可以共存
 当两种情况共存的时候，子类重载的方法一定要调用一下super
 然后它们的调用顺序是BaseManager会先调用子类重载的实现，再调用外部interceptor的实现
 
 notes:
 正常情况下，拦截器是通过代理的方式实现的，因此可以不需要以下这些代码
 但是为了将来拓展方便，如果在调用拦截器之前manager又希望自己能够先做一些事情，所以这些方法还是需要能够被继承重载的
 所有重载的方法，都要调用一下super,这样才能保证外部interceptor能够被调到
 这就是decorate pattern
 */
- (BOOL)beforePerformSuccessWithResponse:(ZWSURLResponse *)response
{
    BOOL result = YES;
    
    self.errorType = ZWSAPIManagerErrorTypeSuccess;
    if (self != self.interceptor && [self.interceptor respondsToSelector:@selector(beforePerformSuccessWithResponse:)]) {
        result = [self.interceptor manager:self beforePerformSuccessWithResponse:response];
    }
    return result;
}

- (void)afterPerformSuccessWithResponse:(ZWSURLResponse *)response
{
    if (self != self.interceptor && [self.interceptor respondsToSelector:@selector(afterPerformSuccessWithResponse:)]) {
        [self.interceptor manager:self afterPerformSuccessWithResponse:response];
    }
}

- (BOOL)beforePerformFailWithResponse:(ZWSURLResponse *)response
{
    BOOL result = YES;
    if (self != self.interceptor && [self.interceptor respondsToSelector:@selector(beforePerformFailWithResponse:)]) {
        result = [self.interceptor manager:self beforePerformFailWithResponse:response];
    }
    return result;
}

- (void)afterPerformFailWithResponse:(ZWSURLResponse *)response
{
    if (self != self.interceptor && [self.interceptor respondsToSelector:@selector(afterPerformFailWithResponse:)]) {
        [self.interceptor manager:self afterPerformFailWithResponse:response];
    }
}

// 只有返回YES才会继续调用API
- (BOOL)shouldCallAPIWithParams:(NSDictionary *)params
{
    if (self != self.interceptor && [self.interceptor respondsToSelector:@selector(shouldCallAPIWithParams:)]) {
        return [self.interceptor manager:self shouldCallAPIWithParams:params];
    } else {
        return YES;
    }
}

- (void)afterCallingAPIWithParams:(NSDictionary *)params
{
    if (self != self.interceptor && [self.interceptor respondsToSelector:@selector(afterCallingAPIWithParams:)]) {
        [self.interceptor manager:self afterCallingAPIWithParams:params];
    }
}

#pragma mark - method for child
- (void)cleanData
{
    [self.cache clean];
    self.fetchedRawData = nil;
    self.errorMessage = nil;
    self.errorType = ZWSAPIManagerErrorTypeDefault;
}

//如果需要在调用API之前额外添加一些参数，比如pageNumber和pageSize之类的就在这里添加
//子类中覆盖这个函数的时候就不需要调用[super reformParams:params]了
- (NSDictionary *)reformParams:(NSDictionary *)params
{
    IMP childIMP = [self.child methodForSelector:@selector(reformParams:)];
    IMP selfIMP = [self methodForSelector:@selector(reformParams:)];
    
    if (childIMP == selfIMP) {
        return params;
    } else {
        // 如果child是继承得来的，那么这里就不会跑到，会直接跑子类中的IMP。
        // 如果child是另一个对象，就会跑到这里
        NSDictionary *result = nil;
        result = [self.child reformParams:params];
        if (result) {
            return result;
        } else {
            return params;
        }
    }
}

- (BOOL)shouldCache
{
    return kZWSShouldCache;
}

#pragma mark - private methods
- (void)removeRequestIdWithRequestID:(NSInteger)requestId
{
    NSNumber *requestIDToRemove = nil;
    for (NSNumber *storedRequestId in self.requestIdList) {
        if ([storedRequestId integerValue] == requestId) {
            requestIDToRemove = storedRequestId;
        }
    }
    if (requestIDToRemove) {
        [self.requestIdList removeObject:requestIDToRemove];
    }
}

- (BOOL)hasCacheWithParams:(NSDictionary *)params
{
    NSString *serviceIdentifier = self.child.serviceType;
    NSString *methodName = self.child.methodName;
    NSData *result = [self.cache fetchCachedDataWithServiceIdentifier:serviceIdentifier methodName:methodName requestParams:params];
    
    if (result == nil) {
        return NO;
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof (weakSelf) strongSelf = weakSelf;
        ZWSURLResponse *response = [[ZWSURLResponse alloc] initWithData:result];
        response.requestParams = params;
        [ZWSLogger logDebugInfoWithCachedResponse:response methodName:methodName serviceIdentifier:[[ZWSServiceFactory sharedInstance] serviceWithIdentifier:serviceIdentifier]];
        [strongSelf successedOnCallingAPI:response];
    });
    return YES;
}

- (void)loadDataFromNative
{
    NSString *methodName = self.child.methodName;
    NSDictionary *result = (NSDictionary *)[[NSUserDefaults standardUserDefaults] objectForKey:methodName];
    
    if (result) {
        self.isNativeDataEmpty = NO;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            ZWSURLResponse *response = [[ZWSURLResponse alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL]];
            [strongSelf successedOnCallingAPI:response];
        });
    } else {
        self.isNativeDataEmpty = YES;
    }
}

#pragma mark - getters and setters
- (ZWSCache *)cache
{
    if (_cache == nil) {
        _cache = [ZWSCache sharedInstance];
    }
    return _cache;
}

- (NSMutableArray *)requestIdList
{
    if (_requestIdList == nil) {
        _requestIdList = [[NSMutableArray alloc] init];
    }
    return _requestIdList;
}

- (BOOL)isReachable
{
    BOOL isReachability = [ZWSAppContext sharedInstance].isReachable;
    if (!isReachability) {
        self.errorType = ZWSAPIManagerErrorTypeNoNetWork;
    }
    return isReachability;
}

- (BOOL)isLoading
{
    if (self.requestIdList.count == 0) {
        _isLoading = NO;
    }
    return _isLoading;
}

- (BOOL)shouldLoadFromNative
{
    return NO;
}


@end








