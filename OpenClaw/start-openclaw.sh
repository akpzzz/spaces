#!/bin/bash

set -e

# 1. 补全目录
mkdir -p /root/.openclaw/agents/main/sessions
mkdir -p /root/.openclaw/credentials
mkdir -p /root/.openclaw/sessions

# ── 2. Fix DNS ────────────────────────────────────────────────
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf
echo ">>> DNS fixed."

# ── 3. Chromium 安装（修复版）────────────────────────────────
export PLAYWRIGHT_BROWSERS_PATH=/root/.openclaw/browsers

# 方法1：使用 openclaw 自带的 playwright
install_chromium_via_openclaw() {
    echo ">>> Trying to install Chromium via openclaw..."
    
    # 查找 openclaw 安装目录
    OPENCLAW_PATH=$(which openclaw 2>/dev/null)
    if [ -n "$OPENCLAW_PATH" ]; then
        # 尝试使用 openclaw 命令安装浏览器
        if openclaw browser install 2>/dev/null; then
            echo ">>> Chromium installed via openclaw browser install"
            return 0
        fi
    fi
    
    # 方法2：直接使用 npx playwright 安装
    echo ">>> Trying npx playwright install..."
    if npx playwright install chromium --with-deps 2>/dev/null; then
        echo ">>> Chromium installed via npx playwright"
        return 0
    fi
    
    # 方法3：使用全局 playwright
    echo ">>> Trying global playwright install..."
    if playwright install chromium --with-deps 2>/dev/null; then
        echo ">>> Chromium installed via global playwright"
        return 0
    fi
    
    # 方法4：手动查找并安装
    echo ">>> Trying manual playwright-core install..."
    NPM_GLOBAL_ROOT=$(npm root -g 2>/dev/null)
    if [ -n "$NPM_GLOBAL_ROOT" ]; then
        PLAYWRIGHT_CLI="$NPM_GLOBAL_ROOT/playwright-core/cli.js"
        if [ -f "$PLAYWRIGHT_CLI" ]; then
            if node "$PLAYWRIGHT_CLI" install chromium; then
                echo ">>> Chromium installed via playwright-core cli.js"
                return 0
            fi
        fi
    fi
    
    # 方法5：使用系统包管理器安装（备用方案）
    echo ">>> Trying system package manager install..."
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y chromium-browser || apt-get install -y chromium
        if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
            echo ">>> Chromium installed via apt"
            # 创建软链接到 playwright 期望的路径
            CHROME_PATH=$(which chromium-browser 2>/dev/null || which chromium 2>/dev/null)
            if [ -n "$CHROME_PATH" ]; then
                mkdir -p /root/.openclaw/browsers/chrome-linux
                ln -sf "$CHROME_PATH" /root/.openclaw/browsers/chrome-linux/chrome 2>/dev/null || true
            fi
            return 0
        fi
    fi
    
    echo ">>> WARN: All Chromium installation methods failed"
    return 1
}

# 检查 Chromium 是否已存在
CHROMIUM_PATH=$(find /root/.openclaw/browsers -name "chrome" -type f 2>/dev/null | head -1)

if [ -z "$CHROMIUM_PATH" ]; then
    echo ">>> Chromium not found, installing..."
    install_chromium_via_openclaw
    # 重新查找
    CHROMIUM_PATH=$(find /root/.openclaw/browsers -name "chrome" -type f 2>/dev/null | head -1)
    if [ -n "$CHROMIUM_PATH" ]; then
        echo ">>> Chromium installed successfully at: $CHROMIUM_PATH"
    else
        echo ">>> WARN: Chromium installation failed, browser features may not work"
    fi
else
    echo ">>> Chromium found: $CHROMIUM_PATH"
fi

# 设置 PLAYWRIGHT 环境变量
if [ -n "$CHROMIUM_PATH" ]; then
    export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH="$CHROMIUM_PATH"
    echo ">>> PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH set to: $CHROMIUM_PATH"
fi

# 4. 处理 API 地址
CLEAN_BASE=$(echo "$OPENAI_API_BASE" | sed "s|/chat/completions||g" | sed "s|/v1/|/v1|g" | sed "s|/v1$|/v1|g")

