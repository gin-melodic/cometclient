
#import <Foundation/Foundation.h>
#import "DDQueue.h"

typedef NS_OPTIONS(NSUInteger, DDCometSupportedTransport)
{
    DDCometWebSocketSupportedTransport = (1 << 0), // => 00000001
    DDCometLongPollingSupportedTransport = (1 << 1), // => 00000010
};

@class DDCometClient;

@protocol DDCometTransport <DDQueueDelegate>

- (id)initWithClient:(DDCometClient *)client;

- (void)start;

- (void)cancel;

- (DDCometSupportedTransport) supportedTransport;

@end
