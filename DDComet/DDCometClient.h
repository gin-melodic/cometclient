
#import <Foundation/Foundation.h>
#import "DDCometTransport.h"
#import "DDCometMessage.h"
#import "DDCometSubscription.h"

@protocol DDCometClientDelegate;
@protocol DDCometClientSubscriptionDelegate;
@protocol DDCometClientDataDelegate;

typedef enum
{
	DDCometStateDisconnected,
    DDCometStateHandshaking,
	DDCometStateConnecting,
	DDCometStateConnected,
	DDCometStateDisconnecting,
    DDCometStateTransportError
} DDCometState;


#pragma mark - DDCometClient

@interface DDCometClient : NSObject


@property (nonatomic, readonly) NSURL *endpointURL;

@property (nonatomic, assign) DDCometSupportedTransport supportedTransports;

@property (strong) NSDictionary * handshakeData;

@property (nonatomic, readonly) DDCometState state;

@property (nonatomic, readonly) NSString *clientID;

@property (nonatomic, weak) id<DDCometClientDelegate> delegate;

@property (nonatomic, assign) BOOL allowDuplicateSubscriptions;

//Should we reconnect automatically and create a new client session if the session we were using expired
//    If YES and on a "/meta/connect" request the server returns error 402, then [self handshake] will immediately be called
@property (nonatomic, assign) BOOL reconnectOnClientExpired; // Default is YES

//If the client is disconnected (because the server session expired, 'disconnect' was called or because of a transport error)
//     should subscriptions be maintained so that they are resubscribed once the client reconnects?
//     If set to NO, all subscriptions will need to be resubscribed when any disconnection occurs
//     If set to YES (default) and you would need to call 'unsubscribeAll' after calling 'disconnect' if you don't want subscriptions to resubscribe automatically when 'handshake' is called
@property (nonatomic, assign) BOOL persistentSubscriptions; // Default to YES

//Allow callbacks to happen off the main thread
@property (nonatomic, strong) dispatch_queue_t callbackQueue;


- (instancetype)initWithURL:(NSURL *)endpointURL;

- (DDCometMessage *)handshake;

- (DDCometMessage *)handshakeWithData:(NSDictionary *)data;

- (DDCometMessage *)disconnect;

- (DDCometSubscription *)subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector;

- (DDCometSubscription *)subscribeToChannel:(NSString *)channel extensions:(id)extensions target:(id)target selector:(SEL)selector;

- (DDCometSubscription *)subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector delegate:(id<DDCometClientSubscriptionDelegate>)delegate;

- (DDCometSubscription *)subscribeToChannel:(NSString *)channel target:(id)target selector:(SEL)selector successBlock:(void(^)(DDCometClient*,DDCometSubscription*))successBlock errorBlock:(void(^)(DDCometClient*,DDCometSubscription*,NSError*))errorBlock;


- (DDCometMessage *)unsubsubscribeFromChannel:(NSString *)channel target:(id)target selector:(SEL)selector;

- (void)unsubscribeWithSubscription:(DDCometSubscription*)subscription;

- (DDCometMessage *)publishData:(id)data toChannel:(NSString *)channel;

- (DDCometMessage *)publishData:(id)data toChannel:(NSString *)channel withDelegate:(id<DDCometClientDataDelegate>)delegate;

- (DDCometMessage *)publishData:(id)data toChannel:(NSString *)channel
                   successBlock:(void(^)(DDCometClient*,id,NSString*))successBlock
                     errorBlock:(void(^)(DDCometClient*,id,NSString*,NSError*))errorBlock;

- (void) unsubscribeAll;

@end

#pragma mark - DDCometClientDelegate

@protocol DDCometClientDelegate <DDCometClientSubscriptionDelegate, DDCometClientDataDelegate>
@optional

- (void)cometClientHandshakeDidSucceed:(DDCometClient *)client;

- (void)cometClient:(DDCometClient *)client handshakeDidFailWithError:(NSError *)error;

- (void)cometClientConnectDidSucceed:(DDCometClient *)client;

- (void)cometClient:(DDCometClient *)client connectDidFailWithError:(NSError *)error;

- (void)cometClient:(DDCometClient*)client stoppedReceivingMessagesWithError:(NSError*)error;

- (void)cometClientContinuedReceivingMessages:(DDCometClient*)client;

- (void)cometClient:(DDCometClient*)client didFailWithTransportError:(NSError*)error;

- (void)cometClientExpired:(DDCometClient*)client;

@end

#pragma mark - DDCometClientSubscriptionDelegate

@protocol DDCometClientSubscriptionDelegate <NSObject>
@optional

- (void)cometClient:(DDCometClient *)client subscriptionDidSucceed:(DDCometSubscription *)subscription;

- (void)cometClient:(DDCometClient *)client subscription:(DDCometSubscription *)subscription didFailWithError:(NSError *)error;

@end

#pragma mark - DDCometClientDataDelegate

@protocol DDCometClientDataDelegate <NSObject>
@optional

- (void)cometClient:(DDCometClient*)client dataDidSend:(id)data toChannel:(NSString*)channel;

- (void)cometClient:(DDCometClient*)client data:(id)data toChannel:(NSString*)channel didFailWithError:(NSError*)error;

@end

