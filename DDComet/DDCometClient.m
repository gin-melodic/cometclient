
#import "DDCometClient.h"
#import "DDCometClientInternal.h"

#import <libkern/OSAtomic.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "DDCometMessage.h"
#import "DDCometSubscription.h"
#import "DDConcurrentQueue.h"
#import "DDCometWebSocketTransport.h"
#import "DDCometURLSessionLongPollingTransport.h"

#define kCometErrorClientNotFound 402

static void * const delegateKey = (void*)&delegateKey;

static char kAssociatedObjectKey;

extern void DDCometLog(NSString *format, ...);

#pragma mark - DDCometBlockSubscriptionDelegate Interface

@interface DDCometBlockSubscriptionDelegate : NSObject<DDCometClientSubscriptionDelegate>

@property (nonatomic, copy) void (^successBlock)(DDCometClient*,DDCometSubscription*);

@property (nonatomic, copy) void (^errorBlock)(DDCometClient*,DDCometSubscription*,NSError*);

-(id)initWithSuccessBlock:(void(^)(DDCometClient*,DDCometSubscription*))successBlock errorBlock:(void(^)(DDCometClient*,DDCometSubscription*,NSError*))errorBlock;
@end

#pragma mark - DDCometBlockDataDelegate

@interface DDCometBlockDataDelegate : NSObject<DDCometClientDataDelegate>

@property (nonatomic, copy) void (^successBlock)(DDCometClient *, id, NSString *);

@property (nonatomic, copy) void (^errorBlock)(DDCometClient *, id, NSString *, NSError *);

-(instancetype)initWithSuccessBlock:(void(^)(DDCometClient *, id, NSString *))successBlock errorBlock:(void(^)(DDCometClient *, id, NSString *, NSError *))errorBlock;

@end


#pragma mark - DDCometClient

@interface DDCometClient () <DDQueueDelegate>
{
@private
    volatile int32_t _messageCounter;
    
    NSMutableDictionary *_pendingSubscriptions; // by id to NSArray
    BOOL _persistentSubscriptions;
    NSMutableArray *_subscriptions;
    
    id<DDQueue> _outgoingQueue;
    id<DDQueue> _incomingQueue;
    id<DDCometTransport> _transport;
    DDCometSupportedTransport _currentTransport;
    
    dispatch_queue_t _dispatchQueue;

    NSTimer * _disconnectTimer;

#if TARGET_OS_IPHONE
    UIBackgroundTaskIdentifier _bgDisconnectTask;
#endif
}

@property (nonatomic, assign) DDCometState state;

@property (nonatomic, strong) NSURL * endpointURL;

- (NSString *)nextMessageID;
- (void)sendMessage:(DDCometMessage *)message;
- (void)handleMessage:(DDCometMessage *)message;
- (void)handleDisconnection;

@end

@implementation DDCometClient

- (id)initWithURL:(NSURL *)endpointURL
{
    if ((self = [super init]))
        {
         _endpointURL = endpointURL;
        _pendingSubscriptions = [[NSMutableDictionary alloc] init];
        _subscriptions = [[NSMutableArray alloc] init];
        _outgoingQueue = [[DDConcurrentQueue alloc] init];
        _incomingQueue = [[DDConcurrentQueue alloc] init];
        [_incomingQueue setDelegate:self];
        _reconnectOnClientExpired = YES;
        _persistentSubscriptions = YES;
        _dispatchQueue = dispatch_queue_create("ddcometclient.queue", DISPATCH_QUEUE_SERIAL);
        
        _supportedTransports = DDCometWebSocketSupportedTransport | DDCometLongPollingSupportedTransport;
        _currentTransport = [self getNextTransport:0];
        _bgDisconnectTask = UIBackgroundTaskInvalid;

        }
    return self;
}


- (DDCometMessage *)handshake
{
    return [self handshakeWithData:_handshakeData];
}

- (DDCometMessage *)handshakeWithData:(NSDictionary *)data
{
    if (_state == DDCometStateConnecting)
        {
        DDCometLog(@"Only one pending handshake allowed at one time.");
        return nil;
        }
    
    self.state = DDCometStateHandshaking;

    if (_handshakeData != data)
        {
        _handshakeData = data;
        }
    
    DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/handshake"];
    message.version = @"1.0";
    NSMutableArray * connectionTypes = [NSMutableArray array];
    if (self.supportedTransports & DDCometWebSocketSupportedTransport)
        {
        [connectionTypes addObject:@"websocket"];
        }
    if (self.supportedTransports & DDCometLongPollingSupportedTransport)
        {
        [connectionTypes addObject:@"long-polling"];
        }
    message.supportedConnectionTypes = connectionTypes;
    if (data != nil)
        {
        message.ext = data;
        }
    
    [self sendMessage:message];
    return message;
}