# 5. 生成配置文件（修复 JSON 语法错误）
cat > /root/.openclaw/openclaw.json <<EOF
{
  "models": {
    "providers": {
      "nvidia": {
        "baseUrl": "$CLEAN_BASE",
        "apiKey": "$OPENAI_API_KEY",
        "api": "openai-completions",
        "models": [
          { "id": "$MODEL", "name": "$MODEL", "contextWindow": 128000 }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "$MODEL"
      }
    }
  },
  "commands": {
    "restart": true
  },
  "tools": {
    "exec": {
      "ask": "off",
      "security": "full"
    }
  },
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 7861,
    "trustedProxies": ["0.0.0.0/0"],
    "auth": {
      "mode": "token",
      "token": "$OPENCLAW_GATEWAY_PASSWORD"
    },
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true,
      "allowedOrigins": ["*"],
      "dangerouslyDisableDeviceAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
EOF

# 创建nginx配置
cat > /etc/nginx/nginx.conf <<'EOF'
worker_processes 1;
events {
    worker_connections 1024;
}

http {
   upstream codeServer {
      server 0.0.0.0:7862;
    }
    
    map $http_upgrade $connection_upgrade {
      default keep-alive;
      'websocket' upgrade;
    }
    
    server {
        listen 7860;
        server_name _;
        
        location / {
            proxy_pass http://127.0.0.1:7861/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Prefix /openclaw/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header X-Forwarded-Host $host;
        }

        location /coder/ {
            proxy_pass http://codeServer/;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header Host $http_host;
            proxy_set_header X-NginX-Proxy true;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header X-Real-IP $remote_addr;
            proxy_buffering off;
            proxy_redirect default;
            proxy_connect_timeout 1800;
            proxy_send_timeout 1800;
            proxy_read_timeout 1800;  
        }

        
        location /telegram/webhook {
            proxy_pass http://127.0.0.1:8787;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

    }
}
EOF


# 6. 执行恢复
echo  "======================写入rclone配置========================\n"
echo "$RCLONE_CONF" > ~/.config/rclone/rclone.conf

if [ -n "$RCLONE_CONF" ]; then
  echo "##########同步备份############"
  # 为了防止不存在目录报错
  rclone mkdir $REMOTE_FOLDER
  # 使用 rclone ls 命令列出文件夹内容，将输出和错误分别捕获
  OUTPUT=$(rclone ls "$REMOTE_FOLDER" 2>&1)
  # 获取 rclone 命令的退出状态码
  EXIT_CODE=$?
  #echo "rclone退出代码:$EXIT_CODE"
  # 判断退出状态码
  if [ $EXIT_CODE -eq 0 ]; then
    # rclone 命令成功执行，检查文件夹是否为空
    if [ -z "$OUTPUT" ]; then
      #为空不处理
      echo "初次安装"
    else
        echo "远程文件夹不为空开始还原"
        ./sync.sh restore
        echo "恢复完成."   
    fi
  elif [[ "$OUTPUT" == *"directory not found"* ]]; then
    echo "错误：文件夹不存在"
  else
    echo "错误：$OUTPUT"
  fi
else
    echo "没有检测到Rclone配置信息"
fi

# 7. 运行
openclaw doctor --fix

# 启动定时备份
(while true; do
  sleep 3600
  echo ">>> Running scheduled backup..."
  ./sync.sh backup
done) &

nginx -t
if [ $? -ne 0 ]; then
  echo "nginx 配置失败"
  cat /var/log/nginx/error.log
  exit 1
fi

# 启动 nginx 前台运行
nginx -g 'daemon off;' &

# 使用 pm2 启动 openclaw
pm2 start "openclaw gateway run --port 7861" --name openclaw

echo -e "======================启动code-server服务========================\n"
export PASSWORD=$OPENCLAW_GATEWAY_PASSWORD
pm2 start "code-server --bind-addr 0.0.0.0:7862 --port 7862" --name "code-server"
pm2 startup
pm2 save

# 使用 pm2 持续运行，保持容器不退出 需要的话开启
# pm2 logs

tail -f /dev/null
