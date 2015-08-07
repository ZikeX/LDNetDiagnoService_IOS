//
//  LDNetPing.m
//  LDNetCheckServiceDemo
//
//  Created by 庞辉 on 14-10-29.
//  Copyright (c) 2014年 庞辉. All rights reserved.
//
#include <sys/socket.h>
#include <netdb.h>

#import "LDNetPing.h"
#import "LDNetTimer.h"

#define MAXCOUNT_PING 4

@interface LDNetPing () {
    BOOL _isStartSuccess; //监测第一次ping是否成功
    int _sendCount;  //当前执行次数
    long _startTime; //每次执行的开始时间
    NSString *_hostAddress; //目标域名的IP地址
}

@property (nonatomic, strong, readwrite) LDSimplePing *pinger;

@end


@implementation LDNetPing
@synthesize pinger = _pinger;


- (void)dealloc{
    [self->_pinger stop];
}


/**
 * 停止当前ping动作
 */
-(void) stopPing {
    [self->_pinger stop];
    self.pinger =  nil;
    _sendCount = MAXCOUNT_PING + 1;
}


/*
 * 调用pinger解析指定域名
 * @param hostName 指定域名
 */
- (void)runWithHostName:(NSString *)hostName{
    assert(self.pinger == nil);
    self.pinger = [LDSimplePing simplePingWithHostName:hostName];
    assert(self.pinger != nil);
    
    self.pinger.delegate = self;
    [self.pinger start];
    
    //在当前线程一直执行
    _sendCount = 1;
    do {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    } while (self.pinger != nil || _sendCount <= MAXCOUNT_PING);
}


/*
 * 发送Ping数据，pinger会组装一个ICMP控制报文的数据发送过去
 *
 */
- (void)sendPing{
    if(_sendCount > MAXCOUNT_PING){
        _sendCount++;
        self.pinger = nil;
        if(self.delegate && [self.delegate respondsToSelector:@selector(netPingDidEnd)]){
            [self.delegate netPingDidEnd];
        }
    }
    
    else {
        assert(self.pinger != nil);
        _sendCount++;
        _startTime = [LDNetTimer getMicroSeconds];
        [self.pinger sendPingWithData:nil];
        [self performSelector:@selector(pingTimeout:) withObject:[NSNumber numberWithInt:_sendCount] afterDelay:3];
    }
}

-(void)pingTimeout:(NSNumber *)index
{
    if ([index intValue]==_sendCount && _sendCount<=MAXCOUNT_PING+1) {
        NSString *timeoutLog = [NSString stringWithFormat:@"%@ time out", _hostAddress];
        if(self.delegate && [self.delegate respondsToSelector:@selector(appendPingLog:)]){
            [self.delegate appendPingLog:timeoutLog];
        }
        [self sendPing];
    }
}



#pragma mark - Pingdelegate
/*
 * PingDelegate: 套接口开启之后发送ping数据，并开启一个timer（1s间隔发送数据）
 *
 */
- (void)simplePing:(LDSimplePing *)pinger didStartWithAddress:(NSData *)address{
#pragma unused(pinger)
    assert(pinger == self.pinger);
    assert(address != nil);
    _hostAddress = DisplayAddressForAddress(address);
    NSLog(@"pinging %@", _hostAddress);
    
    // Send the first ping straight away.
    _isStartSuccess = YES;
    [self sendPing];
}

/*
 * PingDelegate: ping命令发生错误之后，立即停止timer和线程
 *
 */
- (void)simplePing:(LDSimplePing *)pinger didFailWithError:(NSError *)error{
#pragma unused(pinger)
    assert(pinger == self.pinger);
#pragma unused(error)
    NSString *failCreateLog = [NSString stringWithFormat:@"#%u try create failed: %@", _sendCount, [self shortErrorFromError:error]];
    if(self.delegate && [self.delegate respondsToSelector:@selector(appendPingLog:)]){
        [self.delegate appendPingLog:failCreateLog];
    }
    
    //如果不是创建套接字失败，都是发送数据过程中的错误,可以继续try发送数据
    if(_isStartSuccess){
        [self sendPing];
    } else {
        [self stopPing];
    }
}

/*
 * PingDelegate: 发送ping数据成功
 *
 */
- (void)simplePing:(LDSimplePing *)pinger didSendPacket:(NSData *)packet{
#pragma unused(pinger)
    assert(pinger == self.pinger);
#pragma unused(packet)
  NSLog(@"#%u sent success", (unsigned int) OSSwapBigToHostInt16(((const ICMPHeader *) [packet bytes])->sequenceNumber) );
}


/*
 * PingDelegate: 发送ping数据失败
 *
 */