- (DDCometMessage *)disconnect
{
    if (_state == DDCometStateConnected)
        {
        self.state = DDCometStateDisconnecting;
        
        [self beginBackgroundTaskSupport];
        if (!_disconnectTimer)
            {
            _disconnectTimer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(handleDisconnection) userInfo:nil repeats:NO];
            }
        
        DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/disconnect"];
        [self sendMessage:message];
        return message;
        }
    else
        {
        self.state = DDCometStateDisconnected;
        
        return nil;
        }
}

- (void) beginBackgroundTaskSupport
{
#if TARGET_OS_IPHONE
    //Enable task to continue in the background until disconnect is received.
    if (_bgDisconnectTask != UIBackgroundTaskInvalid)
        {
        [[UIApplication sharedApplication] endBackgroundTask:_bgDisconnectTask];
        _bgDisconnectTask = UIBackgroundTaskInvalid;
        }
    
    _bgDisconnectTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"CometDisconnect" expirationHandler:^{
        // Clean up if it expires
        [self handleDisconnection];
        [[UIApplication sharedApplication] endBackgroundTask:_bgDisconnectTask];
        _bgDisconnectTask = UIBackgroundTaskInvalid;
    }];
#endif
}

- (void) endBackgroundTaskSupport
{
#if TARGET_OS_IPHONE
    if (_bgDisconnectTask != UIBackgroundTaskInvalid)
        {
        [[UIApplication sharedApplication] endBackgroundTask:_bgDisconnectTask];
        _bgDisconnectTask = UIBackgroundTaskInvalid;
        }
#endif
}


- (void)setSupportedTransports:(DDCometSupportedTransport)supportedTransports
{
    _supportedTransports = supportedTransports;
    _currentTransport = [self getNextTransport:0];
}

-(DDCometSubscription*) subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector {
    return [self subscribeToChannel:channel extensions:nil target:target selector:selector delegate:nil];
}

