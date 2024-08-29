---
weight: 9
title: "CMU15-445 Fall 2023 Project 1"
slug: "cmu445_p1"
date: 2024-08-29T17:54:14+08:00
lastmod: 2024-08-29T17:54:14+08:00
draft: false
author: "SszgwDk"
authorLink: "https://sszgwdk.github.io"
description: ""
images: []

tags: ["CMU15-445", "DB"]
categories: ["DB"]

lightgallery: true

toc:
  auto: false
showTableOfContents: true
outdatedInfoWarning: true
---
Project 1是为Bustub构建一个面向磁盘的缓存管理器（Storage Manager）。

缓存管理器（也叫缓存池，Buffer Pool）是数据库系统中一个必不可少的组件，可以显著减少数据库的I/O操作，降低数据库负载。在DBMS中，记录是按照行来存储的，但是数据库的读取并不是以行为单位的，否则一次读取（也就是一次 I/O 操作）只能处理一行数据，效率会非常低。Bustub的数据是按页为单位进行读写的，页的大小可以是4KB、8KB、16KB等，是缓存管理的最小单元。

为了减少磁盘I/O操作，Buffer Pool的作用就是把**最热的数据页**缓存在内存中，下次需要这个数据页时可以直接从内存读取，而不是进行一次磁盘I/O。当需要读取或写入数据时，存储引擎首先检查缓冲池中是否已经存在所需的数据页。如果数据页在缓冲池中，DBMS可以直接从内存中读取或写入数据，避免了磁盘IO的开销。如果数据页不在缓冲池中，DBMS就需要从磁盘加载数据页到缓冲池，并进行相应的操作。

相应的，缓冲池的管理也涉及到数据页的替换策略。当缓冲池已满时，需要替换一些数据页以腾出空间来存储新的数据页。常见的数据页替换策略包括最近最少使用（LRU）和时钟（Clock）算法。

