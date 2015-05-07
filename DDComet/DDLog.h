//
//  DDLog.h
//  CometClient
//
//  Created by Gin on 15/5/7.
//
//

#import <Foundation/Foundation.h>

FOUNDATION_EXTERN int LogSwitch;

FOUNDATION_EXPORT void setLogSwitch(int isLog);

FOUNDATION_EXPORT void DDLog(NSString *format, ...);