-(DDCometSubscription*) subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector successBlock:(void (^)(DDCometClient *, DDCometSubscription *))successBlock errorBlock:(void (^)(DDCometClient *, DDCometSubscription *, NSError *))errorBlock
{
    if (errorBlock || successBlock)
        {
        DDCometBlockSubscriptionDelegate *delegate = [[DDCometBlockSubscriptionDelegate alloc] initWithSuccessBlock:successBlock errorBlock:errorBlock];
        DDCometSubscription * subscription = [self subscribeToChannel:channel target:target selector:selector delegate:delegate];
        objc_setAssociatedObject(subscription, &kAssociatedObjectKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return subscription;
        }
    else
        {
        return [self subscribeToChannel:channel target:target selector:selector delegate:nil];
        }
}

- (DDCometSubscription *)subscribeToChannel:(NSString *)channel extensions:(id)extensions target:(id)target selector:(SEL)selector
{
    return [self subscribeToChannel:channel extensions:extensions target:target selector:selector delegate:nil];
}

- (DDCometSubscription *)subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector delegate:(id<DDCometClientSubscriptionDelegate>)delegate
{
    return [self subscribeToChannel:channel extensions:nil target:target selector:selector delegate:delegate];
}

- (DDCometSubscription *)subscribeToChannel:(NSString *)channel extensions:(id)extensions target:(id)target selector:(SEL)selector delegate:(id<DDCometClientSubscriptionDelegate>)delegate
{
    DDCometSubscription *subscription = [[DDCometSubscription alloc] initWithChannel:channel target:target selector:selector delegate:delegate];
    BOOL alreadySubscribed = NO;
    BOOL shouldAddSubscription = NO;
    BOOL foundDuplicate = NO;
    NSMutableArray *channelsToUnsubscribe = [NSMutableArray array];
    id<DDCometClientSubscriptionDelegate> localDelegate = delegate?delegate:_delegate;
    
    @synchronized(_subscriptions) {
        for (DDCometSubscription *subscription in _subscriptions)
            {
            if ([subscription matchesChannel:channel])
                {
                if ([subscription.target isEqual:target] && subscription.selector == selector)
                    {
                    if (self.allowDuplicateSubscriptions)
                        {
                        shouldAddSubscription = YES;
                        }
                    foundDuplicate = YES;
                    }
                    alreadySubscribed = YES;
                }
            else if ([subscription isParentChannel:channel])
                {
                [channelsToUnsubscribe addObject:subscription.channel];
                }
            }
        
        if (!foundDuplicate && alreadySubscribed)
            {
            shouldAddSubscription = YES;
            }
        
        if (shouldAddSubscription)
            {
            [_subscriptions addObject:subscription];
            }
        
        if (alreadySubscribed)
            {
            if (localDelegate && [localDelegate respondsToSelector:@selector(cometClient:subscriptionDidSucceed:)])
                {
                [localDelegate cometClient:self subscriptionDidSucceed:subscription];
                }
            }
        else
            {
            
            shouldAddSubscription = NO;
            foundDuplicate = NO;
            
            NSMutableArray * pending;
            for (NSString * curChannel in _pendingSubscriptions)
                {
                pending  = _pendingSubscriptions[curChannel];
                //We have a pending subscription that is a subchannel to the one we're about to subscribe
                //Therefore we should unsubscribe the child and replace the list of channels
                if ([DDCometSubscription channel:channel isParentTo:curChannel])
                    {
                    NSMutableArray * curPendingForChannel = _pendingSubscriptions[channel];
                    if (!curPendingForChannel)
                        {
                        if (pending)
                            {
                            curPendingForChannel = [NSMutableArray arrayWithArray:pending];
                            }
                        else
                            {
                            curPendingForChannel = [NSMutableArray array];
                            }
                        }
                    else if (pending)
                        {
                        [curPendingForChannel addObjectsFromArray:pending];
                        }
                    
                    [channelsToUnsubscribe addObject:curChannel];
                    pending = curPendingForChannel;
                    break;
                    }
                else if ([DDCometSubscription channel:channel matchesChannel:curChannel])
                    {
                    if (!pending)
                        {
                        pending = [NSMutableArray arrayWithCapacity:5];
                        _pendingSubscriptions[channel] = pending;
                        }
                    else if (pending.count > 0)
                        {
                        alreadySubscribed = YES;
                        }
                    break;
                    }
                else
                    {
                    pending = nil;
                    }
                }
            
            for (DDCometSubscription *subscription in pending)
                {
                if ([subscription.channel isEqualToString:channel] && [subscription.target isEqual:target] && subscription.selector == selector)
                    {
                    if (self.allowDuplicateSubscriptions)
                        {
                        shouldAddSubscription = YES;
                        }
                    foundDuplicate = YES;
                    break;
                    }
                }
            
            if (!pending)
                {
                pending = [NSMutableArray arrayWithCapacity:5];
                _pendingSubscriptions[channel] = pending;
                }
            
            
            if (!foundDuplicate || shouldAddSubscription)
                {
                [pending addObject:subscription];
                }
            
            if (!alreadySubscribed && _state == DDCometStateConnected)
                {
                DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/subscribe"];
                message.ID = [self nextMessageID];
                message.subscription = channel;
                [self sendMessage:message];
                }
            }
        
        if (channelsToUnsubscribe.count > 0)
            {
            for (NSString * curChannel in channelsToUnsubscribe)
                {
                [_pendingSubscriptions removeObjectForKey:curChannel];
                if (_state == DDCometStateConnected)
                    {
                    DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/unsubscribe"];
                    message.ID = [self nextMessageID];
                    message.subscription = curChannel;
                    [self sendMessage:message];
                    }
                }
            }
    }
    
    return subscription;
}

- (void) unsubscribeAll {
    @synchronized(_subscriptions) {
        
        if (_state == DDCometStateConnected)
            {
            NSMutableSet *channels = [NSMutableSet setWithCapacity:_subscriptions.count];
            for (DDCometSubscription *subscription in _subscriptions)
                {
                [channels addObject:subscription.channel];
                }
            [channels addObjectsFromArray:_pendingSubscriptions.allKeys];
            
            for (NSString * channel in channels)
                {
                DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/unsubscribe"];
                message.ID = [self nextMessageID];
                message.subscription = channel;
                [self sendMessage:message];
                }
            }
        
        [_subscriptions removeAllObjects];
        [_pendingSubscriptions removeAllObjects];
    }
}

- (DDCometMessage *)unsubsubscribeFromChannel:(NSString *)channel target:(id)target selector:(SEL)selector
{
    __block BOOL subscriptionsRemain = NO;
    __block BOOL subscriptionFound = NO;
    
    @synchronized(_subscriptions) {
        NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
        NSUInteger count = [_subscriptions count];
        NSMutableDictionary *subscriptionsToAdd = [NSMutableDictionary dictionaryWithCapacity:_subscriptions.count];
        for (NSUInteger i = 0; i < count; i++)
            {
            DDCometSubscription *subscription = _subscriptions[i];
            if ([subscription.channel isEqualToString:channel])
                {
                if (((target == nil && subscription.target == nil) || [subscription.target isEqual:target]) && subscription.selector == selector)
                    {
                    [indexes addIndex:i];
                    }
                else
                    {
                    //If there is a subscription for this channel that remains that isn't the same selector
                    subscriptionsRemain = YES;
                    }
                
                subscriptionFound = YES;
                }
            else if ([subscription isParentChannel:channel])
                {
                NSMutableArray *pending = subscriptionsToAdd[subscription.channel];
                if (!pending)
                    {
                    pending = [NSMutableArray array];
                    subscriptionsToAdd[subscription.channel] = pending;
                    }
                [indexes addIndex:i];
                [pending addObject:subscription];
                }
            }
        
        [_subscriptions removeObjectsAtIndexes:indexes];
        if (!subscriptionFound)
            {
            //If there is no current subscription, we need to check pending subscriptions to see if we need to remove them
            
            NSMutableArray *keysToRemove = [NSMutableArray arrayWithCapacity:_pendingSubscriptions.count];
            NSMutableDictionary *keysToAdd = [NSMutableDictionary dictionaryWithCapacity:_pendingSubscriptions.count];
            [_pendingSubscriptions enumerateKeysAndObjectsUsingBlock:^(NSString* channelKey, NSMutableArray *subscriptions,BOOL *stop) {
                
                if ([DDCometSubscription channel:channelKey matchesChannel:channel])
                    {
                    NSMutableIndexSet *indexes = [[NSMutableIndexSet alloc] init];
                    [subscriptions enumerateObjectsUsingBlock:^(DDCometSubscription * subscription, NSUInteger i, BOOL* stopInside) {
                        if ([subscription.channel isEqualToString:channel])
                            {
                            if (((target == nil && subscription.target == nil) || [subscription.target isEqual:target]) && subscription.selector == selector)
                                {
                                [indexes addIndex:i];
                                }
                            else
                                {
                                subscriptionsRemain = YES;
                                }
                            subscriptionFound = YES;
                            }
                    }];
                    
                    [subscriptions removeObjectsAtIndexes:indexes];
                    
                    if (subscriptions.count == 0)
                        {
                        [keysToRemove addObject:channelKey];
                        }
                    else if ([channelKey isEqualToString:channel] && !subscriptionsRemain)
                        {
                        //This means it's a child subscription and there aren't any more global subscriptions that match the parent key
                        [keysToRemove addObject:channelKey];
                        for (DDCometSubscription * curSub in subscriptions)
                            {
                            NSMutableArray * newSet = keysToAdd[curSub.channel];
                            if (!newSet)
                                {
                                newSet = [NSMutableArray array];
                                keysToAdd[curSub.channel] = newSet;
                                }
                            [newSet addObject:curSub];
                            }
                        }
                    }
            }];
            
            [_pendingSubscriptions removeObjectsForKeys:keysToRemove];
            for (NSString * key in keysToAdd)
                {
                NSMutableArray * value = keysToAdd[key];
                NSMutableArray * combineWith = subscriptionsToAdd[key];
                if (combineWith)
                    {
                    [value addObjectsFromArray:combineWith];
                    [subscriptionsToAdd removeObjectForKey:key];
                    subscriptionsToAdd[key] = value;
                    }
                else
                    {
                    subscriptionsToAdd[key] = value;
                    }
                }
            }
        
        if (_state == DDCometStateConnected && subscriptionsToAdd.count > 0)
            {
            
            //Just in case there are any other subscriptions in the current pending subscription that are the parent of the others
            NSMutableArray *keysToRemove = [NSMutableArray arrayWithCapacity:subscriptionsToAdd.count];
            for (NSString * curChannel in subscriptionsToAdd)
                {
                for (NSString * parentChannel in subscriptionsToAdd)
                    {
                    if ([DDCometSubscription channel:parentChannel isParentTo:curChannel])
                        {
                        NSMutableArray * arrayToCombineValues = subscriptionsToAdd[curChannel];
                        NSMutableArray * arrayToCombineWith = subscriptionsToAdd[parentChannel];
                        [arrayToCombineWith addObjectsFromArray:arrayToCombineValues];
                        [keysToRemove addObject:curChannel];
                        break;
                        }
                    }
                }
            
            [subscriptionsToAdd removeObjectsForKeys:keysToRemove];
            [subscriptionsToAdd enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
                NSMutableArray * curPending = [self pendingSubscriptionsMatching:key];
                [curPending addObjectsFromArray:obj];
            }];
            
            for (NSString * curChannel in subscriptionsToAdd)
                {
                DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/subscribe"];
                message.ID = [self nextMessageID];
                message.subscription = curChannel;
                [self sendMessage:message];
                }
            }
        
    }//End @synchronized()
    
    if (subscriptionFound && !subscriptionsRemain && _state == DDCometStateConnected)
        {
        DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/unsubscribe"];
        message.ID = [self nextMessageID];
        message.subscription = channel;
        [self sendMessage:message];
        return message;
        }
    else
        {
        return nil;
        }
}

