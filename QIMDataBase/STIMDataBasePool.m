//
//  STIMDataBasePool.m
//  STIMDataBase
//
//  Created by lihaibin.li on 2019/5/29.
//

#if STIMDB_SQLITE_STANDALONE
#import <sqlite3/sqlite3.h>
#else

#import <sqlite3.h>

#endif

#import "STIMDataBasePool.h"
#import "STIMDataBase.h"

typedef NS_ENUM(NSInteger, STIMDBTransaction) {
    STIMDBTransactionExclusive,
    STIMDBTransactionDeferred,
    STIMDBTransactionImmediate,
};

@interface STIMDataBasePool () {
    dispatch_queue_t _lockQueue;

    NSMutableArray *_readDatabaseInPool;
    NSMutableArray *_readDatabaseOutPool;
    NSMutableArray *_writeDatabaseInPool;
    NSMutableArray *_writeDatabaseOutPool;
}

- (void)pushReadDatabaseBackInPool:(STIMDataBase *)db;

- (void)pushWriteDatabaseBackInPool:(STIMDataBase *)db;

- (STIMDataBase *)db;

@end


@implementation STIMDataBasePool
@synthesize path = _path;
@synthesize delegate = _delegate;
@synthesize maximumNumberOfReadDatabasesToCreate = _maximumNumberOfReadDatabasesToCreate;
@synthesize maximumNumberOfWriteDatabasesToCreate = _maximumNumberOfWriteDatabasesToCreate;
@synthesize openFlags = _openFlags;


+ (instancetype)databasePoolWithPath:(NSString *)aPath {
    return STIMDBReturnAutoreleased([[self alloc] initWithPath:aPath]);
}

+ (instancetype)databasePoolWithPath:(NSString *)aPath flags:(int)openFlags vfs:(NSString *)vfsName {
    return STIMDBReturnAutoreleased([[self alloc] initWithPath:aPath flags:openFlags vfs:vfsName]);
}

+ (instancetype)databasePoolWithURL:(NSURL *)url {
    return STIMDBReturnAutoreleased([[self alloc] initWithPath:url.path]);
}

+ (instancetype)databasePoolWithPath:(NSString *)aPath flags:(int)openFlags {
    return STIMDBReturnAutoreleased([[self alloc] initWithPath:aPath flags:openFlags]);
}

+ (instancetype)databasePoolWithURL:(NSURL *)url flags:(int)openFlags {
    return STIMDBReturnAutoreleased([[self alloc] initWithPath:url.path flags:openFlags]);
}

- (instancetype)initWithURL:(NSURL *)url flags:(int)openFlags vfs:(NSString *)vfsName {
    return [self initWithPath:url.path flags:openFlags vfs:vfsName];
}

- (instancetype)initWithPath:(NSString *)aPath flags:(int)openFlags vfs:(NSString *)vfsName {

    self = [super init];

    if (self != nil) {
        _path = [aPath copy];
        _lockQueue = dispatch_queue_create([[NSString stringWithFormat:@"STIMDB.%@", self] UTF8String], NULL);
        _readDatabaseInPool = STIMDBReturnRetained([NSMutableArray array]);
        _readDatabaseOutPool = STIMDBReturnRetained([NSMutableArray array]);
        _writeDatabaseInPool = STIMDBReturnRetained([NSMutableArray array]);
        _writeDatabaseOutPool = STIMDBReturnRetained([NSMutableArray array]);
        _openFlags = openFlags;
        _vfsName = [vfsName copy];
        _maximumNumberOfReadDatabasesToCreate = 25;
        _maximumNumberOfWriteDatabasesToCreate = 5;
    }

    return self;
}

- (instancetype)initWithPath:(NSString *)aPath flags:(int)openFlags {
    return [self initWithPath:aPath flags:openFlags vfs:nil];
}

- (instancetype)initWithURL:(NSURL *)url flags:(int)openFlags {
    return [self initWithPath:url.path flags:openFlags vfs:nil];
}

- (instancetype)initWithPath:(NSString *)aPath {
    // default flags for sqlite3_open
    return [self initWithPath:aPath flags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX];
}

- (instancetype)initWithURL:(NSURL *)url {
    return [self initWithPath:url.path];
}

- (instancetype)init {
    return [self initWithPath:nil];
}

+ (Class)databaseClass {
    return [STIMDataBase class];
}

- (void)dealloc {

    _delegate = 0x00;
    STIMDBRelease(_path);
    STIMDBRelease(_readDatabaseInPool);
    STIMDBRelease(_readDatabaseOutPool);
    STIMDBRelease(_writeDatabaseInPool);
    STIMDBRelease(_writeDatabaseOutPool);
    STIMDBRelease(_vfsName);

    if (_lockQueue) {
        STIMDBDispatchQueueRelease(_lockQueue);
        _lockQueue = 0x00;
    }
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}


