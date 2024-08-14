# TinyKV Project 2C


project2c目的是实现RaftLog GC和Snapshot支持。在Raft和raftstore中均需要修改和新增代码。

## 问题分析

raft 一致性算法并没有考虑log无限增长的情况，若不做任何处理，随着系统的长时间运行，Raft节点中的RaftLog会占用大量内存；所以要引进applied index，把applied之前的条目定期压缩（compact）起来然后落盘，最后在内存删除它们，只需要记录最后applied的`Index、Term`​，以及一些状态。这就是RaftLog GC。

基于RaftLog GC，我们需要实现Snapshot支持来保障Raft算法的正常运行。这主要是在日志复制的过程中，leader需要给follower发送`[next, LastIndex]`​的条目以及`next-1`​的index和Term，很可能`next-1`​（最小索引）的条目已经被compact掉了，此时没法完成日志复制所需的匹配动作，因此leader需要发送一个Snapshot来帮助follower赶上进度。事实上，Project3中实现增加节点（`Add Peer`​）时，也是通过Snapshot来初始化新节点。

### Snapshot的生成

tinykv已经提供了Raft节点获取Snapshot的接口`r.RaftLog.storage.Snapshot()`​。可以发现是一个异步的实现，将一个任务丢给了`ps.regionSched`​，这是消费者端。

之所以采用异步实现，是因为SnapShot通常比较大，所以一般Leader第一次调用`r.RaftLog.storage.Snapshot()`​可能拿不到结果，不过worker已经开始生成了，等后面再调用时就能够直接返回。

```go
// schedule snapshot generate task
ps.regionSched <- &runner.RegionTaskGen{
	RegionId: ps.region.GetId(),
	Notifier: ch,
}
```

生产者端是在kv/raftstore/runner/region_task.go（根据`RegionTaskGen`​就可以找到）

```go
func (r *regionTaskHandler) Handle(t worker.Task) {
	switch t.(type) {
	case *RegionTaskGen:
		task := t.(*RegionTaskGen)
		// It is safe for now to handle generating and applying snapshot concurrently,
		// but it may not when merge is implemented.
		r.ctx.handleGen(task.RegionId, task.Notifier)
	case *RegionTaskApply:
		task := t.(*RegionTaskApply)
		r.ctx.handleApply(task.RegionId, task.Notifier, task.StartKey, task.EndKey, task.SnapMeta)
	case *RegionTaskDestroy:
		task := t.(*RegionTaskDestroy)
		r.ctx.cleanUpRange(task.RegionId, task.StartKey, task.EndKey)
	}
}
```

最后会走到`doSnapshot`​当中，关键的部分如下。这样就生成了一个SnapShot

```go
snapshot := &eraftpb.Snapshot{
	Metadata: &eraftpb.SnapshotMetadata{
		Index:     key.Index,
		Term:      key.Term,
		ConfState: &confState,
	},
}
```

raft leader 发现某个节点落后较多（该节点的Next-1位置的entry已经被leader compact了），则给他发送一个Snapshot

### Snapshot的Apply

SnapShot的Apply也应该采用如上的方法，以异步的方式，创意一个`RegionTaskApply`​结构体丢给`ps.regionSched`​。

‍

## 在Raft中实现

对于Snapshot，在raft模块我们主要需要实现“leader获取并发送SnapShot”，“Follower处理Snapshot消息”，“log”，“ready”四块功能。

​`pb.Snapshot`​类定义：

```go
type Snapshot struct {
	Data                 []byte            `protobuf:"bytes,1,opt,name=data,proto3" json:"data,omitempty"`
	Metadata             *SnapshotMetadata `protobuf:"bytes,2,opt,name=metadata" json:"metadata,omitempty"`
	XXX_NoUnkeyedLiteral struct{}          `json:"-"`
	XXX_unrecognized     []byte            `json:"-"`
	XXX_sizecache        int32             `json:"-"`
}

type SnapshotMetadata struct {
	ConfState            *ConfState `protobuf:"bytes,1,opt,name=conf_state,json=confState" json:"conf_state,omitempty"`
	Index                uint64     `protobuf:"varint,2,opt,name=index,proto3" json:"index,omitempty"`
	Term                 uint64     `protobuf:"varint,3,opt,name=term,proto3" json:"term,omitempty"`
	XXX_NoUnkeyedLiteral struct{}   `json:"-"`
	XXX_unrecognized     []byte     `json:"-"`
	XXX_sizecache        int32      `json:"-"`
}

type ConfState struct {
	// all node id
	Nodes                []uint64 `protobuf:"varint,1,rep,packed,name=nodes" json:"nodes,omitempty"`
	XXX_NoUnkeyedLiteral struct{} `json:"-"`
	XXX_unrecognized     []byte   `json:"-"`
	XXX_sizecache        int32    `json:"-"`
}
```