-(void)unsubscribeWithSubscription:(DDCometSubscription *)subscription
{
    [self unsubsubscribeFromChannel:subscription.channel target:subscription.target selector:subscription.selector];
}

- (DDCometMessage *)publishData:(id)data toChannel:(NSString *)channel
{
    return [self publishData:data toChannel:channel withDelegate:nil];
}

- (DDCometMessage *) publishData:(id)data toChannel:(NSString *)channel withDelegate:(id<DDCometClientDataDelegate>)delegate
{
    DDCometMessage *message = [DDCometMessage messageWithChannel:channel];
    if (delegate) {
        objc_setAssociatedObject(message, delegateKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    message.data = data;
    [self sendMessage:message];
    return message;
}

-(DDCometMessage*) publishData:(id)data toChannel:(NSString *)channel successBlock:(void (^)(DDCometClient *, id, NSString *))successBlock errorBlock:(void (^)(DDCometClient *, id, NSString *, NSError *))errorBlock
{
    DDCometBlockDataDelegate *delegate = [[DDCometBlockDataDelegate alloc]initWithSuccessBlock:successBlock errorBlock:errorBlock];
    return [self publishData:data toChannel:channel withDelegate:delegate];
}

# pragma mark - Transport Support
- (DDCometSupportedTransport) getNextTransport:(DDCometSupportedTransport)transport
{
    NSAssert(self.supportedTransports & (DDCometWebSocketSupportedTransport | DDCometLongPollingSupportedTransport), @"supportedTransports not valid list of transports");

    DDCometSupportedTransport nextTransport = DDCometWebSocketSupportedTransport;
    if (!(nextTransport & self.supportedTransports) ||
        (transport == DDCometWebSocketSupportedTransport && (DDCometLongPollingSupportedTransport & self.supportedTransports))
        )
        {
        nextTransport = DDCometLongPollingSupportedTransport;
        }
    
    return nextTransport;
}

- (id<DDCometTransport>) initializeTransport
{
    Class transportClass = [self getTransportClass:_currentTransport];
    id<DDCometTransport> transport = [[transportClass alloc] initWithClient:self];
    [_outgoingQueue setDelegate:transport];
    [transport start];
    
    return transport;
}

- (Class) getTransportClass:(DDCometSupportedTransport) transport
{
    NSAssert(transport & (DDCometWebSocketSupportedTransport | DDCometLongPollingSupportedTransport), @"transport is not supported transport");
    
    if (transport & DDCometWebSocketSupportedTransport)
        {
        return [DDCometWebSocketTransport class];
        }
    else //if (transport & DDCometLongPollingSupportedTransport) # Implied with the Assert
        {
        return [DDCometURLSessionLongPollingTransport class];
        }
}

- (void) transportDidFail:(id<DDCometTransport>)transport
{
    if (_transport == transport)
        {
        DDCometLog(@"Switching transport types");
        _currentTransport = [self getNextTransport:_currentTransport];
        _transport = [self initializeTransport];
        [transport cancel];
        return;
        }
}



#pragma mark -

- (id<DDQueue>)outgoingQueue
{
    return _outgoingQueue;
}

- (id<DDQueue>)incomingQueue
{
    return _incomingQueue;
}

-(void)messagesDidSend:(NSArray *)messages
{
    for (DDCometMessage *message in messages)
        {
        id<DDCometClientDataDelegate> dataDelegate = objc_getAssociatedObject(message, delegateKey);
        if (dataDelegate)
            {
            objc_setAssociatedObject(message, delegateKey, nil, OBJC_ASSOCIATION_ASSIGN);
            [dataDelegate cometClient:self dataDidSend:message.data toChannel:message.channel];
            }
        }
}

#pragma mark -

- (NSString *)nextMessageID
{
    return [NSString stringWithFormat:@"%d", OSAtomicIncrement32Barrier(&_messageCounter)];
}

- (void)sendMessage:(DDCometMessage *)message
{
    message.clientID = _clientID;
    if (!message.ID)
        message.ID = [self nextMessageID];
    
    if (_transport == nil && _endpointURL != nil)
        {
        _transport = [self initializeTransport];
        }
    
    DDCometLog(@"Sending message: %@", message);
    [_outgoingQueue addObject:message];
}


- (void)handleMessage:(DDCometMessage *)message
{
    DDCometLog(@"Message received: %@", message);
    NSString *channel = message.channel;
    
    if ([channel hasPrefix:@"/meta/"])
        {
        if ([channel isEqualToString:@"/meta/handshake"])
            {
            if ([message.successful boolValue])
                {
                if (_state == DDCometStateTransportError && _delegate && [_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)]) {
                    [_delegate cometClientContinuedReceivingMessages:self];
                }
                
                //Handshake occurred with a different client id.  If we have existing subscriptions, then they need to be removed.
                if (![_clientID isEqualToString:message.clientID])
                    {
                    @synchronized(_subscriptions)
                        {
                        if (_persistentSubscriptions)
                            {
                            for (DDCometSubscription * subscription in _subscriptions)
                                {
                                NSMutableArray *pending = [self pendingSubscriptionsMatching:subscription.channel];
                                [pending addObject:subscription];
                                }
                            }
                        else
                            {
                            [_pendingSubscriptions removeAllObjects];
                            }
                        [_subscriptions removeAllObjects];
                        }
                    }
                
                _clientID = message.clientID;
                self.state = DDCometStateConnecting;
                DDCometMessage *connectMessage = [DDCometMessage messageWithChannel:@"/meta/connect"];
                connectMessage.connectionType =
                    [_transport supportedTransport] & DDCometWebSocketSupportedTransport ? @"websocket" :
                    ([_transport supportedTransport] & DDCometLongPollingSupportedTransport ? @"long-polling" : @"");
                connectMessage.ID = [self nextMessageID];
                [self sendMessage:connectMessage];
                if (_delegate && [_delegate respondsToSelector:@selector(cometClientHandshakeDidSucceed:)])
                    {
                    dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                        [_delegate cometClientHandshakeDidSucceed:self];
                    });
                    }
                }
            else
                {
                [self handleDisconnection];
                if (_delegate && [_delegate respondsToSelector:@selector(cometClient:handshakeDidFailWithError:)])
                    {
                    dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                        [_delegate cometClient:self handshakeDidFailWithError:message.error];
                    });
                    }
                }
            }
        else if ([channel isEqualToString:@"/meta/connect"])
            {
            if (![message.successful boolValue])
                {
                DDCometState beforeState = _state;
                
                [self handleDisconnection];
                if (_state == DDCometStateConnecting && _delegate && [_delegate respondsToSelector:@selector(cometClient:connectDidFailWithError:)])
                    {
                    dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                        [_delegate cometClient:self connectDidFailWithError:message.error];
                    });
                    }

                
                //Error code 402 indicates the clientID was not found on the server which means we should immediately handshake again if configured to do so
                //Subscriptions have already been moved to pending through the "handleDisconnect" method and will be resubscribed if the connection is successful
                if (message.error.code == kCometErrorClientNotFound && beforeState == DDCometStateConnected)
                    {
                    if (_reconnectOnClientExpired)
                        {
                        [self handshake];
                        }
                    
                    if (_delegate && [_delegate respondsToSelector:@selector(cometClientExpired:)])
                        {
                        dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                            [_delegate cometClientExpired:self];
                        });
                        }
                    }
                }
            else if (_state == DDCometStateConnecting || _state == DDCometStateTransportError)
                {
                if (_state == DDCometStateTransportError && _delegate && [_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)])
                    {
                    dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                        [_delegate cometClientContinuedReceivingMessages:self];
                    });
                    }
                
                if (message.advice != nil)
                    {
                    void (^sendConnectMessage)(void) = ^{
                        DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/connect"];
                        message.clientID = self.clientID;
                        message.connectionType = @"websocket";
                        [self sendMessage:message];
                    };
                    
                    NSString * reconnect = [message.advice objectForKey:@"reconnect"];
                    NSNumber * interval = [message.advice objectForKey:@"interval"];
                    if (reconnect != nil && [reconnect isEqualToString:@"retry"])
                        {
                        if (interval != nil && [interval integerValue] == 0)
                            {
                            sendConnectMessage();
                            }
                        else
                            {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([interval integerValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), sendConnectMessage);
                            }
                        }
                    }
                
                @synchronized(_subscriptions) {
                    self.state = DDCometStateConnected;
                    //Once we're connected, send all the pending subscriptions
                    for (NSString * channel in _pendingSubscriptions)
                        {
                        DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/subscribe"];
                        message.ID = [self nextMessageID];
                        message.subscription = channel;
                        [self sendMessage:message];
                        }
                }
                
                if (_delegate && [_delegate respondsToSelector:@selector(cometClientConnectDidSucceed:)])
                    {
                    dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                        [_delegate cometClientConnectDidSucceed:self];
                    });
                    }

                }
            else if (_state == DDCometStateConnected)
                {
                DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/connect"];
                message.clientID = self.clientID;
                message.connectionType = @"websocket";
                [self sendMessage:message];
                }
            }
        
        else if ([channel isEqualToString:@"/meta/unsubscribe"])
            {
            if (_state == DDCometStateTransportError)
                {
                self.state = DDCometStateConnected;
                if (_delegate && [_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)])
                    {
                    dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                        [_delegate cometClientContinuedReceivingMessages:self];
                    });
                    }
                }
            }
        else if ([channel isEqualToString:@"/meta/disconnect"])
            {
            [self handleDisconnection];
            }
        else if ([channel isEqualToString:@"/meta/subscribe"])
            {
            @synchronized(_subscriptions)
                {
                NSMutableArray *subscriptions = _pendingSubscriptions[message.subscription];
                if (subscriptions)
                    {
                    
                    [_pendingSubscriptions removeObjectForKey:message.subscription];
                    if (!message.successful.boolValue)
                        {
                        for (DDCometSubscription *subscription in subscriptions)
                            {
                            id<DDCometClientSubscriptionDelegate> localDelegate = subscription.delegate?subscription.delegate:_delegate;
                            if(localDelegate && [localDelegate respondsToSelector:@selector(cometClient:subscription:didFailWithError:)])
                                {
                                dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                                    [localDelegate cometClient:self subscription:subscription didFailWithError:message.error];
                                });
                                }
                            }
                        }
                    else if (message.successful.boolValue)
                        {
                        for (DDCometSubscription *subscription in subscriptions)
                            {
                            id<DDCometClientSubscriptionDelegate> localDelegate = subscription.delegate?subscription.delegate:_delegate;
                            [_subscriptions addObject:subscription];
                            if (localDelegate && [localDelegate respondsToSelector:@selector(cometClient:subscriptionDidSucceed:)])
                                {
                                dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                                    [localDelegate cometClient:self subscriptionDidSucceed:subscription];
                                });
                                }
                            }
                        }
                    
                    if (_state == DDCometStateTransportError)
                        {
                        self.state = DDCometStateConnected;
                        if (_delegate && [_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)])
                            {
                            dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                                [_delegate cometClientContinuedReceivingMessages:self];
                            });
                            }
                        }
                    }
                }
            }
        else
            {
            DDCometLog(@"Unhandled meta message");
            }
        
        } // end if (![channel hasPrefix:@"/meta"])
    else
        {
        if (_state == DDCometStateTransportError)
            {
            self.state = DDCometStateConnected;
            if (_delegate && [_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)])
                {
                dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                    [_delegate cometClientContinuedReceivingMessages:self];
                });
                }
            }
        
        NSMutableArray *subscriptions = [NSMutableArray arrayWithCapacity:_subscriptions.count];
        @synchronized(_subscriptions)
            {
            for (DDCometSubscription *subscription in _subscriptions)
                {
                if ([subscription matchesChannel:message.channel])
                    [subscriptions addObject:subscription];
                }
            }
        for (DDCometSubscription *subscription in subscriptions)
            {
            //To conform to ARC
            if (!subscription.target)
                {
                //This means the target of the subscription call has been released and cannot receive any message so we should unsubscribe
                [self unsubscribeWithSubscription:subscription];
                }
            else if ([subscription.target respondsToSelector:subscription.selector])
                {
                dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                    IMP imp = [subscription.target methodForSelector:subscription.selector];
                    void (*func)(id, SEL, DDCometMessage *) = (void *)imp;
                    func(subscription.target, subscription.selector, message);
                });
                }
            }
        }
}

