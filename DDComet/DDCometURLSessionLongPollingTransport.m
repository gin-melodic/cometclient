/**
 *  Copyright 2015 - Michael Leo (michael.leo@gmail.com)
 */
#import "DDCometURLSessionLongPollingTransport.h"
#import "DDCometClient.h"
#import "DDCometClientInternal.h"

#import "DDCometMessage.h"

#define kDefaultConnectionTimeout 60.0
#define kConnectionTimeoutVariance 5
#define kMinPollTime 0.020  // The minimum time between polls in seconds

@interface DDCometURLSessionLongPollingTransport () <NSURLSessionTaskDelegate>
    
@property (nonatomic, weak) DDCometClient * cometClient;

@property (nonatomic, strong) NSDate * lastPoll;

@property (nonatomic, strong) NSOperationQueue * operationQueue;

@property (nonatomic, strong) NSURLSession *session;

@property (nonatomic, strong) NSMutableArray * sessionTasks;

@end

@implementation DDCometURLSessionLongPollingTransport

- (id)initWithClient:(DDCometClient *)client
{
	if ((self = [super init]))
        {
        if (client != nil)
            {
            _cometClient = client;

            [_cometClient addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionNew context:nil];
            }
        
        self.operationQueue = [[NSOperationQueue alloc] init];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = self.timeoutInterval;

        NSURLSession *session =
        [NSURLSession sessionWithConfiguration:configuration
                                      delegate:self
                                 delegateQueue:_operationQueue];
        self.session = session;
        
        self.sessionTasks = [NSMutableArray array];
        
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
            //do nothing.  It wad previ
            }
        }
}

- (void)start
{
    
    typeof(self) weakSelf = self;
    [self.operationQueue addOperationWithBlock:^{
        typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf processMessages];
    }];
}

- (void)cancel
{
    if (_cometClient != nil)
        {
        [_cometClient removeObserver:self forKeyPath:@"state"];

        _cometClient = nil;
        }
    
    @synchronized(_sessionTasks)
    {
        while ([_sessionTasks count] > 0)
            {
            NSURLSessionDataTask * task = [_sessionTasks objectAtIndex:0];
            [_sessionTasks removeObjectAtIndex:0];
            [task cancel];
            }
    }
}


- (DDCometSupportedTransport)supportedTransport
{
    return DDCometLongPollingSupportedTransport;
}

#pragma mark - DDQueueDelegate

- (void)queueDidAddObject:(id<DDQueue>)queue
{
    typeof(self) weakSelf = self;
    [self.operationQueue addOperationWithBlock:^{
        typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf processMessages];
    }];
}

#pragma mark -

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"state"])
        {
        DDCometState state = (DDCometState)[(NSNumber *)[change objectForKey:NSKeyValueChangeNewKey] intValue];
        if (state == DDCometStateConnected)
            {
            typeof(self) weakSelf = self;
            [self.operationQueue addOperationWithBlock:^{
                typeof(weakSelf) strongSelf = weakSelf;
                [strongSelf processMessages];
            }];
            }
        }
}

- (void) processMessages
{
    // List of Lists
    NSMutableArray * messagesLists = [NSMutableArray array];
    
    //1. Pull out /meta/connect if present and send separately
    NSMutableArray *outgoingMessagesList = [NSMutableArray array];
    
    for (DDCometMessage * message in [self outgoingMessages])
        {
        if ([message.channel isEqualToString:@"/meta/connect"])
            {
            [messagesLists addObject:@[message]];
            }
        else
            {
            [outgoingMessagesList addObject:message];
            }
        }
    
    if ([outgoingMessagesList count] > 0)
        {
        [messagesLists addObject:outgoingMessagesList];
        }
    
    //2. Send all the message
    for (NSArray * messageList in messagesLists)
        {
        NSURLSessionDataTask *sessionDataTask =
            [self sendMessages:messageList
               success:^(NSURLSessionDataTask *task, id responseObject, NSDate *timeStamp, NSArray *messages) {
                   [self connectionDidFinishWithSuccess:task responseObject:responseObject timeStamp:timeStamp messages:messages];
               } failure:^(NSURLSessionDataTask *task, NSError *error, NSDate *timeStamp, NSArray *messages) {
                    [self connectionDidFinishWithError:task error:error timeStamp:timeStamp messages:messages];
               }];
        
        if (sessionDataTask)
            {
                @synchronized(_sessionTasks)
                {
                [_sessionTasks addObject:sessionDataTask];
                }
            }
        }
}

- (NSURLSessionDataTask *)sendMessages:(NSArray *)messages
                          success:(void (^)(NSURLSessionDataTask *task, id responseObject, NSDate * timeStamp, NSArray * messages))success
                          failure:(void (^)(NSURLSessionDataTask *task, NSError *error, NSDate * timeStamp, NSArray * messages))failure
{
	if ([messages count] != 0)
        {
        __block NSDate * timestampKey = [NSDate date];
        __block NSArray * messagesCopy = [NSArray arrayWithArray:messages];
        
        
        __block NSURLSessionDataTask *sessionDataTask = nil;
        
        sessionDataTask = [self requestWithMessages:messages
                              success:^(NSURLSessionDataTask *task, id responseObject) {
                                  if (success)
                                      {
                                      success(task, responseObject, timestampKey, messagesCopy);
                                      
                                      @synchronized(_sessionTasks)
                                          {
                                          [_sessionTasks removeObject:sessionDataTask];
                                          }
                                      
                                      }
                              }
                              failure:^(NSURLSessionDataTask *task, NSError *error) {
                                  if (failure)
                                      {
                                      failure(task, error, timestampKey, messagesCopy);
                                      
                                      @synchronized(_sessionTasks)
                                          {
                                          [_sessionTasks removeObject:sessionDataTask];
                                          }
                                      }
                              }];
        return sessionDataTask;
        }
    return nil;
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

- (NSURLSessionDataTask *)requestWithMessages:(NSArray *)messages
                                        success:(void (^)(NSURLSessionDataTask *task, id responseObject))success
                                        failure:(void (^)(NSURLSessionDataTask *task, NSError *error))failure
{
    // 1
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_cometClient.endpointURL];
    
    // 2
    NSError *error;
    NSMutableArray *msgArr = [NSMutableArray arrayWithCapacity:messages.count];
    for (int i = 0; i < messages.count;i++) {
        msgArr[i] = ((DDCometMessage*)messages[i]).proxyForJson;
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:msgArr options:NSJSONWritingPrettyPrinted error:&error];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:body];
    [request setTimeoutInterval:self.timeoutInterval];
    
    __block NSURLSessionDataTask *sessionDataTask = nil;
    sessionDataTask = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                              if (error) {
                                                                  if (failure) {
                                                                      failure(sessionDataTask, error);
                                                                  }
                                                              } else {
                                                                  if (success) {
                                                                      NSArray *responses = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];

                                                                      success(sessionDataTask, responses);
                                                                  }
                                                              }
                                                            }];
    [sessionDataTask resume];
    
    return sessionDataTask;
}

-(NSTimeInterval)timeoutInterval
{
    return kDefaultConnectionTimeout;
}

#pragma mark - NSURLConnectionDelegate


- (void)connectionDidFinishWithSuccess:(NSURLSessionDataTask *)task responseObject:(id) responseObject timeStamp:(NSDate *) timeStamp messages:(NSArray *) messages
{
	NSArray *responses = responseObject;
    
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

@end