​​其中`Metadata`​是我们需要注意的关键数据。

### leader获取并发送SnapShot

在“问题分析”中提到raft leader 发现某个节点落后较多（该节点的Next-1位置的entry已经被leader compact了），则给他发送一个Snapshot。

Compact实际做的事情就是日志截断。这里“被leader compact”的含义是由于截断leader中已经找不到Next-1（即论文中的`preLogIndex`​）位置的entry了，所以没办法通过单纯的`sendAppend`​进行日志同步（没办法获取`preLogTerm`​）。

**所以需要做的修改是要在**​`**sendAppend**`​**加入检查并发送Snapshot的逻辑。**

那么首先的一个问题就是如何检查`next-1`​位置的entry已经被compact了？

已知`preLogIndex=next-1`​，通过`r.RaftLog.Term(preLogIndex)`​来获取`preLogTerm`​。

```go
func (l *RaftLog) Term(i uint64) (uint64, error) {
	// Your Code Here (2A).
	if len(l.entries) > 0 && i >= l.dummyIndex {
		if i > l.LastIndex() {
			return 0, ErrUnavailable
		}

		return l.entries[i-l.dummyIndex].Term, nil
	} else {
		term, err := l.storage.Term(i)
		return term, err
	}
}
```

如果发生compact，那么显然上述调用会走到else分支，再来看一下`l.storage.Term`​的实现kv/raftstore/peer_storage.go。

```go
func (ps *PeerStorage) Term(idx uint64) (uint64, error) {
	if idx == ps.truncatedIndex() {
		return ps.truncatedTerm(), nil
	}
	if err := ps.checkRange(idx, idx+1); err != nil {
		return 0, err
	}
	if ps.truncatedTerm() == ps.raftState.LastTerm || idx == ps.raftState.LastIndex {
		return ps.raftState.LastTerm, nil
	}
	var entry eraftpb.Entry
	if err := engine_util.GetMeta(ps.Engines.Raft, meta.RaftLogKey(ps.region.Id, idx), &entry); err != nil {
		return 0, err
	}
	return entry.Term, nil
}

func (ps *PeerStorage) checkRange(low, high uint64) error {
	if low > high {
		return errors.Errorf("low %d is greater than high %d", low, high)
	} else if low <= ps.truncatedIndex() {
		return raft.ErrCompacted
	} else if high > ps.raftState.LastIndex+1 {
		return errors.Errorf("entries' high %d is out of bound, lastIndex %d",
			high, ps.raftState.LastIndex)
	}
	return nil
}
```

仔细阅读上面的代码，在`checkRange`​函数中找到了一个错误`ErrCompacted`​，它的条件是`low <= ps.truncatedIndex()`​，即小于被截断的最高Index，符合我们上面描述的Compact的操作。因此可以确定只要对这个错误进行检查即可。

```go
preLogTerm, err := r.RaftLog.Term(preLogIndex)
if err != nil {
	if err == ErrCompacted {
		r.sendSnapshot(to)
		return false
	}
	return false
}
```

接下来考虑实现`sendSnapshot`​这一函数。

首先是Snapshot的获取，根据在“Snapshot生成”中的描述，通过`r.RaftLog.storage.Snapshot()`​可以异步生成一个SnapShot，由于SnapShot通常比较大，因此第一次调用可能会返回错误，即SnapShot还没有准备好，因此要对这种情况做判断，对应的错误是`ErrSnapshotTemporailyUnavailable`​。

```go
func (r *Raft) sendSnapshot(to uint64) {
	// Your Code Here (2C).
	snap, err := r.RaftLog.storage.Snapshot()
	// because snapshot is handled asynchronously, so we should check if snapshot is valid
	if err != nil {
		if err == ErrSnapshotTemporarilyUnavailable {
			return
		}
		panic(err)
	}

	r.msgs = append(r.msgs, pb.Message{
		MsgType:  pb.MessageType_MsgSnapshot,
		From:     r.id,
		To:       to,
		Term:     r.Term,
		Snapshot: &snap,
	})

	// avoid snapshot is sent too frequently
	r.Prs[to].Next = snap.Metadata.Index + 1
}
```

> 注意，在发送Snapshot成功之后，可以直接在leader更新目标节点的Next，避免需要频繁发送snapshot造成较高的带宽占用。

‍

## 在raftstore中实现

### processAdminRequest

