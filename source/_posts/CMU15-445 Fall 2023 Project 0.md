# CMU15-445 Fall 2023 Project 0

Project 0是一个C++热身项目。使用的C++的版本是C++17，但是知道C++11的知识点就足够了。

## C++前置知识

从我的编码过程来看，P0主要涉及智能指针、强制类型转换、右值引用和锁管理四个部分的C++知识。

C++智能指针分为`unique_ptr`​、`shared_ptr`​和`weak_ptr`​，`unique_ptr`​是独占的，而`shared_ptr`​是共享的，底层使用引用计数，当引用为0时会自动释放指针所指向的资源，能够有效避免内存泄漏问题。可以通过`std::make_unique`​和`std::make_shared`​创建对应的智能指针。`weak_ptr`​则是为了协助`shared_ptr`​，它不会引起引用计数的变化，在bustub中几乎没有用到。

C++强制类型转换运算符有`static_cast`​、`const_cast`​、`reinterpret_cast`​和`dynamic_cast`​。重点关注后两个，`reinterpret_cast`​和`dynamic_cast`​均可以将**多态基类的指针或引用强制转换为派生类的指针或引用**，区别在于`dynamic_cast`​会检查转换的安全性，对于不安全的指针转换，会返回`nullptr`​。`dynamic_cast`​通过“运行时类型检查”来保证安全性。但是`reinterpret_cast`​更加灵活，`dynamic_cast`​不能用于将非多态基类的指针或引用强制转换为派生类的指针或引用——这种转换没法保证安全性，只好用`reinterpret_cast`​来完成。

右值引用涉及的概念较多，这里我只简单描述一下我的理解，可能存在谬误。

首先右值可以简单理解为临时对象，没办法取它的地址。之所以取名右值，是因为在等式右边的表达式值往往是临时对象。C++ 11引入了右值引用类型`&&`​，可以用来实现**移动语义和完美转发**，在bustub中主要关注移动语义。

什么是移动语义？举个例子，当一个类中的指针成员申请了堆内存，发生拷贝操作时如果没有自定义拷贝构造函数，会使用默认的拷贝构造函数，即成员逐个赋值，那么就会出现多个指针指向同一块堆内存的情况，在析构时就会出现double free的问题，也就是我们常说的浅拷贝的问题。通过自定义拷贝构造函数实现深拷贝自然可以解决，如果此时我们只需要一份数据，那么深拷贝就增加了很多不必要的资源申请和释放操作。我们完全可以在拷贝的过程中，在新对象的指针赋值之后，将原始对象的指针均置为nullptr，这样就省去了拷贝带来的资源消耗，这也正是移动语义的作用之一。

那么如何使用右值引用实现移动语义？通过在类中定义**移动构造函数和移动赋值运算符（参数就是该类的右值引用），**这样在传入一个右值时就会调用移动构造函数或移动赋值运算符，有时为了避免拷贝，还可以禁用拷贝构造函数和拷贝赋值运算符。可以参考下面的代码：（来自`trie.h`​）

```c++
/// A special type that will block the move constructor and move assignment operator. Used in TrieStore tests.
class MoveBlocked {
 public:
  explicit MoveBlocked(std::future<int> wait) : wait_(std::move(wait)) {}

  MoveBlocked(const MoveBlocked &) = delete;
  MoveBlocked(MoveBlocked &&that) noexcept {
    if (!that.waited_) {
      that.wait_.get();
    }
    that.waited_ = waited_ = true;
  }

  auto operator=(const MoveBlocked &) -> MoveBlocked & = delete;
  auto operator=(MoveBlocked &&that) noexcept -> MoveBlocked & {
    if (!that.waited_) {
      that.wait_.get();
    }
    that.waited_ = waited_ = true;
    return *this;
  }

  bool waited_{false};
  std::future<int> wait_;
};
```

需要注意的是，如果禁用了拷贝构造函数和拷贝赋值函数，此时通过该类的旧对象（此时为左值）创建新的类对象会报错，要通过`std::move`​将旧对象强制转为右值引用。例如：`MoveBlocked b(std::move(a))`​或者`auto b = std::make_shared<MoveBlocked>(std::move(a))`​。此时a中的资源会被转移到b中，如果a未赋新值，后续不应再被使用。

