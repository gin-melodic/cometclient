
#import "DDCometClient.h"
#import <libkern/OSAtomic.h>
#import <objc/message.h>
#import "DDCometAFLongPollingTransport.h"
#import "DDCometMessage.h"
#import "DDCometSubscription.h"
#import "DDConcurrentQueue.h"
#import "DDQueueProcessor.h"

#define kCometErrorClientNotFound 402

static void * const delegateKey = (void*)&delegateKey;

@interface DDCometBlockDataDelegate : NSObject<DDCometClientDataDelegate>
@property (nonatomic, copy) void (^successBlock)(DDCometClient*,id,NSString*);
@property (nonatomic, copy) void (^errorBlock)(DDCometClient*,id,NSString*,NSError*);
-(id)initWithSuccessBlock:(void(^)(DDCometClient*,id,NSString*))successBlock errorBlock:(void(^)(DDCometClient*,id,NSString*,NSError*))errorBlock;
@end

@interface DDCometBlockSubscriptionDelegate : NSObject<DDCometClientSubscriptionDelegate>
@property (nonatomic, copy) void (^successBlock)(DDCometClient*,DDCometSubscription*);
@property (nonatomic, copy) void (^errorBlock)(DDCometClient*,DDCometSubscription*,NSError*);
-(id)initWithSuccessBlock:(void(^)(DDCometClient*,DDCometSubscription*))successBlock errorBlock:(void(^)(DDCometClient*,DDCometSubscription*,NSError*))errorBlock;
@end

@implementation DDCometBlockDataDelegate
-(id)initWithSuccessBlock:(void (^)(DDCometClient *, id, NSString *))successBlock errorBlock:(void (^)(DDCometClient *, id, NSString *, NSError *))errorBlock
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
{    if ([object isKindOfClass:[DDCometBlockSubscriptionDelegate class]])
    {
        DDCometBlockSubscriptionDelegate *oth = (DDCometBlockSubscriptionDelegate*)object;
        return oth.successBlock == self.successBlock && oth.errorBlock == self.errorBlock;
    } else {
        return object == self;
    }
}
@end


@interface DDCometClient ()

- (NSString *)nextMessageID;
- (void)sendMessage:(DDCometMessage *)message;
- (void)handleMessage:(DDCometMessage *)message;
- (void)handleDisconnection;

@end

@implementation DDCometClient

@synthesize clientID = m_clientID,
	endpointURL = m_endpointURL,
	state = m_state,
	advice = m_advice,
	delegate = m_delegate,
    allowDuplicateSubscriptions = m_allowDuplicateSubscriptions,
    reconnectOnClientExpired = m_reconnectOnClientExpired;

- (id)initWithURL:(NSURL *)endpointURL
{
	if ((self = [super init]))
	{
		m_endpointURL = endpointURL;
		m_pendingSubscriptions = [[NSMutableDictionary alloc] init];
		m_subscriptions = [[NSMutableArray alloc] init];
		m_outgoingQueue = [[DDConcurrentQueue alloc] init];
		m_incomingQueue = [[DDConcurrentQueue alloc] init];
        m_reconnectOnClientExpired = YES;
        m_persistentSubscriptions = YES;
//        _maxServerTimeDifference = kCometClientDefaultMaxTimestampDifference;
	}
	return self;
}


- (void)scheduleInRunLoop:(NSRunLoop *)runLoop forMode:(NSString *)mode
{
	m_incomingProcessor = [[DDQueueProcessor alloc] initWithTarget:self selector:@selector(processIncomingMessages)];
	[m_incomingQueue setDelegate:m_incomingProcessor];
	[m_incomingProcessor scheduleInRunLoop:runLoop forMode:mode];
}

- (DDCometMessage *)handshake
{
    return [self handshakeWithData:nil];
}

- (DDCometMessage *)handshakeWithData:(NSDictionary *)data
{
    m_state = DDCometStateHandshaking;
    
    DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/handshake"];
    message.version = @"1.0";
    message.supportedConnectionTypes = @[@"long-polling"];
    message.data = data;
    
    [self sendMessage:message];
    return message;
}