有关数据库缓存机制，可以学习参考以下文章：[MySQL缓冲池（Buffer Pool）深入解析：原理、组成及其在数据操作中的核心作用-腾讯云开发者社区-腾讯云 (tencent.com)](https://cloud.tencent.com/developer/article/2398498)

Bustub的缓存管理器需要我们实现三个组件：

1. LRU-K页面替换策略：管理缓存页的替换、淘汰
2. 磁盘调度器：执行底层的磁盘IO操作
3. 缓存池管理器：封装向上层提供的缓存页面操作接口（`FetchPage`​、`FlushPage`​、`NewPage`​等）

## Task#1 LRU-K Replacement Policy

LRU-K是LRU算法的一种衍生，每次替换会优先替换 **k-distance** 最远的一个数。LRU算法实现虽然简单，并且在大量频繁访问热点页面时十分高效，但同样也有一个缺点，就是如果该热点页面在偶然一个时间节点被其他大量仅访问了一次的页面所取代（例如Scan操作），那自然造成了浪费。LRU-K的主要目的是为了解决 LRU 算法"缓存污染"的问题，其核心思想是将“最近使用过 1 次”的判断标准扩展为“最近使用过 K 次”。

这里的 **k-distance** 是这样定义的：

* 如果它访问的次数大于等于 k ，那么它的 k-distance 是倒数第k次访问的时间
* 如果它访问的次数小于 k ，那么它的 k-distance 是无穷大 +inf

驱逐方法是这样的：

* 如果有 k-distance 为 +inf 的，优先驱逐

  * 如果有多个 k-distance 为 +inf 的，根据题目的定义，采用FIFO，即最早访问的
* 否则，驱逐 k-distance 最小的

在`lru_k_replacer.h`​和`lru_k_replacer.cpp`​中，首先需要完成`LRUKNode`​类的封装：

```c++
const size_t K_MAX_TIMESTAMP = std::numeric_limits<size_t>::max();
class LRUKNode {
 public:
  LRUKNode() = default;
  explicit LRUKNode(size_t timestamp, size_t k, frame_id_t fid, bool is_evictable);

  //   std::weak_ptr<LRUKNode> prev_;
  //   std::shared_ptr<LRUKNode> next_;
  auto GetKDistance() const -> size_t;
  auto GetFrameId() const -> frame_id_t;
  auto GetEarliestAccessTimestamp() const -> size_t;
  void RemoveAccessHistory();
  void UpdateAccessHistory(size_t timestamp);
  auto IsEvictable() const -> bool;
  void SetEvictable(bool is_evictable);

 private:
  /** History of last seen K timestamps of this page. Least recent timestamp stored in front. */
  // Remove maybe_unused if you start using them. Feel free to change the member variables as you want.
  std::list<size_t> history_;
  size_t k_;
  frame_id_t fid_;
  bool is_evictable_{false};
};
```

1. ​`GetKDistance()`​：如果`history_.size() < k_`​，返回`K_MAX_TIMESTAMP`​，否则返回`history_.front()`​（我们在`history_`​中只需要维护最近的`k_`​个访问时间戳）
2. ​`GetEarliestAccessTimestamp()`​：返回`history_.front()`​
3. ​`RemoveAccessHistory()`​：清空`history_`​
4. ​`UpdateAccessHistory(ts)`​：尾部插入`ts`​，如果当前大小超过`k_`​，从头部pop直到`size == k_`​

​`LRUKReplacer`​是实现LRU-K算法的主要类，为了方便算法实现，需要增加几个私有成员。

```c++
class LRUKReplacer {
 public:
 ...
 private:
  // TODO(student): implement me! You can replace these member variables as you like.
  // Remove maybe_unused if you start using them.
  std::unordered_map<frame_id_t, std::shared_ptr<LRUKNode>> node_store_;
  std::list<frame_id_t> less_k_list_;
  std::list<frame_id_t> more_k_list_;
  size_t current_timestamp_{0};
  size_t curr_size_{0};
  size_t replacer_size_;
  size_t k_;
  std::mutex latch_;
};
```

1. ​`node_store_`​维护缓存页号`frame_id_t`​（注意区分数据页的概念，对应`page_id_t`​）到`LRUKNode`​的映射
2. ​`less_k_list_`​和`more_k_list_`​分别维护访问次数小于和大于等于k的缓存页链表

我们要实现`LRUKReplacer`​的以下几个接口：

1. ​`Evict`​：淘汰一个缓存页
2. ​`RecordAccess`​：记录一次对一个缓存页的访问
3. ​`SetEvictable`​：设置一个缓存页的`is_evictable_`​
4. ​`Remove`​：直接删除某个特定的缓存页，不用考虑k-distance

特别注意，由于`node_store_`​、`less_k_list_`​等都不是线程安全的，因此对于每个接口，都要用`std::lock_guard<std::mutex> lock(latch_)`​加一把大锁。

### Evict

1. 首先淘汰`less_k_list_`​中的缓存页，如果不为空

    1. 取出头部的`frame_id`​并`pop_front`​，从`node_store_`​中获取对应的`LRUKNode`​，记作`node`​
    2. ​`node->RemoveAccessHistory();`​
    3. ​`node->SetEvictable(false);`​
    4. ​`curr_size_--;`​
    5. 返回`true`​
2. 在考虑淘汰`more_k_list_`​中的缓存页

    1. 选择链表中`EarliestAccessTimestamp`​最小的缓存页号`frame_id`​
    2. 后续步骤同`less_k_list_`​

### RecordAccess

这里不用考虑做Evict，由上层调用

1. ​`current_timestamp_++`​
2. ​`BUSTUB_ASSERT`​检查`frame_id`​是否合理，即`frame_id <= replacer_size_`​
3. 如果当前`frame_id`​不在`node_store_`​，说明是一个新节点，需要创建`LRUKNode`​，默认`is_evictable_`​设置为false，因此不需要插入`more_k_list_`​或`less_k_list_`​
4. 如果当前`frame_id`​在`node_store_`​，说明是一个老节点，需要更新`LRUKNode`​的`history_`​，并从原来的list中remove掉，如果`is_evictable_=true`​，根据kdistance重新插入到`more_k_list_`​或`less_k_list_`​尾部

### SetEvictable

1. ​`BUSTUB_ASSERT`​检查`frame_id`​是否合理，即`frame_id <= replacer_size_`​
2. 在`node_store_`​中查找，如果节点不存在，直接返回
3. 检查`is_evictable`​是否有变化，无变化直接返回；如果有变化，先从`more_k_list_`​和`less_k_list_`​中remove掉，更新节点的`is_evictable_`​；
4. 如果`set_evictable`​为True，`curr_size_++`​，并根据当前kdistance插入对应链表
5. 如果为false，`curr_size_--`​

## Remove

1. 同样​`BUSTUB_ASSERT`​检查`frame_id`​是否合理
2. 检查是否能在`node_store_`​中查找到
3. ​`BUSTUB_ASSERT`​检查node是否可淘汰，根据node的`is_evictable_`​，如果不可淘汰，报错
4. 从`less_k_list_`​或`more_k_list_`​中remove掉
5. ​`node->RemoveAccessHistory();`​、`node->SetEvictable(false);`​
6. ​`node_store_.erase(frame_id);`​、`curr_size--`​

## Task#2 Disk Scheduler

磁盘调度器，主要实现`Schedule(DiskRequest r)`​和`StartWorkerThread()`​两个接口。

### Schedule

主要任务：调度一个request给`DiskManager`​执行。

注意这里不需要使用`background_thread_`​，而是直接将一个请求加入到channel当中，即只有一个线程来Schedule，`background_thread_`​是用于process这些request的。

```c++
void DiskScheduler::Schedule(DiskRequest r) {
  request_queue_.Put(std::move(r));
}
```

### StartWorkerThread

这是后台线程`background_thread_`​执行的函数，是一个死循环，当收到空的请求时才break掉。

它负责循环访问channel（`request_queue_`​），获取其中请求调用`disk_manager_`​的读写接口进行实际磁盘I/O处理，并且在I/O操作完成后将请求中的`callback_`​设置为true，用以通知上层（缓存管理器，buffer_pool_manager）操作完成。

​`Channel<std::optionaldiskrequest&gt; request_queue_;`​​

```c++
/**
 * Channels allow for safe sharing of data between threads. This is a multi-producer multi-consumer channel.
 */
template <class T>
class Channel {
 public:
  Channel() = default;
  ~Channel() = default;

  /**
   * @brief Inserts an element into a shared queue.
   *
   * @param element The element to be inserted.
   */
  void Put(T element) {
    std::unique_lock<std::mutex> lk(m_);
    q_.push(std::move(element));
    lk.unlock();
    cv_.notify_all();
  }

  /**
   * @brief Gets an element from the shared queue. If the queue is empty, blocks until an element is available.
   */
  auto Get() -> T {
    std::unique_lock<std::mutex> lk(m_);
    cv_.wait(lk, [&]() { return !q_.empty(); });
    T element = std::move(q_.front());
    q_.pop();
    return element;
  }

 private:
  std::mutex m_;
  std::condition_variable cv_;
  std::queue<T> q_;
};
```

源码`src/include/common/channel.h`​提供了一个可供多线程安全访问的队列，是一个多生产者多消费者模型。（不过目前我们在磁盘调度器中的使用方式是单生产者单消费者，后续可以优化）

​`disk_manager_`​实现的I/O逻辑也比较简单，可以看到在bustub当中，数据页号`page_id`​与其在数据文件中的偏移的计算公式为`offset = page_id * BUSTUB_PAGE_SIZE`​。

```c++
void DiskManager::WritePage(page_id_t page_id, const char *page_data) {
  std::scoped_lock scoped_db_io_latch(db_io_latch_);
  size_t offset = static_cast<size_t>(page_id) * BUSTUB_PAGE_SIZE;
  // set write cursor to offset
  num_writes_ += 1;
  db_io_.seekp(offset);
  db_io_.write(page_data, BUSTUB_PAGE_SIZE);
  // check for I/O error
  if (db_io_.bad()) {
    LOG_DEBUG("I/O error while writing");
    return;
  }
  // needs to flush to keep disk file in sync
  db_io_.flush();
}
```

> 涉及的C++知识：
>
> ​`std::promise`​ 是C++11并发编程中常用的一个类，常配合`std::future`​使用。其作用是在一个线程t1中保存一个类型typename T的值，可供相绑定的`std::future`​对象在另一线程t2中获取。promise一个典型应用场景就是callback函数。
>
> [[C++11]std::promise介绍及使用_c++ 中的promise-CSDN博客](https://blog.csdn.net/godmaycry/article/details/72844159)
>
> 条件变量`std::condition_variable`​用于阻塞一个或多个线程，直到某个线程修改线程间的共享变量，并通过`condition_variable`​通知其余阻塞线程。从而使得已阻塞的线程可以继续处理后续的操作。经常与`unique_lock`​搭配使用。
>
> [条件变量condition_variable的使用及陷阱 - 封fenghl - 博客园 (cnblogs.com)](https://www.cnblogs.com/fenghualong/p/13855360.html)

## Task #3 - Buffer Pool Manager

Buffer Pool Manger有两个主要职责：

1. 利用`DiskScheduler`​从磁盘获取数据页并存储在内存当中；
2. 当明确指示将脏页写入磁盘时，或者当需要逐出页面以便为新页腾出空间时，将脏页写入磁盘。

我们先来看一下`BufferPoolManager`​的定义：

```c++
 private:
  /** Number of pages in the buffer pool. */
  const size_t pool_size_;
  /** The next page id to be allocated  */
  std::atomic<page_id_t> next_page_id_ = 0;

  /** Array of buffer pool pages. */
  Page *pages_;
  /** Pointer to the disk sheduler. */
  std::unique_ptr<DiskScheduler> disk_scheduler_ __attribute__((__unused__));
  /** Pointer to the log manager. Please ignore this for P1. */
  LogManager *log_manager_ __attribute__((__unused__));
  /** Page table for keeping track of buffer pool pages. */
  std::unordered_map<page_id_t, frame_id_t> page_table_;
  /** Replacer to find unpinned pages for replacement. */
  std::unique_ptr<LRUKReplacer> replacer_;
  /** List of free frames that don't have any pages on them. */
  std::list<frame_id_t> free_list_;
  /** This latch protects shared data structures. We recommend updating this comment to describe what it protects. */
  std::mutex latch_;
```

其中几个比较重要的成员的作用：

1. ​`pages_`​：存储数据页的数组，它的下标对应缓存页号`frame_id_t`​，`Page`​中存的是数据页号`page_id_t`​；
2. ​`disk_scheduler_`​：磁盘调度器；
3. ​`page_table_`​：数据页号到缓存页号的映射；
4. ​`replacer_`​：LRU-K算法，实现页面淘汰；
5. ​`free_list_`​：当前空闲的缓存页；
6. ​`latch_`​：一把大锁保平安，后续再考虑优化。

在类的构造函数当中，需要为`pages_`​申请内存空间，初始化`free_list_`​，创建`disk_scheduler_`​和`repalcer_`​。析构函数中只需要`delete[] pages_`​。

​`Page`​类中还有一个`pin_count_`​成员需要注意，记录了被不用线程 pinned 的次数，BufferPoolManager 不应该驱逐被 pinned 的 Page。

```c++
class Page {
 public:
  ...
 private:
  /** Zeroes out the data that is held within the page. */
  inline void ResetMemory() { memset(data_, OFFSET_PAGE_START, BUSTUB_PAGE_SIZE); }

  /** The actual data that is stored within a page. */
  // Usually this should be stored as `char data_[BUSTUB_PAGE_SIZE]{};`. But to enable ASAN to detect page overflow,
  // we store it as a ptr.
  char *data_;
  /** The ID of this page. */
  page_id_t page_id_ = INVALID_PAGE_ID;
  /** The pin count of this page. */
  int pin_count_ = 0;
  /** True if the page is dirty, i.e. it is different from its corresponding page on disk. */
  bool is_dirty_ = false;
  /** Page latch. */
  ReaderWriterLatch rwlatch_;
};
```

我们需要实现头文件 （src/include/buffer/buffer_pool_manager.h） 和源文件（src/buffer/buffer_pool_manager.cpp） 中定义的以下函数：

* ​`FetchPage(page_id_t page_id)`​：用于获取数据页。首先在`page_table_`​中查找，如果存在，令`pin_count++`​，在`replacer_`​中记录以及设置为不可淘汰，然后返回Page；如果没找到，先从`free_list_`​获取空闲的缓存页，如果为空，利用`replacer_->Evict`​淘汰一个，如果还是失败，直接返回；如果成功得到一个缓存页，更新`page_table_`​指向新数据页，如果缓存页对应的旧数据页是脏页，调用`DiskScheduler`​写回磁盘，完成写操作后，将`page_id_`​、`is_dirty_`​、`pin_count_`​赋新值或初始化，并`ResetMemory()`​，接着再次利用磁盘调度器读取新数据页中的数据到内存当中，完成读操作后，在`replacer_`​中记录以及设置为不可淘汰。
* ​`UnpinPage(page_id_t page_id, bool is_dirty)`​：用于减少指定页面的`pin_count_`​，并在必要时标记页面为脏页。首先检查页面id是否有效，查找`page_table_`​获取缓存页号，失败均返回false；访问对应数据页的内存，设置`is_dirty_`​和`pin_count_--`​，如果减少到0，标记缓存页可淘汰，最后返回true。
* ​`FlushPage(page_id_t page_id)`​：不论`is_dirty_`​，强制flush到磁盘。
* ​`NewPage(page_id_t* page_id)`​：新建一个数据页。首先从`free_list_`​（优先）或`replacer_`​中得到一个缓存页frame_id，如果失败则返回`nullptr`​；接着调用`AllocatePage()`​为新数据页分配id，并在`page_table_`​更新映射关系，如果缓存页对应的旧数据页是脏页，调用`DiskScheduler`​写回磁盘，完成写操作后，将`page_id_`​、`is_dirty_`​、`pin_count_`​赋新值或初始化，并`ResetMemory()`​。最后在`replacer_`​中记录以及设置为不可淘汰。
* ​`DeletePage(page_id_t page_id)`​：删除一个数据页。首先在`page_table_`​中查找，如果不存在，直接返回true。接着检查`pin_count_`​，如果大于0，说明不能被删除，返回false。如果满足删除的条件，依次从`page_table_`​、`repalcer_`​中删除，并将对应的缓存页添加到`free_list_`​，并重置该数据页的数据和元数据。
* ​`FlushAllPages()`​：将`page_table_`​中所有有效的数据页都flush到磁盘，此时可以先批量发出所有I/O请求，然后统一等待I/O完成。

对于上述所有接口，建议先用一把大锁进行并发控制，确保逻辑正确通过测试后，再考虑性能的优化。

‍
