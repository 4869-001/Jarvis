#import "WeChatController.h"

#import <Foundation/Foundation.h>
#import <sqlite3.h>
#include <sys/stat.h>

static NSString *const kWeChatNotificationID = @"com.tencent.xinwechat";

@implementation WeChatController

- (NSString *)databasePath {
    NSString *home = NSHomeDirectory();
    NSArray *roots = @[
        [home stringByAppendingPathComponent:@"Library/Group Containers/group.com.apple.usernoted"],
        [home stringByAppendingPathComponent:@"Library/Group Containers/group.com.apple.UserNotifications"]
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        NSDirectoryEnumerator *walk = [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
                               includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                  options:0
                                             errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
        for (NSURL *url in walk) {
            NSNumber *regular = nil, *size = nil;
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            if (!regular.boolValue || size.longLongValue < 512) continue;
            sqlite3 *db = NULL;
            int rc = sqlite3_open_v2(url.path.fileSystemRepresentation, &db,
                                     SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
            BOOL valid = NO;
            if (rc == SQLITE_OK) {
                sqlite3_stmt *stmt = NULL;
                valid = sqlite3_prepare_v2(db, "SELECT app_id,identifier,badge FROM app LIMIT 1",
                                           -1, &stmt, NULL) == SQLITE_OK;
                if (stmt) sqlite3_finalize(stmt);
            }
            if (db) sqlite3_close(db);
            if (valid) return url.path;
        }
    }
    return nil;
}

- (NSDictionary *)plistDictionary:(const void *)bytes length:(int)length {
    if (!bytes || length <= 0) return nil;
    NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    id value = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:nil error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

- (NSString *)hexUUID:(const void *)bytes length:(int)length {
    if (!bytes || length <= 0) return @"";
    const unsigned char *input = bytes;
    NSMutableString *result = [NSMutableString stringWithCapacity:(NSUInteger)length * 2];
    for (int i = 0; i < length; i++) [result appendFormat:@"%02x", input[i]];
    return result;
}

- (NSDictionary *)currentNotifications:(NSString **)errorText {
    NSString *path = [self databasePath];
    if (!path) {
        if (errorText) *errorText = @"Jarvis 无法访问通知中心数据库；请确认完全磁盘访问权限已开启并重新启动 J.A.R.V.I.S.";
        return nil;
    }
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (errorText) *errorText = @"通知中心数据库暂时无法打开";
        if (db) sqlite3_close(db);
        return nil;
    }

    NSMutableArray *notifications = [NSMutableArray array];
    NSInteger badge = 0;
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT a.badge,r.uuid,r.data,r.delivered_date,r.presented "
                      "FROM app a LEFT JOIN record r ON r.app_id=a.app_id "
                      "WHERE lower(a.identifier)=? ORDER BY r.delivered_date DESC";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, kWeChatNotificationID.UTF8String, -1, SQLITE_TRANSIENT);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            badge = sqlite3_column_int64(stmt, 0);
            NSDictionary *record = [self plistDictionary:sqlite3_column_blob(stmt, 2)
                                                  length:sqlite3_column_bytes(stmt, 2)];
            NSDictionary *request = [record[@"req"] isKindOfClass:NSDictionary.class] ? record[@"req"] : nil;
            NSString *title = [request[@"titl"] isKindOfClass:NSString.class] ? request[@"titl"] : @"";
            NSString *body = [request[@"body"] isKindOfClass:NSString.class] ? request[@"body"] : @"";
            if (!title.length && !body.length) continue;
            // 群聊通知里 titl 是群名、subt 才是真正说话的人；单聊没有 subt。
            // 两个字段来自同一条记录，所以拆开也不会出现"张三的名字配李四的话"。
            NSString *subtitle = [request[@"subt"] isKindOfClass:NSString.class] ? request[@"subt"] : @"";
            NSString *uuid = [self hexUUID:sqlite3_column_blob(stmt, 1)
                                     length:sqlite3_column_bytes(stmt, 1)];
            NSTimeInterval appleTime = sqlite3_column_double(stmt, 3);
            NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:appleTime];
            [notifications addObject:@{ @"id": uuid, @"contact": title, @"content": body,
                                        @"sender": subtitle.length ? subtitle : title,
                                        @"is_group": @(subtitle.length > 0),
                                        @"timestamp": @([date timeIntervalSince1970]),
                                        @"time": [NSISO8601DateFormatter stringFromDate:date
                                                                                timeZone:NSTimeZone.localTimeZone
                                                                           formatOptions:NSISO8601DateFormatWithInternetDateTime],
                                        @"presented": @(sqlite3_column_int(stmt, 4) != 0),
                                        @"direction": @"incoming", @"message_type": @"text" }];
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return @{ @"badge_count": @(badge), @"notifications": notifications };
}

- (NSString *)archivePath {
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@".jarvis/wechat"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions:@0700} error:nil];
    chmod(directory.fileSystemRepresentation, 0700);
    return [directory stringByAppendingPathComponent:@"notifications.json"];
}

