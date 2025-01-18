#!/bin/bash

ver=v1.1.1
CURRENT_TIME=$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M:%S")

echo "################## A MonChkUpRmFile Script By Karry Klein ##################"
echo "#                    MonChkUpRmFile Script Version：$ver                 #"
echo "#           Github：https://github.com/karryklein/MonChkUpRmFile           #"
echo "#                     监测同步时间：$CURRENT_TIME CST                #"
echo "############################################################################"

CURRENT_STATE=$(mktemp)
LOCAL_NEW_FILES=$(mktemp)
LOCAL_DELETED_FILES=$(mktemp)
REMOTE_FILES_LIST=$(mktemp)
UNIFIED_REMOTE_FILES_LIST=$(mktemp)
UNIFIED_LOCAL_NEW_FILES_LIST=$(mktemp)
UNIFIED_LOCAL_DELETED_FILES_LIST=$(mktemp)
trap "rm -f '$CURRENT_STATE' '$LOCAL_NEW_FILES' '$LOCAL_DELETED_FILES' '$REMOTE_FILES_LIST' '$UNIFIED_REMOTE_FILES_LIST' '$UNIFIED_LOCAL_NEW_FILES_LIST' '$UNIFIED_LOCAL_DELETED_FILES_LIST'" EXIT

# 配置参数
export S3_UPLOADS_PROVIDER=cloudflard # S3服务提供商
export S3_UPLOADS_BUCKET=yourbucketname # 你的存储桶名称
export S3_UPLOADS_REGION=auto # 你的存储桶地域
export S3_UPLOADS_ENDPOINT=https://yourbucketendpoint.com # 你的存储桶Endpoint
export S3_UPLOADS_KEY=youraccesskeyid # 你的Access Key ID
export S3_UPLOADS_SECRET=yoursecretaccesskey # 你的Secret Access Key
MONITOR_DIR="/path/to/be/monitor"  # 要监控的文件夹路径（绝对路径）
STATE_FILE="/tmp/MonChkUpRmFile_monitor_files_state.txt"  # 用于记录监控文件夹中文件状态的文件
LOG_DIR="/var/log/MonChkUpRmFile"  # 日志文件目录
S3_REMOTE_PATH="be/monitor"  # 远程存储的目标路径（无需 / ）
MAX_RETRY=3  # 最大重试次数
RETRY_DELAY=10  # 每次重试的延迟时间（秒）

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/MonChkUpRmFile_$(TZ=Asia/Shanghai date +%Y%m%d_%H%M%S).log"

echo "################## A MonChkUpRmFile Script By Karry Klein ##################" >> "$LOG_FILE"
echo "#                    MonChkUpRmFile Script Version：$ver                 #" >> "$LOG_FILE"
echo "#           Github：https://github.com/karryklein/MonChkUpRmFile           #" >> "$LOG_FILE"
echo "#                     监测同步时间：$CURRENT_TIME CST                #" >> "$LOG_FILE"
echo "############################################################################" >> "$LOG_FILE"

echo "[$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M:%S")] 检查监控文件夹中文件的状态文件是否存在..." >> "$LOG_FILE"
if [ ! -f "$STATE_FILE" ]; then
  echo "[$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M:%S")] 首次运行，初始化监控文件夹中文件的状态文件..." >> "$LOG_FILE"
  find "$MONITOR_DIR" -type f -exec stat --format='%n %Y' {} \; > "$STATE_FILE"
  echo "[$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M:%S")] 监控文件夹中文件的状态文件已初始化。" >> "$LOG_FILE"
  exit 0
fi

echo "[$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M:%S")] 获取当前监控文件夹中文件的状态..." >> "$LOG_FILE"
find "$MONITOR_DIR" -type f -exec stat --format='%n %Y' {} \; > "$CURRENT_STATE"

echo "[$(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M:%S")] 比较文件状态..." >> "$LOG_FILE"
comm -13 <(sort "$STATE_FILE") <(sort "$CURRENT_STATE") >> "$LOCAL_NEW_FILES"
comm -23 <(sort "$STATE_FILE") <(sort "$CURRENT_STATE") >> "$LOCAL_DELETED_FILES"

echo "[$CURRENT_TIME] 监控文件夹中文件的状态检查完成。" >> "$LOG_FILE"

retry_operation() {
  local operation=$1
  local source=$2
  local target=$3
  local max_retries=$4

  local attempt=0
  while [ $attempt -lt $max_retries ]; do
    if [ -z "$source" ]; then
      $operation "$target"
    else
      $operation "$source" "$target"
    fi

    if [ $? -eq 0 ]; then
      return 0
    fi
    ((attempt++))
    echo "[$CURRENT_TIME] $operation 失败 (重试次数: $attempt)" >> "$LOG_FILE"
    sleep $RETRY_DELAY
  done
  return 1
}