- (void)executeLocked:(void (^)(void))aBlock {
    dispatch_sync(_lockQueue, aBlock);
}

- (void)pushReadDatabaseBackInPool:(STIMDataBase *)db {

    if (!db) { // db can be null if we set an upper bound on the # of databases to create.
        return;
    }

    [self executeLocked:^() {

        if ([self->_readDatabaseInPool containsObject:db]) {
            [[NSException exceptionWithName:@"Database already in read pool" reason:@"The STIMDataBasebeing put back into the pool is already present in the read pool" userInfo:nil] raise];
        }

        [self->_readDatabaseInPool addObject:db];
        [self->_readDatabaseOutPool removeObject:db];

    }];
}

- (void)pushWriteDatabaseBackInPool:(STIMDataBase *)db {
    if (!db) { // db can be null if we set an upper bound on the # of databases to create.
        return;
    }

    [self executeLocked:^() {

        if ([self->_writeDatabaseInPool containsObject:db]) {
            [[NSException exceptionWithName:@"Database already in write pool" reason:@"The STIMDataBasebeing put back into the pool is already present in the write pool" userInfo:nil] raise];
        }

        [self->_writeDatabaseInPool addObject:db];
        [self->_writeDatabaseOutPool removeObject:db];

    }];
}

- (STIMDataBase *)writeDb {
    __block STIMDataBase *db;


    [self executeLocked:^() {
        db = [self->_writeDatabaseInPool lastObject];

        BOOL shouldNotifyDelegate = NO;

        if (db) {
            [self->_writeDatabaseOutPool addObject:db];
            [self->_writeDatabaseInPool removeLastObject];
        } else {

            if (self->_maximumNumberOfWriteDatabasesToCreate) {
                NSUInteger currentCount = [self->_writeDatabaseOutPool count] + [self->_writeDatabaseInPool count];

                if (currentCount >= self->_maximumNumberOfWriteDatabasesToCreate) {
                    NSLog(@"Maximum number of databases (%ld) has already been reached!", (long) currentCount);
                    return;
                }
            }

            db = [[[self class] databaseClass] databaseWithPath:self->_path];
            shouldNotifyDelegate = YES;
        }

        //This ensures that the db is opened before returning
#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [db openWithFlags:self->_openFlags vfs:self->_vfsName];
#else
        BOOL success = [db open];
#endif
        if (success) {
            if ([self->_delegate respondsToSelector:@selector(databasePool:shouldAddDatabaseToPool:)] && ![self->_delegate databasePool:self shouldAddDatabaseToPool:db]) {
                [db close];
                db = 0x00;
            } else {
                //It should not get added in the pool twice if lastObject was found
                if (![self->_writeDatabaseOutPool containsObject:db]) {
                    [self->_writeDatabaseOutPool addObject:db];

                    if (shouldNotifyDelegate && [self->_delegate respondsToSelector:@selector(databasePool:didAddDatabase:)]) {
                        [self->_delegate databasePool:self didAddDatabase:db];
                    }
                }
            }
        } else {
            NSLog(@"Could not open up the database at path %@", self->_path);
            db = 0x00;
        }
    }];

    return db;
}

- (STIMDataBase *)readDb {

    __block STIMDataBase *db;


    [self executeLocked:^() {
        db = [self->_readDatabaseInPool lastObject];

        BOOL shouldNotifyDelegate = NO;

        if (db) {
            [self->_readDatabaseOutPool addObject:db];
            [self->_readDatabaseInPool removeLastObject];
        } else {

            if (self->_maximumNumberOfReadDatabasesToCreate) {
                NSUInteger currentCount = [self->_readDatabaseOutPool count] + [self->_readDatabaseInPool count];

                if (currentCount >= self->_maximumNumberOfReadDatabasesToCreate) {
                    NSLog(@"Maximum number of databases (%ld) has already been reached!", (long) currentCount);
                    return;
                }
            }

            db = [[[self class] databaseClass] databaseWithPath:self->_path];
            shouldNotifyDelegate = YES;
        }

        //This ensures that the db is opened before returning
#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [db openWithFlags:self->_openFlags vfs:self->_vfsName];
#else
        BOOL success = [db open];
#endif
        if (success) {
            if ([self->_delegate respondsToSelector:@selector(databasePool:shouldAddDatabaseToPool:)] && ![self->_delegate databasePool:self shouldAddDatabaseToPool:db]) {
                [db close];
                db = 0x00;
            } else {
                //It should not get added in the pool twice if lastObject was found
                if (![self->_readDatabaseOutPool containsObject:db]) {
                    [self->_readDatabaseOutPool addObject:db];

                    if (shouldNotifyDelegate && [self->_delegate respondsToSelector:@selector(databasePool:didAddDatabase:)]) {
                        [self->_delegate databasePool:self didAddDatabase:db];
                    }
                }
            }
        } else {
            NSLog(@"Could not open up the database at path %@", self->_path);
            db = 0x00;
        }
    }];

    return db;
}

