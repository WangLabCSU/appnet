#!/usr/bin/env bash
# AppNet Node.js >=20 运行环境解析器（用户态安装，免 sudo）
#
# 用法（source 后调用）：
#   source scripts/node-env.sh
#   ensure_node20        # 保证 PATH 中有 Node>=20；缺失则用户态引导安装
#
# 解析顺序：
#   1. 系统 PATH 中已有 node >= 20 → 直接用
#   2. ~/.local/node20 已安装 → 挂载到 PATH
#   3. 以上皆无 → 下载 Node 20 LTS 解压到 ~/.local/node20（可用 NODE20_VERSION 换版本）
#
# 供 apps/bizard-mcp/start.sh 与 app-manager.sh 的 git_pull_npm 更新方法共用，
# 保证服务启动与自动更新使用同一个 Node 运行时。

NODE20_MIN_MAJOR="${NODE20_MIN_MAJOR:-20}"
NODE20_VERSION="${NODE20_VERSION:-v20.18.1}"
NODE20_HOME="${NODE20_HOME:-$HOME/.local/node20}"

# 已安装未挂载时补上（source 本文件即生效，幂等）
if [ -x "$NODE20_HOME/bin/node" ]; then
    case ":$PATH:" in
        *":$NODE20_HOME/bin:"*) : ;;
        *) PATH="$NODE20_HOME/bin:$PATH" ;;
    esac
fi

node20_ready() {
    command -v node >/dev/null 2>&1 || return 1
    local major
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    [ "${major:-0}" -ge "$NODE20_MIN_MAJOR" ]
}

# 下载并解压 Node 20 到 NODE20_HOME（npmmirror 国内加速，nodejs.org 兜底）
node20_bootstrap() {
    if [ "${NODE20_SKIP_BOOTSTRAP:-0}" = "1" ]; then
        echo "node-env: 未找到 Node>=$NODE20_MIN_MAJOR，且已禁用自动安装（NODE20_SKIP_BOOTSTRAP=1）" >&2
        return 1
    fi
    local arch tarball tmp
    case "$(uname -m)" in
        x86_64)  arch="x64" ;;
        aarch64) arch="arm64" ;;
        *) echo "node-env: 不支持的 CPU 架构: $(uname -m)" >&2; return 1 ;;
    esac
    tarball="node-$NODE20_VERSION-linux-$arch.tar.xz"
    tmp="$(mktemp -d)"

    echo "node-env: 正在用户态安装 $NODE20_VERSION 到 $NODE20_HOME ..."
    mkdir -p "$NODE20_HOME"
    if ! curl -fsSL --connect-timeout 15 --retry 2 \
            "https://registry.npmmirror.com/-/binary/node/$NODE20_VERSION/$tarball" \
            -o "$tmp/$tarball" 2>/dev/null; then
        curl -fsSL --connect-timeout 15 --retry 2 \
            "https://nodejs.org/dist/$NODE20_VERSION/$tarball" \
            -o "$tmp/$tarball" || { rm -rf "$tmp"; echo "node-env: Node 下载失败" >&2; return 1; }
    fi
    tar -xJf "$tmp/$tarball" -C "$NODE20_HOME" --strip-components=1
    rm -rf "$tmp"

    case ":$PATH:" in
        *":$NODE20_HOME/bin:"*) : ;;
        *) PATH="$NODE20_HOME/bin:$PATH" ;;
    esac
    node20_ready || { echo "node-env: 安装后仍无 Node>=$NODE20_MIN_MAJOR" >&2; return 1; }
}

# 主入口：保证 node>=20 可用；做不到则返回非 0（调用方决定如何处理）
ensure_node20() {
    if node20_ready; then
        return 0
    fi
    if [ -x "$NODE20_HOME/bin/node" ]; then
        PATH="$NODE20_HOME/bin:$PATH"
        node20_ready && return 0
    fi
    node20_bootstrap
}
