
#import "DDCometAFLongPollingTransport.h"
#import "DDCometClient.h"
#import "DDCometMessage.h"
#import "DDQueue.h"
#import <objc/runtime.h>

#define kDefaultConnectionTimeout 60.0
#define kConnectionTimeoutVariance 5
#define kMinPollTime 0.020  // The minimum time between polls in seconds

@interface DDCometAFLongPollingTransport ()
    
@property (nonatomic, weak) DDCometClient * cometClient;
@property (nonatomic, assign) BOOL shouldCancel;

@property (nonatomic, assign) BOOL polling;
@property (nonatomic, strong) NSDate * lastPoll;

- (NSURLConnection *)sendMessages:(NSArray *)messages;
- (NSArray *)outgoingMessages;
- (NSURLRequest *)requestWithMessages:(NSArray *)messages;

@end

@implementation DDCometAFLongPollingTransport
static void * const responseDataKey = (void*)&responseDataKey;
static void * const messagesKey = (void*)&messagesKey;
static void * const timestampKey = (void*)&timestampKey;
static void * const statusKey = (void*)&statusKey;

- (id)initWithClient:(DDCometClient *)client
{
	if ((self = [super init]))
	{
		_cometClient = client;
//		_responseDatas = [[NSMutableDictionary alloc] initWithCapacity:2];
	}
	return self;
}


- (void)start
{
	[self performSelectorInBackground:@selector(main) withObject:nil];
}

- (void)cancel
{
	_shouldCancel = YES;
    _cometClient = nil;
}

#pragma mark -

- (void)main
{
	do
	{
		@autoreleasepool {
			NSArray *messages = [self outgoingMessages];
			
			BOOL isPolling = NO;
			if ([messages count] == 0)
			{
				if (_cometClient.state == DDCometStateConnected && !_polling && (!_lastPoll || fabs([_lastPoll timeIntervalSinceNow]) > kMinPollTime))
				{
					isPolling = YES;
                    _polling = YES;
					DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/connect"];
					message.clientID = _cometClient.clientID;
					message.connectionType = @"long-polling";
					DDLog(@"Sending long-poll message: %@", message);
					messages = @[message];
                    _lastPoll = [NSDate date];
				}
				else
				{
					[NSThread sleepForTimeInterval:kMinPollTime / 2];
                    continue;
				}
			}
			
			NSURLConnection *connection = [self sendMessages:messages];
			if (connection)
			{
				NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
				while ([runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]])
				{
					if (isPolling)
					{
						if (_shouldCancel)
						{
							_shouldCancel = NO;
							[connection cancel];
						}
						else
						{
							messages = [self outgoingMessages];
							[self sendMessages:messages];
						}
					}
				}
			}
		}
	} while (_cometClient.state != DDCometStateDisconnected && !_shouldCancel);
}

- (NSURLConnection *)sendMessages:(NSArray *)messages
{
	NSURLConnection *connection = nil;
	if ([messages count] != 0)
	{
		NSURLRequest *request = [self requestWithMessages:messages];
		connection = [NSURLConnection connectionWithRequest:request delegate:self];
        objc_setAssociatedObject(connection, &messagesKey, messages, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(connection, &timestampKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		if (connection)
		{
			NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
			[connection scheduleInRunLoop:runLoop forMode:[runLoop currentMode]];
			[connection start];
		}
	}
	return connection;
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

- (NSURLRequest *)requestWithMessages:(NSArray *)messages
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_cometClient.endpointURL];
	
    NSError *error;
    NSMutableArray *msgArr = [NSMutableArray arrayWithCapacity:messages.count];
    for (int i = 0; i < messages.count;i++) {
        msgArr[i] = ((DDCometMessage*)messages[i]).proxyForJson;
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:msgArr options:NSJSONWritingPrettyPrinted error:&error];

    DDLog(@"Sending Comet message:\n%@", [[NSString alloc] initWithBytes:body.bytes length:body.length encoding:NSUTF8StringEncoding]);
	
	[request setHTTPMethod:@"POST"];
	[request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
	[request setHTTPBody:body];
	[request setTimeoutInterval:self.timeoutInterval];
	return request;
}

-(NSTimeInterval)timeoutInterval
{
    NSNumber *timeout = (_cometClient.advice)[@"timeout"];
	if (timeout)
        return (([timeout floatValue] / 1000) + kConnectionTimeoutVariance);
    else
        return kDefaultConnectionTimeout;
}

#pragma mark - NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSInteger * lastStatusCode = [((NSHTTPURLResponse *)response) statusCode];
    objc_setAssociatedObject(connection, &statusKey, [NSNumber numberWithInteger:lastStatusCode], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(connection, &responseDataKey, [NSMutableData data], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	NSMutableData *responseData = objc_getAssociatedObject(connection, &responseDataKey);
	[responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	NSData *responseData = objc_getAssociatedObject(connection, &responseDataKey);
    NSArray * messages = objc_getAssociatedObject(connection, &messagesKey);
    NSNumber * statusCode = objc_getAssociatedObject(connection, &statusKey);
    
    objc_setAssociatedObject(connection, &responseDataKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(connection, &messagesKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(connection, &timestampKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(connection, &statusKey, nil, OBJC_ASSOCIATION_ASSIGN);
    
    NSError *error;
	NSArray *responses = [NSJSONSerialization JSONObjectWithData:responseData options:kNilOptions error:&error];

	responseData = nil;
    
    if ([responses count] == 0 && [statusCode integerValue] == 403)
        {
        NSDictionary * message =
        @{
          @"channel": @"/meta/handshake",
          @"successful": @"NO"
        };
        responses = @[message];
        }
    
    if (_cometClient) {
        id<DDQueue> incomingQueue = [_cometClient incomingQueue];

        for (NSDictionary *messageData in responses)
        {
            DDCometMessage *message = [DDCometMessage messageWithJson:messageData];
            if (_polling && [message.channel isEqualToString:@"/meta/connect"]) {
                _polling = NO;
            }
            [incomingQueue addObject:message];
        }
        [_cometClient messagesDidSend:messages];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    _polling = NO;
    NSArray * messages = objc_getAssociatedObject(connection, &messagesKey);
    NSDate * timestamp = objc_getAssociatedObject(connection, &timestampKey);
    NSTimeInterval sinceConnect = fabs([timestamp timeIntervalSinceNow]);        
    objc_setAssociatedObject(connection, &responseDataKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(connection, &messagesKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(connection, &timestampKey, nil, OBJC_ASSOCIATION_ASSIGN);
    //If the time since connect is greater than the timeout interval, it means we were in the background and should ignore the connection failure
    if (_cometClient && sinceConnect < connection.originalRequest.timeoutInterval) {
        [_cometClient connectionFailed:connection withError:error withMessages:messages];
    }
}

@end
