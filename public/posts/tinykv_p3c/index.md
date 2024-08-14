# TinyKV Project 3C


3c要求实现region balance调度器，文档给了详细的算法步骤，相对比较容易。

## processRegionHeartbeat

每个region都会周期性的发送心跳给调度器，调度器需要首先检查RegionEpoch是否是最新的，如果是则进行更新，否则忽略。

检查的逻辑是：

1. 如果该心跳对应的region id在调度器中存在，检查心跳中的RegionEpoch是否过时，如果过时则直接返回；
2. 如果该心跳对应的region id在调度器中找不到，扫描调度器中所有与心跳region有重叠的Regions。同样的方法对比RegionEpoch，如果Regions中存在一个region比心跳region新，那么就是过时的。

## Schedule

region balance调度器目标是让集群中的stores所负载的region数目趋于平衡。一个调度命令通常就是将某个region从一个store移动到另一个store，因此Schedule的逻辑是先找到合适的region和目标store，然后创建一个`MovePeerOperator`​。详细算法官方文档给的很详细，具体步骤如下：
1. 获取所有“合适”的store并根据`RegionSize`排序

    1. “合适”的条件：`store.IsUp() && store.DownTime() < maxStoreDownTime`
2. 遍历第一步获取的`suitableStores`（从`RegionSize`最大的开始），找到最适合在 store 中移动的 region

    1. `GetPendingRegionsWithLock`：尝试选择一个挂起的region
    2. `GetFollowersWithLock`：尝试选择一个follower region
    3. `GetLeadersWithLock`：尝试选择一个leader region
3. 若成功选择了一个要移动的 region，选择`RegionSize`最小的一个 store 作为目标
4. 检查此次移动是否有价值：

    1. 判断条件：如果`fromStore.GetRegionSize()-toStore.GetRegionSize() < 2*region.GetApproximateSize()`，表明两个store负载的region大小相近，此次移动没有必要
5. `CreateMovePeerOperator`

