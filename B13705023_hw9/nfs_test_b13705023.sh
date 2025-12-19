#!/bin/bash

STUDENT_ID="${USER}"
TEST_NAME=${1:-"test"}
FILE_SIZE_GB=1
FILE_SIZE_MB=$((FILE_SIZE_GB * 1024))
NFS_MOUNT="/mnt/nfs-share"
TIMESTAMP=$(date +%s)
TEST_FILE="${NFS_MOUNT}/test_${STUDENT_ID}_${TIMESTAMP}.dat"

echo "==========================================="
echo "       NFS 效能測試"
echo "==========================================="
echo "測試名稱: ${TEST_NAME}"
echo "使用者: ${STUDENT_ID}"
echo "時間: $(date)"
echo "==========================================="
echo ""

# 檢查 NFS 是否掛載
if ! mountpoint -q ${NFS_MOUNT}; then
    echo "錯誤: ${NFS_MOUNT} 未掛載"
    exit 1
fi

# 顯示 NFS 掛載參數
echo "當前 NFS 掛載參數:"
mount | grep ${NFS_MOUNT}
echo ""

# ===== 寫入測試 =====
echo "===== 寫入測試開始 ====="
echo "建立 ${FILE_SIZE_GB}GB 測試檔案..."

# 記錄開始狀態
write_start=$(date +%s.%N)
write_start_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')

# 啟動背景 CPU 監控
cpu_log="/tmp/cpu_${TIMESTAMP}.log"
> ${cpu_log}
while true; do
    mpstat 1 1 | awk '/Average/ {print 100-$NF}' >> ${cpu_log} 2>/dev/null || \
    top -bn2 -d 1 | grep "Cpu(s)" | tail -1 | awk '{print $2}' | cut -d'%' -f1 >> ${cpu_log}
    sleep 1
done &
monitor_pid=$!

# 執行寫入
echo "開始寫入..."
dd if=/dev/zero of=${TEST_FILE} bs=1M count=${FILE_SIZE_MB} oflag=direct 2>&1 | grep -E "copied|MB/s"

# 停止監控
kill ${monitor_pid} 2>/dev/null
wait ${monitor_pid} 2>/dev/null

# 記錄結束狀態
write_end=$(date +%s.%N)
write_end_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')

# 計算結果
write_time=$(echo "$write_end - $write_start" | bc)
write_speed=$(echo "scale=2; ${FILE_SIZE_MB} / ${write_time}" | bc)
write_cpu=$(awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n; else print "0"}' ${cpu_log})

echo "寫入完成！"
echo "  時間: ${write_time} 秒"
echo "  速率: ${write_speed} MB/s"
echo "  CPU: ${write_cpu}%"
echo "  負載: ${write_start_load} -> ${write_end_load}"
echo ""

# ===== 讀取測試 =====
echo "===== 讀取測試開始 ====="

# 清除快取
if [ "$EUID" -eq 0 ]; then
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    echo "已清除系統快取"
else
    echo "警告: 非 root 使用者，無法清除快取"
fi

# 記錄開始狀態
read_start=$(date +%s.%N)
read_start_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')

# 重啟 CPU 監控
> ${cpu_log}
while true; do
    mpstat 1 1 | awk '/Average/ {print 100-$NF}' >> ${cpu_log} 2>/dev/null || \
    top -bn2 -d 1 | grep "Cpu(s)" | tail -1 | awk '{print $2}' | cut -d'%' -f1 >> ${cpu_log}
    sleep 1
done &
monitor_pid=$!

# 執行讀取
echo "開始讀取..."
dd if=${TEST_FILE} of=/dev/null bs=1M 2>&1 | grep -E "copied|MB/s"

# 停止監控
kill ${monitor_pid} 2>/dev/null
wait ${monitor_pid} 2>/dev/null

# 記錄結束狀態
read_end=$(date +%s.%N)
read_end_load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')

# 計算結果
read_time=$(echo "$read_end - $read_start" | bc)
read_speed=$(echo "scale=2; ${FILE_SIZE_MB} / ${read_time}" | bc)
read_cpu=$(awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n; else print "0"}' ${cpu_log})

echo "讀取完成！"
echo "  時間: ${read_time} 秒"
echo "  速率: ${read_speed} MB/s"
echo "  CPU: ${read_cpu}%"
echo "  負載: ${read_start_load} -> ${read_end_load}"
echo ""

# ===== 清理 =====
rm -f ${TEST_FILE}
rm -f ${cpu_log}

# ===== 輸出摘要 =====
echo "==========================================="
echo "           測試結果摘要"
echo "==========================================="
echo "測試名稱: ${TEST_NAME}"
echo ""
echo "寫入測試:"
echo "  時間: ${write_time} 秒"
echo "  速率: ${write_speed} MB/s"
echo "  CPU:  ${write_cpu}%"
echo ""
echo "讀取測試:"
echo "  時間: ${read_time} 秒"
echo "  速率: ${read_speed} MB/s"
echo "  CPU:  ${read_cpu}%"
echo "==========================================="