- (NSArray *)mergedArchive:(NSArray *)current {
    NSString *path = [self archivePath];
    NSData *existingData = [NSData dataWithContentsOfFile:path];
    NSArray *existing = existingData ? [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil] : nil;
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    if ([existing isKindOfClass:NSArray.class]) {
        for (NSDictionary *item in existing) if ([item[@"id"] isKindOfClass:NSString.class]) byID[item[@"id"]] = item;
    }
    for (NSDictionary *item in current) if ([item[@"id"] isKindOfClass:NSString.class]) byID[item[@"id"]] = item;
    NSArray *all = [byID.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"timestamp"] compare:a[@"timestamp"]];
    }];
    if (all.count > 2000) all = [all subarrayWithRange:NSMakeRange(0, 2000)];
    NSData *json = [NSJSONSerialization dataWithJSONObject:all options:0 error:nil];
    [json writeToFile:path options:NSDataWritingAtomic error:nil];
    chmod(path.fileSystemRepresentation, 0600);
    return all;
}

/// 关键词同时匹配会话名和群内发言人：问「李四说了什么」时，李四只出现在 sender 里。
- (BOOL)item:(NSDictionary *)item matchesContact:(NSString *)contact {
    if (!contact.length) return YES;
    for (NSString *key in @[@"contact", @"sender"]) {
        NSString *name = [item[key] isKindOfClass:NSString.class] ? item[key] : @"";
        if (name.length && [name rangeOfString:contact options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    }
    return NO;
}

- (NSArray *)filtered:(NSArray *)items contact:(NSString *)contact limit:(NSInteger)limit {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![self item:item matchesContact:contact]) continue;
        [result addObject:item];
        if (result.count >= limit) break;
    }
    return result;
}

- (void)read:(NSDictionary *)arguments completion:(JarvisWeChatCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSDictionary *current = [self currentNotifications:&error];
        if (!current) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        NSArray *archive = [self mergedArchive:current[@"notifications"]];
        NSString *mode = [arguments[@"mode"] isKindOfClass:NSString.class] ? arguments[@"mode"] : @"unread";
        NSArray *knownModes = @[@"unread", @"recent_sessions", @"chat_history", @"contacts", @"status"];
        if (![knownModes containsObject:mode]) {
            // 静默按某个默认模式处理会让调用方以为查的是别的东西，宁可报错
            NSString *message = [NSString stringWithFormat:@"不认识的 mode「%@」，可用：%@",
                                 mode, [knownModes componentsJoinedByString:@"、"]];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, message); });
            return;
        }
        NSString *contact = [arguments[@"contact"] isKindOfClass:NSString.class] ? arguments[@"contact"] : @"";
        NSInteger limit = [arguments[@"limit"] respondsToSelector:@selector(integerValue)] ? [arguments[@"limit"] integerValue] : 20;
        limit = MAX(1, MIN(limit, 100));
        NSMutableDictionary *result = [@{ @"mode": mode, @"method": @"macos_notification_database",
                                          @"ocr_used": @NO, @"read_only": @YES,
                                          @"badge_count": current[@"badge_count"],
                                          @"has_unread": @([current[@"badge_count"] integerValue] > 0),
                                          @"coverage": @"incoming_notifications_only",
                                          @"coverage_note": @"只包含产生过 macOS 通知的收到消息；不包含自己发出的消息、静音会话或通知归档前已清除的旧消息",
                                          @"privacy": @"微信通知正文仅保存在本机 ~/.jarvis/wechat/notifications.json，并会进入当前 Jarvis 模型上下文" } mutableCopy];
        if ([mode isEqualToString:@"status"]) {
            result[@"ready"] = @YES;
            result[@"archived_count"] = @(archive.count);
        } else if ([mode isEqualToString:@"contacts"]) {
            NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
            for (NSDictionary *item in archive) {
                NSString *name = item[@"contact"] ?: @"";
                if ((!contact.length || [name rangeOfString:contact options:NSCaseInsensitiveSearch].location != NSNotFound) && name.length)
                    [names addObject:name];
                if (names.count >= limit) break;
            }
            result[@"contacts"] = names.array;
        } else if ([mode isEqualToString:@"recent_sessions"]) {
            NSMutableDictionary *seen = [NSMutableDictionary dictionary];
            NSMutableArray *sessions = [NSMutableArray array];
            for (NSDictionary *item in archive) {
                NSString *name = item[@"contact"] ?: @"";
                if (!name.length || seen[name]) continue;
                seen[name] = @YES;
                [sessions addObject:@{ @"contact": name, @"last_message": item[@"content"] ?: @"",
                                       @"last_sender": item[@"sender"] ?: name,
                                       @"is_group": item[@"is_group"] ?: @NO,
                                       @"timestamp": item[@"timestamp"], @"time": item[@"time"] }];
                if (sessions.count >= limit) break;
            }
            result[@"sessions"] = sessions;
        } else if ([mode isEqualToString:@"chat_history"] && !contact.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"chat_history 需要指定 contact；不指定就成了把所有人的私信一起倒出来");
            });
            return;
        } else {
            NSArray *source = archive;
            if ([mode isEqualToString:@"unread"]) {
                // 未读数是 App 级徽标，通知记录里没有"已读/未读"这一位。按时间倒序取
                // 前 badge 条是唯一可行的近似——所以要如实标出来，别让调用方当成精确未读集。
                NSInteger unread = [current[@"badge_count"] integerValue];
                NSArray *records = current[@"notifications"];
                source = unread > 0 ? [records subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)unread, records.count))] : @[];
                result[@"unread_note"] = @"未读集合按徽标数从最新通知里截取，是近似值，不是微信标记的未读";
            }
            result[@"messages"] = [self filtered:source contact:contact limit:limit];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, nil); });
    });
}

@end
