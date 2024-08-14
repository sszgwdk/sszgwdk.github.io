---
weight: 9
title: "TinyKV Project 3C"
slug: "tinykv_p3c"
date: 2024-08-14T12:04:47+08:00
lastmod: 2024-08-14T12:04:47+08:00
draft: true
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

3c要求实现region balance调度器，文档给了详细的算法步骤，相对比较容易。

## processRegionHeartbeat

每个region都会周期性的发送心跳给调度器，调度器需要首先检查RegionEpoch是否是最新的，如果是则进行更新，否则忽略。

检查的逻辑是：

1. 如果该心跳对应的region id在调度器中存在，检查心跳中的RegionEpoch是否过时，如果过时则直接返回；
2. 如果该心跳对应的region id在调度器中找不到，扫描调度器中所有与心跳region有重叠的Regions。同样的方法对比RegionEpoch，如果Regions中存在一个region比心跳region新，那么就是过时的。

```go
// processRegionHeartbeat updates the region information.
func (c *RaftCluster) processRegionHeartbeat(region *core.RegionInfo) error {
	// Your Code Here (3C).
	epoch := region.GetRegionEpoch()
	if epoch == nil {
		return errors.Errorf("region has no epoch")
	}

	// check if the region is in the cluster
	rawRegion := c.GetRegion(region.GetID())
	if rawRegion != nil {
		// check if regionVersion is stale or not
		stale := util.IsEpochStale(epoch, rawRegion.GetRegionEpoch())
		if stale {
			return errors.Errorf("region is stale")
		}
	} else {
		// scan all regions that overlap with it
		overlapRegions := c.ScanRegions(region.GetStartKey(), region.GetEndKey(), -1)
		for _, oRegion := range overlapRegions {
			stale := util.IsEpochStale(epoch, oRegion.GetRegionEpoch())
			if stale {
				return errors.Errorf("region is stale")
			}
		}
	}
	c.putRegion(region)
	for i := range region.GetStoreIds() {
		c.updateStoreStatusLocked(i)
	}
	return nil
}
```

## Schedule

region balance调度器目标是让集群中的stores所负载的region数目趋于平衡。一个调度命令通常就是将某个region从一个store移动到另一个store，因此Schedule的逻辑是先找到合适的region和目标store，然后创建一个`MovePeerOperator`​。详细算法官方文档给的很详细，实现代码如下：

```go
type StoreInfoSlice []*core.StoreInfo

func (s StoreInfoSlice) Len() int           { return len(s) }
func (s StoreInfoSlice) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }
func (s StoreInfoSlice) Less(i, j int) bool { return s[i].GetRegionSize() > s[j].GetRegionSize() } // 降序

func (s *balanceRegionScheduler) Schedule(cluster opt.Cluster) *operator.Operator {
	// Your Code Here (3C).
	maxStoreDownTime := cluster.GetMaxStoreDownTime()
	// // Get suitable stores.
	source := cluster.GetStores()
	suitableStores := make([]*core.StoreInfo, 0)
	for _, store := range source {
		if store.IsUp() && store.DownTime() < maxStoreDownTime {
			suitableStores = append(suitableStores, store)
		}
	}

	if len(suitableStores) < 2 {
		return nil
	}

	// Sort stores by regionSize.
	sort.Sort(StoreInfoSlice(suitableStores))

	// scan suitableStores to find the best store to move region from.
	var fromStore, toStore *core.StoreInfo
	var region *core.RegionInfo
	for _, store := range suitableStores {
		var regions core.RegionsContainer
		cluster.GetPendingRegionsWithLock(store.GetID(), func(rc core.RegionsContainer) { regions = rc })
		region = regions.RandomRegion(nil, nil)
		if region != nil {
			fromStore = store
			break
		}
		cluster.GetFollowersWithLock(store.GetID(), func(rc core.RegionsContainer) { regions = rc })
		region = regions.RandomRegion(nil, nil)
		if region != nil {
			fromStore = store
			break
		}
		cluster.GetLeadersWithLock(store.GetID(), func(rc core.RegionsContainer) { regions = rc })
		region = regions.RandomRegion(nil, nil)
		if region != nil {
			fromStore = store
			break
		}
	}

	if region == nil {
		return nil
	}

	storeIds := region.GetStoreIds()
	if len(storeIds) < cluster.GetMaxReplicas() {
		return nil
	}

	// scan suitableStores again to find the best store to move region to.
	// the best store is the one with the smallest regionSize.
	for i := len(suitableStores) - 1; i >= 0; i-- {
		if _, ok := storeIds[suitableStores[i].GetID()]; !ok {
			toStore = suitableStores[i]
			break
		}
	}
	if toStore == nil {
		return nil
	}

	// if diff < 2*ApproximateSize, give up.
	if fromStore.GetRegionSize()-toStore.GetRegionSize() < 2*region.GetApproximateSize() {
		return nil
	}

	// create operator
	newPeer, _ := cluster.AllocPeer(toStore.GetID())
	op, _ := operator.CreateMovePeerOperator("balance-region", cluster, region, operator.OpBalance, fromStore.GetID(), toStore.GetID(), newPeer.GetId())
	return op
}
```