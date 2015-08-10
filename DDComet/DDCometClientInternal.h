//
//  DDCometClientInternal.h
//  CometClient
//
//  Created by Michael Leo on 7/17/15.
//
//
#pragma mark - DDCometClient (Internal)

@interface DDCometClient (Internal)  //Should not be accessed externally

- (id<DDQueue>)outgoingQueue;

- (id<DDQueue>)incomingQueue;

- (void) transportDidFail:(id<DDCometTransport>)transport;

- (void) connection:(id<DDCometTransport>)transport failedWithError:(NSError*)error withMessages:(NSArray*)messages;

- (void) messagesDidSend:(NSArray*)messages;

- (id<DDCometClientDataDelegate>)delegateForMessage:(DDCometMessage*)message;

- (void)handleMessage:(DDCometMessage *)message;

@end


#pragma mark - Logging Support

static inline void DDCometLog(NSString *format, ...)  {
#ifdef DDCOMET_ENABLE_LOG
    __block va_list arg_list;
    va_start (arg_list, format);
    
    NSString *formattedString = [[NSString alloc] initWithFormat:format arguments:arg_list];
    
    va_end(arg_list);
    
    NSLog(@"[DDComet] %@", formattedString);
#endif
}

