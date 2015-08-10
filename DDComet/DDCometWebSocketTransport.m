
//
//  DDCometWebSecontTransport.m
//  CometClient
//
//  Created by Michael Leo on 6/25/15.
//
//

#import "DDCometWebSocketTransport.h"
#import <SocketRocket/SRWebSocket.h>

#import "DDCometClient.h"
#import "DDCometClientInternal.h"

#import "DDCometMessage.h"

#define kDefaultPingTimer 30.0

extern void DDCometLog(NSString *format, ...);

@interface DDCometWebSocketTransport () <SRWebSocketDelegate>

@property (nonatomic, weak) DDCometClient * cometClient;

@property (nonatomic, strong) SRWebSocket * webSocket;

@property (nonatomic, strong) NSTimer * pingTimer;

@end

@implementation DDCometWebSocketTransport
{
    dispatch_queue_t _dispatchQueue;
}

- (id)initWithClient:(DDCometClient *)client
{
    if ((self = [super init]))
        {
        if (client != nil)
            {
            _cometClient = client;
            
            [_cometClient addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionNew context:nil];
            }
        
        _dispatchQueue = dispatch_queue_create("ddcometclient.websocket.queue", DISPATCH_QUEUE_SERIAL);
        
        }
    return self;
}

- (void)dealloc
{
    if (_cometClient != nil)
        {
        @try
            {
            [_cometClient removeObserver:self forKeyPath:@"state"];
            }
        @catch(id anException)
            {
            //do nothing.  It was previously removed
            }
        }
}

- (void)start
{
    [self processMessages];
}

- (void)cancel
{
    if (_pingTimer)
        {
        [_pingTimer invalidate];

        _pingTimer = nil;
        }
    
    if (_webSocket)
        {
        [self disconnectWebSocket];
        }
    
    if (_cometClient != nil)
        {
        [_cometClient removeObserver:self forKeyPath:@"state"];
        
        _cometClient = nil;
        }
}

- (DDCometSupportedTransport)supportedTransport
{
    return DDCometWebSocketSupportedTransport;
}

#pragma mark - DDQueueDelegate

- (void)queueDidAddObject:(id<DDQueue>)queue
{
    [self processMessages];
}

#pragma mark -

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"state"])
        {
        DDCometState state = (DDCometState)[(NSNumber *)[change objectForKey:NSKeyValueChangeNewKey] intValue];
        if (state == DDCometStateConnected)
            {
            [self processMessages];
            [self setupPingTimer];
            }
        }
}

- (void) processMessages
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(_dispatchQueue, ^{
        __strong typeof(weakSelf) strongSelf = self;
        
        if (!strongSelf)
            {
            return;
            }
        
        NSMutableArray * messagesList = [NSMutableArray array];

        SRWebSocket * webSocket = strongSelf.webSocket;
        //1. Set up Long Polling if it is required
        DDCometLog(@"SR State: %p, %ul", webSocket, webSocket.readyState);
        if (webSocket == nil || webSocket.readyState == SR_CLOSED || webSocket.readyState == SR_CLOSING)
            {
            [strongSelf ensureConnected];
            return;
            }
        
        if (webSocket.readyState == SR_OPEN)
            {
            
            //2. Send additional messages if present
            NSArray *outgoingMessagesList = [strongSelf outgoingMessages];
            
            if ([outgoingMessagesList count] > 0)
                {
                [messagesList addObject:outgoingMessagesList];
                }
            
            //3. Send all the messages
            for (NSArray * messages in messagesList)
                {
                
                if ([messages count] != 0)
                    {
                    for (int i = 0; i < messages.count;i++)
                        {
                        NSDictionary * message = ((DDCometMessage*)messages[i]).proxyForJson;
                        [strongSelf writeMessageToWebSocket:message];
                        }
                    }
                }
            }
    });

}

- (NSArray *)outgoingMessages
{
    NSMutableArray *messages = [NSMutableArray array];
    DDCometMessage *message;
    id<DDQueue> outgoingQueue = [_cometClient outgoingQueue];
    while ((message = [outgoingQueue removeObject]))
        [messages addObject:message];
    return messages;
}

#pragma mark - NSURLConnectionDelegate


- (void)connectionDidFinishWithSuccess:(NSURLSessionDataTask *)task responseObject:(id) responseObject timeStamp:(NSDate *) timeStamp messages:(NSArray *) messages
{
    NSArray *responses = responseObject;
    
    if (_cometClient) {
        id<DDQueue> incomingQueue = [_cometClient incomingQueue];
        
        for (NSDictionary *messageData in responses)
            {
            DDCometMessage *message = [DDCometMessage messageWithJson:messageData];
            [incomingQueue addObject:message];
            }
        [_cometClient messagesDidSend:messages];
    }
}


