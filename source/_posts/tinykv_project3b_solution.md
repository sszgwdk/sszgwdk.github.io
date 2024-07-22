---
title: tinykv project3b思路
date: 2024-05-12 21:22:00
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

project3b是整个tinykv中最难的部分，测试会出现很多问题，往往需要通过打印大量日志才能找到问题的原因，因此在编程时要尤其注意一些细节。不过调试这些Bug也是该项目的内容之一，锻炼发现问题解决问题的能力，加深对分布式kv引擎的认识。

project3b的代码实现最主要还是在`kv/raftstore/peer_msg_handler.go`​当中，当然在调试过程中必然会发现Raft层的处理也会有很多问题要进行修改。

project3b增加了三个admin命令：TransferLeader，ChangePeer，Split。为了使tinykv支持这些命令，要完成对应的Propose和Process的逻辑。建议尽量将普通命令和admin命令的Propose和Process分开处理，不要太耦合。

## TransferLeader

如文档所说，TransferLeader是一个动作不需要作为一条日志Propose到Raft层共识，更不需要Process，只需要调用 RawNode 的 TransferLeader() 方法并返回响应。

## ChangePeer

propose ChangePeer命令的流程与之前普通命令类似，不同的是调用的RawNode接口由`Propose`​变成了`ProposeConfChange`​

```go
			perr := d.RaftGroup.ProposeConfChange(eraftpb.ConfChange{
				ChangeType: msg.AdminRequest.ChangePeer.ChangeType,
				NodeId:     msg.AdminRequest.ChangePeer.Peer.Id,
				Context:    ctx,
			})
```

process的流程则相对复杂，需要按照check、apply、response三步来做。

对于check，由于ChangePeer不涉及key，所以不要考虑**ErrKeyNotInRegion，**但是需要考虑**ErrEpochNotMatch**，使用`util.CheckRegionEpoch`​方法，具体用法可以参考`preProposeRaftCommand`​中的代码。

> 实际上在propose之前也需要检查**ErrEpochNotMatch，**不过已经在`preProposeRaftCommand`​中已经实现了。
>
> **如果检查出错误，需要利用proposals中的回调返回errResponse。**

对于apply，分为AddNode和RemoveNode两种。

### AddNode的Apply

1. 检查是否是重复的命令，即如果节点已在集群中，此时跳过apply
2. 修改并写入`RegionLocalState`​（使用​`meta.WriteRegionState`​），包括`RegionEpoch`​和`Region's peers`​

    1. ​`region.Peers = append(region.Peers, targetPeer)`​
    2. ​`region.RegionEpoch.ConfVer += 1`​
3. 更新`GlobalContext storeMeta`​，包括`regions`​和`regionRanges`​，**注意访问和修改时的加锁**
4. ​`insertPeerCache`​，`d.RaftGroup.ApplyConfChange`​

> 注意不需要实际创建的一个Peer，这里是先加入到集群当中，Leader发送心跳，转发消息时发现节点不存在，由storeWorker调用maybeCreatePeer()进行实际的创建

### RemoveNode的Apply

1. 如果需要Remove的节点ID与当前节点ID相等，调用`d.destroyPeer()`​
2. 检查是否是重复的命令，即如果节点已不在集群中，此时跳过apply
3. 修改并写入`RegionLocalState`​（使用`meta.WriteRegionState`​），包括`RegionEpoch`​和`Region's peers`​
4. 不用更新`GlobalContext storeMeta`​，这个是由`d.destroyPeer()`​完成的
5. ​`removePeerCache`​，​`d.RaftGroup.ApplyConfChange`​

另外，在完成process后，要检查节点是否停止，因为有可能会销毁当前节点，此时直接返回即可，不需要做后面的任何处理。

```go
	for _, entry := range ready.CommittedEntries {
		d.process(&entry)
		// may destroy oneself, so need to check if stopped
		if d.stopped {
			return
	}
```

对于response，按照之前在project2b中相同的处理，我使用自定义的`clearStaleAndGetTargetProposal`​（详见project2b思路），注意在最后需要调用`d.notifyHeartbeatScheduler(region, d.peer)`​给Scheduler（project3c）发送一个心跳，来通知region的变化（冗余的更新不会影响正确性，因此建议在发生region修改的地方都发送一个心跳）

```go
	if d.clearStaleAndGetTargetProposal(entry) {
		p := d.proposals[0]
		resp := &raft_cmdpb.RaftCmdResponse{
			Header: &raft_cmdpb.RaftResponseHeader{},
		}
		switch req.CmdType {
		case raft_cmdpb.AdminCmdType_ChangePeer:
			resp.AdminResponse = &raft_cmdpb.AdminResponse{
				CmdType:    raft_cmdpb.AdminCmdType_ChangePeer,
				ChangePeer: &raft_cmdpb.ChangePeerResponse{},
				// ChangePeer: &raft_cmdpb.ChangePeerResponse{Region: d.Region()},
			}
		}
		p.cb.Done(resp)
		d.proposals = d.proposals[1:]
	}

	d.notifyHeartbeatScheduler(region, d.peer)
```

```go
func (d *peerMsgHandler) notifyHeartbeatScheduler(region *metapb.Region, peer *peer) {
	clonedRegion := new(metapb.Region)
	err := util.CloneMsg(region, clonedRegion)
	if err != nil {
		return
	}
	d.ctx.schedulerTaskSender <- &runner.SchedulerRegionHeartbeatTask{
		Region:          clonedRegion,
		Peer:            peer.Meta,
		PendingPeers:    peer.CollectPendingPeers(),
		ApproximateSize: peer.ApproximateSize,
	}
}
```

