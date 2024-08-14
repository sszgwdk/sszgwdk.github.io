#!/bin/bash
post_dir="content/posts"
content_dir="content"

project_name=$1
post_name=$2

# 如果没有输入参数，则提示错误并退出
if [ -z "$post_name" ] || [ -z "$project_name" ]; then
    echo "Usage: $0 <project_name> <post_name>"
    exit 1
fi

project_dir="$post_dir/$project_name"
if [ ! -d "$project_dir" ]; then
    mkdir -p "$project_dir"
fi

new_dir="$project_dir/$post_name"

# 如果new_dir存在，则提示错误并退出
if [ -d "$new_dir" ]; then
    echo "Error: $new_dir already exists."
    exit 1
fi

mkdir -p "$new_dir"

# 创建index.zh-cn.md文件
hugo new index.zh-cn.md

mv "$content_dir/index.zh-cn.md" "$new_dir/index.zh-cn.md"