
#import "DDCometSubscription.h"
#import "DDCometClient.h"

@implementation DDCometSubscription

- (id)initWithChannel:(NSString *)channel target:(id)target selector:(SEL)selector
{
	if ((self = [super init]))
	{
		_channel = channel;
		_target = target;
		_selector = selector;
	}
	return self;
}

- (id)initWithChannel:(NSString *)channel target:(id)target selector:(SEL)selector delegate:(id<DDCometClientDelegate>)delegate
{
	if ((self = [self initWithChannel:channel target:target selector:selector]))
	{
        _delegate = delegate;
	}
	return self;
}


- (BOOL)matchesChannel:(NSString *)channel
{
	if ([_channel isEqualToString:channel])
		return YES;
	if ([_channel hasSuffix:@"/**"])
	{
		NSString *prefix = [_channel substringToIndex:([_channel length] - 2)];
        return [channel hasPrefix:prefix];
	}
	else if ([_channel hasSuffix:@"/*"])
	{
		NSString *prefix = [_channel substringToIndex:([_channel length] - 1)];
		if ([channel hasPrefix:prefix] && [[channel substringFromIndex:([_channel length] - 1)] rangeOfString:@"*"].location == NSNotFound)
			return YES;
	}
	return NO;
}

-(BOOL)isWildcard
{
    return [_channel hasSuffix:@"/*"] || [_channel hasSuffix:@"/**"];
}

-(BOOL)isParentChannel:(NSString*)channel
{
    if ([channel hasSuffix:@"/*"]) {
        NSString *prefix = [channel substringToIndex:([channel length] - 1)];
        return [_channel hasPrefix:prefix] && [[_channel substringFromIndex:([_channel length] - 1)] rangeOfString:@"*"].location == NSNotFound;
    } else if ([channel hasSuffix:@"/**"]) {
        NSString *prefix = [channel substringToIndex:([channel length] - 2)];
        return [_channel hasPrefix:prefix];
    } else {
        return NO;
    }
}

+(BOOL)channel:(NSString*)parent isParentTo:(NSString*)channel {
    if ([parent hasSuffix:@"/*"]) {
        NSString *prefix = [parent substringToIndex:([parent length] - 1)];
        return [channel hasPrefix:prefix] && [[channel substringFromIndex:([channel length] - 1)] rangeOfString:@"*"].location == NSNotFound;
    } else if ([parent hasSuffix:@"/**"]) {
        NSString *prefix = [parent substringToIndex:([parent length] - 2)];
        return [channel hasPrefix:prefix];
    } else {
        return NO;
    }

}

+(BOOL)channel:(NSString*)subchannel matchesChannel:(NSString*)parent {
    if ([parent isEqualToString:subchannel])
		return YES;
	if ([parent hasSuffix:@"/**"])
	{
		NSString *prefix = [parent substringToIndex:([parent length] - 2)];
        return [subchannel hasPrefix:prefix];
	}
	else if ([parent hasSuffix:@"/*"])
	{
		NSString *prefix = [parent substringToIndex:([parent length] - 1)];
		return ([subchannel hasPrefix:prefix] && [[subchannel substringFromIndex:([subchannel length] - 1)] rangeOfString:@"*"].location == NSNotFound);
	}
	return NO;

}

-(NSString*)description
{
    return [NSString stringWithFormat:@"%@-%lu", self.channel, (unsigned long)self.hash];
}

@end