- (NSUInteger)countOfCheckedInDatabases {

    __block NSUInteger count;

    [self executeLocked:^() {
        count = [self->_readDatabaseInPool count] + [self->_writeDatabaseInPool count];
    }];

    return count;
}

- (NSUInteger)countOfCheckedOutDatabases {

    __block NSUInteger count;

    [self executeLocked:^() {
        count = [self->_readDatabaseOutPool count] + [self->_writeDatabaseOutPool count];
    }];

    return count;
}

- (NSUInteger)countOfOpenDatabases {
    __block NSUInteger count;

    [self executeLocked:^() {
        count = [self->_readDatabaseOutPool count] + [self->_readDatabaseInPool count] + [self->_writeDatabaseInPool count] + [self->_writeDatabaseOutPool count];
    }];

    return count;
}

- (void)releaseAllDatabases {
    [self executeLocked:^() {
        [self->_readDatabaseOutPool removeAllObjects];
        [self->_readDatabaseInPool removeAllObjects];
        [self->_writeDatabaseInPool removeAllObjects];
        [self->_writeDatabaseOutPool removeAllObjects];
    }];
}

- (void)inDatabase:(__attribute__((noescape)) void (^)(STIMDataBase *db))block {

    STIMDataBase *db = [self readDb];
    block(db);

    [self pushReadDatabaseBackInPool:db];
}

- (void)beginTransaction:(STIMDBTransaction)transaction withBlock:(void (^)(STIMDataBase *db, BOOL *rollback))block {

    BOOL shouldRollback = NO;

    STIMDataBase *db = [self writeDb];
    switch (transaction) {
        case STIMDBTransactionExclusive:
            [db beginTransaction];
            break;
        case STIMDBTransactionDeferred:
            [db beginDeferredTransaction];
            break;
        case STIMDBTransactionImmediate:
            [db beginImmediateTransaction];
            break;
    }


    block(db, &shouldRollback);

    if (shouldRollback) {
        [db rollback];
    } else {
        [db commit];
    }

    [self pushWriteDatabaseBackInPool:db];
}

- (void)inTransaction:(__attribute__((noescape)) void (^)(STIMDataBase *db, BOOL *rollback))block {
    [self beginTransaction:STIMDBTransactionExclusive withBlock:block];
}

- (void)inDeferredTransaction:(__attribute__((noescape)) void (^)(STIMDataBase *db, BOOL *rollback))block {
    [self beginTransaction:STIMDBTransactionDeferred withBlock:block];
}

- (void)inExclusiveTransaction:(__attribute__((noescape)) void (^)(STIMDataBase *db, BOOL *rollback))block {
    [self beginTransaction:STIMDBTransactionExclusive withBlock:block];
}

- (void)syncUsingTransaction:(__attribute__((noescape)) void (^)(STIMDataBase *db, BOOL *rollback))block {
    [self beginTransaction:STIMDBTransactionExclusive withBlock:block];
}

- (NSError *)inSavePoint:(__attribute__((noescape)) void (^)(STIMDataBase *db, BOOL *rollback))block {
#if SQLITE_VERSION_NUMBER >= 3007000
    static unsigned long savePointIdx = 0;

    NSString *name = [NSString stringWithFormat:@"savePoint%ld", savePointIdx++];

    BOOL shouldRollback = NO;

    STIMDataBase *db = [self writeDb];

    NSError *err = 0x00;

    if (![db startSavePointWithName:name error:&err]) {
        [self pushWriteDatabaseBackInPool:db];
        return err;
    }

    block(db, &shouldRollback);

    if (shouldRollback) {
        // We need to rollback and release this savepoint to remove it
        [db rollbackToSavePointWithName:name error:&err];
    }
    [db releaseSavePointWithName:name error:&err];

    [self pushWriteDatabaseBackInPool:db];

    return err;
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Save point functions require SQLite 3.7", @"STIMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
    return [NSError errorWithDomain:@"STIMDataBase" code:0 userInfo:@{NSLocalizedDescriptionKey : errorMessage}];
#endif
}

@end
