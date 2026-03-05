#!/bin/bash
if [ -s /teleport.pem ];then
  if [ -z "$TELEPORT_PROXY" -o -z "$APP_NAME" ];then
    cat << "EOF"
env set $TELEPORT_PROXY & $APP_NAME
env optional ${APP_PORT:-1443}
EOF
  fi

  nohup socat TCP-LISTEN:${APP_PORT:-1443},fork,bind=0.0.0.0 TCP:127.0.0.1:443 &
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
  if [ -z "${!APP_NAME}" ];then
    continue
  fi
  APP_NAME=${!APP_NAME}
  APP_URL=${!APP_URL:-${DEFAULT_URL}} 
  APP_LABEL=${!APP_LABEL}
  APP_HOST=${!APP_HOST}
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
cat app_config.yaml
teleport start --config=`pwd`/app_config.yaml