-(void)handleDisconnection {
    @synchronized(_subscriptions) {
        if (_disconnectTimer)
            {
            [_disconnectTimer invalidate];
            _disconnectTimer = nil;
            }
        
        [_transport cancel];
        _transport = nil;
        self.state = DDCometStateDisconnected;
        _clientID = nil;
        if (_persistentSubscriptions)
            {
            for (DDCometSubscription * subscription in _subscriptions)
                {
                NSMutableArray *pending = [self pendingSubscriptionsMatching:subscription.channel];
                [pending addObject:subscription];
                }
            }
        else
            {
            [_pendingSubscriptions removeAllObjects];
            }
        [_subscriptions removeAllObjects];
    }
    [self endBackgroundTaskSupport];

}

-(NSMutableArray*)pendingSubscriptionsMatching:(NSString*)channel
{
    NSMutableArray * exactMatch = _pendingSubscriptions[channel];
    if (exactMatch)
        {
        return exactMatch;
        }
    for (NSString *pendingChannel in _pendingSubscriptions)
        {
        if ([DDCometSubscription channel:pendingChannel matchesChannel:channel])
            {
            return _pendingSubscriptions[pendingChannel];
            }
        }
    
    NSMutableArray *newArray = [NSMutableArray array];
    _pendingSubscriptions[channel] = newArray;
    return newArray;
}

