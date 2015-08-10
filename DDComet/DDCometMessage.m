
#import "DDCometMessage.h"
#import <objc/runtime.h>

@interface NSDate (ISO8601)

+ (NSDate *)dateWithISO8601String:(NSString *)string;
- (NSString *)ISO8601Representation;

@end

@implementation NSDate (ISO8601)
static __strong NSDateFormatter* FMT;

+(void)initFormat
{
    if (!FMT) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        [fmt setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
        FMT = fmt;
    }
}

+ (NSDate *)dateWithISO8601String:(NSString *)string
{
	[NSDate initFormat];
    return [FMT dateFromString:string];
}

- (NSString *)ISO8601Representation
{
    [NSDate initFormat];
    return [FMT stringFromDate:self];
}

@end

@interface NSError (Bayeux)

+ (NSError *)errorWithBayeuxFormat:(NSString *)string;
- (NSString *)bayeuxFormat;

@end

@implementation NSError (Bayeux)

+ (NSError *)errorWithBayeuxFormat:(NSString *)string
{
	NSArray *components = [string componentsSeparatedByString:@":"];
	NSInteger code = [components[0] integerValue];
	NSDictionary *userInfo = @{NSLocalizedDescriptionKey: components[2]};
	return [[NSError alloc] initWithDomain:@"" code:code userInfo:userInfo];
}

- (NSString *)bayeuxFormat
{
	NSString *args = @"";
	NSArray *components = @[[NSString stringWithFormat:@"%ld", (long)[self code]], args, [self localizedDescription]];
	return [components componentsJoinedByString:@":"];
}

@end

@implementation DDCometMessage

+ (DDCometMessage *)messageWithChannel:(NSString *)channel
{
	DDCometMessage *message = [[DDCometMessage alloc] init];
	message.channel = channel;
	return message;
}

@end

@implementation DDCometMessage (JSON)

+ (DDCometMessage *)messageWithJson:(NSDictionary *)jsonData
{
	DDCometMessage *message = [[DDCometMessage alloc] init];
	for (NSString *key in [jsonData keyEnumerator])
	{
		id object = jsonData[key];
		
		if ([key isEqualToString:@"channel"])
			message.channel = object;
		else if ([key isEqualToString:@"version"])
			message.version = object;
		else if ([key isEqualToString:@"minimumVersion"])
			message.minimumVersion = object;
		else if ([key isEqualToString:@"supportedConnectionTypes"])
			message.supportedConnectionTypes = object;
		else if ([key isEqualToString:@"clientId"])
			message.clientID = object;
		else if ([key isEqualToString:@"advice"])
			message.advice = object;
		else if ([key isEqualToString:@"connectionType"])
			message.connectionType = object;
		else if ([key isEqualToString:@"id"])
			message.ID = object;
		else if ([key isEqualToString:@"timestamp"])
			message.timestamp = [NSDate dateWithISO8601String:object];
		else if ([key isEqualToString:@"data"])
			message.data = object;
		else if ([key isEqualToString:@"successful"])
			message.successful = object;
		else if ([key isEqualToString:@"subscription"])
			message.subscription = object;
		else if ([key isEqualToString:@"error"])
			message.error = [NSError errorWithBayeuxFormat:object];
		else if ([key isEqualToString:@"ext"])
			message.ext = object;
	}
	return message;
}

- (NSDictionary *)proxyForJson
{
	NSMutableDictionary *dict = [NSMutableDictionary dictionary];
	if (_channel)
		dict[@"channel"] = _channel;
	if (_version)
		dict[@"version"] = _version;
	if (_minimumVersion)
		dict[@"minimumVersion"] = _minimumVersion;
	if (_supportedConnectionTypes)
		dict[@"supportedConnectionTypes"] = _supportedConnectionTypes;
	if (_clientID)
		dict[@"clientId"] = _clientID;
	if (_advice)
		dict[@"advice"] = _advice;
	if (_connectionType)
		dict[@"connectionType"] = _connectionType;
	if (_ID)
		dict[@"id"] = _ID;
	if (_timestamp)
		dict[@"timestamp"] = [_timestamp ISO8601Representation];
	if (_data) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
        if ([_data respondsToSelector:@selector(asDictionary)]) {
            dict[@"data"] = [_data performSelector:@selector(asDictionary)];
#pragma clang diagnostic pop
        } else {
            dict[@"data"] = _data;
        }
    }
	if (_successful)
		dict[@"successful"] = _successful;
	if (_subscription)
		dict[@"subscription"] = _subscription;
	if (_error)
		dict[@"error"] = [_error bayeuxFormat];
	if (_ext)
		dict[@"ext"] = _ext;
	return dict;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"%@ %@", [super description], [self proxyForJson]];
}

@end
