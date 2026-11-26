#!/bin/bash
# v2ray一键安装脚本
# Author: hijk<https://hijk.art>



apt install jq aptitude apt-get  dnsutils -y
aptitude  install jq dnsutils -y
apt-get install jq dnsutils -y
apt install dnsutils -y


yum install epel-release dnsutils  -y
yum install jq dnsutils -y



RED="\033[31m"      # Error message
GREEN="\033[32m"    # Success message
YELLOW="\033[33m"   # Warning message
BLUE="\033[36m"     # Info message
PLAIN='\033[0m'

# 以下网站是随机从Google上找到的无广告小说网站，不喜欢请改成其他网址，以http或https开头
# 搭建好后无法打开伪装域名，可能是反代小说网站挂了，请在网站留言，或者Github发issue，以便替换新的网站
SITES=(
http://www.zhuizishu.com/
http://xs.56dyc.com/
#http://www.xiaoshuosk.com/
#https://www.quledu.net/
http://www.ddxsku.com/
http://www.biqu6.com/
https://www.wenshulou.cc/
#http://www.auutea.com/
http://www.55shuba.com/
http://www.39shubao.com/
https://www.23xsw.cc/
https://www.huanbige.com/
https://www.jueshitangmen.info/
https://www.zhetian.org/
http://www.bequgexs.com/
http://www.tjwl.com/
)

CONFIG_FILE="/etc/v2ray/config.json"
SERVICE_FILE="/etc/systemd/system/v2ray.service"
# 随机 16 位文件名与令牌，重跑时复用
LINK_STATE="/etc/v2ray/reality-site.link"
TOKEN_STATE="/etc/v2ray/reality-site.token"
LINK_NAME=""
LINK_TOKEN=""
OS=`hostnamectl | grep -i system | cut -d: -f2`

V6_PROXY=""
IP=`curl -sL -4 ip.sb`
if [[ "$?" != "0" ]]; then
    IP=`curl -sL -6 ip.sb`
    V6_PROXY="https://gh.hijk.art/"
fi

BT="false"
NGINX_CONF_PATH="/etc/nginx/conf.d/"
# 静态网站伪装时的首页拉取地址
STATIC_INDEX_URL="https://raw.githubusercontent.com/qiu996/v2-qiu/main/index.html"
res=`which bt 2>/dev/null`
if [[ "$res" != "" ]]; then
    BT="true"
    NGINX_CONF_PATH="/www/server/panel/vhost/nginx/"
fi

VLESS="false"
TROJAN="false"
TLS="false"
WS="false"
XTLS="false"
KCP="false"

checkSystem() {
 #   result=$(id | awk '{print $1}')
 #   if [[ $result != "uid=0(root)" ]]; then
 
    result=$(id | awk '{print $1}' |  cut -d "(" -f2 | cut -d  ")" -f1)
    if [[ $result != "root" ]]; then
        colorEcho $RED " 请以root身份执行该脚本"
        exit 1
    fi

    res=`which yum 2>/dev/null`
    if [[ "$?" != "0" ]]; then
        res=`which apt 2>/dev/null`
        if [[ "$?" != "0" ]]; then
            colorEcho $RED " 不受支持的Linux系统"
            exit 1
        fi
        PMT="apt"
        CMD_INSTALL="apt install -y "
        CMD_REMOVE="apt remove -y "
        CMD_UPGRADE="apt update; apt upgrade -y; apt autoremove -y"
    else
        PMT="yum"
        CMD_INSTALL="yum install -y "
        CMD_REMOVE="yum remove -y "
        CMD_UPGRADE="yum update -y"
    fi
    res=`which systemctl 2>/dev/null`
    if [[ "$?" != "0" ]]; then
        colorEcho $RED " 系统版本过低，请升级到最新版本"
        exit 1
    fi
}

colorEcho() {
    echo -e "${1}${@:2}${PLAIN}"
}

# ===== 以下为健壮性增强函数（自动重试 / 换源 / 多回退）=====