根据文档和之前的分析，需要在`process`​的逻辑中增加对`AdminCmdType_CompactLog`​这一消息的处理，不同于普通的`Request`​，它的类型是`AdminRequest`​，要分开处理。

```go
func (d *peerMsgHandler) processAdminRequest(entry *eraftpb.Entry, cmd *raft_cmdpb.RaftCmdRequest)

func (d *peerMsgHandler) process(entry *eraftpb.Entry) {
	cmd := &raft_cmdpb.RaftCmdRequest{}
	cmd.Unmarshal(entry.Data)
	if cmd.AdminRequest != nil {
		d.processAdminRequest(entry, cmd)
	}
	...
}
```

对该消息的处理流程，文档中说明的比较详细，即先更新`applyState.TruncatedState`​的状态，然后通过接口`d.ScheduleCompactLog`​为 raftlog-gc worker 安排一个任务。Raftlog-gc worker 会异步完成实际的日志删除工作。

‍

### ApplySnapshot

​`appluSnapshot`​即`peer_storage`​对于`Ready()`​获得的`snapshot`​进行实际应用，要做的事情基本上能根据前面的分析推出来：删除过时的数据（所有的数据）、更新各种状态、发送任务给region_worker进行实际应用。

删除过时数据，根据注释可知是`ClearMeta`​和`ps.clearExtraData`​，所需要的参数也十分简单。

```go
ps.clearMeta(kvWB, raftWB)
ps.clearExtraData(snapData.Region)
```

更新peer_storage的内存状态，`RaftLocalState`​ 、`RaftApplyState`​和 `RegionLocalState`​。

简要分析一下需要更新哪些状态，首先`snapshot.MetaData`​只有`Index、Term、ConfState`​三个字段。对于`RaftLocalState`​，很显然只要更新`LastIndex`​、`LastTerm`​（`HardState`​的更新在`ApplySnapshot`​的上层`SaveReadyState`​当中）。对于`RaftApplyState`​，`AppliedIndex`​肯定要更新到`meta.Index`​，`TruncatedState`​代表截断状态，同样有`Index、Term`​两个字段，很显然也要更新。文档中还指明“您还需要更新`PeerStorage.snapState`​到`snap.SnapState_Applying`​”。

```go
type RaftApplyState struct {
	// Record the applied index of the state machine to make sure
	// not apply any index twice after restart.
	AppliedIndex uint64 `protobuf:"varint,1,opt,name=applied_index,json=appliedIndex,proto3" json:"applied_index,omitempty"`
	// Record the index and term of the last raft log that have been truncated. (Used in 2C)
	TruncatedState       *RaftTruncatedState `protobuf:"bytes,2,opt,name=truncated_state,json=truncatedState" json:"truncated_state,omitempty"`
	XXX_NoUnkeyedLiteral struct{}            `json:"-"`
	XXX_unrecognized     []byte              `json:"-"`
	XXX_sizecache        int32               `json:"-"`
}
```

但是文档中提到的`RegionLocalState`​怎么更新？

```go
type PeerStorage struct {
	// current region information of the peer
	region *metapb.Region
	// current raft state of the peer
	raftState *rspb.RaftLocalState
	// current apply state of the peer
	applyState *rspb.RaftApplyState

	// current snapshot state
	snapState snap.SnapState
	// regionSched used to schedule task to region worker
	regionSched chan<- worker.Task
	// generate snapshot tried count
	snapTriedCnt int
	// Engine include two badger instance: Raft and Kv
	Engines *engine_util.Engines
	// Tag used for logging
	Tag string
}
```

根据`PeerStorage`​定义，推断`metapb.Region`​即`RegionLocalState`​。在`Snapshot.MetaData`​中似乎没有找到与之相关的内容。

```go
type Region struct {
	Id uint64 `protobuf:"varint,1,opt,name=id,proto3" json:"id,omitempty"`
	// Region key range [start_key, end_key).
	StartKey             []byte       `protobuf:"bytes,2,opt,name=start_key,json=startKey,proto3" json:"start_key,omitempty"`
	EndKey               []byte       `protobuf:"bytes,3,opt,name=end_key,json=endKey,proto3" json:"end_key,omitempty"`
	RegionEpoch          *RegionEpoch `protobuf:"bytes,4,opt,name=region_epoch,json=regionEpoch" json:"region_epoch,omitempty"`
	Peers                []*Peer      `protobuf:"bytes,5,rep,name=peers" json:"peers,omitempty"`
	XXX_NoUnkeyedLiteral struct{}     `json:"-"`
	XXX_unrecognized     []byte       `json:"-"`
	XXX_sizecache        int32        `json:"-"`
}
```

