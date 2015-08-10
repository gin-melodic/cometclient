
#import "DDConcurrentQueue.h"
#import <objc/objc-auto.h>
#import <libkern/OSAtomic.h>


@interface DDConcurrentQueueNode : NSObject
{
@private
    id __strong _object;
	DDConcurrentQueueNode * volatile __strong _next;
}

@property (nonatomic, strong) id object;
@property (nonatomic, strong, readonly) DDConcurrentQueueNode *next;

- (BOOL)compareNext:(DDConcurrentQueueNode *)old andSet:(DDConcurrentQueueNode *)new;

@end

@implementation DDConcurrentQueueNode

- (id)initWithObject:(id)object
{
	if ((self = [super init]))
	{
		_object = object;
        _next = nil;
	}
	return self;
}

- (BOOL)compareNext:(DDConcurrentQueueNode *)old andSet:(DDConcurrentQueueNode *)new
{
	return OSAtomicCompareAndSwapPtrBarrier((__bridge void *)(old), (__bridge void *)(new), (void * volatile)&_next);
}

@end

@interface DDConcurrentQueue ()
{
@private
    DDConcurrentQueueNode * volatile _head;
    DDConcurrentQueueNode * volatile _tail;
    id<DDQueueDelegate> _delegate;
}
- (BOOL)compareHead:(DDConcurrentQueueNode *)old andSet:(DDConcurrentQueueNode *)new;
- (BOOL)compareTail:(DDConcurrentQueueNode *)old andSet:(DDConcurrentQueueNode *)new;

@end

@implementation DDConcurrentQueue

- (id)init
{
	if ((self = [super init]))
	{
		DDConcurrentQueueNode *node = [[DDConcurrentQueueNode alloc] init];
        //CFRetain((__bridge CFTypeRef)node);
		_head = node;
		_tail = node;
	}
	return self;
}

- (void)addObject:(id)object
{
	DDConcurrentQueueNode *node = [[DDConcurrentQueueNode alloc] initWithObject:object];
    CFRetain((__bridge CFTypeRef)node);
	while (YES)
	{
		DDConcurrentQueueNode *tail = _tail;
		DDConcurrentQueueNode *next = tail.next;
		if (tail == _tail)
		{
			if (next == nil)
			{
				if ([tail compareNext:next andSet:node])
				{
					[self compareTail:tail andSet:node];
					break;
				}
			}
			else
			{
				[self compareTail:tail andSet:node];
			}
		}
	}
	if (_delegate)
		[_delegate queueDidAddObject:self];
}

- (id)removeObject
{
	while (YES)
	{
		DDConcurrentQueueNode *head = (DDConcurrentQueueNode*)_head;
		DDConcurrentQueueNode *tail = (DDConcurrentQueueNode*)_tail;
		DDConcurrentQueueNode *first = head.next;
		if (head == _head)
		{
			if (head == tail)
			{
				if (first == nil)
					return nil;
				else
					[self compareTail:tail andSet:first];
			}
			else if ([self compareHead:head andSet:first])
			{
				id object = first.object;
                //CFRelease((__bridge CFTypeRef) head);
				if (object != nil)
				{
					first.object = nil;
					return object;
				}
				// else skip over deleted item, continue loop
			}
		}
	}
}

- (void)setDelegate:(id<DDQueueDelegate>)delegate
{
	_delegate = delegate;
}

- (BOOL)compareHead:(DDConcurrentQueueNode *)old andSet:(DDConcurrentQueueNode *)new
{
	return OSAtomicCompareAndSwapPtrBarrier((__bridge void *)old, (__bridge void *)new, (volatile void *) &_head);
}

- (BOOL)compareTail:(DDConcurrentQueueNode *)old andSet:(DDConcurrentQueueNode *)new
{
	return OSAtomicCompareAndSwapPtrBarrier((__bridge void *)old, (__bridge void *)new, (volatile void *)&_tail);
}

@end