# 刷新软件源索引，失败不致命
aptRefresh() {
    if [[ "$PMT" = "apt" ]]; then
        rm -rf /var/lib/apt/lists/*
        apt-get update || colorEcho $YELLOW " apt update 失败，继续尝试..."
    else
        yum clean all; yum makecache || true
    fi
}

# 健壮的软件包安装：失败自动刷新索引并重试 N 次（适配 apt/yum）
# 用法: safeInstall nginx   或   safeInstall wget vim unzip
safeInstall() {
    local pkgs="$*"
    local max=3 i=1
    while (( i <= max )); do
        if [[ "$PMT" = "apt" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing $pkgs && return 0
        else
            yum install -y $pkgs && return 0
        fi
        colorEcho $YELLOW " 第${i}/${max}次安装 [$pkgs] 失败，刷新索引后重试..."
        aptRefresh
        ((i++))
    done
    colorEcho $RED " [$pkgs] 安装失败（已重试${max}次），请检查网络或软件源"
    return 1
}

# 多源 DNS 解析检测，精确匹配目标 IP
# 避免：单一 @1.1.1.1 在 53 端口被禁时全部超时；以及 grep 子串误判（1.2.3.4 命中 11.2.3.4）
# 返回 0 = 域名解析到了 $2；返回 1 = 没有
checkDnsResolve() {
    local domain="$1" server_ip="$2" resolved=""
    for ns in "1.1.1.1" "8.8.8.8" "223.5.5.5" "119.29.29.29" ""; do
        if [[ -n "$ns" ]]; then
            resolved=$(dig +short +time=2 +tries=1 A "$domain" @"$ns" 2>/dev/null)
        else
            resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
        fi
        [[ -n "$resolved" ]] && break
    done
    echo "${domain}  points to: ${resolved:-无}"
    [[ -z "$resolved" ]] && return 1
    # 精确匹配整个 IP
    echo "$resolved" | grep -qw "$server_ip"
}

# 带重试的下载，按顺序尝试多个地址（主链失败自动回退镜像）
# 用法: downloadWithRetry <输出文件> <主url> [备用url...]
downloadWithRetry() {
    local out="$1"; shift
    local urls=("$@")
    local max=3 i url
    for url in "${urls[@]}"; do
        for (( i=1; i<=max; i++ )); do
            if curl -L --connect-timeout 15 --retry 2 -H "Cache-Control: no-cache" -o "$out" "$url" 2>/dev/null && [[ -s "$out" ]]; then
                return 0
            fi
            colorEcho $YELLOW " 下载失败(${i}/${max})：$url"
            sleep 2
        done
    done
    return 1
}

configNeedNginx() {
    local ws=`grep wsSettings $CONFIG_FILE`
    if [[ -z "$ws" ]]; then
        echo no
        return
    fi
    echo yes
}

needNginx() {
    if [[ "$WS" = "false" ]]; then
        echo no
        return
    fi
    echo yes
}

status() {
    if [[ ! -f /usr/bin/v2ray/v2ray ]]; then
        echo 0
        return
    fi
    if [[ ! -f $CONFIG_FILE ]]; then
        echo 1
        return
    fi
    port=`grep port $CONFIG_FILE| head -n 1| cut -d: -f2| tr -d \",' '`
    res=`ss -nutlp| grep ${port} | grep -i v2ray`
    if [[ -z "$res" ]]; then
        echo 2
        return
    fi

    if [[ `configNeedNginx` != "yes" ]]; then
        echo 3
    else
        res=`ss -nutlp|grep -i nginx`
        if [[ -z "$res" ]]; then
            echo 4
        else
            echo 5
        fi
    fi
}

statusText() {
    res=`status`
    case $res in
        2)
            echo -e ${GREEN}已安装${PLAIN} ${RED}未运行${PLAIN}
            ;;
        3)
            echo -e ${GREEN}已安装${PLAIN} ${GREEN}V2ray正在运行${PLAIN}
            ;;
        4)
            echo -e ${GREEN}已安装${PLAIN} ${GREEN}V2ray正在运行${PLAIN}, ${RED}Nginx未运行${PLAIN}
            ;;
        5)
            echo -e ${GREEN}已安装${PLAIN} ${GREEN}V2ray正在运行, Nginx正在运行${PLAIN}
            ;;
        *)
            echo -e ${RED}未安装${PLAIN}
            ;;
    esac
}

normalizeVersion() {
    if [ -n "$1" ]; then
        case "$1" in
            v*)
                echo "$1"
            ;;
            *)
                echo "v$1"
            ;;
        esac
    else
        echo ""
    fi
}

# 1: new V2Ray. 0: no. 1: yes. 2: not installed. 3: check failed.
getVersion() {
    VER="$(/usr/bin/v2ray/v2ray -version 2>/dev/null)"
    RETVAL=$?
    CUR_VER="$(normalizeVersion "$(echo "$VER" | head -n 1 | cut -d " " -f2)")"
    TAG_URL="${V6_PROXY}https://api.github.com/repos/v2fly/v2ray-core/releases/latest"
#    NEW_VER="$(normalizeVersion "$(curl -s "${TAG_URL}" --connect-timeout 10| tr ',' '\n' | grep 'tag_name' | cut -d\" -f4)")"
    NEW_VER="$(curl -fSsL "${TAG_URL}" --connect-timeout 20  | jq -r '.tag_name' )"
    if [[ "$XTLS" = "true" ]]; then
        NEW_VER=v4.32.1
    fi

    if [[ $? -ne 0 ]] || [[ $NEW_VER == "" ]]; then
        colorEcho $RED " 检查V2ray版本信息失败，请检查网络"
        return 3
    elif [[ $RETVAL -ne 0 ]];then
        return 2
    elif [[ $NEW_VER != $CUR_VER ]];then
        return 1
    fi
    return 0
}

archAffix(){
    case "$(uname -m)" in
        i686|i386)
            echo '32'
        ;;
        x86_64|amd64)
            echo '64'
        ;;
        *armv7*)
            echo 'arm32-v7a'
            ;;
        armv6*)
            echo 'arm32-v6a'
        ;;
        *armv8*|aarch64)
            echo 'arm64-v8a'
        ;;
        *mips64le*)
            echo 'mips64le'
        ;;
        *mips64*)
            echo 'mips64'
        ;;
        *mipsle*)
            echo 'mipsle'
        ;;
        *mips*)
            echo 'mips'
        ;;
        *s390x*)
            echo 's390x'
        ;;
        ppc64le)
            echo 'ppc64le'
        ;;
        ppc64)
            echo 'ppc64'
        ;;
        *)
            colorEcho $RED " 不支持的CPU架构！"
            exit 1
        ;;
    esac

    return 0
}

getData() {
    if [[ "$TLS" = "true" || "$XTLS" = "true" ]]; then
        echo ""
        echo " V2ray一键脚本，运行之前请确认如下条件已经具备："
        colorEcho ${YELLOW} "  1. 一个伪装域名"
        colorEcho ${YELLOW} "  2. 伪装域名DNS解析指向当前服务器ip（${IP}）"
        colorEcho ${BLUE} "  3. 如果/root目录下有 v2ray.pem 和 v2ray.key 证书密钥文件，无需理会条件2"
        echo " "
        read -p " 确认满足按y，按其他退出脚本：" answer
        if [[ "${answer,,}" != "y" ]]; then
            exit 0
        fi

        echo ""
        while true
        do
            read -p "请输入伪装域名：" DOMAIN
            if [[ -z "${DOMAIN}" ]]; then
                colorEcho ${RED} " 域名输入错误，请重新输入！"
            else
                break
            fi
        done
        DOMAIN=${DOMAIN,,}
        colorEcho ${BLUE}  "伪装域名(host)：$DOMAIN"

        if [[ -f ~/v2ray.pem && -f ~/v2ray.key ]]; then
            colorEcho ${BLUE}  " 检测到自有证书，将使用其部署"
            CERT_FILE="/etc/v2ray/${DOMAIN}.pem"
            KEY_FILE="/etc/v2ray/${DOMAIN}.key"
        else
            # 多源 DNS 解析校验：精确匹配本机公网 IP（IP 在脚本开头已通过 ip.sb 探测）
            if ! checkDnsResolve "$DOMAIN" "$IP"; then
                colorEcho ${RED}  " 域名未解析到当前服务器IP(${IP})!"
                colorEcho ${YELLOW} " 请确认 DNS 已将 ${DOMAIN} 解析到 ${IP}，且服务器 53 端口出站未被拦截"
                exit 1
            fi
        fi
    fi

    echo ""
    if [[ "$(needNginx)" = "no" ]]; then
        if [[ "$TLS" = "true" ]]; then
            read -p " 请输入v2ray监听端口[强烈建议443，默认443]：" PORT
            [[ -z "${PORT}" ]] && PORT=443
        else
            read -p " 请输入v2ray监听端口[100-65535的一个数字]：" PORT
            [[ -z "${PORT}" ]] && PORT=`shuf -i200-65000 -n1`
            if [[ "${PORT:0:1}" = "0" ]]; then
                colorEcho ${RED}  " 端口不能以0开头"
                exit 1
            fi
        fi
        colorEcho ${BLUE}  " v2ray端口：$PORT"
    else
        read -p " 请输入Nginx监听端口[100-65535的一个数字，默认443]：" PORT
        [[ -z "${PORT}" ]] && PORT=443
        if [ "${PORT:0:1}" = "0" ]; then
            colorEcho ${BLUE}  " 端口不能以0开头"
            exit 1
        fi
        colorEcho ${BLUE}  " Nginx端口：$PORT"
        V2PORT=`shuf -i10000-65000 -n1`
    fi

    if [[ "$KCP" = "true" ]]; then
        echo ""
        colorEcho $BLUE " 请选择伪装类型："
        echo "   1) 无"
        echo "   2) BT下载"
        echo "   3) 视频通话"
        echo "   4) 微信视频通话"
        echo "   5) dtls"
        echo "   6) wiregard"
        read -p "  请选择伪装类型[默认：无]：" answer
        case $answer in
            2)
                HEADER_TYPE="utp"
                ;;
            3)
                HEADER_TYPE="srtp"
                ;;
            4)
                HEADER_TYPE="wechat-video"
                ;;
            5)
                HEADER_TYPE="dtls"
                ;;
            6)
                HEADER_TYPE="wireguard"
                ;;
            *)
                HEADER_TYPE="none"
                ;;
        esac
        colorEcho $BLUE " 伪装类型：$HEADER_TYPE"
        SEED=`cat /proc/sys/kernel/random/uuid`
    fi

    if [[ "$TROJAN" = "true" ]]; then
        echo ""
        read -p " 请设置trojan密码（不输则随机生成）:" PASSWORD
        [[ -z "$PASSWORD" ]] && PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1`
        colorEcho $BLUE " trojan密码：$PASSWORD"
    fi

    if [[ "$XTLS" = "true" ]]; then
        echo ""
        colorEcho $BLUE " 请选择流控模式:" 
        echo -e "   1) xtls-rprx-direct [$RED推荐$PLAIN]"
        echo "   2) xtls-rprx-origin"
        read -p "  请选择流控模式[默认:direct]" answer
        [[ -z "$answer" ]] && answer=1
        case $answer in
            1)
                FLOW="xtls-rprx-direct"
                ;;
            2)
                FLOW="xtls-rprx-origin"
                ;;
            *)
                colorEcho $RED " 无效选项，使用默认的xtls-rprx-direct"
                FLOW="xtls-rprx-direct"
                ;;
        esac
        colorEcho $BLUE " 流控模式：$FLOW"
    fi

    if [[ "${WS}" = "true" ]]; then
        echo ""
        while true
        do
            read -p " 请输入伪装路径，以/开头(不懂请直接回车)：" WSPATH
            if [[ -z "${WSPATH}" ]]; then
                len=`shuf -i5-12 -n1`
                ws=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $len | head -n 1`
                WSPATH="/$ws"
                break
            elif [[ "${WSPATH:0:1}" != "/" ]]; then
                colorEcho ${RED}  " 伪装路径必须以/开头！"
            elif [[ "${WSPATH}" = "/" ]]; then
                colorEcho ${RED}   " 不能使用根路径！"
            else
                break
            fi
        done
        colorEcho ${BLUE}  " ws路径：$WSPATH"
    fi

    if [[ "$TLS" = "true" || "$XTLS" = "true" ]]; then
        echo ""
        colorEcho $BLUE " 请选择伪装站类型:"
        echo "   1) 静态网站(位于/usr/share/nginx/html)"
        echo "   2) 小说站(随机选择)"
        echo "   3) 跨境腾讯视频(https://wetv.vip)"
        echo "   4) 高清壁纸站(https://www.pexels.com)"
        echo "   5) 自定义反代站点(需以http或者https开头)"
        read -p "  请选择伪装网站类型[默认:静态网站]" answer
        if [[ -z "$answer" ]]; then
            PROXY_URL=""
        else
            case $answer in
            1)
                PROXY_URL=""
                ;;
            2)
                len=${#SITES[@]}
                ((len--))
                while true
                do
                    index=`shuf -i0-${len} -n1`
                    PROXY_URL=${SITES[$index]}
                    host=`echo ${PROXY_URL} | cut -d/ -f3`
                    ip=`curl -sL https://hijk.art/hostip.php?d=${host}`
                    res=`echo -n ${ip} | grep ${host}`
                    if [[ "${res}" = "" ]]; then
                        echo "$ip $host" >> /etc/hosts
                        break
                    fi
                done
                ;;
            3)
                PROXY_URL="https://wetv.vip/"
                ;;
            4)
                PROXY_URL="https://wetv.vip"
                ;;
            5)
                read -p " 请输入反代站点(以http或者https开头)：" PROXY_URL
                if [[ -z "$PROXY_URL" ]]; then
                    colorEcho $RED " 请输入反代网站！"
                    exit 1
                elif [[ "${PROXY_URL:0:4}" != "http" ]]; then
                    colorEcho $RED " 反代网站必须以http或https开头！"
                    exit 1
                fi
                ;;
            *)
                colorEcho $RED " 请输入正确的选项！"
                exit 1
            esac
        fi
        REMOTE_HOST=`echo ${PROXY_URL} | cut -d/ -f3`
        if [[ -z "$PROXY_URL" ]]; then
            colorEcho $BLUE " 伪装网站：静态网站(/usr/share/nginx/html)"
        else
            colorEcho $BLUE " 伪装网站：$PROXY_URL"
        fi

        echo ""
        colorEcho $BLUE "  是否允许搜索引擎爬取网站？[默认：不允许]"
        echo "    y)允许，会有更多ip请求网站，但会消耗一些流量，vps流量充足情况下推荐使用"
        echo "    n)不允许，爬虫不会访问网站，访问ip比较单一，但能节省vps流量"
        read -p "  请选择：[y/n]" answer
        if [[ -z "$answer" ]]; then
            ALLOW_SPIDER="n"
        elif [[ "${answer,,}" = "y" ]]; then
            ALLOW_SPIDER="y"
        else
            ALLOW_SPIDER="n"
        fi
        colorEcho $BLUE " 允许搜索引擎：$ALLOW_SPIDER"
    fi

    echo ""
    read -p " 是否安装BBR(默认安装)?[y/n]:" NEED_BBR
    [[ -z "$NEED_BBR" ]] && NEED_BBR=y
    [[ "$NEED_BBR" = "Y" ]] && NEED_BBR=y
    colorEcho $BLUE " 安装BBR：$NEED_BBR"
}

installNginx() {
    echo ""
    colorEcho $BLUE " 安装nginx..."
    if [[ "$BT" = "false" ]]; then
        if [[ "$PMT" = "yum" ]]; then
            $CMD_INSTALL epel-release
            if [[ "$?" != "0" ]]; then
                echo '[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true' > /etc/yum.repos.d/nginx.repo
            fi
        fi
        if safeInstall nginx; then
            systemctl enable nginx
        else
            # 失败自愈：apt 系临时禁用可能不同步的 security 源，改用主源重装，装完恢复源配置
            if [[ "$PMT" = "apt" ]] && [[ -f /etc/apt/sources.list ]]; then
                colorEcho $YELLOW " 默认源安装 nginx 失败，尝试切换软件源..."
                cp /etc/apt/sources.list /etc/apt/sources.list.bak.v2ray 2>/dev/null
                sed -i '/^[[:space:]]*deb .*security\.debian\.org/s/^/#/' /etc/apt/sources.list
                apt-get update
                if safeInstall nginx; then
                    systemctl enable nginx
                    [[ -f /etc/apt/sources.list.bak.v2ray ]] && mv /etc/apt/sources.list.bak.v2ray /etc/apt/sources.list
                    colorEcho $GREEN " 已通过切换软件源成功安装 nginx，源配置已恢复"
                else
                    [[ -f /etc/apt/sources.list.bak.v2ray ]] && mv /etc/apt/sources.list.bak.v2ray /etc/apt/sources.list
                    colorEcho $RED " Nginx安装失败，请检查网络或软件源后重试"
                    exit 1
                fi
            else
                colorEcho $RED " Nginx安装失败，请检查网络或软件源后重试"
                exit 1
            fi
        fi
    else
        res=`which nginx 2>/dev/null`
        if [[ "$?" != "0" ]]; then
            colorEcho $RED " 您安装了宝塔，请在宝塔后台安装nginx后再运行本脚本"
            exit 1
        fi
    fi
}

startNginx() {
    if [[ "$BT" = "false" ]]; then
        systemctl start nginx
    else
        nginx -c /www/server/nginx/conf/nginx.conf
    fi
}

stopNginx() {
    if [[ "$BT" = "false" ]]; then
        systemctl stop nginx
    else
        res=`ps aux | grep -i nginx`
        if [[ "$res" != "" ]]; then
            nginx -s stop
        fi
    fi
}

getCert() {
    mkdir -p /etc/v2ray
    if [[ -z ${CERT_FILE+x} ]]; then
        stopNginx
        sleep 2
        res=`netstat -ntlp| grep -E ':80 |:443 '`
        if [[ "${res}" != "" ]]; then
            colorEcho ${RED}  " 其他进程占用了80或443端口，请先关闭再运行一键脚本"
            echo " 端口占用信息如下："
            echo ${res}
            exit 1
        fi

        safeInstall socat openssl
        if [[ "$PMT" = "yum" ]]; then
            safeInstall cronie
            systemctl start crond
            systemctl enable crond
        else
            safeInstall cron
            systemctl start cron
            systemctl enable cron
        fi
CERT_LOCK="/tmp/v2ray_cert_renewing"

        curl -sL https://get.acme.sh | sh -s email=hijk.pw@protonmail.ch
        source ~/.bashrc
        ~/.acme.sh/acme.sh  --upgrade  --auto-upgrade
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        if [[ "$BT" = "false" ]]; then
		if [[ ! -z "${res4}" ]]; then
            ~/.acme.sh/acme.sh   --issue -d $DOMAIN --keylength ec-256 --pre-hook "touch $CERT_LOCK; systemctl stop nginx" --post-hook "systemctl restart nginx; rm -f $CERT_LOCK"  --standalone --listen-v6
		else
            ~/.acme.sh/acme.sh   --issue -d $DOMAIN --keylength ec-256 --pre-hook "touch $CERT_LOCK; systemctl stop nginx" --post-hook "systemctl restart nginx; rm -f $CERT_LOCK"  --standalone --listen-v6
		fi
        else
		if [[ ! -z "${res4}" ]]; then	
            ~/.acme.sh/acme.sh   --issue -d $DOMAIN --keylength ec-256 --pre-hook "touch $CERT_LOCK; nginx -s stop || { echo -n ''; }" --post-hook "nginx -c /www/server/nginx/conf/nginx.conf || { echo -n ''; }; rm -f $CERT_LOCK"  --standalone --listen-v6
		else
            ~/.acme.sh/acme.sh   --issue -d $DOMAIN --keylength ec-256 --pre-hook "touch $CERT_LOCK; nginx -s stop || { echo -n ''; }" --post-hook "nginx -c /www/server/nginx/conf/nginx.conf || { echo -n ''; }; rm -f $CERT_LOCK"  --standalone --listen-v6
		fi
        fi
        [[ -f ~/.acme.sh/${DOMAIN}_ecc/ca.cer ]] || {
            colorEcho $RED " 获取证书失败，请复制上面的红色文字到 https://hijk.art 反馈"
            exit 1
        }
        CERT_FILE="/etc/v2ray/${DOMAIN}.pem"
        KEY_FILE="/etc/v2ray/${DOMAIN}.key"
        ~/.acme.sh/acme.sh  --install-cert -d $DOMAIN --ecc \
            --key-file       $KEY_FILE  \
            --fullchain-file $CERT_FILE \
            --reloadcmd     "service nginx force-reload"
        [[ -f $CERT_FILE && -f $KEY_FILE ]] || {
            colorEcho $RED " 获取证书失败，请到 https://hijk.art 反馈"
            exit 1
        }
    else
        cp ~/v2ray.pem /etc/v2ray/${DOMAIN}.pem
        cp ~/v2ray.key /etc/v2ray/${DOMAIN}.key
    fi
}

# 随机 16 位十六进制文件名 + 32 位令牌，用于私密访问伪装站；
# 文件名记录到 $LINK_STATE，重跑时复用；无令牌访问由 nginx 直接返回 404。
writeLink() {
    local root="/usr/share/nginx/html" name='' token='' f
    mkdir -p "$root" /etc/v2ray
    [[ -s "$LINK_STATE" ]] && name=$(<"$LINK_STATE")
    [[ $name =~ ^[0-9a-f]{16}$ ]] || name=''
    if [[ -z $name ]]; then
        for f in "$root"/*; do
            [[ -f $f ]] || continue
            f=${f##*/}
            [[ $f =~ ^[0-9a-f]{16}$ ]] && { name=$f; break; }
        done
        [[ -n $name ]] || name=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
        printf '%s\n' "$name" > "$LINK_STATE"
        chmod 600 "$LINK_STATE"
    fi
    [[ -s "$TOKEN_STATE" ]] && token=$(<"$TOKEN_STATE")
    [[ $token =~ ^[0-9a-f]{32}$ ]] || token=''
    if [[ -z $token ]]; then
        token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
        printf '%s\n' "$token" > "$TOKEN_STATE"
        chmod 600 "$TOKEN_STATE"
    fi
    if [[ ! -f "$root/$name" ]]; then
        printf 'hysteria2://1.1.1@127.0.0.1:443?alpn=h3&insecure=1#%s号到期\n' "$(date +%-d)" > "$root/$name"
        chmod 644 "$root/$name"
    fi
    LINK_NAME=$name
    LINK_TOKEN=$token
}