- (void)connectionDidFinishWithError:(NSURLSessionDataTask *)task error:(NSError *)error timeStamp:(NSDate *) timeStamp messages:(NSArray *) messages
{
    
    if (((NSHTTPURLResponse *)task.response).statusCode == 403)
        {
        NSDictionary * message =
        @{
          @"channel": @"/meta/handshake",
          @"successful": @"NO"
          };
        NSArray * responses = @[message];
        
        if (_cometClient)
            {
            id<DDQueue> incomingQueue = [_cometClient incomingQueue];
            
            for (NSDictionary *messageData in responses)
                {
                DDCometMessage *message = [DDCometMessage messageWithJson:messageData];
                [incomingQueue addObject:message];
                }
            [_cometClient messagesDidSend:messages];
            }
        }
    else
        {
        NSTimeInterval sinceConnect = fabs([timeStamp timeIntervalSinceNow]);
        
        //If the time since connect is greater than the timeout interval, it means we were in the background and should ignore the connection failure
        if (_cometClient && sinceConnect < task.originalRequest.timeoutInterval)
            {
            [_cometClient connection:self failedWithError:error withMessages:messages];
            }
        }
}

- (void)ensureConnected {
    DDCometLog(@"ensureConnected, _socket.readyState = %d", _webSocket.readyState);
    BOOL connect = NO;
    if (_webSocket == nil)
        {
        connect = YES;
        }
    else
        {
        switch (_webSocket.readyState)
            {
            case SR_CLOSING:
            case SR_CLOSED:
                connect = YES;
                break;
            default:
                break;
            }
        }
    if (connect)
        {
        [self connectWebSocket];
        }
}


- (BOOL) isConnected
{
    return _webSocket.readyState == SR_OPEN;
}


#pragma mark - WebSocket Methods

- (void)connectWebSocket
{
    
    [self disconnectWebSocket];
    
    NSURL * url = self.cometClient.endpointURL;
    if ([[url absoluteString] hasPrefix:@"http"])
        {
        url = [NSURL URLWithString:[NSString stringWithFormat:@"ws%@", [[url absoluteString] substringFromIndex:4]]];
        }
    
    NSURLRequest *request = [[NSURLRequest alloc] initWithURL:url];
    self.webSocket = [[SRWebSocket alloc] initWithURLRequest:request];
    self.webSocket.delegate = self;
    [self.webSocket open];
}

- (void)writeMessageToWebSocket:(NSDictionary *)message
{
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (error) {
        [self.cometClient connection:self failedWithError:error withMessages:@[message]];
    } else {
        NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [self.webSocket send:json];
    }
}

- (void)setupPingTimer
{
    if (_pingTimer)
        {
        [_pingTimer invalidate];
        _pingTimer = nil;
        }
    _pingTimer = [NSTimer timerWithTimeInterval:kDefaultPingTimer target:self selector:@selector(pingWebSocket) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_pingTimer forMode:NSRunLoopCommonModes];
    
}

- (void)pingWebSocket
{
    if (self.isConnected) {
        // send an empty array to do nothing, but keep the socket open
        DDCometLog(@"Sending ping...");
        [self.webSocket send:@"[]"];
    }
}

- (void)disconnectWebSocket
{
    if (self.webSocket != nil)
        {
        self.webSocket.delegate = nil;
        [self.webSocket close];
        self.webSocket = nil;
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        }
}


#pragma mark - SRWebSocketDelegate

- (void)webSocketDidOpen:(SRWebSocket *)webSocket
{
    DDCometLog(@"SRDidOpen State: %p, %ul", webSocket, webSocket.readyState);
    if (webSocket.readyState == SR_OPEN)
        {
        [self processMessages];
        }
    else
        {
        DDCometLog(@"WebSocket State is not ready state");
        }
}

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message
{
    id data = message;
    if ([data isKindOfClass:[NSString class]])
        data = [data dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSArray *messages = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) {
        [self.cometClient connection:self failedWithError:error withMessages:message];
    } else {
        if (_cometClient) {
            id<DDQueue> incomingQueue = [_cometClient incomingQueue];
        for (__strong NSDictionary *messageData in messages)
            {
                DDCometMessage *message = [DDCometMessage messageWithJson:messageData];
                [incomingQueue addObject:message];
            }
        }
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error
{
    //Need a better way to handle Switching to Long Polling from Websocket communication when it fails.
    if(error.code == 57)
        {
        [self ensureConnected];
        }
    else if ([error.domain isEqualToString:@"org.lolrus.SocketRocket"] && error.code == 2132)
        {
        [self.cometClient transportDidFail:self];
        }
    else
        {
        [self.cometClient connection:self failedWithError:error withMessages:nil];
        }
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean
{
    [self disconnectWebSocket];
    [self ensureConnected];
    {
        NSDictionary *errorInfo = @{NSLocalizedDescriptionKey: @"The WebSocket encountered an error."};
        if (reason) {
            NSMutableDictionary *mutableErrorInfo = [errorInfo mutableCopy];
            mutableErrorInfo[NSLocalizedFailureReasonErrorKey] = reason;
            errorInfo = mutableErrorInfo;
        }
        
        NSError *error = [NSError errorWithDomain:@"org.cometd.BayeuxClient.WebSocketError" code:code userInfo:errorInfo];
    [self.cometClient connection:self failedWithError:error withMessages:nil];
    }
}

@end
