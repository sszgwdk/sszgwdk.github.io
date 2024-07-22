---
title: tinykv project3a思路
date: 2024-05-11 11:00:00
categories:
- 存储
tags:
- kv
- 分布式系统
- raft
keywords:
- kv
- raft
- 分布式系统
- 存储
description: ' '
---
<!--more-->

在Raft层实现领导者转移和成员变更（**虽然Raft层实现简单，但是存在很多细节问题需要注意，后面3B的测试问题一半都来自Raft层**）

## 领导者转移

HandleTransferLeader

1. 检查目标节点是否在集群当中，如果不在直接返回
2. 如果当前节点不是leader，转发给Leader后返回
3. r.leadTransferee = m.From
4. 接收该请求

    1. 检查目标节点的日志是否最新，如果不是则`sendAppend`​，而后返回（等后续`HandleAppendResponse`​来进一步处理
    2. 如果目标节点的日志已经最新，发送`TimeoutNow`​消息给它，让其立即开始选举；最后将leadTransferee置为None

HandleAppendResponse

当转移的目标节点日志不是最新时，HandleTransferLeader不能立即发送`TimeoutNow`​消息，而是`sendAppend`​使目标日志最新，这时需要在HandleAppendResponse中增加发送`TimeoutNow`​和重置`r.leadTransferee`​的逻辑。

> 注意，当`leaderTransferee != None`​时，即在领导这转移过程中，不接受Propose请求，避免循环。

‍

## 成员变更

Raft层的逻辑十分简单，主要是针对`r.Prs`​的修改。

```go
// addNode add a new node to raft group
func (r *Raft) addNode(id uint64) {
	// Your Code Here (3A).
	// if exit
	if _, ok := r.Prs[id]; ok {
		r.PendingConfIndex = None
		return
	}
	r.Prs[id] = &Progress{
		Match: 0,
		Next:  1,
	}
	r.PendingConfIndex = None
}

// removeNode remove a node from raft group
func (r *Raft) removeNode(id uint64) {
	// Your Code Here (3A).
	if _, ok := r.Prs[id]; !ok {
		r.PendingConfIndex = None
		return
	}
	delete(r.Prs, id)
	// important: if leader, should update commit
	if r.State == StateLeader {
		r.tryUpdateCommit()
	}
	r.PendingConfIndex = None
}

```

notice

1. 当`removeNode`​时，由于集群成员数量发生变化，Leader要尝试推进日志的提交
2. PendingConfIndex是一个值得注意的变量。当其不为None时，代表目前正有confChange发生，不再接收新的confChange请求，因此要在`HandlePropose`​中做一定的检查。判断条件为`r.PendingConfIndex != None && r.PendingConfIndex > r.RaftLog.applied`​，代表存在尚未应用的confChange。

‍