- (void)simplePing:(LDSimplePing *)pinger didFailToSendPacket:(NSData *)packet error:(NSError *)error{
#pragma unused(pinger)
    assert(pinger == self.pinger);
#pragma unused(packet)
#pragma unused(error)
    NSString *sendFailLog = [NSString stringWithFormat:@"#%u send failed: %@", (unsigned int) OSSwapBigToHostInt16(((const ICMPHeader *) [packet bytes])->sequenceNumber), [self shortErrorFromError:error]];
    //记录
    if(self.delegate && [self.delegate respondsToSelector:@selector(appendPingLog:)]){
        [self.delegate appendPingLog:sendFailLog];
    }

    [self sendPing];
}


/*
 * PingDelegate: 成功接收到PingResponse数据
 *
 */
- (void)simplePing:(LDSimplePing *)pinger didReceivePingResponsePacket:(NSData *)packet{
#pragma unused(pinger)
    assert(pinger == self.pinger);
#pragma unused(packet)
    
    NSString *successLog = [NSString stringWithFormat:@"%lu bytes from %@ icmp_seq=#%u ttl=%d time=%ldms",
          (unsigned long)[packet length],
          _hostAddress,
          (unsigned int) OSSwapBigToHostInt16([LDSimplePing icmpInPacket:packet]->sequenceNumber),
          (unsigned int) ([LDSimplePing ipHeaderInPacket:packet]->timeToLive),
          [LDNetTimer computeDurationSince:_startTime] /1000];
    //记录ping成功的数据
    if(self.delegate && [self.delegate respondsToSelector:@selector(appendPingLog:)]){
        [self.delegate appendPingLog:successLog];
    }
    
    [self sendPing];
}


/*
 * PingDelegate: 接收到错误的pingResponse数据
 *
 */
- (void)simplePing:(LDSimplePing *)pinger didReceiveUnexpectedPacket:(NSData *)packet{
    const ICMPHeader *  icmpPtr;
    if(self.pinger && pinger == self.pinger){
        icmpPtr = [LDSimplePing icmpInPacket:packet];
        NSString *errorLog = @"";
        if (icmpPtr != NULL) {
            errorLog = [NSString stringWithFormat:@"#%u unexpected ICMP type=%u, code=%u, identifier=%u", (unsigned int) OSSwapBigToHostInt16(icmpPtr->sequenceNumber), (unsigned int) icmpPtr->type, (unsigned int) icmpPtr->code, (unsigned int) OSSwapBigToHostInt16(icmpPtr->identifier)];
        } else {
            errorLog = [NSString stringWithFormat:@"#%u try unexpected packet size=%zu", _sendCount, (size_t) [packet length]];
        }
        //记录
        if(self.delegate && [self.delegate respondsToSelector:@selector(appendPingLog:)]){
            [self.delegate appendPingLog:errorLog];
        }

    }
    
    //当检测到错误数据的时候，再次发送
    [self sendPing];
}


/**
 * 将ping接收的数据转换成ip地址
 * @param address 接受的ping数据
 */
NSString * DisplayAddressForAddress(NSData * address){
    int         err;
    NSString *  result;
    char        hostStr[NI_MAXHOST];
    
    result = nil;
    
    if (address != nil) {
        err = getnameinfo([address bytes], (socklen_t) [address length], hostStr, sizeof(hostStr), NULL, 0, NI_NUMERICHOST);
        if (err == 0) {
            result = [NSString stringWithCString:hostStr encoding:NSASCIIStringEncoding];
            assert(result != nil);
        }
    }
    
    return result;
}

/*
 * 解析错误数据并翻译
 */
- (NSString *)shortErrorFromError:(NSError *)error{
    NSString *      result;
    NSNumber *      failureNum;
    int             failure;
    const char *    failureStr;
    
    assert(error != nil);
    
    result = nil;
    
    // Handle DNS errors as a special case.
    
    if ( [[error domain] isEqual:(NSString *)kCFErrorDomainCFNetwork] && ([error code] == kCFHostErrorUnknown) ) {
        failureNum = [[error userInfo] objectForKey:(id)kCFGetAddrInfoFailureKey];
        if ( [failureNum isKindOfClass:[NSNumber class]] ) {
            failure = [failureNum intValue];
            if (failure != 0) {
                failureStr = gai_strerror(failure);
                if (failureStr != NULL) {
                    result = [NSString stringWithUTF8String:failureStr];
                    assert(result != nil);
                }
            }
        }
    }
    
    // Otherwise try various properties of the error object.
    
    if (result == nil) {
        result = [error localizedFailureReason];
    }
    if (result == nil) {
        result = [error localizedDescription];
    }
    if (result == nil) {
        result = [error description];
    }
    assert(result != nil);
    return result;
}

@end