以上就完成了最基本的confChange，但是不能通过所有测试，由于可能存在网络不稳定和隔离等情况，需要做一些特殊处理和优化，这些处理会在下一篇“tinykv project3b疑难杂症”中汇总。

## Region Split

Split命令的Propose过程与ChangePeer也是类似的，不同的是Split命令中包含一个`split_key`​，代表将当前region按`split_key`​拆分，因此要检查**ErrKeyNotInRegion。**

> 之前在project2b中对于普通命令没有对**ErrKeyNotInRegion**检查，此处也需要为除了Snap（Snap命令中不包含key）命令之外的其他普通命令增加检查**ErrKeyNotInRegion**的代码。

Split命令的Process同样可以分成check、apply、response三步。

对于check，实际上是重复Propose的检查过程，需要检查**ErrEpochNotMatch和ErrKeyNotInRegion。**

### apply Split

apply的过程则相对复杂，我的实现步骤如下：

1. ​`split := req.GetSplit()`​​获取Split命令中的数据，拷贝一份当前节点原始Region信息暂存在`rawRegion`​​中（利用`util.CloneMsg`​​方法），原始Region使用`leftRegion`​​命名，再拷贝一份`rightRegion`​​，代表拆分后的右半region。
2. 使用`split.NewPeerIds`​​初始化`rightRegion.Peers`​​，将`split.NewRegionId`​​赋值给`rightRegion.Id`​​，将`split.SplitKey`​​赋值给`rightRegion.StartKey`​​，将`split.SplitKey`​​赋值给`leftRegion.EndKey`​​，即`[StartKey, SplitKey) -> leftRegion`​​、`[SplitKey, EndKey) -> rightRegion`​​。最后不要忘记`leftRegion.RegionEpoch.Version += 1`​​、`rightRegion.RegionEpoch.Version += 1`​​。此时`leftRegion`​​和`rightRegion`​​对应Split之后的左右Region。（**注意leftRegion继承原始region的所有数据**）
3. 使用`meta.WriteRegionState`​​写入两个region
4. 更新`storeMeta`​​，包括：

    1. 在`storeMeta.regionRanges`​​中删除`rawRegion`​​
    2. 在`storeMeta.regions`​​中添加`rightRegion`​​
    3. 使用`leftRegion`​​和`rightRegion`​​更新`storeMeta.regionRanges`​​（调用方法`storeMeta.regionRanges.ReplaceOrInsert`​​）
    4. 注意加锁
5. 清理region size，包括`SizeDiffHint`​和`ApproximateSize`​，这个很关键，在下一篇疑难杂症也会提到
6. 使用`createPeer`​​方法创建`newPeer`​​，利用`d.ctx.router`​​注册和启动该节点

reponse的过程与ChangePeer类似：

1. `notifyHeartbeatScheduler`​​发送心跳，注意两个Region都要调用
2. 返回响应，还是利用自定义的`clearStaleAndGetTargetProposal`​​

## 其他修改

### ApplySnapshot后的region状态更新

应用快照会通常会伴随region的更新（例如未初始化的新节点），`SaveReadyState`​的返回值中有一个`*ApplySnapResult`​，如果它不为`nil`​且其中的`PrevRegion`​和`Region`​不相等，说明发生了Region更新，不仅要在内存中更新`regionLocalState`​以及持久化，还要更新全局的`storeMeta`​并发送心跳给Scheduler，如下：

```go
		result, err := d.peerStorage.SaveReadyState(&ready)
		if err != nil {
			panic(err)
		}
		// update region
		if result != nil && !reflect.DeepEqual(result.PrevRegion, result.Region) {
			d.peerStorage.SetRegion(result.Region)

			storeMeta := d.ctx.storeMeta
			storeMeta.Lock()
			storeMeta.regions[result.Region.GetId()] = result.Region
			storeMeta.regionRanges.ReplaceOrInsert(&regionItem{region: result.Region})
			storeMeta.Unlock()

			d.HeartbeatScheduler(d.ctx.schedulerTaskSender)
		}
```

### 普通命令的修改

由于引入了region，对普通命令的propose和process也要做相应修改。

首先就是对Get、Put、Delete检查**ErrEpochNotMatch**​和**ErrKeyNotInRegion。**

其次对于Put和Delete命令的应用，需要记录当前region的大小变化，这是通过`SizeDiffHint`​记录的。

```go
type peer struct {
	...
	// An inaccurate difference in region size since last reset.
	// split checker is triggered when it exceeds the threshold, it makes split checker not scan the data very often
	// (Used in 3B split)
	SizeDiffHint uint64
	// Approximate size of the region.
	// It's updated everytime the split checker scan the data
	// (Used in 3B split)
	ApproximateSize *uint64

	...
}
```

1. 对于Put，​`d.SizeDiffHint += uint64(len(req.Put.Key) + len(req.Put.Value))`​
2. 对于Delete命令，​`d.SizeDiffHint -= uint64(len(req.Delete.Key))`​

在Split中也提到Apply Admin_Split完成后，要对`SizeDiffHint`​和`ApproximateSize`​更新。

> 如果不做上述处理在测试时会引发Request Timeout。原来split checker会依据`SizeDiffHint`​来判断region承载的数据量是否超出阈值，从而触发split操作。这在文档中并没有说明，害我调了很久。

‍

以上就完成了3B的所有基本内容，但测试通常是过不了的，会有很多异常情况，下一篇将对我当时遇到的疑难杂症进行汇总。

‍
