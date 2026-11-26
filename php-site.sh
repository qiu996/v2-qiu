#!/usr/bin/env bash
# 一键搭建 Nginx + PHP + HTTPS 网站
# 用法：bash php-site.sh          进入菜单
#       bash php-site.sh install  直接安装
# 特性：输入域名自动申请证书；acme.sh 定时任务自动续签；webroot 验证，不停机、签发快。
set -o pipefail

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[36m"; PLAIN="\033[0m"

DOMAIN=""
EMAIL=""
WEBROOT=""
PHP_VER=""
PHP_SOCK=""
PHP_SVC=""
WEB_USER=""
PKG=""
CERT_DIR="/etc/nginx/ssl"
NGINX_SITE="/etc/nginx/conf.d"
STATE_DIR="/etc/php-site"
STATE_FILE="$STATE_DIR/site.state"
ACME="$HOME/.acme.sh/acme.sh"

colorEcho() { echo -e "${1}${@:2}${PLAIN}"; }
say()   { echo ""; colorEcho "$BLUE" " $*"; }
ok()    { colorEcho "$GREEN" " ✔ $*"; }
warn()  { colorEcho "$YELLOW" " ! $*"; }
die()   { colorEcho "$RED" " ✘ $*"; exit 1; }
has()   { command -v "$1" >/dev/null 2>&1; }

# 读取本脚本上次部署记录
state_get() { [[ -f "$STATE_FILE" ]] && awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1);exit}' "$STATE_FILE"; }

checkSystem() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行：sudo bash $0"
    if has apt-get; then
        PKG="apt"
    elif has dnf; then
        PKG="dnf"
    elif has yum; then
        PKG="yum"
    else
        die "不受支持的 Linux 系统（未找到 apt/dnf/yum）"
    fi
    has systemctl || die "系统缺少 systemd，本脚本不支持"
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|aarch64|arm64|amd64) : ;;
        *) die "未适配的 CPU 架构：$arch" ;;
    esac
}

