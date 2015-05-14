
#import "DDQueueProcessor.h"
#import <objc/message.h>


void DDQueueProcessorPerform(void *info);

@implementation DDQueueProcessor

+ (DDQueueProcessor *)queueProcessorWithQueue:(id<DDQueue>)queue
									   target:(id)target
									 selector:(SEL)selector
{
	DDQueueProcessor *processor = [[DDQueueProcessor alloc] initWithTarget:target selector:selector];
	[queue setDelegate:processor];
	[processor scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	return processor;
}

- (id)initWithTarget:(id)target selector:(SEL)selector
{
	if ((self = [super init]))
	{
		m_target = target;
		m_selector = selector;
		
		CFRunLoopSourceContext context =
		{
			0, (__bridge void *)(self), NULL, NULL, NULL, NULL, NULL, NULL, NULL,
			DDQueueProcessorPerform
		};
		
		m_source = CFRunLoopSourceCreate(NULL, 0, &context);
	}
	return self;
}

- (void)dealloc
{
	if (m_runLoop)
		CFRunLoopRemoveSource([m_runLoop getCFRunLoop], m_source, (__bridge CFStringRef)m_mode);

	CFRelease(m_source);
}

- (void)scheduleInRunLoop:(NSRunLoop *)runLoop forMode:(NSString *)mode
{
	@synchronized(self)
	{
		CFRunLoopAddSource([runLoop getCFRunLoop], m_source, (__bridge CFStringRef)mode);
		m_runLoop = runLoop;
		m_mode = mode;
	}
}

- (void)queueDidAddObject:(id<DDQueue>)queue
{
	CFRunLoopSourceSignal(m_source);
	CFRunLoopWakeUp([m_runLoop getCFRunLoop]);
}

- (void)makeTargetPeformSelector
{
  if (!m_target) return;
  @synchronized(self) {
    ((void (*)(id, SEL))[m_target methodForSelector:m_selector])(m_target, m_selector);
  }
}

@end

void DDQueueProcessorPerform(void *info)
{
	DDQueueProcessor *processor = (__bridge DDQueueProcessor *)(info);
	[processor makeTargetPeformSelector];
}