# 记录私密文件的成功访问：只保留状态码 200，格式 来源IP---归属地---日期---时间，
# 写入网页目录 web.log（nginx 已对该路径返回 404，只能 SSH/SFTP 查看）。
writeLinkLog() {
    cat > /usr/local/sbin/v2ray-link-log.sh <<'EOF'
#!/bin/sh
src=/var/log/nginx/reality-link.log
dst=/usr/share/nginx/html/web.log
cache=/var/cache/reality-link/ipgeo
mkdir -p "$(dirname "$cache")"

geo_of() {
    ip="$1"
    case "$ip" in
        127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|::1|fe80:*|fc*|fd*)
            printf '内网'; return ;;
    esac
    hit=$(awk -F'|' -v k="$ip" '$1 == k {print $2; exit}' "$cache" 2>/dev/null)
    if [ -n "$hit" ]; then printf '%s' "$hit"; return; fi
    geo=$(curl -s --max-time 3 "http://ip-api.com/line/$ip?lang=zh-CN&fields=country,regionName,city,isp" | awk '!seen[$0]++' | paste -sd' ' -)
    case "$geo" in fail*|invalid*|'') geo='未知' ;; esac
    printf '%s|%s\n' "$ip" "$geo" >> "$cache"
    printf '%s' "$geo"
}