-(void)connection:(id<DDCometTransport>)transport failedWithError:(NSError *)error withMessages:(NSArray *)messages {
    if (_state == DDCometStateConnected && _delegate && [_delegate respondsToSelector:@selector(cometClient:stoppedReceivingMessagesWithError:)])
        {
        dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
            [_delegate cometClient:self stoppedReceivingMessagesWithError:error];
        });
        }
    self.state = DDCometStateTransportError;
    
    for (DDCometMessage *message in messages)
        {
        [self processMessageFailed:message withError:error];
        }
    
    if (_delegate && [_delegate respondsToSelector:@selector(cometClient:didFailWithTransportError:)])
        {
        dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
            [_delegate cometClient:self didFailWithTransportError:error];
        });
        }
}

-(void)processMessageFailed:(DDCometMessage*)message withError:(NSError*)error {
    
    NSString *channel = message.channel;
    if ([channel hasPrefix:@"/meta/"])
        {
        if ([channel isEqualToString:@"/meta/handshake"])
            {
            if (_delegate && [_delegate respondsToSelector:@selector(cometClient:handshakeDidFailWithError:)])
                {
                dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                    [_delegate cometClient:self handshakeDidFailWithError:error];
                });
                }
            }
        else if ([channel isEqualToString:@"/meta/connect"])
            {
            if (_state == DDCometStateConnecting && _delegate && [_delegate respondsToSelector:@selector(cometClient:connectDidFailWithError:)])
                {
                dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                    [_delegate cometClient:self connectDidFailWithError:error];
                });
                }
            }
        else if ([channel isEqualToString:@"/meta/unsubscribe"] || [channel isEqualToString:@"/meta/disconnect"])
            {
            //Do nothing as we don't notify of a disconnect/unsubscribe error, we don't care
            }
        else if ([channel isEqualToString:@"/meta/subscribe"])
            {
            @synchronized(_subscriptions)
                {
                NSMutableArray *subscriptions = _pendingSubscriptions[message.subscription];
                if (subscriptions)
                    {
                    for (DDCometSubscription *subscription in subscriptions)
                        {
                        id<DDCometClientSubscriptionDelegate> localDelegate = subscription.delegate?subscription.delegate:_delegate;
                        if (localDelegate && [localDelegate respondsToSelector:@selector(cometClient:subscription:didFailWithError:)])
                            {
                            dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                                [localDelegate cometClient:self subscription:subscription didFailWithError:error];
                            });
                            }
                        }
                    }
                [_pendingSubscriptions removeObjectForKey:message.subscription];
                }
            }
        }
    else
        {
        //If it's not a meta message then we should handle it through the data delegate
        id<DDCometClientDataDelegate> dataDelegate = [self delegateForMessage:message];
        if (dataDelegate)
            {
            objc_setAssociatedObject(message, delegateKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
        
        if (dataDelegate && [dataDelegate respondsToSelector:@selector(cometClient:data:toChannel:didFailWithError:)])
            {
            dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                [dataDelegate cometClient:self data:message.data toChannel:message.channel didFailWithError:error];
            });
            }
        else if (_delegate && [_delegate respondsToSelector:@selector(cometClient:data:toChannel:didFailWithError:)])
            {
            dispatch_async(_callbackQueue ? _callbackQueue : dispatch_get_main_queue(), ^{
                [_delegate cometClient:self data:message.data toChannel:message.channel didFailWithError:error];
            });
            }
        }
}