valid_domain() {
    local n="$1"
    [[ ${#n} -le 253 && "$n" == *.* && "$n" != *..* ]] || return 1
    [[ "$n" =~ ^[a-z0-9.-]+$ && ! "$n" =~ ^[0-9.]+$ ]] || return 1
    [[ "$n" != .* && "$n" != *. ]] || return 1
    local label; local -a labels
    IFS=. read -r -a labels <<< "$n"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

valid_email() { [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }

public_ip() {
    local ip
    ip=$(curl -4 -sL --max-time 8 https://api.ipify.org 2>/dev/null)
    [[ -n "$ip" ]] || ip=$(curl -4 -sL --max-time 8 https://ip.sb 2>/dev/null)
    echo "$ip"
}

check_dns() {
    local ip resolve
    ip=$(public_ip)
    resolve=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    [[ -z "$resolve" ]] && resolve=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | tr '\n' ' ')
    if [[ -z "$resolve" ]]; then
        warn "无法解析 $DOMAIN，请确认 A 记录已添加并生效"
        read -r -p " 仍要继续吗？[y/N]：" a; [[ "${a,,}" == "y" ]] || exit 1
        return 0
    fi
    if [[ -n "$ip" && "$resolve" != *"$ip"* ]]; then
        warn "$DOMAIN 当前解析：$resolve"
        warn "本机公网 IP：$ip（不一致时证书申请会失败，且不要开启 CDN 代理）"
        read -r -p " 仍要继续吗？[y/N]：" a; [[ "${a,,}" == "y" ]] || exit 1
    else
        ok "域名解析指向本机：$resolve"
    fi
}

ask_info() {
    local def_domain def_email answer
    def_domain=$(state_get domain)
    def_email=$(state_get email)
    while true; do
        read -r -p " 网站域名（只填域名，如 example.com）${def_domain:+ [$def_domain]}：" answer
        answer=${answer//[[:space:]]/}
        DOMAIN=${answer:-$def_domain}
        DOMAIN=${DOMAIN,,}
        if valid_domain "$DOMAIN"; then break; fi
        colorEcho "$RED" " 域名格式不正确，不要带 https:// 、端口或路径"
    done
    while true; do
        read -r -p " 证书联系邮箱（可留空）${def_email:+ [$def_email]}：" answer
        EMAIL=${answer:-$def_email}
        if [[ -z "$EMAIL" ]] || valid_email "$EMAIL"; then break; fi
        colorEcho "$RED" " 邮箱格式不正确，请重新输入或直接回车留空"
    done
    read -r -p " 是否安装 BBR 加速（默认已开则跳过）？[Y/n]：" answer
    NEED_BBR=${answer:-y}; NEED_BBR=${NEED_BBR,,}
    [[ "$NEED_BBR" != "n" ]] && NEED_BBR=y
    WEBROOT="/var/www/$DOMAIN"
    colorEcho "$BLUE" " 域名：$DOMAIN    网页目录：$WEBROOT"
}
installPackages() {
    say "安装 Nginx / PHP-FPM / 依赖（首次较慢，之后可秒装）"
    if [[ "$PKG" == "apt" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y -qq
        apt-get install -y -qq --no-install-recommends \
            nginx php-fpm php-mysql php-curl php-gd php-mbstring php-xml \
            php-zip php-opcache curl unzip ca-certificates cron \
            || die "软件包安装失败，请检查软件源与网络"
    else
        local pm="$PKG"
        $pm install -y nginx php-fpm php-mysqlnd php-gd php-mbstring php-xml \
            php-zip php-opcache curl unzip ca-certificates cronie \
            || die "软件包安装失败，请检查软件源与网络"
    fi
    ok "软件包安装完成"
}

installAcme() {
    if [[ -x "$ACME" ]]; then
        ok "已安装 acme.sh（$ACME）"
    else
        say "安装 acme.sh（证书申请与自动续签工具）"
        local email="${EMAIL:-admin@$DOMAIN}"
        curl -sL --max-time 60 https://get.acme.sh | sh -s email="$email" >/dev/null 2>&1 \
            || die "acme.sh 安装失败，请检查网络"
        [[ -x "$ACME" ]] || die "acme.sh 安装后未找到可执行文件"
    fi
    "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

# 找出 php-fpm 的 socket、服务名与版本
detectPhp() {
    local sock svc
    if [[ "$PKG" == "apt" ]]; then
        sock=$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | head -n1)
        if [[ -z "$sock" ]]; then
            svc=$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | head -n1)
            [[ -n "$svc" ]] && { systemctl enable --now "$svc" >/dev/null 2>&1; sleep 1; }
            sock=$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | head -n1)
        fi
        [[ -n "$sock" ]] || die "未找到 php-fpm socket，请检查 PHP 是否安装成功"
        PHP_SVC=$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | head -n1)
        PHP_SVC=${PHP_SVC:-php-fpm}
        PHP_VER=$(basename "$sock"); PHP_VER=${PHP_VER%-fpm.sock}
        PHP_VER=${PHP_VER#php}
    else
        sock="/run/php-fpm/www.sock"
        PHP_SVC="php-fpm"
        PHP_VER=$(rpm -q --qf '%{VERSION}\n' php-fpm 2>/dev/null | head -n1 | cut -d. -f1,2)
        systemctl enable --now php-fpm >/dev/null 2>&1 || true
        # RHEL 系 nginx 与 php-fpm 用户不同，需让 nginx 加入 apache 组才能连上 socket
        if id apache >/dev/null 2>&1 && id nginx >/dev/null 2>&1; then
            usermod -aG apache nginx >/dev/null 2>&1 || true
            systemctl restart nginx >/dev/null 2>&1 || true
        fi
    fi
    PHP_SOCK="$sock"
    ok "PHP-FPM：${PHP_VER:-未知版本}，socket：$PHP_SOCK"
}

detectWebUser() {
    if id www-data >/dev/null 2>&1; then WEB_USER="www-data"; else WEB_USER="nginx"; fi
}

prepareWebroot() {
    mkdir -p /var/www
    mkdir -p "$WEBROOT/.well-known/acme-challenge" "$CERT_DIR" "$STATE_DIR"
    chown -R "$WEB_USER":"$WEB_USER" "$WEBROOT"
    chmod 755 "$WEBROOT"
    # 默认首页仅在不存在时生成，避免覆盖已有网站内容
    if [[ ! -f "$WEBROOT/index.php" && ! -f "$WEBROOT/index.html" ]]; then
        cat > "$WEBROOT/index.php" <<'PHPEOF'
<?php
$phpv = PHP_VERSION;
echo "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">";
echo "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">";
echo "<title>网站已就绪</title><style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0f172a;color:#e2e8f0;font-family:system-ui,-apple-system,\"Segoe UI\",Roboto,sans-serif}";
echo ".card{text-align:center;padding:48px 56px;border-radius:18px;background:#1e293b;box-shadow:0 20px 60px rgba(0,0,0,.45)}";
echo "h1{margin:0 0 12px;font-size:26px;color:#38bdf8}p{margin:6px 0;color:#94a3b8;font-size:15px}code{color:#fbbf24}</style></head><body>";
echo "<div class=\"card\"><h1>网站已成功部署</h1><p>Nginx + PHP-FPM + HTTPS 运行中</p>";
echo "<p>PHP 版本：<code>", htmlspecialchars($phpv), "</code></p>";
echo "<p>把网站文件上传到本目录即可，默认访问 index.php 或 index.html</p></div></body></html>";
PHPEOF
        chown "$WEB_USER":"$WEB_USER" "$WEBROOT/index.php"
    fi
    ok "网页目录准备完成：$WEBROOT"
}

# 先仅监听 80，保证 acme 的 HTTP-01 验证可访问；签完证书再启用 443
writeHttpOnlyConf() {
    cat > "$NGINX_SITE/$DOMAIN.conf" <<EOF
# Managed by php-site.sh
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $WEBROOT;
    index index.php index.html;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    nginx -t >/dev/null 2>&1 || die "Nginx 配置校验失败：nginx -t 查看详情"
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || die "Nginx 启动失败：journalctl -u nginx -n 30"
}
copyCertToRoot() {
    local crt="$1" key="$2"
    cp -f "$crt" "/root/$DOMAIN.crt" && chmod 644 "/root/$DOMAIN.crt" || return 1
    cp -f "$key" "/root/$DOMAIN.key" && chmod 600 "/root/$DOMAIN.key" || return 1
    ok "证书已复制到：/root/$DOMAIN.crt 与 /root/$DOMAIN.key"
}

issueCert() {
    local crt="$CERT_DIR/$DOMAIN.crt" key="$CERT_DIR/$DOMAIN.key"
    if [[ -s "$crt" && -s "$key" ]]; then
        copyCertToRoot "$crt" "$key" || warn "证书复制到 /root 失败"
        ok "检测到已有证书，跳过申请（需要重签请用菜单第 5 项）"
        return 0
    fi
    say "申请 Let's Encrypt 证书（HTTP-01 验证，通常数秒完成）"
    if ! "$ACME" --issue -d "$DOMAIN" --webroot "$WEBROOT" --keylength ec-256; then
        die "证书申请失败：请确认 80 端口公网可达、域名 A 记录指向本机且未开启 CDN 代理"
    fi
    # 续签时先刷新 /root 副本，再重载 nginx
    "$ACME" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$key" \
        --fullchain-file "$crt" \
        --reloadcmd "cp -f $key /root/$DOMAIN.key; cp -f $crt /root/$DOMAIN.crt; systemctl reload nginx" >/dev/null 2>&1 \
        || die "证书安装失败（生成 $crt / $key）"
    chmod 600 "$key"; chmod 644 "$crt"
    copyCertToRoot "$crt" "$key" || warn "证书复制到 /root 失败"
    ok "证书申请成功：$crt"
}

enableRenew() {
    # acme.sh 安装时会写入每日 cron 检查，证书剩余约 30 天自动续签；
    # install-cert 的 reloadcmd 会在续签后自动重载 nginx。
    if [[ "$PKG" == "apt" ]]; then
        systemctl enable --now cron >/dev/null 2>&1 || true
    else
        systemctl enable --now crond >/dev/null 2>&1 || true
    fi
    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        ok "自动续签已启用（acme.sh 每日检查，到期自动续签并重载 Nginx）"
    else
        warn "未检测到 acme.sh 定时任务，正在补写"
        ( crontab -l 2>/dev/null; echo '17 3 * * * '"$ACME"' --cron --home "'"$HOME"'/.acme.sh" > /dev/null' ) | crontab -
        ok "已补写每日续签任务"
    fi
}

writeSiteConf() {
    local crt="$CERT_DIR/$DOMAIN.crt" key="$CERT_DIR/$DOMAIN.key"
    cat > "$NGINX_SITE/$DOMAIN.conf" <<EOF
# Managed by php-site.sh
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # 证书续签验证路径必须直接可达，不能跳转
    location /.well-known/acme-challenge/ {
        root $WEBROOT;
        try_files \$uri =404;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    root $WEBROOT;
    index index.php index.html;

    ssl_certificate     $crt;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    client_max_body_size 64m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_index index.php;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|webp|woff2?)\$ {
        expires 30d;
        access_log off;
    }
}
EOF
    nginx -t >/dev/null 2>&1 || { nginx -t; die "Nginx 配置校验失败，请检查上面的错误"; }
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 \
        || die "Nginx 重载失败：journalctl -u nginx -n 30"
    ok "HTTPS 站点配置已生效"
}

installBBR() {
    [[ "$NEED_BBR" == "y" ]] || return 0
    if lsmod 2>/dev/null | grep -q bbr; then ok "BBR 已启用"; return 0; fi
    if hostnamectl 2>/dev/null | grep -qi openvz; then warn "OpenVZ 环境，跳过 BBR"; return 0; fi
    if grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        sysctl -p >/dev/null 2>&1; ok "BBR 参数已存在"; return 0
    fi
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    lsmod 2>/dev/null | grep -q bbr && ok "BBR 已启用" || warn "内核暂不支持 BBR，已写入参数，重启后生效"
}

saveState() {
    cat > "$STATE_FILE" <<EOF
domain=$DOMAIN
email=$EMAIL
webroot=$WEBROOT
php_ver=$PHP_VER
php_sock=$PHP_SOCK
php_svc=$PHP_SVC
web_user=$WEB_USER
pkg=$PKG
EOF
    chmod 600 "$STATE_FILE"
}
loadState() {
    [[ -f "$STATE_FILE" ]] || die "未找到部署记录，请先执行安装"
    DOMAIN=$(state_get domain)
    EMAIL=$(state_get email)
    WEBROOT=$(state_get webroot)
    PHP_VER=$(state_get php_ver)
    PHP_SOCK=$(state_get php_sock)
    PHP_SVC=$(state_get php_svc)
    WEB_USER=$(state_get web_user)
    PKG=$(state_get pkg)
    [[ -n "$DOMAIN" && -n "$WEBROOT" ]] || die "部署记录内容异常：$STATE_FILE"
}

verifySite() {
    local attempt status
    say "验证本机 HTTPS 访问"
    for ((attempt=1; attempt<=15; attempt++)); do
        status=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 4 \
            --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null)
        if [[ "$status" == "200" ]]; then
            ok "验证通过：证书受信任，页面返回 HTTP 200"
            return 0
        fi
        sleep 1
    done
    warn "本机 HTTPS 暂未返回 200（当前：${status:-无响应}），请检查："
    warn "1) 云安全组与本机防火墙是否放行 80/443；2) 域名 A 记录是否已生效且未开 CDN"
    warn "查看日志：journalctl -u nginx -n 50 --no-pager ；journalctl -u $PHP_SVC -n 50 --no-pager"
    return 2
}

showSummary() {
    local enddate
    enddate=$(openssl x509 -in "$CERT_DIR/$DOMAIN.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
    echo ""
    echo "=============================================================="
    colorEcho "$GREEN" " 部署完成！"
    echo "--------------------------------------------------------------"
    echo -e " 网站地址：  ${BLUE}https://$DOMAIN/${PLAIN}"
    echo -e " 网页目录：  $WEBROOT"
    echo -e " PHP 版本：  ${PHP_VER}（$PHP_SVC，socket：$PHP_SOCK）"
    echo -e " 网站配置：  $NGINX_SITE/$DOMAIN.conf"
    echo -e " 证书文件：  $CERT_DIR/$DOMAIN.crt（副本：/root/$DOMAIN.crt、/root/$DOMAIN.key）"
    echo -e " 证书到期：  ${enddate:-未知}"
    echo "--------------------------------------------------------------"
    echo " 自动续签：acme.sh 每日检查，到期前自动续签并重载 Nginx，无需人工干预"
    echo " 上传网站：把 PHP/HTML 文件传到网页目录即可，默认读取 index.php / index.html"
    echo " 防火墙/安全组：请放行 TCP 80 与 443（脚本不改动防火墙）"
    echo " 常用命令：systemctl reload nginx | systemctl restart $PHP_SVC"
    echo "=============================================================="
}

install() {
    local t0 t1
    t0=$(date +%s)
    checkSystem
    say "=== 一键搭建 Nginx + PHP + HTTPS 网站 ==="
    ask_info

    installPackages
    check_dns
    detectWebUser
    prepareWebroot
    # 先让 80 端口可访问，供证书 HTTP-01 验证（全程不停 Nginx，签发更快）
    if [[ -s "$CERT_DIR/$DOMAIN.crt" && -s "$CERT_DIR/$DOMAIN.key" ]]; then
        ok "检测到已有证书，跳过 HTTP 预配置"
    else
        writeHttpOnlyConf
    fi
    installAcme
    issueCert
    detectPhp
    writeSiteConf
    enableRenew
    installBBR
    saveState

    verifySite
    showSummary
    t1=$(date +%s)
    ok "总耗时：$((t1 - t0)) 秒"
}
certStatus() {
    loadState
    local enddate
    enddate=$(openssl x509 -in "$CERT_DIR/$DOMAIN.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
    say "证书状态：$DOMAIN"
    echo -e " 到期时间：${GREEN}${enddate:-未知}${PLAIN}"
    echo " 证书路径：$CERT_DIR/$DOMAIN.crt"
    echo " 副本路径：/root/$DOMAIN.crt 与 /root/$DOMAIN.key（续签时自动同步）"
    echo " 续签方式：acme.sh 每日 cron 检查，剩余约 30 天自动续签并重载 Nginx"
    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        ok "自动续签定时任务存在"
    else
        warn "未发现 acme.sh 定时任务，请执行菜单第 4 项或重新安装"
    fi
}

renewCert() {
    loadState
    [[ -x "$ACME" ]] || die "未找到 acme.sh，请重新执行安装"
    say "检查证书是否需要续签（未到期将跳过）"
    "$ACME" --renew -d "$DOMAIN" --ecc || warn "当前无需续签或续签未执行"
    ok "检查完成"
}

forceReissue() {
    loadState
    [[ -x "$ACME" ]] || die "未找到 acme.sh，请重新执行安装"
    echo ""
    read -r -p " 强制重新申请证书 $DOMAIN ？[y/N]：" a
    [[ "${a,,}" == "y" ]] || { say "已取消"; return 0; }
    say "强制重签中（请勿关闭终端）"
    "$ACME" --issue -d "$DOMAIN" --webroot "$WEBROOT" --keylength ec-256 --force || die "重签失败，请检查 80 端口与域名解析"
    "$ACME" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$CERT_DIR/$DOMAIN.key" \
        --fullchain-file "$CERT_DIR/$DOMAIN.crt" \
        --reloadcmd "cp -f $CERT_DIR/$DOMAIN.key /root/$DOMAIN.key; cp -f $CERT_DIR/$DOMAIN.crt /root/$DOMAIN.crt; systemctl reload nginx" >/dev/null 2>&1
    copyCertToRoot "$CERT_DIR/$DOMAIN.crt" "$CERT_DIR/$DOMAIN.key" || warn "证书复制到 /root 失败"
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
    ok "证书已重新签发并生效"
    certStatus
}

showService() {
    loadState
    say "服务状态"
    printf "  Nginx  ：%s\n" "$(systemctl is-active nginx 2>/dev/null)"
    printf "  %-8s：%s\n" "$PHP_SVC" "$(systemctl is-active "$PHP_SVC" 2>/dev/null)"
    printf "  网站配置：%s\n" "$NGINX_SITE/$DOMAIN.conf"
    printf "  网页目录：%s\n" "$WEBROOT"
    echo ""
    ss -lntp 2>/dev/null | grep -E ':(80|443) ' || warn "未检测到 80/443 监听"
}

restartServices() {
    loadState
    systemctl restart "$PHP_SVC" >/dev/null 2>&1 || warn "$PHP_SVC 重启失败"
    nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 && ok "Nginx 与 $PHP_SVC 已重启" \
        || warn "Nginx 重启失败，请执行 nginx -t 查看原因"
}

uninstall() {
    loadState
    local keep_web
    echo ""
    warn "将删除站点配置、证书，并移除 acme.sh 对该域名的续签"
    read -r -p " 是否同时删除网页目录 $WEBROOT ？[y/N]：" keep_web
    read -r -p " 确认卸载 $DOMAIN ？输入 yes 继续：" a
    [[ "$a" == "yes" ]] || { say "已取消"; return 0; }

    rm -f "$NGINX_SITE/$DOMAIN.conf"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
    [[ -x "$ACME" ]] && "$ACME" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
    rm -f "$CERT_DIR/$DOMAIN.crt" "$CERT_DIR/$DOMAIN.key"
    if [[ "${keep_web,,}" == "y" ]]; then
        warn "已保留网页目录：$WEBROOT"
    else
        rm -rf "$WEBROOT"
    fi
    rm -f "$STATE_FILE"
    ok "已卸载网站 $DOMAIN（Nginx 与 PHP 程序保留）"
}

menu() {
    local st_domain st_cert
    [[ -f "$STATE_FILE" ]] && st_domain=$(state_get domain)
    if [[ -n "$st_domain" && -f "$CERT_DIR/$st_domain.crt" ]]; then
        st_cert=$(openssl x509 -in "$CERT_DIR/$st_domain.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
    fi
    clear
    echo "#############################################################"
    echo -e "#        ${GREEN}Nginx + PHP + HTTPS 一键建站脚本${PLAIN}               #"
    echo "#############################################################"
    echo -e "  ${GREEN}1.${PLAIN} 安装 / 修复网站（输入域名，自动申请证书）"
    echo -e "  ${GREEN}2.${PLAIN} 查看网站信息"
    echo -e "  ${GREEN}3.${PLAIN} 查看服务与端口状态"
    echo -e "  ${GREEN}4.${PLAIN} 立即检查续签（未到期自动跳过）"
    echo -e "  ${GREEN}5.${PLAIN} 强制重签证书"
    echo -e "  ${GREEN}6.${PLAIN} 重启 Nginx 与 PHP"
    echo -e "  ${GREEN}7.${PLAIN} 卸载网站"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo "-------------------------------------------------------------"
    if [[ -n "$st_domain" ]]; then
        echo -e " 当前站点：${BLUE}$st_domain${PLAIN}    证书到期：${st_cert:-未知}"
    else
        echo -e " 当前状态：${YELLOW}未部署${PLAIN}"
    fi
    echo ""
    read -r -p " 请选择操作 [0-7]：" answer
    case "$answer" in
        0) exit 0 ;;
        1) install ;;
        2) loadState; showSummary ;;
        3) showService ;;
        4) renewCert ;;
        5) forceReissue ;;
        6) restartServices ;;
        7) uninstall ;;
        *) die "无效选项" ;;
    esac
}

main() {
    case "${1:-}" in
        install) install ;;
        menu|"") menu ;;
        *) echo "用法：bash $0 [install|menu]"; exit 1 ;;
    esac
}

main "$@"