- (DDCometMessage *)disconnect
{
    if (m_state == DDCometStateConnected) {
        m_state = DDCometStateDisconnecting;
        
        DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/disconnect"];
        [self sendMessage:message];
        return message;
    } else {
        return nil;
    }
}

-(DDCometSubscription*) subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector {
    return [self subscribeToChannel:channel target:target selector:selector delegate:nil];
}
-(DDCometSubscription*) subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector successBlock:(void (^)(DDCometClient *, DDCometSubscription *))successBlock errorBlock:(void (^)(DDCometClient *, DDCometSubscription *, NSError *))errorBlock
{
    if (errorBlock || successBlock) {
        DDCometBlockSubscriptionDelegate *delegate = [[DDCometBlockSubscriptionDelegate alloc] initWithSuccessBlock:successBlock errorBlock:errorBlock];
        return [self subscribeToChannel:channel target:target selector:selector delegate:delegate];
    } else {
        return [self subscribeToChannel:channel target:target selector:selector delegate:nil];
    }
}

- (DDCometSubscription *)subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector delegate:(id<DDCometClientSubscriptionDelegate>)delegate
{
    DDCometSubscription *subscription = [[DDCometSubscription alloc] initWithChannel:channel target:target selector:selector delegate:delegate];
    BOOL alreadySubscribed = NO;
    BOOL shouldAddSubscription = NO;
    BOOL foundDuplicate = NO;
    NSMutableArray *channelsToUnsubscribe = [NSMutableArray array];
    id<DDCometClientSubscriptionDelegate> localDelegate = delegate?delegate:m_delegate;
    @synchronized(m_subscriptions) {
        for (DDCometSubscription *subscription in m_subscriptions)
        {
            if ([subscription matchesChannel:channel])
            {
                if ([subscription.target isEqual:target] && subscription.selector == selector) {
                    if (self.allowDuplicateSubscriptions) {
                        shouldAddSubscription = YES;
                    }
                    foundDuplicate = YES;
                }
                alreadySubscribed = YES;
            } else if ([subscription isParentChannel:channel]) {
                [channelsToUnsubscribe addObject:subscription.channel];
            }
        }
        if (!foundDuplicate && alreadySubscribed) {
            shouldAddSubscription = YES;
        }
        if (shouldAddSubscription) {
            [m_subscriptions addObject:subscription];        
        }    
    
        if (alreadySubscribed) {
            if (localDelegate && [localDelegate respondsToSelector:@selector(cometClient:subscriptionDidSucceed:)])
                [localDelegate cometClient:self subscriptionDidSucceed:subscription];
        } else {
            
            shouldAddSubscription = NO;
            foundDuplicate = NO;

            NSMutableArray * pending;
            for (NSString * curChannel in m_pendingSubscriptions) {
                pending  = m_pendingSubscriptions[curChannel];
                //We have a pending subscription that is a subchannel to the one we're about to subscribe
                //Therefore we should unsubscribe the child and replace the list of channels
                if ([DDCometSubscription channel:channel isParentTo:curChannel]) {
                    NSMutableArray * curPendingForChannel = m_pendingSubscriptions[channel];
                    if (!curPendingForChannel) {
                        if (pending) {
                            curPendingForChannel = [NSMutableArray arrayWithArray:pending];
                        } else {
                            curPendingForChannel = [NSMutableArray array];
                        }
                    } else if (pending) {
                        [curPendingForChannel addObjectsFromArray:pending];                        
                    }
                    [channelsToUnsubscribe addObject:curChannel];
                    pending = curPendingForChannel;
                    break;
                } else if ([DDCometSubscription channel:channel matchesChannel:curChannel]) {
                    if (!pending) {
                        pending = [NSMutableArray arrayWithCapacity:5];
                        m_pendingSubscriptions[channel] = pending;
                    } else if (pending.count > 0) {
                        alreadySubscribed = YES;
                    }
                    break;
                } else {
                    pending = nil;
                }
            }
            for (DDCometSubscription *subscription in pending) {
                if ([subscription.channel isEqualToString:channel] && [subscription.target isEqual:target] && subscription.selector == selector) {
                    if (self.allowDuplicateSubscriptions) {
                        shouldAddSubscription = YES;
                    }
                    foundDuplicate = YES;
                    break;
                }
            }
            if (!pending) {
                pending = [NSMutableArray arrayWithCapacity:5];
                m_pendingSubscriptions[channel] = pending;
            }
            

                                    
            if (!foundDuplicate || shouldAddSubscription) {
                [pending addObject:subscription];
            }
            
            if (!alreadySubscribed && m_state == DDCometStateConnected) {
                DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/subscribe"];
                message.ID = [self nextMessageID];
                message.subscription = channel;
                [self sendMessage:message];
            }
        }
        
        if (channelsToUnsubscribe.count > 0) {
            for (NSString * curChannel in channelsToUnsubscribe) {
                [m_pendingSubscriptions removeObjectForKey:curChannel];
                if (m_state == DDCometStateConnected) {
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
    @synchronized(m_subscriptions) {
        if (m_state == DDCometStateConnected) {
            NSMutableSet *channels = [NSMutableSet setWithCapacity:m_subscriptions.count];
            for (DDCometSubscription *subscription in m_subscriptions) {
                [channels addObject:subscription.channel];
            }
            [channels addObjectsFromArray:m_pendingSubscriptions.allKeys];
            
            for (NSString * channel in channels) {
                DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/unsubscribe"];
                message.ID = [self nextMessageID];
                message.subscription = channel;
                [self sendMessage:message];
            }
        }
        [m_subscriptions removeAllObjects];
        [m_pendingSubscriptions removeAllObjects];
    }
}

- (DDCometMessage *)unsubsubscribeFromChannel:(NSString *)channel target:(id)target selector:(SEL)selector
{
    __block BOOL subscriptionsRemain = NO;
    __block BOOL subscriptionFound = NO;
    @synchronized(m_subscriptions)
	{
		NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
		NSUInteger count = [m_subscriptions count];
        NSMutableDictionary *subscriptionsToAdd = [NSMutableDictionary dictionaryWithCapacity:m_subscriptions.count];
		for (NSUInteger i = 0; i < count; i++)
		{
			DDCometSubscription *subscription = m_subscriptions[i];
			if ([subscription.channel isEqualToString:channel])
			{
                if (((target == nil && subscription.target == nil) || [subscription.target isEqual:target]) && subscription.selector == selector) {
                    [indexes addIndex:i];
                } else {
                    //If there is a subscription for this channel that remains that isn't the same selector
                    subscriptionsRemain = YES;
                }
                subscriptionFound = YES;
			} else if ([subscription isParentChannel:channel]) {
                NSMutableArray *pending = subscriptionsToAdd[subscription.channel];
                if (!pending) {
                    pending = [NSMutableArray array];
                    subscriptionsToAdd[subscription.channel] = pending;
                }
                [indexes addIndex:i];
                [pending addObject:subscription];
            }
		}        
		[m_subscriptions removeObjectsAtIndexes:indexes];    
        if (!subscriptionFound) {
        //If there is no current subscription, we need to check pending subscriptions to see if we need to remove them
        
            NSMutableArray *keysToRemove = [NSMutableArray arrayWithCapacity:m_pendingSubscriptions.count];
            NSMutableDictionary *keysToAdd = [NSMutableDictionary dictionaryWithCapacity:m_pendingSubscriptions.count];
            [m_pendingSubscriptions enumerateKeysAndObjectsUsingBlock:^(NSString* channelKey, NSMutableArray *subscriptions,BOOL *stop) {
                
                if ([DDCometSubscription channel:channelKey matchesChannel:channel]) {
                    NSMutableIndexSet *indexes = [[NSMutableIndexSet alloc] init];
                    [subscriptions enumerateObjectsUsingBlock:^(DDCometSubscription * subscription, NSUInteger i, BOOL* stopInside) {
                        if ([subscription.channel isEqualToString:channel]) {
                            if (((target == nil && subscription.target == nil) || [subscription.target isEqual:target]) && subscription.selector == selector) {
                                [indexes addIndex:i];
                            } else {
                                subscriptionsRemain = YES;
                            }
                            subscriptionFound = YES;                        
                        }
                    }];
                    [subscriptions removeObjectsAtIndexes:indexes];
                    if (subscriptions.count == 0) {
                        [keysToRemove addObject:channelKey];
                    } else if ([channelKey isEqualToString:channel] && !subscriptionsRemain) {
                        //This means it's a child subscription and there aren't any more global subscriptions that match the parent key
                        [keysToRemove addObject:channelKey];
                        for (DDCometSubscription * curSub in subscriptions)
                        {
                            NSMutableArray * newSet = keysToAdd[curSub.channel];
                            if (!newSet) {
                                newSet = [NSMutableArray array];
                                keysToAdd[curSub.channel] = newSet;
                            }
                            [newSet addObject:curSub];
                        }
                        
//                        NSMutableArray *newKeysToRemove = [NSMutableArray arrayWithCapacity:keysToAdd.count];
//                        //Just in case there are any other subscriptions in the current pending subscription that are the parent of the others
//                        for (NSString * curChannel in keysToAdd) {
//                            for (NSString * parentChannel in keysToAdd) {
//                                if ([DDCometSubscription channel:parentChannel isParentTo:curChannel]) {
//                                    NSMutableArray * arrayToCombineValues = keysToAdd[curChannel];
//                                    NSMutableArray * arrayToCombineWith = keysToAdd[parentChannel];
//                                    [arrayToCombineWith addObjectsFromArray:arrayToCombineValues];
//                                    [newKeysToRemove addObject:curChannel];
//                                    break;
//                                }
//                            }
//                        }
//                        [keysToAdd removeObjectsForKeys:newKeysToRemove];
                    }
                }
            }];
                
            [m_pendingSubscriptions removeObjectsForKeys:keysToRemove];
            for (NSString * key in keysToAdd) {
                NSMutableArray * value = keysToAdd[key];
                NSMutableArray * combineWith = subscriptionsToAdd[key];
                if (combineWith) {
                    [value addObjectsFromArray:combineWith];
                    [subscriptionsToAdd removeObjectForKey:key];
                    subscriptionsToAdd[key] = value;
                } else {
                    subscriptionsToAdd[key] = value;
                }
            }
        }
        if (m_state == DDCometStateConnected && subscriptionsToAdd.count > 0) {

            //Just in case there are any other subscriptions in the current pending subscription that are the parent of the others
            NSMutableArray *keysToRemove = [NSMutableArray arrayWithCapacity:subscriptionsToAdd.count];
            for (NSString * curChannel in subscriptionsToAdd) {
                for (NSString * parentChannel in subscriptionsToAdd) {
                    if ([DDCometSubscription channel:parentChannel isParentTo:curChannel]) {
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
//            __block NSMutableIndexSet *removeFromAdd = [NSMutableIndexSet indexSet];
//            [subscriptionsToAdd enumerateObjectsUsingBlock:^(NSString *channelToAdd, NSUInteger i, BOOL *stopOuter) {
//                 for (DDCometSubscription * subscription in m_subscriptions) {
//                    //We don't need to add any subscriptions that have other subscriptions that are it's parent
//                    if (![subscription.channel isEqualToString:channelToAdd] && [subscription matchesChannel:channelToAdd]) {
//                        [removeFromAdd addIndex:i];
//                        break;
//                    }
//                }
//            }];
//           
//            [subscriptionsToAdd removeObjectsAtIndexes:removeFromAdd];
            
            for (NSString * curChannel in subscriptionsToAdd) {
                DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/subscribe"];
                message.ID = [self nextMessageID];
                message.subscription = curChannel;
                [self sendMessage:message];
            }
        }
            
    }
    if (subscriptionFound && !subscriptionsRemain && m_state == DDCometStateConnected) {
        DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/unsubscribe"];
        message.ID = [self nextMessageID];
        message.subscription = channel;
        [self sendMessage:message];
        return message;
    } else {
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

#pragma mark -

- (id<DDQueue>)outgoingQueue
{
	return m_outgoingQueue;
}

- (id<DDQueue>)incomingQueue
{
	return m_incomingQueue;
}

-(void)messagesDidSend:(NSArray *)messages
{
    for (DDCometMessage *message in messages)
    {
        id<DDCometClientDataDelegate> dataDelegate = objc_getAssociatedObject(message, delegateKey);
        if (dataDelegate) {
            objc_setAssociatedObject(message, delegateKey, nil, OBJC_ASSOCIATION_ASSIGN);
            [dataDelegate cometClient:self dataDidSend:message.data toChannel:message.channel];
        }
    }
}

#pragma mark -

- (NSString *)nextMessageID
{
	return [NSString stringWithFormat:@"%d", OSAtomicIncrement32Barrier(&m_messageCounter)];
}

- (void)sendMessage:(DDCometMessage *)message
{
	message.clientID = m_clientID;
	if (!message.ID)
		message.ID = [self nextMessageID];
	DDLog(@"Sending message: %@", message);
	[m_outgoingQueue addObject:message];
	
	if (m_transport == nil && m_endpointURL != nil)
	{
		m_transport = [[DDCometAFLongPollingTransport alloc] initWithClient:self];
		[m_transport start];
	}
}

- (void)handleMessage:(DDCometMessage *)message
{    
	DDLog(@"Message received: %@", message);
	NSString *channel = message.channel;
    
	if ([channel hasPrefix:@"/meta/"])
	{
		if ([channel isEqualToString:@"/meta/handshake"])
		{
			if ([message.successful boolValue])
			{
                if (m_state == DDCometStateTransportError && m_delegate && [m_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)]) {
                    [m_delegate cometClientContinuedReceivingMessages:self];
                }
				m_clientID = message.clientID;
				m_state = DDCometStateConnecting;
				DDCometMessage *connectMessage = [DDCometMessage messageWithChannel:@"/meta/connect"];
				connectMessage.connectionType = @"long-polling";
				[self sendMessage:connectMessage];
				if (m_delegate && [m_delegate respondsToSelector:@selector(cometClientHandshakeDidSucceed:)])
					[m_delegate cometClientHandshakeDidSucceed:self];
			}
			else
			{
                [self handleDisconnection];
				if (m_delegate && [m_delegate respondsToSelector:@selector(cometClient:handshakeDidFailWithError:)])
					[m_delegate cometClient:self handshakeDidFailWithError:message.error];
			}
		}
		else if ([channel isEqualToString:@"/meta/connect"])
		{
			if (message.advice)
			{
				m_advice = message.advice;
			}
			if (![message.successful boolValue])
			{
                DDCometState beforeState = m_state;
                
                [self handleDisconnection];
				if (m_state == DDCometStateConnecting && m_delegate && [m_delegate respondsToSelector:@selector(cometClient:connectDidFailWithError:)])
					[m_delegate cometClient:self connectDidFailWithError:message.error];
                
                //Error code 402 indicates the clientID was not found on the server which means we should immediately handshake again if configured to do so
                //Subscriptions have already been moved to pending through the "handleDisconnect" method and will be resubscribed if the connection is successful
                if (message.error.code == kCometErrorClientNotFound && beforeState == DDCometStateConnected) {
                    if (m_reconnectOnClientExpired) {
                        [self handshake];
                    }
                    if (m_delegate && [m_delegate respondsToSelector:@selector(cometClientExpired:)]) {
                        [m_delegate cometClientExpired:self];
                    }
                }
			}
			else if (m_state == DDCometStateConnecting || m_state == DDCometStateTransportError)
			{
                if (m_state == DDCometStateTransportError && m_delegate && [m_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)]) {
                    [m_delegate cometClientContinuedReceivingMessages:self];
                }
                
                @synchronized(m_subscriptions) {
                    m_state = DDCometStateConnected;
                    //Once we're connected, send all the pending subscriptions
                    for (NSString * channel in m_pendingSubscriptions) {
                        DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/subscribe"];
                        message.ID = [self nextMessageID];
                        message.subscription = channel;
                        [self sendMessage:message];
                    }
                }
                
				if (m_delegate && [m_delegate respondsToSelector:@selector(cometClientConnectDidSucceed:)])
					[m_delegate cometClientConnectDidSucceed:self];
			}
		}
        else if ([channel isEqualToString:@"/meta/unsubscribe"]) {
            if (m_state == DDCometStateTransportError) {
                m_state = DDCometStateConnected;
                if (m_delegate && [m_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)]) {
                    [m_delegate cometClientContinuedReceivingMessages:self];
                }
            }
        }
		else if ([channel isEqualToString:@"/meta/disconnect"])
		{
			[self handleDisconnection];
		}
		else if ([channel isEqualToString:@"/meta/subscribe"])
		{
            @synchronized(m_subscriptions)
            {
                NSMutableArray *subscriptions = m_pendingSubscriptions[message.subscription];
                if (subscriptions) {

                    [m_pendingSubscriptions removeObjectForKey:message.subscription];
                    if (!message.successful.boolValue) {
                        for (DDCometSubscription *subscription in subscriptions) {
                            id<DDCometClientSubscriptionDelegate> localDelegate = subscription.delegate?subscription.delegate:m_delegate;
                            if(localDelegate && [localDelegate respondsToSelector:@selector(cometClient:subscription:didFailWithError:)]) {
                                [localDelegate cometClient:self subscription:subscription didFailWithError:message.error];
                            }
                        }
                    } else if (message.successful.boolValue) {
                        for (DDCometSubscription *subscription in subscriptions) {
                            id<DDCometClientSubscriptionDelegate> localDelegate = subscription.delegate?subscription.delegate:m_delegate;
                            [m_subscriptions addObject:subscription];
                            if (localDelegate && [localDelegate respondsToSelector:@selector(cometClient:subscriptionDidSucceed:)]) {
                                [localDelegate cometClient:self subscriptionDidSucceed:subscription];
                            }
                        }
                    }
                    if (m_state == DDCometStateTransportError) {
                        m_state = DDCometStateConnected;
                        if (m_delegate && [m_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)]) {
                            [m_delegate cometClientContinuedReceivingMessages:self];
                        }
                    }
                }
            }			
			
		}
		else
		{
			DDLog(@"Unhandled meta message");
		}
	}
	else
	{
        if (m_state == DDCometStateTransportError) {
            m_state = DDCometStateConnected;
            if (m_delegate && [m_delegate respondsToSelector:@selector(cometClientContinuedReceivingMessages:)]) {
                [m_delegate cometClientContinuedReceivingMessages:self];
            }
        }
		NSMutableArray *subscriptions = [NSMutableArray arrayWithCapacity:m_subscriptions.count];
		@synchronized(m_subscriptions)
		{
			for (DDCometSubscription *subscription in m_subscriptions)
			{
				if ([subscription matchesChannel:message.channel])
					[subscriptions addObject:subscription];
			}
		}
		for (DDCometSubscription *subscription in subscriptions) {
            //To conform to ARC
			if (!subscription.target) 
			{
				//This means the target of the subscription call has been released and cannot receive any message so we should unsubscribe
				[self unsubscribeWithSubscription:subscription];
			}
      if ([subscription.target respondsToSelector:subscription.selector])
			{
        //Fix bug in ARC
        if (!subscription.target) {
          return;
        }
        IMP imp = [subscription.target methodForSelector:subscription.selector];
        void (*func)(id, SEL, id) = (void *)imp;
        func(subscription.target, subscription.selector, message);
      }
    }
	}
}

-(void)handleDisconnection {        
    @synchronized(m_subscriptions) {
        [m_transport cancel];
        m_transport = nil;
        m_state = DDCometStateDisconnected;
        m_advice = nil;
        m_clientID = nil;
        if (m_persistentSubscriptions) {
            for (DDCometSubscription * subscription in m_subscriptions) {
                NSMutableArray *pending = [self pendingSubscriptionsMatching:subscription.channel];            
                [pending addObject:subscription];
            }
        } else {
            [m_pendingSubscriptions removeAllObjects];
        }
        [m_subscriptions removeAllObjects];
    }
}

-(NSMutableArray*)pendingSubscriptionsMatching:(NSString*)channel
{
    NSMutableArray * exactMatch = m_pendingSubscriptions[channel];
    if (exactMatch) {
        return exactMatch;
    }
    for (NSString *pendingChannel in m_pendingSubscriptions) {
        if ([DDCometSubscription channel:pendingChannel matchesChannel:channel]) {
            return m_pendingSubscriptions[pendingChannel];
        }
    }
    NSMutableArray *newArray = [NSMutableArray array];
    m_pendingSubscriptions[channel] = newArray;
    return newArray;
}

- (void)processIncomingMessages
{
	DDCometMessage *message;
	while ((message = [m_incomingQueue removeObject]))
		[self handleMessage:message];
}

-(void)connectionFailed:(NSURLConnection *)connection withError:(NSError *)error withMessages:(NSArray *)messages {
    if (m_state == DDCometStateConnected && m_delegate && [m_delegate respondsToSelector:@selector(cometClient:stoppedReceivingMessagesWithError:)]) {
        [m_delegate cometClient:self stoppedReceivingMessagesWithError:error];
    }
    m_state = DDCometStateTransportError;

    for (DDCometMessage *message in messages) {
        [self processMessageFailed:message withError:error];
    }
    
    if (m_delegate && [m_delegate respondsToSelector:@selector(cometClient:didFailWithTransportError:)]) {
        [m_delegate cometClient:self didFailWithTransportError:error];
    }
}

-(void)processMessageFailed:(DDCometMessage*)message withError:(NSError*)error {
    
    NSString *channel = message.channel;
	if ([channel hasPrefix:@"/meta/"])
	{
		if ([channel isEqualToString:@"/meta/handshake"])
		{
            if (m_delegate && [m_delegate respondsToSelector:@selector(cometClient:handshakeDidFailWithError:)]) {
                [m_delegate cometClient:self handshakeDidFailWithError:error];
            }
        }
		else if ([channel isEqualToString:@"/meta/connect"])
		{
			if (m_state == DDCometStateConnecting && m_delegate && [m_delegate respondsToSelector:@selector(cometClient:connectDidFailWithError:)]) {
                [m_delegate cometClient:self connectDidFailWithError:error];                
            }
		}
		else if ([channel isEqualToString:@"/meta/unsubscribe"] || [channel isEqualToString:@"/meta/disconnect"])
		{
            //Do nothing as we don't notify of a disconnect/unsubscribe error, we don't care
		}
		else if ([channel isEqualToString:@"/meta/subscribe"])
		{
            @synchronized(m_subscriptions)
            {
                NSMutableArray *subscriptions = m_pendingSubscriptions[message.subscription];
                if (subscriptions) {
                    for (DDCometSubscription *subscription in subscriptions) {
                        id<DDCometClientSubscriptionDelegate> localDelegate = subscription.delegate?subscription.delegate:m_delegate;
                        if (localDelegate && [localDelegate respondsToSelector:@selector(cometClient:subscription:didFailWithError:)]) {
                            [localDelegate cometClient:self subscription:subscription didFailWithError:error];
                        }
                    }
                }
                [m_pendingSubscriptions removeObjectForKey:message.subscription];
            }
			
		}
	}
	else
	{
        //If it's not a meta message then we should handle it through the data delegate
		id<DDCometClientDataDelegate> dataDelegate = [self delegateForMessage:message];
        if (dataDelegate) {
            objc_setAssociatedObject(message, delegateKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        if (dataDelegate && [dataDelegate respondsToSelector:@selector(cometClient:data:toChannel:didFailWithError:)]) {
            [dataDelegate cometClient:self data:message.data toChannel:message.channel didFailWithError:error];
        } else if (m_delegate && [m_delegate respondsToSelector:@selector(cometClient:data:toChannel:didFailWithError:)]) {
            [m_delegate cometClient:self data:message.data toChannel:message.channel didFailWithError:error];
        }
	}

}

-(id<DDCometClientDataDelegate>)delegateForMessage:(DDCometMessage *)message
{
    return objc_getAssociatedObject(message, delegateKey);
}

#pragma mark - 日志相关
- (void)setDebugMode:(BOOL)debugMode {
  _debugMode = debugMode;
  if (debugMode) {
    setLogSwitch(1);
  }
  else {
    setLogSwitch(0);
  }
}

@end