-(id<DDCometClientDataDelegate>)delegateForMessage:(DDCometMessage *)message
{
    return objc_getAssociatedObject(message, delegateKey);
}

#pragma mark - DDQueueDelegate
- (void)queueDidAddObject:(id<DDQueue>)queue
{
    if (queue == _incomingQueue)
        {
            dispatch_async(_callbackQueue ? _callbackQueue : _dispatchQueue, ^{
                DDCometMessage *message;
                while ((message = [_incomingQueue removeObject]))
                    {
                    [self handleMessage:message];
                    }
            });
        }
}

@end


#pragma mark - DDCometBlockDataDelegate

@implementation DDCometBlockDataDelegate
-(instancetype)initWithSuccessBlock:(void (^)(DDCometClient *, id, NSString *))successBlock errorBlock:(void (^)(DDCometClient *, id, NSString *, NSError *))errorBlock
{
    if (self = [super init]) {
        _successBlock = successBlock;
        _errorBlock = errorBlock;
    }
    return self;
}

-(void)cometClient:(DDCometClient *)client data:(id)data toChannel:(NSString *)channel didFailWithError:(NSError *)error
{
    if (_errorBlock) {
        _errorBlock(client, data, channel, error);
    }
}

-(void)cometClient:(DDCometClient *)client dataDidSend:(id)data toChannel:(NSString *)channel {
    if (_successBlock) {
        _successBlock(client, data, channel);
    }
}