但是在已经写好的代码当中，有一个`RaftSnapshotData`​类型的`snapData`​是将`Snapshot`​中的`Data`​解析后的数据，可以看到其中的`region`​数据，正是想要的。

```go
type RaftSnapshotData struct {
	Region               *metapb.Region `protobuf:"bytes,1,opt,name=region" json:"region,omitempty"`
	FileSize             uint64         `protobuf:"varint,2,opt,name=file_size,json=fileSize,proto3" json:"file_size,omitempty"`
	Data                 []*KeyValue    `protobuf:"bytes,3,rep,name=data" json:"data,omitempty"`
	Meta                 *SnapshotMeta  `protobuf:"bytes,5,opt,name=meta" json:"meta,omitempty"`
	XXX_NoUnkeyedLiteral struct{}       `json:"-"`
	XXX_unrecognized     []byte         `json:"-"`
	XXX_sizecache        int32          `json:"-"`
}

// Apply the peer with given snapshot
func (ps *PeerStorage) ApplySnapshot(snapshot *eraftpb.Snapshot, kvWB *engine_util.WriteBatch, raftWB *engine_util.WriteBatch) (*ApplySnapResult, error) {
	log.Infof("%v begin to apply snapshot", ps.Tag)
	snapData := new(rspb.RaftSnapshotData)
	if err := snapData.Unmarshal(snapshot.Data); err != nil {
		return nil, err
	}

	// Hint: things need to do here including: update peer storage state like raftState and applyState, etc,
	// and send RegionTaskApply task to region worker through ps.regionSched, also remember call ps.clearMeta
	// and ps.clearExtraData to delete stale data
	// Your Code Here (2C).
	return nil, nil
}
```

但是想用`kvWB.SetMeta(meta.RegionStateKey(snapData.Region.Id), snapData.Region)`​来持久化时却发现`snapData.Region`​参数不匹配，`*rspb.RegionLocalState`​。

后面在kv/raftstore/meta/values.go找到了`WriteRegionState`​函数，正是我们想要的。

```go
func WriteRegionState(kvWB *engine_util.WriteBatch, region *metapb.Region, state rspb.PeerState) {
	regionState := new(rspb.RegionLocalState)
	regionState.State = state
	regionState.Region = region
	kvWB.SetMeta(RegionStateKey(region.Id), regionState)
}
```

一个新的问题来了，之前不论是`RaftLocalState`​ 、`RaftApplyState`​还是`SnapState`​都是先在`PeerStorage`​内存中更新，再持久化，我们显然不能先对`RegionState`​持久化。

那么如何在内存中更新`RegionState`​？

在之前的分析当中以及文档当中都提到，需要“**通过**​`**PeerStorage.regionSched**`​**发送**​`**runner.RegionTaskApply**`​**任务给到region_worker**”，这里的`RegionTask`​是否可以理解为在内存中更新`RegionState`​呢？通过查看代码调用链`runner.RegionTaskApply`​->`Handle`​->`r.ctx.handleApply`​->`applySnap`​验证了这一想法。

简单参考`func (ps *PeerStorage) Snapshot() (eraftpb.Snapshot, error)`​中的代码实现（能够注意到它没有等待snapshot的生成，直接返回了一个`ErrSnaoshotTemporarilyUnavailable`​，对应我们在raft模块中的处理）：

```go
func (ps *PeerStorage) Snapshot() (eraftpb.Snapshot, error) {
	...
	ch := make(chan *eraftpb.Snapshot, 1)
	ps.snapState = snap.SnapState{
		StateType: snap.SnapState_Generating,
		Receiver:  ch,
	}
	// schedule snapshot generate task
	ps.regionSched <- &runner.RegionTaskGen{
		RegionId: ps.region.GetId(),
		Notifier: ch,
	}
	return snapshot, raft.ErrSnapshotTemporarilyUnavailable
}
```

但是此处不能直接返回，文档中指明了要“`wait until region worker finishes`​”。猜测是因为如果直接返回，raft节点可能在没有更新regionState的情况下发生错误。

```go
	// send RegionTaskApply task to region worker
	ch := make(chan bool, 1)
	ps.regionSched <- &runner.RegionTaskApply{
		RegionId: snapData.Region.Id,
		Notifier: ch,
		SnapMeta: snapshot.Metadata,
		StartKey: snapData.Region.GetStartKey(),
		EndKey:   snapData.Region.GetEndKey(),
	}

	// according to document, need to wait until region worker finishes
	<-ch
	// regionState update
	result := &ApplySnapResult{
		PrevRegion: ps.region,
		Region:     snapData.Region,
	}

	meta.WriteRegionState(kvWB, snapData.Region, rspb.PeerState_Normal)
	return result, nil
```
