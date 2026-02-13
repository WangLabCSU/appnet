#!/usr/bin/env bash
# AppNet 初始化脚本
# 将 app-manager.sh 添加到系统路径

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== AppNet 初始化 ===${NC}"
echo ""

# 检测 shell 配置文件
detect_shell_config() {
    if [ -n "$ZSH_VERSION" ]; then
        echo "$HOME/.zshrc"
    elif [ -n "$BASH_VERSION" ]; then
        if [ -f "$HOME/.bashrc" ]; then
            echo "$HOME/.bashrc"
        else
            echo "$HOME/.bash_profile"
        fi
    else
        echo "$HOME/.profile"
    fi
}

SHELL_CONFIG=$(detect_shell_config)
BIN_DIR="$HOME/.local/bin"
COMMAND_NAME="appnet"

echo "Shell 配置文件: $SHELL_CONFIG"
echo "命令名称: $COMMAND_NAME"
echo ""

# 方法1: 创建符号链接到 ~/.local/bin
install_symlink() {
    echo -e "${BLUE}方法1: 创建符号链接到 ~/.local/bin${NC}"
    
    # 创建 bin 目录
    mkdir -p "$BIN_DIR"
    
    # 创建符号链接
    ln -sf "$SCRIPT_DIR/app-manager.sh" "$BIN_DIR/$COMMAND_NAME"
    
    # 确保 ~/.local/bin 在 PATH 中
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        echo ""
        echo -e "${YELLOW}需要将 $BIN_DIR 添加到 PATH${NC}"
        echo ""
        
        # 添加到 shell 配置文件
        if ! grep -q "export PATH=\"\$PATH:$BIN_DIR\"" "$SHELL_CONFIG" 2>/dev/null; then
            echo "" >> "$SHELL_CONFIG"
            echo "# AppNet" >> "$SHELL_CONFIG"
            echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$SHELL_CONFIG"
            echo -e "${GREEN}✅ 已添加 PATH 配置到 $SHELL_CONFIG${NC}"
        fi
    fi
    
    echo -e "${GREEN}✅ 符号链接已创建: $BIN_DIR/$COMMAND_NAME${NC}"
}

# 方法2: 添加 alias 到 shell 配置
install_alias() {
    echo -e "${BLUE}方法2: 添加 alias 到 shell 配置${NC}"
    
    if ! grep -q "alias $COMMAND_NAME=" "$SHELL_CONFIG" 2>/dev/null; then
        echo "" >> "$SHELL_CONFIG"
        echo "# AppNet" >> "$SHELL_CONFIG"
        echo "alias $COMMAND_NAME='$SCRIPT_DIR/app-manager.sh'" >> "$SHELL_CONFIG"
        echo -e "${GREEN}✅ 已添加 alias 到 $SHELL_CONFIG${NC}"
    else
        echo -e "${YELLOW}alias 已存在于 $SHELL_CONFIG${NC}"
    fi
}

# 显示使用说明
show_usage() {
    echo ""
    echo -e "${GREEN}=== 安装完成 ===${NC}"
    echo ""
    echo "请运行以下命令使配置生效:"
    echo ""
    echo -e "  ${YELLOW}source $SHELL_CONFIG${NC}"
    echo ""
    echo "或者重新打开终端窗口。"
    echo ""
    echo "然后可以使用以下命令:"
    echo ""
    echo -e "  ${BLUE}$COMMAND_NAME status${NC}       # 查看服务状态"
    echo -e "  ${BLUE}$COMMAND_NAME start${NC}        # 启动所有服务"
    echo -e "  ${BLUE}$COMMAND_NAME stop${NC}         # 停止所有服务"
    echo -e "  ${BLUE}$COMMAND_NAME restart otk${NC}  # 重启 otk 应用"
    echo -e "  ${BLUE}$COMMAND_NAME list${NC}         # 列出所有应用"
    echo ""
}

# 卸载
uninstall() {
    echo -e "${YELLOW}卸载 AppNet 命令...${NC}"
    
    # 删除符号链接
    if [ -L "$BIN_DIR/$COMMAND_NAME" ]; then
        rm -f "$BIN_DIR/$COMMAND_NAME"
        echo "✅ 已删除符号链接: $BIN_DIR/$COMMAND_NAME"
    fi
    
    # 从 shell 配置中移除
    if [ -f "$SHELL_CONFIG" ]; then
        # 移除 PATH 配置
        sed -i '/# AppNet/d' "$SHELL_CONFIG" 2>/dev/null || true
        sed -i "s|export PATH=\"\\\$PATH:$BIN_DIR\"||g" "$SHELL_CONFIG" 2>/dev/null || true
        
        # 移除 alias
        sed -i "/alias $COMMAND_NAME=/d" "$SHELL_CONFIG" 2>/dev/null || true
        
        echo "✅ 已清理 $SHELL_CONFIG"
    fi
    
    echo ""
    echo -e "${GREEN}卸载完成，请运行: source $SHELL_CONFIG${NC}"
}

# 主函数
main() {
    case "${1:-}" in
        uninstall|--uninstall|-u)
            uninstall
            exit 0
            ;;
        alias|-a)
            install_alias
            show_usage
            exit 0
            ;;
        help|--help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  无参数      安装符号链接 (默认)"
            echo "  alias, -a   安装 alias 方式"
            echo "  uninstall   卸载"
            echo "  help, -h    显示帮助"
            exit 0
            ;;
    esac
    
    # 默认使用符号链接方式
    install_symlink
    show_usage
}

main "$@"