锁管理比较简单就是`std::lock_guard`​和`std::unique_lock`​的使用。可以参考以下文章：[C++ 锁管理：std::lock_guard 和 std::unique_lock 使用方法_c++ lockguard 手动开锁-CSDN博客](https://blog.csdn.net/qq_28256407/article/details/140214003)

## Task1 Copy-On-Write Trie

trie字典树这个数据结构不过多介绍，Copy-On-Write即写时复制，用在字典树上是指在进行写操作时，原有树形或数据保持不变（这样还能处理同时进行的读，便于并发操作），对需要修改的节点进行拷贝和修改。

代码主要在`trie.cpp`​中，要求实现`Get(key)`​、`Put(key, value)`​、`Delete(key)`​三个接口。

Get过程和原始trie一致：

1. 获取根节点`root_`​
2. 遍历`key`​的路径，期间如果节点不存在则返回`nullptr`​
3. 如果满足`key`​的节点不为空且`is_value_node_`​，通过`dynamic_cast<const TrieNodeWithValue<T> *>`​强转为带值节点指针，如果转换成功，返回`value_.get()`​
4. 返回`nullptr`​

Put和Remove的实现则相对较难，需要仔细阅读文档理解Copy-On-Write Trie进行Put、Remove的过程。另外需要注意`TrieNode`​类的定义中，`children_`​成员指向的子节点类型都是`const TrieNode`​，所以一个写入操作需要自底向上构建。

```c++
// A TrieNode is a node in a Trie.
class TrieNode {
 public:
  TrieNode() = default;
  explicit TrieNode(std::map<char, std::shared_ptr<const TrieNode>> children) : children_(std::move(children)) {}
  virtual ~TrieNode() = default;
  virtual auto Clone() const -> std::unique_ptr<TrieNode> { return std::make_unique<TrieNode>(children_); }
  std::map<char, std::shared_ptr<const TrieNode>> children_;
  bool is_value_node_{false};
};
```

### Put

1. 首先自底向上，创建不存在的`TrieNode`​（或 `TrieNodeWithValue`​）
2. 如果`TrieNode`​已存在，进行拷贝，将下一层的新节点进行进行插入或覆盖，即 `children_[c]=newNode`​
3. 返回`Trie(new_root)`​

建议采用递归实现，递归部分伪代码如下

```c++
void DiguiPut(new_ptr, key, val) {
	bool flag_find = false;
	auto iter = new_ptr->children_.find(key.at(0));
	// if found
	if (iter != new_ptr->children_.end()) {
		flag_find = true;
		// when remian key size > 1, continue to digui
		if (key.size() > 1 ) {
			// (1) clone
			// (2) digui_put
			// (3) update children of new_ptr
			auto node = iter->second->Clone();
			auto node_ptr = shared_ptr(std::move(node));
			DiguiPut(node_ptr, key[1:], std::move(val));
			update children of new_ptr; (iter->second = node_ptr)
		} else {
			// now key size == 1, means the last element of the key
			// only need to create a new value node
			create a new value node with val;
			update children of new_ptr;
		}
		return;
	}
	// if not found, need to create more new empty nodes
	if (!find_flag) {
		if (key.size() > 1) {
			create empty node and node_ptr;
			DiguiPut(node_ptr, key[1:], std::move(val));
			update children of new_ptr;
		} else {
			// now key.size() == 1, only need to create a new value node
			create a value_node and val_ptr;
			update children of new_ptr;
		}
	}
}
```

## Remove

Remove的过程与Put相近

1. 首先自底向上，找到需要删除的`TrieNodeWithValue`​（如果是`TrieNode`​或找不到，说明不需要做任何事）

    1. 如果有孩子节点，转为`TrieNode`​保留
    2. 如果没有孩子节点，说明需要删除
2. 自底向上对路径上的节点进行拷贝，对下一层节点进行修改或删除
3. 返回`Trie(new_root)`​

## Task2 Concurrent Key-Value Store

任务2需要对1中实现的Copy-On-Write Trie进行封装，实现可并发的kv存储，支持多读一写。

这一部分代码较为简单，锻炼锁的使用。

### Get

Get操作只需要在访问`root_`​时加锁，获取`root_`​之后即可解锁

1. 对`root_lock_`​加`unique_lock`​，获取`root_`​到临时变量`root`​，解锁
2. 调用`root.Get<T>(key)`​，获取`val`​
3. 如果`val != nullptr`​，返回一个`ValueGuard`​，否则返回一个`std::nullopt`​

> ​`std::optional`​管理一个可选﻿的容纳值，既可以存在也可以不存在的值。方便后续对**返回空（std::nullopt）**的处理。

### Put

写操作之间是冲突的，所以需要加一把大锁`write_lock_`​

1. 对`write_lock_`​加​`unique_lock`​
2. ​`new_trie = root_.Put<T>(key, std::move(value));`​
3. 对`root_lock_`​加锁，修改`root_ = new_trie`​
4. 解锁`root_lock_`​和`write_lock_`​

> 这里调用`root_.Put<T>(key, std::move(value));`​时并未对`root_lock_`​加锁，是因为加了`write_lock_`​，同一时间不存在对`root_`​的修改操作。并且是写时拷贝，不会对原始Trie进行修改。
>
> 之后获取访问锁`root_lock_`​，此时需要更新trie，所以需要避免其他进程读。
>
> 对Get访问root_加锁的根本原因就是避免Put或Remove在同一时刻修改root_，造成错误。

Remove与Put一致。

> 由于使用的都是`shared_ptr`​，调用`put`​、`remove`​返回新的root节点并完成赋值以后，旧的根节点指针在引用计数变为0后就会自动释放，进而它的所有子节点引用计数也会减一，对应put、remove的key，key路径上的所有旧节点都会被自动释放。

官方给的测试步骤如下：

```shell
$ cd build
$ make trie_test trie_store_test -j$(nproc)
$ make trie_noncopy_test trie_store_noncopy_test -j$(nproc)
$ ./test/trie_test
$ ./test/trie_noncopy_test
$ ./test/trie_store_test
$ ./test/trie_store_noncopy_test
```

## Task3 Debugging

我们需要进行调试的是`trie_debug_test.cpp`​。我的环境配置VScode + clangd + codeLLDB

debug步骤：

```shell
$ cd build
$ make trie_debug_test
```

编译完成后，根据`trie_debug_test.cpp`​中的提示设置断点，开启F5调试，起初会报错显示没有配置文件，会自动在`.vscode`​目录下创建`launch.json`​，我们需要将`program`​字段修改成`"${workspaceFolder}/build/test/trie_debug_test"`​（对照上面的测试脚本`./test/trie_test`​）

```json
{
    // 使用 IntelliSense 了解相关属性。 
    // 悬停以查看现有属性的描述。
    // 欲了解更多信息，请访问: https://go.microsoft.com/fwlink/?linkid=830387
    "version": "0.2.0",
    "configurations": [
        {
            "type": "lldb",
            "request": "launch",
            "name": "Debug",
            "program": "${workspaceFolder}/build/test/trie_debug_test",
            "args": [],
            "cwd": "${workspaceFolder}"
        }
    ]
}
```

然后在题目指定的位置加上断点，再次点击F5，就可以开始调试啦。

实在不行可以在测试代码里面打印结果。

## Task4 SQL String

​`string_expression.h`​：`Compute`​实现大小写转换，直接用`std::tolower`​和`std::toupper`​

​`plan_func_call.cpp`​：`Planner::GetFuncCallFromFactory`​，按照注释要求来写即可

```c++
// NOLINTNEXTLINE
auto Planner::GetFuncCallFromFactory(const std::string &func_name, std::vector<AbstractExpressionRef> args)
    -> AbstractExpressionRef {
  // 1. check if the parsed function name is "lower" or "upper".
  // 2. verify the number of args (should be 1), refer to the test cases for when you should throw an `Exception`.
  // 3. return a `StringExpression` std::shared_ptr.
  throw Exception(fmt::format("func call {} not supported in planner yet", func_name));
}
```

## 风格、内存泄漏检查和提交Grade

```shell
$ make format
$ make check-clang-tidy-p0
```

内存泄漏检查会在Debug模式下运行程序时自动执行，如果有内存泄漏，会有错误的报告

```shell
cmake -DCMAKE_BUILD_TYPE=Debug ..
```

代码提交到Gradescope：

在build目录下运行以下代码，得到project0-submission.zip

```shell
make submit-p0
cd ..
python3 gradescope_sign.py
```

最后一步Gradscope这个网站的一些要求，要签个名啥的，之后就可以上传到Gradescope了。
