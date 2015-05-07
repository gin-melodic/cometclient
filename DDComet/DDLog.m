//
//  DDLog.m
//  CometClient
//
//  Created by Gin on 15/5/7.
//
//

#import "DDLog.h"

int LogSwitch = 0;

void setLogSwitch(int isLog) {
  LogSwitch = isLog;
}

void DDLog(NSString *format, ...) {
  //如果format为nil
  if (!format && LogSwitch == 1) {
    va_list args;
    va_start(args, format);
    //只取第一个参数
    void *str = nil;
    while ((str = va_arg(args, void*))) {
      if ([NSString stringWithUTF8String:str]) {
        format = @"%s";
        break;
      }
      else {
        format = @"%@";
        break;
      }
    }
    va_end(args);
  }
  NSString *hrdFormat = [[NSString alloc] initWithFormat:@"[DDLOG]#####%@#####",format];
  va_list args;
  va_start(args, format);
  NSLogv(hrdFormat, args);
  va_end(args);
}
