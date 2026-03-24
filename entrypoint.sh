#!/bin/bash
if [ -s /teleport.pem ];then
  if [ -z "$TELEPORT_PROXY" -o -z "$APP_NAME" ];then
    cat << "EOF"
env set $TELEPORT_PROXY & $APP_NAME
env optional ${APP_PORT:-1443}
EOF
  fi

  nohup socat TCP-LISTEN:${APP_PORT:-1443},fork,bind=0.0.0.0 TCP:127.0.0.1:443 &
  tsh apps ls -i /teleport.pem --proxy=$TELEPORT_PROXY
  tsh proxy app $APP_NAME --port 443 -i /teleport.pem --proxy=$TELEPORT_PROXY
  exit $?
fi
if [ -z "$TELEPORT_TOKEN" -o -z "$TELEPORT_PROXY" ];then
  cat << "EOF"
env set $TELEPORT_TOKEN & $TELEPORT_PROXY
env optional $APP_NAME & $APP_URL
EOF
  exit 1
fi
cd /data
if [ -z "$NODE_NAME" ];then
  NODE_IP=$(curl httpbin.org/get|jq .origin -r)
  NODE_NAME="${HOSTNAME}-${NODE_IP}"
fi
yq -y -i ".teleport.nodename = \"${NODE_NAME}\"" app_config.yaml
yq -y -i ".teleport.join_params.token_name = \"${TELEPORT_TOKEN}\"" app_config.yaml
yq -y -i ".teleport.proxy_server = \"${TELEPORT_PROXY}\"" app_config.yaml
if [ ! -z "$APP_NAME" ];then
  export APP_0_NAME=$APP_NAME
  export APP_0_URL=$APP_URL
fi
for I in `env|grep APP_|grep _NAME|sort -n|cut -d= -f1|grep '[0-9]*' -o`;do
  APP_NAME=APP_${I}_NAME
  APP_URL=APP_${I}_URL
  APP_LABEL=APP_${I}_LABEL
  APP_HOST=APP_${I}_HOST
  APP_WS=APP_${I}_WS
  if [ -z "${!APP_NAME}" ];then
    continue
  fi
  APP_NAME=${!APP_NAME}
  APP_URL=${!APP_URL:-${DEFAULT_URL}}
  APP_LABEL=${!APP_LABEL}
  APP_HOST=${!APP_HOST}
  APP_WS_VAL=${!APP_WS:-false}
  
  # 如果启用 WS 支持，通过 nginx 转发
  if [ "${APP_WS_VAL}" = "true" ]; then
    WS_PORT=$((8080 + I))
    ORIGINAL_URL="${APP_URL}"
    APP_URL="http://localhost:${WS_PORT}"
    
    # 生成 nginx 配置
    mkdir -p /etc/nginx/conf.d
    cat > /etc/nginx/conf.d/ws-${APP_NAME}.conf << EOF
server {
    listen ${WS_PORT};
    server_name localhost;

    location / {
        proxy_pass ${ORIGINAL_URL};
        proxy_http_version 1.1;
        proxy_ssl_server_name on;
        
        # 处理 upgrade header 和 connection header
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        #proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Origin ${ORIGINAL_URL};
        
        # WebSocket 超时设置
        proxy_read_timeout 86400;
        # todo: text/event-stream 
    }
}
EOF
    echo "已创建 nginx 配置: ${APP_NAME} -> ${ORIGINAL_URL} (端口: ${WS_PORT})"
  fi
  
  yq -y -i ".app_service.apps += [
   {
      \"name\":\"${APP_NAME}\",
      \"uri\":\"${APP_URL}\",
      \"labels\":{
         \"app-name\":\"${APP_NAME}\"
      },
      \"rewrite\":{
         \"headers\":[]
      }
   }
]" app_config.yaml
  if [ "${DEFAULT_LABEL};${APP_LABEL}" ];then
    while IFS= read -r kv; do
      [[ -z $kv ]] && continue        # 跳过空段
      case "$kv" in
          *=*)
              KEY="${kv%%=*}"
              VALUE="${kv#*=}"
              ;;
          *:*)
              KEY="${kv%%:*}"
              VALUE="${kv#*:}"
              ;;
          *)
              echo "⚠️  跳过无效格式: $kv" >&2
              continue
              ;;
      esac
      yq -y -i ".app_service.apps[-1].labels += {\"${KEY}\":\"${VALUE}\"}" app_config.yaml
    done < <(tr ';' '\n' <<<"${DEFAULT_LABEL};${APP_LABEL}")
  fi
  if [ "${APP_HOST}" ];then
    yq -y -i ".app_service.apps[-1].rewrite.headers += [\"host: ${APP_HOST}\"]" app_config.yaml
  fi 
done
# 如果有 WebSocket 配置，启动 nginx
if [ "$(ls -A /etc/nginx/conf.d/ws*)" ]; then
    echo "启动 nginx 处理 WebSocket 连接..."
    nginx
fi

cat app_config.yaml
teleport start --config=`pwd`/app_config.yaml