while [ ! -f "$src" ]; do sleep 2; done
tail -n 0 -F "$src" 2>/dev/null | while IFS= read -r line; do
    status=$(printf '%s\n' "$line" | awk -F'"' '{print $3+0}')
    [ "$status" = 200 ] || continue
    ip=$(printf '%s\n' "$line" | awk '{print $1}')
    ts=$(printf '%s\n' "$line" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    [ -n "$ip" ] && [ -n "$ts" ] || continue
    printf '%s---%s---%s\n' "$ip" "$(geo_of "$ip")" "$(date -d "$ts" '+%Y-%m-%d---%H:%M:%S')" >> "$dst"
done
EOF
    chmod 755 /usr/local/sbin/v2ray-link-log.sh
    if command -v logrotate >/dev/null 2>&1; then
        cat > /etc/logrotate.d/v2ray-link <<EOF
/usr/share/nginx/html/web.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    fi
    cat > /etc/systemd/system/v2ray-link-log.service <<EOF
[Unit]
Description=v2ray private link access log formatter
After=nginx.service

[Service]
ExecStart=/usr/local/sbin/v2ray-link-log.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable v2ray-link-log.service >/dev/null 2>&1 || true
    systemctl restart v2ray-link-log.service || true
}

configNginx() {
    mkdir -p /usr/share/nginx/html;
    # 伪装站为静态网站时，拉取自定义首页到 nginx 站点目录
    if [[ "$PROXY_URL" = "" ]]; then
        colorEcho $BLUE " 拉取静态网站首页..."
        curl -fsSL ${STATIC_INDEX_URL} -o /usr/share/nginx/html/index.html \
            && colorEcho $BLUE " 首页已放到 /usr/share/nginx/html/index.html" \
            || colorEcho $RED " 首页拉取失败，请检查服务器网络后重试"
        # 仅 TLS 站点生成随机私密文件，无 TLS 时 nginx 不提供站点
        if [[ "$TLS" = "true" ]]; then
            writeLink
        fi
    fi
    if [[ "$ALLOW_SPIDER" = "n" ]]; then
        echo 'User-Agent: *' > /usr/share/nginx/html/robots.txt
        echo 'Disallow: /' >> /usr/share/nginx/html/robots.txt
        ROBOT_CONFIG="    location = /robots.txt {}"
    else
        ROBOT_CONFIG=""
    fi

    if [[ "$BT" = "false" ]]; then
        if [[ ! -f /etc/nginx/nginx.conf.bak ]]; then
            mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
        fi
        res=`id nginx 2>/dev/null`
        if [[ "$?" != "0" ]]; then
            user="www-data"
        else
            user="nginx"
        fi
        cat > /etc/nginx/nginx.conf<<-EOF
user $user;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

# Load dynamic modules. See /usr/share/doc/nginx/README.dynamic.
include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;
    server_tokens off;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    gzip                on;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    # Load modular configuration files from the /etc/nginx/conf.d directory.
    # See http://nginx.org/en/docs/ngx_core_module.html#include
    # for more information.
    include /etc/nginx/conf.d/*.conf;
}
EOF
    fi

    if [[ "$PROXY_URL" = "" ]]; then
        action=""
    else
        action="proxy_ssl_server_name on;
        proxy_pass $PROXY_URL;
        proxy_set_header Accept-Encoding '';
        sub_filter \"$REMOTE_HOST\" \"$DOMAIN\";
        sub_filter_once off;"
    fi

    # 随机文件必须带正确令牌，否则一律 404
    if [[ -n "$LINK_NAME" ]]; then
        LINK_CONFIG="location = /${LINK_NAME} {
        if (\$arg_k != \"${LINK_TOKEN}\") { return 404; }
        access_log /var/log/nginx/reality-link.log combined;
    }"
    else
        LINK_CONFIG=""
    fi

    if [[ "$TLS" = "true" || "$XTLS" = "true" ]]; then
        mkdir -p $NGINX_CONF_PATH
        # VMESS+WS+TLS
        # VLESS+WS+TLS
        if [[ "$WS" = "true" ]]; then
            cat > ${NGINX_CONF_PATH}${DOMAIN}.conf<<-EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$server_name:${PORT}\$request_uri;
}

server {
    listen       ${PORT} ssl http2;
    listen       [::]:${PORT} ssl http2;
    server_name ${DOMAIN};
    charset utf-8;

    # ssl配置
    ssl_protocols TLSv1.1 TLSv1.2;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE:ECDH:AES:HIGH:!NULL:!aNULL:!MD5:!ADH:!RC4;
    ssl_ecdh_curve secp384r1;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    root /usr/share/nginx/html;
    location / {
        $action
    }
    $ROBOT_CONFIG
    $LINK_CONFIG
    location = /link.txt { return 404; }
    location = /web.log { return 404; }

    location ${WSPATH} {
      proxy_redirect off;
      proxy_pass http://127.0.0.1:${V2PORT};
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
      # Show real IP in v2ray access.log
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
        else
            # VLESS+TCP+TLS
            # VLESS+TCP+XTLS
            # trojan
            cat > ${NGINX_CONF_PATH}${DOMAIN}.conf<<-EOF
server {
    listen 80;
    listen [::]:80;
    listen 81 http2;
    server_name ${DOMAIN};
    root /usr/share/nginx/html;
    location / {
        $action
    }
    $ROBOT_CONFIG
    $LINK_CONFIG
    location = /link.txt { return 404; }
    location = /web.log { return 404; }
}
EOF
        fi
    fi

    # 完整私密链接存一份，便于日后查看（不在网站目录，无法被外部访问）
    if [[ -n "$LINK_NAME" ]]; then
        local link_host="$DOMAIN"
        [[ "$PORT" = "443" ]] || link_host="$DOMAIN:$PORT"
        mkdir -p /etc/v2ray
        printf 'https://%s/%s?k=%s\n' "$link_host" "$LINK_NAME" "$LINK_TOKEN" > /etc/v2ray/link.txt
        chmod 600 /etc/v2ray/link.txt
        # 网页目录也放一份便于 SFTP 查看；nginx 已对 /link.txt 统一返回 404
        cp -f /etc/v2ray/link.txt /usr/share/nginx/html/link.txt
        chmod 644 /usr/share/nginx/html/link.txt
        writeLinkLog
    fi
}

setSelinux() {
    if [[ -s /etc/selinux/config ]] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
        setenforce 0
    fi
}

setFirewall() {
    res=`which firewall-cmd 2>/dev/null`
    if [[ $? -eq 0 ]]; then
        systemctl status firewalld > /dev/null 2>&1
        if [[ $? -eq 0 ]];then
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            if [[ "$PORT" != "443" ]]; then
                firewall-cmd --permanent --add-port=${PORT}/tcp
                firewall-cmd --permanent --add-port=${PORT}/udp
            fi
            firewall-cmd --reload
        else
            nl=`iptables -nL | nl | grep FORWARD | awk '{print $1}'`
            if [[ "$nl" != "3" ]]; then
                iptables -I INPUT -p tcp --dport 80 -j ACCEPT
                iptables -I INPUT -p tcp --dport 443 -j ACCEPT
                if [[ "$PORT" != "443" ]]; then
                    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
                    iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT
                fi
            fi
        fi
    else
        res=`which iptables 2>/dev/null`
        if [[ $? -eq 0 ]]; then
            nl=`iptables -nL | nl | grep FORWARD | awk '{print $1}'`
            if [[ "$nl" != "3" ]]; then
                iptables -I INPUT -p tcp --dport 80 -j ACCEPT
                iptables -I INPUT -p tcp --dport 443 -j ACCEPT
                if [[ "$PORT" != "443" ]]; then
                    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
                    iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT
                fi
            fi
        else
            res=`which ufw 2>/dev/null`
            if [[ $? -eq 0 ]]; then
                res=`ufw status | grep -i inactive`
                if [[ "$res" = "" ]]; then
                    ufw allow http/tcp
                    ufw allow https/tcp
                    if [[ "$PORT" != "443" ]]; then
                        ufw allow ${PORT}/tcp
                        ufw allow ${PORT}/udp
                    fi
                fi
            fi
        fi
    fi
}

installBBR() {
    if [[ "$NEED_BBR" != "y" ]]; then
        INSTALL_BBR=false
        return
    fi
    result=$(lsmod | grep bbr)
    if [[ "$result" != "" ]]; then
        colorEcho $BLUE " BBR模块已安装"
        INSTALL_BBR=false
        return
    fi
    res=`hostnamectl | grep -i openvz`
    if [[ "$res" != "" ]]; then
        colorEcho $BLUE " openvz机器，跳过安装"
        INSTALL_BBR=false
        return
    fi
    
    # 检测内核是否已支持 BBR（内置模块 lsmod 不显示，用 sysctl 更可靠）
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        modprobe tcp_bbr 2>/dev/null
        grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            colorEcho $GREEN " BBR已启用"
            INSTALL_BBR=false
            return
        fi
    fi

    colorEcho $BLUE " 当前内核不支持BBR，尝试安装新内核..."
    if [[ "$PMT" = "yum" ]]; then
        if [[ "$V6_PROXY" = "" ]]; then
            rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
            rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-4.el7.elrepo.noarch.rpm
            safeInstall --enablerepo=elrepo-kernel kernel-ml
            $CMD_REMOVE kernel-3.*
            grub2-set-default 0
            echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
            INSTALL_BBR=true
        fi
    else
        # 按发行版选择内核包（原写死的 linux-generic-hwe-16.04 仅 Ubuntu 16.04 存在，Debian 上不存在）
        local bbr_pkg=""
        if grep -qi ubuntu /etc/os-release 2>/dev/null; then
            bbr_pkg="linux-generic-hwe-$(grep -i version_id /etc/os-release | cut -d'"' -f2 | cut -d. -f1).04"
        else
            bbr_pkg="linux-image-amd64"
        fi
        if safeInstall "$bbr_pkg"; then
            grub-set-default 0
            echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
            INSTALL_BBR=true
        else
            colorEcho $YELLOW " 内核包安装失败，跳过BBR（可稍后手动升级内核后启用）"
            INSTALL_BBR=false
        fi
    fi
}

installV2ray() {
    rm -rf /tmp/v2ray
    mkdir -p /tmp/v2ray
    GITHUB_LINK="https://github.com/v2fly/v2ray-core/releases/download/${NEW_VER}/v2ray-linux-$(archAffix).zip"
    DOWNLOAD_LINK="${V6_PROXY}${GITHUB_LINK}"
    MIRROR_LINK="https://ghproxy.com/${GITHUB_LINK}"
    colorEcho $BLUE " 下载V2Ray: ${DOWNLOAD_LINK}"
    if ! downloadWithRetry /tmp/v2ray/v2ray.zip "$DOWNLOAD_LINK" "$MIRROR_LINK"; then
        colorEcho $RED " 下载V2ray文件失败，请检查服务器网络设置"
        exit 1
    fi
    mkdir -p '/etc/v2ray' '/var/log/v2ray' && \
    unzip /tmp/v2ray/v2ray.zip -d /tmp/v2ray
    mkdir -p /usr/bin/v2ray
  #  cp /tmp/v2ray/v2ctl /usr/bin/v2ray/;
    cp /tmp/v2ray/v2ray /usr/bin/v2ray/; cp /tmp/v2ray/geo* /usr/bin/v2ray/;
#    chmod +x '/usr/bin/v2ray/v2ray' '/usr/bin/v2ray/v2ctl' || {
 chmod +x '/usr/bin/v2ray/v2ray'  || {
        colorEcho $RED " V2ray安装失败"
        exit 1
    }

    cat >$SERVICE_FILE<<-EOF
[Unit]
Description=V2ray Service
Documentation=https://hijk.art
After=network.target nss-lookup.target

[Service]
# If the version of systemd is 240 or above, then uncommenting Type=exec and commenting out Type=simple
#Type=exec
Type=simple
# This service runs as root. You may consider to run it as another user for security concerns.
# By uncommenting User=nobody and commenting out User=root, the service will run as user nobody.
# More discussion at https://github.com/v2ray/v2ray-core/issues/1011
User=root
#User=nobody
NoNewPrivileges=true
ExecStart=/usr/bin/v2ray/v2ray run -config /etc/v2ray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable v2ray.service
}

trojanConfig() {
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "trojan",
    "settings": {
      "clients": [
        {
          "password": "$PASSWORD"
        }
      ],
      "fallbacks": [
        {
              "alpn": "http/1.1",
              "dest": 80
          },
          {
              "alpn": "h2",
              "dest": 81
          }
      ]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": "$DOMAIN",
            "alpn": ["http/1.1", "h2"],
            "certificates": [
                {
                    "certificateFile": "$CERT_FILE",
                    "keyFile": "$KEY_FILE"
                }
            ]
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

trojanXTLSConfig() {
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "trojan",
    "settings": {
      "clients": [
        {
          "password": "$PASSWORD",
          "flow": "$FLOW"
        }
      ],
      "fallbacks": [
          {
              "alpn": "http/1.1",
              "dest": 80
          },
          {
              "alpn": "h2",
              "dest": 81
          }
      ]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "xtls",
        "xtlsSettings": {
            "serverName": "$DOMAIN",
            "alpn": ["http/1.1", "h2"],
            "certificates": [
                {
                    "certificateFile": "$CERT_FILE",
                    "keyFile": "$KEY_FILE"
                }
            ]
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

vmessConfig() {
    local uuid="$(cat '/proc/sys/kernel/random/uuid')"
    local alterid=`shuf -i50-80 -n1`
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vmess",
    "settings": {
      "clients": [
        {
          "id": "$uuid",
          "level": 1,
          "alterId": $alterid
        }
      ]
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

vmessKCPConfig() {
    local uuid="$(cat '/proc/sys/kernel/random/uuid')"
    local alterid=`shuf -i50-80 -n1`
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vmess",
    "settings": {
      "clients": [
        {
          "id": "$uuid",
          "level": 1,
          "alterId": $alterid
        }
      ]
    },
    "streamSettings": {
        "network": "mkcp",
        "kcpSettings": {
            "uplinkCapacity": 100,
            "downlinkCapacity": 100,
            "congestion": true,
            "header": {
                "type": "$HEADER_TYPE"
            },
            "seed": "$SEED"
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

vmessTLSConfig() {
    local uuid="$(cat '/proc/sys/kernel/random/uuid')"
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vmess",
    "settings": {
      "clients": [
        {
          "id": "$uuid",
          "level": 1,
          "alterId": 0
        }
      ],
      "disableInsecureEncryption": false
    },
    "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": "$DOMAIN",
            "alpn": ["http/1.1", "h2"],
            "certificates": [
                {
                    "certificateFile": "$CERT_FILE",
                    "keyFile": "$KEY_FILE"
                }
            ]
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

vmessWSConfig() {
    local uuid="$(cat '/proc/sys/kernel/random/uuid')"
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $V2PORT,
    "listen": "127.0.0.1",
    "protocol": "vmess",
    "settings": {
      "clients": [
        {
          "id": "$uuid",
          "level": 1,
          "alterId": 0
        }
      ],
      "disableInsecureEncryption": false
    },
    "streamSettings": {
        "network": "ws",
        "wsSettings": {
            "path": "$WSPATH",
            "headers": {
                "Host": "$DOMAIN"
            }
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

vlessTLSConfig() {
    local uuid="$(cat '/proc/sys/kernel/random/uuid')"
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": "$uuid",
          "level": 0
        }
      ],
      "decryption": "none",
      "fallbacks": [
          {
              "alpn": "http/1.1",
              "dest": 80
          },
          {
              "alpn": "h2",
              "dest": 81
          }
      ]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": "$DOMAIN",
            "alpn": ["http/1.1", "h2"],
            "certificates": [
                {
                    "certificateFile": "$CERT_FILE",
                    "keyFile": "$KEY_FILE"
                }
            ]
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

vlessXTLSConfig() {
    local uuid="$(cat '/proc/sys/kernel/random/uuid')"
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": "$uuid",
          "flow": "$FLOW",
          "level": 0
        }
      ],
      "decryption": "none",
      "fallbacks": [
          {
              "alpn": "http/1.1",
              "dest": 80
          },
          {
              "alpn": "h2",
              "dest": 81
          }
      ]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "xtls",
        "xtlsSettings": {
            "serverName": "$DOMAIN",
            "alpn": ["http/1.1", "h2"],
            "certificates": [
                {
                    "certificateFile": "$CERT_FILE",
                    "keyFile": "$KEY_FILE"
                }
            ]
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

vlessWSConfig() {
    local uuid="$(cat '/proc/sys/kernel/random/uuid')"
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $V2PORT,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
        "clients": [
            {
                "id": "$uuid",
                "level": 0
            }
        ],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
            "path": "$WSPATH",
            "headers": {
                "Host": "$DOMAIN"
            }
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

vlessKCPConfig() {
    local uuid="$(cat '/proc/sys/kernel/random/uuid')"
    cat > $CONFIG_FILE<<-EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [
        {
          "id": "$uuid",
          "level": 0
        }
      ],
      "decryption": "none"
    },
    "streamSettings": {
        "streamSettings": {
            "network": "mkcp",
            "kcpSettings": {
                "uplinkCapacity": 100,
                "downlinkCapacity": 100,
                "congestion": true,
                "header": {
                    "type": "$HEADER_TYPE"
                },
                "seed": "$SEED"
            }
        }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {}
  },{
    "protocol": "blackhole",
    "settings": {},
    "tag": "blocked"
  }]
}
EOF
}

configV2ray() {
    mkdir -p /etc/v2ray
    if [[ "$TROJAN" = "true" ]]; then
        if [[ "$XTLS" = "true" ]]; then
            trojanXTLSConfig
        else
            trojanConfig
        fi
        return 0
    fi
    if [[ "$VLESS" = "false" ]]; then
        # VMESS + kcp
        if [[ "$KCP" = "true" ]]; then
            vmessKCPConfig
            return 0
        fi
        # VMESS
        if [[ "$TLS" = "false" ]]; then
            vmessConfig
        elif [[ "$WS" = "false" ]]; then
            # VMESS+TCP+TLS
            vmessTLSConfig
        # VMESS+WS+TLS
        else
            vmessWSConfig
        fi
    #VLESS
    else
        if [[ "$KCP" = "true" ]]; then
            vlessKCPConfig
            return 0
        fi
        # VLESS+TCP
        if [[ "$WS" = "false" ]]; then
            # VLESS+TCP+TLS
            if [[ "$XTLS" = "false" ]]; then
                vlessTLSConfig
            # VLESS+TCP+XTLS
            else
                vlessXTLSConfig
            fi
        # VLESS+WS+TLS
        else
            vlessWSConfig
        fi
    fi
}

install() {
    getData

    aptRefresh
    #echo $CMD_UPGRADE | bash
    safeInstall wget vim unzip tar gcc openssl
    safeInstall net-tools
    if [[ "$PMT" = "apt" ]]; then
        safeInstall libssl-dev g++
    fi
    res=`which unzip 2>/dev/null`
    if [[ $? -ne 0 ]]; then
        colorEcho $RED " unzip安装失败，请检查网络"
        exit 1
    fi

    installNginx
    setFirewall
    if [[ "$TLS" = "true" || "$XTLS" = "true" ]]; then
        getCert
    fi
    configNginx

    colorEcho $BLUE " 安装V2ray..."
    getVersion
    RETVAL="$?"
    if [[ $RETVAL == 0 ]]; then
        colorEcho $BLUE " V2ray最新版 ${CUR_VER} 已经安装"
    elif [[ $RETVAL == 3 ]]; then
        exit 1
    else
        colorEcho $BLUE " 安装V2Ray ${NEW_VER} ，架构$(archAffix)"
        installV2ray
    fi

    configV2ray

    setSelinux
    installBBR

    start
    showInfo

    bbrReboot

    installMonitor
}

bbrReboot() {
    if [[ "${INSTALL_BBR}" == "true" ]]; then
        echo  
        echo " 为使BBR模块生效，系统将在30秒后重启"
        echo  
        echo -e " 您可以按 ctrl + c 取消重启，稍后输入 ${RED}reboot${PLAIN} 重启系统"
        sleep 30
        reboot
    fi
}

update() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        colorEcho $RED " V2ray未安装，请先安装！"
        return
    fi

    getVersion
    RETVAL="$?"
    if [[ $RETVAL == 0 ]]; then
        colorEcho $BLUE " V2ray最新版 ${CUR_VER} 已经安装"
    elif [[ $RETVAL == 3 ]]; then
        exit 1
    else
        colorEcho $BLUE " 安装V2Ray ${NEW_VER} ，架构$(archAffix)"
        installV2ray
        stop
        start

        colorEcho $GREEN " 最新版V2ray安装成功！"
    fi
}

uninstall() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        colorEcho $RED " V2ray未安装，请先安装！"
        return
    fi

    echo ""
    read -p " 确定卸载V2ray？[y/n]：" answer
    if [[ "${answer,,}" = "y" ]]; then
        domain=`grep Host $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
        if [[ "$domain" = "" ]]; then
            domain=`grep serverName $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
        fi
        
        stop
        systemctl disable v2ray
        rm -rf $SERVICE_FILE
        rm -rf /etc/v2ray
        rm -rf /usr/bin/v2ray

        if [[ "$BT" = "false" ]]; then
            systemctl disable nginx
            $CMD_REMOVE nginx
            if [[ "$PMT" = "apt" ]]; then
                $CMD_REMOVE nginx-common
            fi
            rm -rf /etc/nginx/nginx.conf
            if [[ -f /etc/nginx/nginx.conf.bak ]]; then
                mv /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
            fi
        fi
        if [[ "$domain" != "" ]]; then
            rm -rf $NGINX_CONF_PATH${domain}.conf
        fi
        [[ -f ~/.acme.sh/acme.sh ]] && ~/.acme.sh/acme.sh --uninstall
        # 清理私密文件访问记录服务
        systemctl disable --now v2ray-link-log.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/v2ray-link-log.service /etc/logrotate.d/v2ray-link /usr/local/sbin/v2ray-link-log.sh
        systemctl daemon-reload
        uninstallMonitor
        colorEcho $GREEN " V2ray卸载成功"
    fi
}

start() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        colorEcho $RED " V2ray未安装，请先安装！"
        return
    fi
    stopNginx
    startNginx
    systemctl restart v2ray
    sleep 2
    port=`grep port $CONFIG_FILE| head -n 1| cut -d: -f2| tr -d \",' '`
    res=`ss -nutlp| grep ${port} | grep -i v2ray`
    if [[ "$res" = "" ]]; then
        colorEcho $RED " v2ray启动失败，请检查日志或查看端口是否被占用！"
    else
        colorEcho $BLUE " v2ray启动成功"
    fi
}

stop() {
    stopNginx
    systemctl stop v2ray
    colorEcho $BLUE " V2ray停止成功"
}


restart() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        colorEcho $RED " V2ray未安装，请先安装！"
        return
    fi

    stop
    start
}

getConfigFileInfo() {
    vless="false"
    tls="false"
    ws="false"
    xtls="false"
    trojan="false"
    protocol="VMess"
    kcp="false"

    uid=`grep id $CONFIG_FILE | head -n1| cut -d: -f2 | tr -d \",' '`
    alterid=`grep alterId $CONFIG_FILE  | cut -d: -f2 | tr -d \",' '`
    network=`grep network $CONFIG_FILE  | tail -n1| cut -d: -f2 | tr -d \",' '`
    [[ -z "$network" ]] && network="tcp"
    domain=`grep serverName $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
    if [[ "$domain" = "" ]]; then
        domain=`grep Host $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
        if [[ "$domain" != "" ]]; then
            ws="true"
            tls="true"
            wspath=`grep path $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
        fi
    else
        tls="true"
    fi
    if [[ "$ws" = "true" ]]; then
        port=`grep -i ssl $NGINX_CONF_PATH${domain}.conf| head -n1 | awk '{print $2}'`
    else
        port=`grep port $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
    fi
    res=`grep -i kcp $CONFIG_FILE`
    if [[ "$res" != "" ]]; then
        kcp="true"
        type=`grep header -A 3 $CONFIG_FILE | grep 'type' | cut -d: -f2 | tr -d \",' '`
        seed=`grep seed $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
    fi

    vmess=`grep vmess $CONFIG_FILE`
    if [[ "$vmess" = "" ]]; then
        trojan=`grep trojan $CONFIG_FILE`
        if [[ "$trojan" = "" ]]; then
            vless="true"
            protocol="VLESS"
        else
            trojan="true"
            password=`grep password $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
            protocol="trojan"
        fi
        tls="true"
        encryption="none"
        xtls=`grep xtlsSettings $CONFIG_FILE`
        if [[ "$xtls" != "" ]]; then
            xtls="true"
            flow=`grep flow $CONFIG_FILE | cut -d: -f2 | tr -d \",' '`
        else
            flow="无"
        fi
    fi
}

outputVmess() {
    raw="{
  \"v\":\"2\",
  \"ps\":\"\",
  \"add\":\"$IP\",
  \"port\":\"${port}\",
  \"id\":\"${uid}\",
  \"aid\":\"$alterid\",
  \"net\":\"tcp\",
  \"type\":\"none\",
  \"host\":\"\",
  \"path\":\"\",
  \"tls\":\"\"
}"
    link=`echo -n ${raw} | base64 -w 0`
    link="vmess://${link}"

    echo -e "   ${BLUE}IP(address): ${PLAIN} ${RED}${IP}${PLAIN}"
    echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
    echo -e "   ${BLUE}id(uuid)：${PLAIN}${RED}${uid}${PLAIN}"
    echo -e "   ${BLUE}额外id(alterid)：${PLAIN} ${RED}${alterid}${PLAIN}"
    echo -e "   ${BLUE}加密方式(security)：${PLAIN} ${RED}auto${PLAIN}"
    echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}" 
    echo  
    echo -e "   ${BLUE}vmess链接:${PLAIN} $RED$link$PLAIN"
}

outputVmessKCP() {
    echo -e "   ${BLUE}IP(address): ${PLAIN} ${RED}${IP}${PLAIN}"
    echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
    echo -e "   ${BLUE}id(uuid)：${PLAIN}${RED}${uid}${PLAIN}"
    echo -e "   ${BLUE}额外id(alterid)：${PLAIN} ${RED}${alterid}${PLAIN}"
    echo -e "   ${BLUE}加密方式(security)：${PLAIN} ${RED}auto${PLAIN}"
    echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}"
    echo -e "   ${BLUE}伪装类型(type)：${PLAIN} ${RED}${type}${PLAIN}"
    echo -e "   ${BLUE}mkcp seed：${PLAIN} ${RED}${seed}${PLAIN}" 
}

outputTrojan() {
    if [[ "$xtls" = "true" ]]; then
        echo -e "   ${BLUE}IP/域名(address): ${PLAIN} ${RED}${domain}${PLAIN}"
        echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
        echo -e "   ${BLUE}密码(password)：${PLAIN}${RED}${password}${PLAIN}"
        echo -e "   ${BLUE}流控(flow)：${PLAIN}$RED$flow${PLAIN}"
        echo -e "   ${BLUE}加密(encryption)：${PLAIN} ${RED}none${PLAIN}"
        echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}" 
        echo -e "   ${BLUE}底层安全传输(tls)：${PLAIN}${RED}XTLS${PLAIN}"
    else
        echo -e "   ${BLUE}IP/域名(address): ${PLAIN} ${RED}${domain}${PLAIN}"
        echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
        echo -e "   ${BLUE}密码(password)：${PLAIN}${RED}${password}${PLAIN}"
        echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}" 
        echo -e "   ${BLUE}底层安全传输(tls)：${PLAIN}${RED}TLS${PLAIN}"
    fi
}

outputVmessTLS() {
    raw="{
  \"v\":\"2\",
  \"ps\":\"\",
  \"add\":\"$IP\",
  \"port\":\"${port}\",
  \"id\":\"${uid}\",
  \"aid\":\"$alterid\",
  \"net\":\"${network}\",
  \"type\":\"none\",
  \"host\":\"${domain}\",
  \"path\":\"\",
  \"tls\":\"tls\"
}"
    link=`echo -n ${raw} | base64 -w 0`
    link="vmess://${link}"
    echo -e "   ${BLUE}IP(address): ${PLAIN} ${RED}${IP}${PLAIN}"
    echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
    echo -e "   ${BLUE}id(uuid)：${PLAIN}${RED}${uid}${PLAIN}"
    echo -e "   ${BLUE}额外id(alterid)：${PLAIN} ${RED}${alterid}${PLAIN}"
    echo -e "   ${BLUE}加密方式(security)：${PLAIN} ${RED}none${PLAIN}"
    echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}" 
    echo -e "   ${BLUE}伪装域名/主机名(host)/SNI/peer名称：${PLAIN}${RED}${domain}${PLAIN}"
    echo -e "   ${BLUE}底层安全传输(tls)：${PLAIN}${RED}TLS${PLAIN}"
    echo  
    echo -e "   ${BLUE}vmess链接: ${PLAIN}$RED$link$PLAIN"
}

outputVmessWS() {
    raw="{
  \"v\":\"2\",
  \"ps\":\"\",
  \"add\":\"$IP\",
  \"port\":\"${port}\",
  \"id\":\"${uid}\",
  \"aid\":\"$alterid\",
  \"net\":\"${network}\",
  \"type\":\"none\",
  \"host\":\"${domain}\",
  \"path\":\"${wspath}\",
  \"tls\":\"tls\"
}"
    link=`echo -n ${raw} | base64 -w 0`
    link="vmess://${link}"

    echo -e "   ${BLUE}IP(address): ${PLAIN} ${RED}${IP}${PLAIN}"
    echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
    echo -e "   ${BLUE}id(uuid)：${PLAIN}${RED}${uid}${PLAIN}"
    echo -e "   ${BLUE}额外id(alterid)：${PLAIN} ${RED}${alterid}${PLAIN}"
    echo -e "   ${BLUE}加密方式(security)：${PLAIN} ${RED}none${PLAIN}"
    echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}" 
    echo -e "   ${BLUE}伪装类型(type)：${PLAIN}${RED}none$PLAIN"
    echo -e "   ${BLUE}伪装域名/主机名(host)/SNI/peer名称：${PLAIN}${RED}${domain}${PLAIN}"
    echo -e "   ${BLUE}路径(path)：${PLAIN}${RED}${wspath}${PLAIN}"
    echo -e "   ${BLUE}底层安全传输(tls)：${PLAIN}${RED}TLS${PLAIN}"
    echo  
    echo -e "   ${BLUE}vmess链接:${PLAIN} $RED$link$PLAIN"
}

# 打印随机私密链接（未生成时静默跳过）
showLinkInfo() {
    local name token link_host
    [[ -s "$LINK_STATE" && -s "$TOKEN_STATE" ]] || return 0
    name=$(<"$LINK_STATE")
    token=$(<"$TOKEN_STATE")
    [[ -n "$name" && -n "$token" ]] || return 0
    link_host=${domain:-$IP}
    [[ "$port" = "443" ]] || link_host="$link_host:$port"
    echo ""
    echo -e "   ${BLUE}私密链接(请勿公开): ${PLAIN}${RED}https://${link_host}/${name}?k=${token}${PLAIN}"
    echo -e "   ${BLUE}链接备份: ${PLAIN}${RED}/etc/v2ray/link.txt${PLAIN}"
    echo -e "   ${BLUE}访问记录: ${PLAIN}${RED}/usr/share/nginx/html/web.log${PLAIN}"
}

showInfo() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        colorEcho $RED " V2ray未安装，请先安装！"
        return
    fi

    echo ""
    echo -n -e " ${BLUE}V2ray运行状态：${PLAIN}"
    statusText
    echo -e " ${BLUE}V2ray配置文件: ${PLAIN} ${RED}${CONFIG_FILE}${PLAIN}"
    colorEcho $BLUE " V2ray配置信息："

    getConfigFileInfo
    showLinkInfo

    echo -e "   ${BLUE}协议: ${PLAIN} ${RED}${protocol}${PLAIN}"
    if [[ "$trojan" = "true" ]]; then
        outputTrojan
        return 0
    fi
    if [[ "$vless" = "false" ]]; then
        if [[ "$kcp" = "true" ]]; then
            outputVmessKCP
            return 0
        fi
        if [[ "$tls" = "false" ]]; then
            outputVmess
        elif [[ "$ws" = "false" ]]; then
            outputVmessTLS
        else
            outputVmessWS
        fi
    else
        if [[ "$kcp" = "true" ]]; then
            echo -e "   ${BLUE}IP(address): ${PLAIN} ${RED}${IP}${PLAIN}"
            echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
            echo -e "   ${BLUE}id(uuid)：${PLAIN}${RED}${uid}${PLAIN}"
            echo -e "   ${BLUE}加密(encryption)：${PLAIN} ${RED}none${PLAIN}"
            echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}"
            echo -e "   ${BLUE}伪装类型(type)：${PLAIN} ${RED}${type}${PLAIN}"
            echo -e "   ${BLUE}mkcp seed：${PLAIN} ${RED}${seed}${PLAIN}" 
            return 0
        fi
        if [[ "$xtls" = "true" ]]; then
            echo -e "   ${BLUE}IP(address): ${PLAIN} ${RED}${IP}${PLAIN}"
            echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
            echo -e "   ${BLUE}id(uuid)：${PLAIN}${RED}${uid}${PLAIN}"
            echo -e "   ${BLUE}流控(flow)：${PLAIN}$RED$flow${PLAIN}"
            echo -e "   ${BLUE}加密(encryption)：${PLAIN} ${RED}none${PLAIN}"
            echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}" 
            echo -e "   ${BLUE}伪装类型(type)：${PLAIN}${RED}none$PLAIN"
            echo -e "   ${BLUE}伪装域名/主机名(host)/SNI/peer名称：${PLAIN}${RED}${domain}${PLAIN}"
            echo -e "   ${BLUE}底层安全传输(tls)：${PLAIN}${RED}XTLS${PLAIN}"
        elif [[ "$ws" = "false" ]]; then
            echo -e "   ${BLUE}IP(address):  ${PLAIN}${RED}${IP}${PLAIN}"
            echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
            echo -e "   ${BLUE}id(uuid)：${PLAIN}${RED}${uid}${PLAIN}"
            echo -e "   ${BLUE}流控(flow)：${PLAIN}$RED$flow${PLAIN}"
            echo -e "   ${BLUE}加密(encryption)：${PLAIN} ${RED}none${PLAIN}"
            echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}" 
            echo -e "   ${BLUE}伪装类型(type)：${PLAIN}${RED}none$PLAIN"
            echo -e "   ${BLUE}伪装域名/主机名(host)/SNI/peer名称：${PLAIN}${RED}${domain}${PLAIN}"
            echo -e "   ${BLUE}底层安全传输(tls)：${PLAIN}${RED}TLS${PLAIN}"
        else
            echo -e "   ${BLUE}IP(address): ${PLAIN} ${RED}${IP}${PLAIN}"
            echo -e "   ${BLUE}端口(port)：${PLAIN}${RED}${port}${PLAIN}"
            echo -e "   ${BLUE}id(uuid)：${PLAIN}${RED}${uid}${PLAIN}"
            echo -e "   ${BLUE}流控(flow)：${PLAIN}$RED$flow${PLAIN}"
            echo -e "   ${BLUE}加密(encryption)：${PLAIN} ${RED}none${PLAIN}"
            echo -e "   ${BLUE}传输协议(network)：${PLAIN} ${RED}${network}${PLAIN}" 
            echo -e "   ${BLUE}伪装类型(type)：${PLAIN}${RED}none$PLAIN"
            echo -e "   ${BLUE}伪装域名/主机名(host)/SNI/peer名称：${PLAIN}${RED}${domain}${PLAIN}"
            echo -e "   ${BLUE}路径(path)：${PLAIN}${RED}${wspath}${PLAIN}"
            echo -e "   ${BLUE}底层安全传输(tls)：${PLAIN}${RED}TLS${PLAIN}"
        fi
    fi
}

showLog() {
    res=`status`
    if [[ $res -lt 2 ]]; then
        colorEcho $RED " V2ray未安装，请先安装！"
        return
    fi

    journalctl -xen -u v2ray --no-pager
}

MONITOR_SCRIPT="/usr/local/bin/check_v2ray_services.sh"
CRON_MARK="# v2ray-service-monitor"

installMonitor() {
    colorEcho $BLUE " 安装服务守护脚本..."

    # 写入监控脚本，兼容 systemd nginx 和宝塔 nginx
    cat > $MONITOR_SCRIPT <<-EOF
#!/bin/bash
LOG="/var/log/check_v2ray_services.log"
CERT_LOCK="/tmp/v2ray_cert_renewing"

check_restart() {
    local name=\$1
    local check_cmd=\$2
    local restart_cmd=\$3
    if ! eval "\$check_cmd" >/dev/null 2>&1; then
        echo "[\$(date '+%F %T')] \$name 未运行，正在重启..." >> \$LOG
        eval "\$restart_cmd" >> \$LOG 2>&1
    fi
}

check_restart "v2ray" "systemctl is-active --quiet v2ray" "systemctl restart v2ray"

# 证书续签期间 acme.sh standalone 模式会临时停 nginx，跳过避免冲突
if [[ -f "\$CERT_LOCK" ]]; then
    echo "[\$(date '+%F %T')] 证书续签中，跳过 nginx 检查" >> \$LOG
else
    if systemctl list-unit-files | grep -q '^nginx.service'; then
        check_restart "nginx" "systemctl is-active --quiet nginx" "systemctl restart nginx"
    else
        check_restart "nginx" "pgrep -x nginx" "nginx -c /www/server/nginx/conf/nginx.conf || true"
    fi
fi
EOF
    chmod +x $MONITOR_SCRIPT

    # 确保 cron 服务在运行
    if [[ "$PMT" = "yum" ]]; then
        systemctl start crond 2>/dev/null
        systemctl enable crond 2>/dev/null
    else
        systemctl start cron 2>/dev/null
        systemctl enable cron 2>/dev/null
    fi

    # 幂等追加 crontab：先去掉旧的同名条目，再追加新的。不影响其它条目
    local cron_line="* * * * * $MONITOR_SCRIPT $CRON_MARK"
    local existing=`crontab -l 2>/dev/null | grep -F "$CRON_MARK" || true`
    if [[ -n "$existing" ]]; then
        colorEcho $YELLOW "  检测到已有守护任务，先清理旧条目"
        crontab -l 2>/dev/null | grep -v -F "$CRON_MARK" | crontab -
    fi
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -

    colorEcho $GREEN " 服务守护脚本安装完成，每分钟检测一次。日志：/var/log/check_v2ray_services.log"
}

uninstallMonitor() {
    colorEcho $BLUE " 卸载服务守护脚本..."
    crontab -l 2>/dev/null | grep -v -F "$CRON_MARK" | crontab -
    rm -f $MONITOR_SCRIPT
    colorEcho $GREEN " 服务守护脚本已卸载"
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#                   ${RED}v2ray一键安装脚本${PLAIN}                      #"
    echo -e "#                   ${GREEN}修改版${PLAIN}:  勇友i                          #"
    echo "#############################################################"

   echo -e "  ${GREEN}1.${PLAIN}   安装V2ray-VMESS"
    echo -e "  ${GREEN}2.${PLAIN}   安装V2ray-${BLUE}VMESS+mKCP${PLAIN}"
   echo -e "  ${GREEN}3.${PLAIN}   安装V2ray-VMESS+TCP+TLS"
    echo -e "  ${GREEN}4.${PLAIN}   安装V2ray-${BLUE}VMESS+WS+TLS${PLAIN}${RED}(推荐)${PLAIN}"
    echo -e "  ${GREEN}5.${PLAIN}   安装V2ray-${BLUE}VLESS+mKCP${PLAIN}"
    echo -e "  ${GREEN}6.${PLAIN}   安装V2ray-VLESS+TCP+TLS"
    echo -e "  ${GREEN}7.${PLAIN}   安装V2ray-${BLUE}VLESS+WS+TLS${PLAIN}${RED}(可过cdn)${PLAIN}"
    echo -e "  ${GREEN}8.${PLAIN}   安装V2ray-${BLUE}VLESS+TCP+XTLS${PLAIN}${RED}(推荐)${PLAIN}"
    echo -e "  ${GREEN}9.${PLAIN}   安装${BLUE}trojan${PLAIN}${RED}(推荐)${PLAIN}"
    echo -e "  ${GREEN}10.${PLAIN}  安装${BLUE}trojan+XTLS${PLAIN}${RED}(推荐)${PLAIN}"
    echo " -------------"
    echo -e "  ${GREEN}11.${PLAIN}  更新V2ray"
    echo -e "  ${GREEN}12.  ${RED}卸载V2ray${PLAIN}"
    echo " -------------"
    echo -e "  ${GREEN}13.${PLAIN}  启动V2ray"
    echo -e "  ${GREEN}14.${PLAIN}  重启V2ray"
    echo -e "  ${GREEN}15.${PLAIN}  停止V2ray"
    echo " -------------"
    echo -e "  ${GREEN}16.${PLAIN}  查看V2ray配置"
    echo -e "  ${GREEN}17.${PLAIN}  查看V2ray日志"
    echo " -------------"
    echo -e "  ${GREEN}18.${PLAIN}  安装服务守护(Nginx+V2ray挂了自动拉起)"
    echo -e "  ${GREEN}19.${PLAIN}  卸载服务守护"
    echo " -------------"
    echo -e "  ${GREEN}0.${PLAIN}   退出"
    echo -n " 当前状态："
    statusText
    echo 

    read -p " 请选择操作[0-19]：" answer
    case $answer in
        0)
            exit 0
            ;;
        1)
            install
            ;;
        2)
            KCP="true"
            install
            ;;
        3)
            TLS="true"
            install
            ;;
        4)
            TLS="true"
            WS="true"
            install
            ;;
        5)
            VLESS="true"
            KCP="true"
            install
            ;;
        6)
            VLESS="true"
            TLS="true"
            install
            ;;
        7)
            VLESS="true"
            TLS="true"
            WS="true"
            install
            ;;
        8)
            VLESS="true"
            TLS="true"
            XTLS="true"
            install
            ;;
        9)
            TROJAN="true"
            TLS="true"
            install
            ;;
        10)
            TROJAN="true"
            TLS="true"
            XTLS="true"
            install
            ;;
        11)
            update
            ;;
        12)
            uninstall
            ;;
        13)
            start
            ;;
        14)
            restart
            ;;
        15)
            stop
            ;;
        16)
            showInfo
            ;;
        17)
            showLog
            ;;
        18)
            installMonitor
            ;;
        19)
            uninstallMonitor
            ;;
        *)
            colorEcho $RED " 请选择正确的操作！"
            exit 1
            ;;
    esac
}

checkSystem

action=$1
[[ -z $1 ]] && action=menu
case "$action" in
    menu|update|uninstall|start|restart|stop|showInfo|showLog|installMonitor|uninstallMonitor)
        ${action}
        ;;
    *)
        echo " 参数错误"
        echo " 用法: `basename $0` [menu|update|uninstall|start|restart|stop|showInfo|showLog|installMonitor|uninstallMonitor]"
        ;;
esac
