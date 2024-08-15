---
weight: 9
title: "TinyKV Project 4"
slug: "tinykv_p4"
date: 2024-08-15T19:34:21+08:00
lastmod: 2024-08-15T19:34:21+08:00
draft: false
author: "SszgwDk"
authorLink: "https://sszgwdk.github.io"
description: ""
images: []

tags: ["raft", "kv", "tinykv"]
categories: ["kv"]

lightgallery: true

toc:
  auto: false
showTableOfContents: true
outdatedInfoWarning: true
---

## 参考资料

Project 4 通过建立一个事务系统实现多版本并发控制 MVCC。在编码之前，需要对事务的相关概念提前了解（事务的属性，事务隔离级别等）。

文档可以参考以下翻译（细节部分需要看英文文档）：

[实验指导书（翻译）Project 4: Transactions_从实验六中的people-CSDN博客](https://blog.csdn.net/FEATHER2016/article/details/120912259)

TinyKV的事务设计遵循 Percolator 模型，它本质上是一个两阶段提交协议（2PC）。如果看完文档还是云里雾里，可以通过这篇文章加深对 Percolator 的理解：

[Percolator模型及其在TiKV中的实现-腾讯云开发者社区-腾讯云 (tencent.com)](https://cloud.tencent.com/developer/article/1880397)

## Part A

Part A主要实现 MVCC 。基于lock、write、default三个列族，封装`MvccTxn`​的 API，代码主要在`transaction.go`​中，里面提供了一些用于对key进行编解码的辅助函数。

```go
type MvccTxn struct {
	StartTS uint64
	Reader  storage.StorageReader
	writes  []storage.Modify
}
```

事务所有的写入操作都存入writes当中，便于被一次性写到底层数据库，保障原子性。因此`PutWrite`​、`PutLock`​、`DeleteLock`​、`PutValue`​和`DeleteValue`​都是将 key、cf、value（delete不包含）append到`writes`​中。需要注意的是不同cf对应的key的构成：

1. lock：CfLock + Key
2. write：CfWrite + Key + CommitTs
3. default：CfDefault + Key + StartTs

val的构成也不同：

```go
type Lock struct {
	Primary []byte
	Ts      uint64
	Ttl     uint64
	Kind    WriteKind
}
type Write struct {
	StartTS uint64
	Kind    WriteKind
}
// default value
value []byte
```

### GetValue

查询当前事务下，传入 key 对应的 Value。

1. 通过 `iter.Seek(EncodeKey(key, txn.StartTS))`​ 查找遍历 Write，找到满足 commitTs <= ts 的最新 write；
2. 判断该 write 的 userkey 与当前 key相同，如果不是，说明不存在，直接返回；
3. 判断该 write 的`Kind`​是不是`WriteKindPut`​，如果不是，说明不存在，直接返回；
4. 从 Default 中通过 EncodeKey(key, write.StartTS) 获取目标 Value；

### CurrentWrite

查询当前事务下，传入 key 的最新 write。

1. 通过 `iter.Seek(EncodeKey(key, ^uint64(0)))`​查询该 key 的最新 write；
2. 如果`​ write.StartTS > txn.StartTS`​，继续遍历，直到找到 `write.StartTS == txn.StartTS`​ 的 write；
3. 返回这个 write 和 它的 commitTs；

### ​​MostRecentWrite​

查询传入 key 的最新 write，不用考虑当前事务的开始时间戳。

## Part B

Part B主要利用 A 中封装的 Mvcc API 实现 Percolator 模型的事务性 API，包括`KvGet`​、`KvPrewrite`​和`KvCommit`​，分别对应读写过程。

### KvGet

对应 Percolator 的读过程：

1. 获取一个时间戳ts（`req.GetVersion`​），并创建一个 `MvccTxn`​；
2. 查询当前我们要读取的 key 上是否存在一个时间戳在[0, ts]范围内的锁。

    1. 如果存在一个时间戳在[0, ts]范围的锁，那么意味着当前的数据被一个比当前事务更早启动的事务锁定了，但是当前这个事务还没有提交。此时直接返回`Locked`​错误。
    2. 如果没有锁，或者锁的时间戳大于ts，那么读请求可以被满足。
3. 从write列族中查询在[0, ts]范围内的最大 commit_ts 的记录，然后依此获取到对应的start_ts。
4. 根据上一步获取的start_ts，从data列获取对应的记录（3，4两步已经被封装在 `GetValue`​当中）；
5. 如果发生`RegionError`​或者未找到要返回对应的错误。

### KvPrewrite 和 KvCommit

对应 2PC 的 Prewrite 和 Commit两个阶段。

**在Prewrite阶段：**

1. 利用`req.GetStartVersion()`​创建一个 Mvcc `txn`​；
2. 遍历`req.Mutations`​，对于其中的每一个`key`​：

    1. 利用`txn.MostRecentWrite`​检查是否一个有一个比`startTs`​更大的新write，如果存在，则append一个`WriteConflict`​错误到​`keyErrors`​；
    2. 利用`txn.GetLock`​检查是否已经存在一个lock，如果存在，则append一个`Locked`​错误到​`keyErrors`​；
    3. 根据`WriteKind`​调用`txn.PutValue`​或`txn.DeleteValue`​；
    4. 利用`txn.PutLock`​写入该key的lock。
3. 如果`len(keyErrors) > 0`​，作为响应返回；
4. 最后利用`server.storage.Write(req.Context, txn.Writes())`​一次性写到底层数据库

**在Commit阶段：**

1. 利用`req.GetStartVersion()`​创建一个 Mvcc `txn`​；
2. ​`server.Latches.WaitForLatches(req.Keys)`​锁定 Commit 请求中涉及的所有key，避免局部竞争条件；
3. 遍历请求中的所有`key`​：

    1. 利用`txn.CurrentWrite(key)`​检查是否有重复的提交，如果是重复提交则返回；
    2. 利用`txn.GetLock(key)`​检查是否 lock 依然存在，如果lock为空或者lock的时间戳与当前请求的`StartVersion`​不相等，说明该事务已经被其他事务清理，返回一个`Retryable`​错误；
    3. ​`txn.PutWrite`​，`txn.DeleteLock`​
4. ​`server.storage.Write(req.Context, txn.Writes())`​一次性写到底层数据库，完成提交。

## Part C

### KvScan

扫描操作需要利用`mvcc.NewScanner(req.StartKey, txn)`​创建一个`scanner`​来进行迭代，对于迭代过程中每个key的处理，都是与`KvGet`​中类似的，需要检查一下lock的情况；如果某个key出现错误，不能中止迭代，将错误信息append到最终的结果当中即可。

### ​KvCheckTxnStatus​​

用于 Client failure 后，想继续执行时，先检查 Primary Key 的状态，以此决定是回滚还是继续推进 commit。

1. 通过`txn.CurrentWrite(req.PrimaryKey)`​获取 primary key 的`write`​，如果`write`​且不是`WriteKindRollback`​，则说明已经被commit了，直接返回 commitTs；如果是`WriteKindRollback`​说明已经被回滚，因此无需操作，返回`Action_NoAction`​即可。
2. 通过`txn.GetLock(req.PrimaryKey)`​获取 primary key 的`lock`​；如果`lock == nil`​，打上 rollback 标记（`WriteKindRollback`​），返回 `Action_LockNotExistRollback`​；
3. 如果`lock`​存在，并且超时了。那么删除这个`lock`​，并且删除对应的`Value`​，同时打上rollback标记，然后返回`Action_TTLExpireRollback`​；
4. 如果以上条件均为发生，说明`write`​不存在，且`lock`​存在但并没有超时，直接返回，事务继续执行。

根据文档，检查lock超时要用到`mvcc.PhysicalTime`​，方法如下

```go
func isLockTimeout(lock *mvcc.Lock, currentTs uint64) bool {
	return mvcc.PhysicalTime(lock.Ts)+lock.Ttl <= mvcc.PhysicalTime(currentTs)
}
```

### ​​KvBatchRollback​​

回滚操作与Commit逻辑相反，执行流程是相似的：

1. ​`server.Latches.WaitForLatches(req.Keys)`​锁定本次回滚操作涉及的所有key
2. 遍历所有key

    1. ​`txn.CurrentWrite(key)`​获取当前事务下的`write`​，如果不为空，若`write.Kind == mvcc.WriteKindRollback`​，说明该`key`​已经回滚，continue，否则说明事务已提交，直接返回一个`Abort`​响应；
    2. 利用`txn.GetLock(k)`​获取`lock`​，若`lock`​为空或者不是本事务的，则直接打上 rollback 标记（`WriteKindRollback`​）并continue；若本事务还持有`lock`​，则要依次`txn.DeleteLock`​、`txn.DeleteValue`​、打上 rollback 标记。
3. ​`server.storage.Write(req.Context, txn.Writes())`​一次性写到底层数据库，完成rollback。

### ​​KvResolveLock​

这个方法主要用于解决锁冲突，当客户端已经通过`KvCheckTxnStatus()`​检查了 primary key 的状态，要么全部回滚，要么全部提交，具体取决于 `ResolveLockRequest`​的`CommitVersion`​。

1. 首先遍历`CfLock`​，找到当前事务下的所有现存lock，将对应的key加入集合`keys`​，若`len(keys) == 0`​，直接返回；
2. 若`req.CommitVersion == 0`​，调用`KvBatchRollback`​全部回滚；否则，调用`KvCommit`​全部提交

‍