while IFS= read -r line; do
  if [[ "$line" == *"$S3_REMOTE_PATH"* ]]; then
    echo "${line#*$S3_REMOTE_PATH}"  | awk '{print $1}' >> "$UNIFIED_LOCAL_NEW_FILES_LIST"
  fi
done < "$LOCAL_NEW_FILES"
while IFS= read -r line; do
  if [[ "$line" == *"$S3_REMOTE_PATH"* ]]; then
    echo "${line#*$S3_REMOTE_PATH}"  | awk '{print $1}' >> "$UNIFIED_LOCAL_DELETED_FILES_LIST"
  fi
done < "$LOCAL_DELETED_FILES"
retry_operation "/usr/local/bin/s3 operate list-files" "" "$S3_REMOTE_PATH" "$MAX_RETRY" >> "$REMOTE_FILES_LIST"
while IFS= read -r line; do
  if [[ "$line" == *"$S3_REMOTE_PATH"* ]]; then
    echo "${line#*$S3_REMOTE_PATH}" >> "$UNIFIED_REMOTE_FILES_LIST"
  fi
done < "$REMOTE_FILES_LIST"

if [ -s "$UNIFIED_LOCAL_NEW_FILES_LIST" ] && [ -s "$UNIFIED_REMOTE_FILES_LIST" ]; then
  TO_NEW_UPLOAD_FILES=$(comm -23 <(sort "$UNIFIED_LOCAL_NEW_FILES_LIST") <(sort "$UNIFIED_REMOTE_FILES_LIST") | awk -v prefix="$MONITOR_DIR" '{print prefix$1}')
else
  echo "[$CURRENT_TIME] 本地新增文件列表或远程文件列表为空，跳过比较操作。" >> "$LOG_FILE"
  fi
if [ -s "$UNIFIED_LOCAL_DELETED_FILES_LIST" ] && [ -s "$UNIFIED_REMOTE_FILES_LIST" ]; then
  TO_NEW_DELETE_FILES=$(comm -12 <(sort "$UNIFIED_LOCAL_DELETED_FILES_LIST") <(sort "$UNIFIED_REMOTE_FILES_LIST") | awk -v prefix="$MONITOR_DIR" '{print prefix$1}')
else
  echo "[$CURRENT_TIME] 本地新增已删除文件列表或远程文件列表为空，跳过比较操作。" >> "$LOG_FILE"
fi

if [ -n "$TO_NEW_UPLOAD_FILES" ]; then
  echo "[$CURRENT_TIME] 检测到新增文件，开始上传..." >> "$LOG_FILE"
  for FILE in $TO_NEW_UPLOAD_FILES; do
    RELATIVE_PATH="${FILE#$MONITOR_DIR/}"
    UPLOAD_TARGET="$S3_REMOTE_PATH/$RELATIVE_PATH"
    echo "[$CURRENT_TIME] 正在上传文件: $FILE -> $UPLOAD_TARGET" >> "$LOG_FILE"
    retry_operation "/usr/local/bin/s3 operate upload-file" "$FILE" "$UPLOAD_TARGET" "$MAX_RETRY"
  done
else
  echo "[$CURRENT_TIME] 无本地新增文件或云端已存在本地新增文件，无需上传文件。" >> "$LOG_FILE"
fi

if [ -n "$TO_NEW_DELETE_FILES" ]; then
  echo "[$CURRENT_TIME] 检测到本地已删除的文件，开始删除远程文件..." >> "$LOG_FILE"
  for FILE in $TO_NEW_DELETE_FILES; do
    RELATIVE_PATH="${FILE#$MONITOR_DIR/}"
    DELETE_TARGET="$S3_REMOTE_PATH/$RELATIVE_PATH"
    echo "[$CURRENT_TIME] 正在删除远程文件: $DELETE_TARGET" >> "$LOG_FILE"
    retry_operation "/usr/local/bin/s3 operate delete-file" "" "$DELETE_TARGET" "$MAX_RETRY"
  done
else
  echo "[$CURRENT_TIME] 无本地新增已删除文件，无需删除远程文件。" >> "$LOG_FILE"
fi

echo "[$CURRENT_TIME] 更新监控文件夹中文件的状态文件..." >> "$LOG_FILE"
mv "$CURRENT_STATE" "$STATE_FILE"