@end


#pragma mark - DDCometBlockSubscriptionDelegate

@implementation DDCometBlockSubscriptionDelegate
-(id)initWithSuccessBlock:(void (^)(DDCometClient *, DDCometSubscription *))successBlock errorBlock:(void (^)(DDCometClient *, DDCometSubscription *, NSError *))errorBlock
{
    if (self = [super init]) {
        _successBlock = successBlock;
        _errorBlock = errorBlock;
    }
    return self;
}

-(void)cometClient:(DDCometClient *)client subscription:(DDCometSubscription *)subscription didFailWithError:(NSError *)error
{
    if (_errorBlock)
        {
        _errorBlock(client,subscription,error);
        }
}

-(void)cometClient:(DDCometClient *)client subscriptionDidSucceed:(DDCometSubscription *)subscription
{
    if (_successBlock)
        {
        _successBlock(client,subscription);
        }
}

-(BOOL)isEqual:(id)object
{
    if ([object isKindOfClass:[DDCometBlockSubscriptionDelegate class]])
        {
        DDCometBlockSubscriptionDelegate *oth = (DDCometBlockSubscriptionDelegate*)object;
        return oth.successBlock == self.successBlock && oth.errorBlock == self.errorBlock;
        }
    else
        {
        return object == self;
        }
}

@end
