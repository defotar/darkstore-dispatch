#!/bin/zsh
# Стенд БД: исходная схема v1, данные за 90 дней, замеры, миграция и откат.
# Использование: ./run.sh all | init | load | bench1 | migrate | bench2 | rollback | reapply | nfr001 | rollback-track | stop | clean
set -e
cd "$(dirname "$0")"
DIR="$PWD"
PGBIN="${PGBIN:-/Applications/Postgres.app/Contents/Versions/17/bin}"
export PGBIN PGPORT="${PGPORT:-55432}"
PSQL=("$PGBIN/psql" -h 127.0.0.1 -p "$PGPORT" -U postgres -v ON_ERROR_STOP=1 -q)
mkdir -p results

say() { print -P "\n%B== $1%b" }

init() {
  say "Создание временного экземпляра PostgreSQL в $DIR/pgdata (порт $PGPORT)"
  "$PGBIN/initdb" -D pgdata -U postgres -A trust --no-locale -E UTF8 >/dev/null
  cat >> pgdata/postgresql.conf <<EOF
port=$PGPORT
unix_socket_directories=''
shared_buffers=512MB
work_mem=32MB
maintenance_work_mem=512MB
max_wal_size=4GB
fsync=off
synchronous_commit=off
full_page_writes=off
jit=off
EOF
  start
}
start() { "$PGBIN/pg_ctl" -D pgdata -l pgdata/server.log -w start >/dev/null; }

load() {
  say "Исходная схема v1 и данные за 90 дней (около 3 минут)"
  "${PSQL[@]}" -c "CREATE DATABASE cluster" -c "CREATE DATABASE track"
  "${PSQL[@]}" -d cluster -f sql/v1_ddl.sql
  time "${PSQL[@]}" -d cluster -f sql/gen.sql >/dev/null
  say "База трека: 30 суточных разделов, 12,9 млн точек (около 1 минуты)"
  time "${PSQL[@]}" -d track -f sql/track.sql
}

retention() {
  "${PSQL[@]}" -d cluster -f sql/ret.sql | grep Execution | sed 's/^/  удаление заказов за сутки: /'
}

bench1() {
  say "Замеры на исходной схеме (столбец «До»)"
  python3 bench.py v1 v1
  retention
  say "Контрольные суммы исходных данных"
  "${PSQL[@]}" -d cluster -f sql/check.sql | tee results/check_v1_before.txt
  "${PSQL[@]}" -d track -tAc "SELECT count(*), md5(string_agg(concat_ws(',', shift_id, receive_dttm, point_lat, point_lon), ';' ORDER BY shift_id, receive_dttm)) FROM d03.TrackPoint" | tee results/track_v1.txt
}

migrate() {
  say "Миграция v1 -> v2 (план миграции, шаги 1–8)"
  time "${PSQL[@]}" -d cluster -f sql/migrate_up.sql >/dev/null
  time "${PSQL[@]}" -d track -f sql/track_up.sql >/dev/null
  say "Проверка после миграции: суммы должны совпасть с исходными, нарушений — 0"
  "${PSQL[@]}" -d cluster -v v2=1 -f sql/check.sql | tee results/check_v2.txt
  "${PSQL[@]}" -d track -tAc "SELECT count(*), md5(string_agg(concat_ws(',', shift_id, receive_dttm, point_lat, point_lon), ';' ORDER BY shift_id, receive_dttm)) FROM d03.TrackPoint" \
    | diff - results/track_v1.txt && echo "  трек: данные совпадают с исходными"
  say "Ключ трека: пакет точек проходит, повтор точки отклоняется"
  "${PSQL[@]}" -d track -f sql/track_check.sql 2>&1 | grep -v '^$' | sed 's/^/  /'
}

bench2() {
  say "Замеры на целевой схеме (столбец «После»)"
  python3 bench.py v2 v2
  retention
  "${PSQL[@]}" -d cluster -f sql/ret_log.sql | grep Execution | sed 's/^/  удаление журнала за сутки: /'
  say "Индексы, которые решено не создавать"
  python3 bench.py extra
}

rollback() {
  say "Откат v2 -> v1 базы кластера"
  time "${PSQL[@]}" -d cluster -f sql/migrate_down.sql >/dev/null
  "${PSQL[@]}" -d cluster -f sql/check.sql > results/check_v1_after.txt
  if diff results/check_v1_before.txt results/check_v1_after.txt; then echo "  откат: данные совпадают с исходными"; else echo "  откат: РАСХОЖДЕНИЕ"; exit 1; fi
}

rollback_track() {
  say "Откат базы трека (около 8 минут)"
  time "${PSQL[@]}" -d track -f sql/track_down.sql >/dev/null
  "${PSQL[@]}" -d track -tAc "SELECT count(*), md5(string_agg(concat_ws(',', shift_id, receive_dttm, point_lat, point_lon), ';' ORDER BY shift_id, receive_dttm)) FROM d03.TrackPoint" \
    | diff - results/track_v1.txt && echo "  откат трека: данные совпадают с исходными"
}

reapply() {
  say "Повторная миграция после отката"
  "${PSQL[@]}" -d cluster -f sql/migrate_up.sql >/dev/null
  "${PSQL[@]}" -d cluster -v v2=1 -f sql/check.sql
}

nfr001() {
  setopt local_options null_glob
  say "NFR001: выдача направления, обращения к БД (100 открытых смен, 10 параллельных курьеров, 60 с)"
  "${PSQL[@]}" -d cluster -f sql/fr027_setup.sql >/dev/null
  rm -f results/fr027_log*
  "$PGBIN/pgbench" -h 127.0.0.1 -p "$PGPORT" -U postgres -n -c 10 -j 2 -T 60 -f sql/fr027.sql \
    --log --log-prefix=results/fr027_log cluster | grep -E "transactions actually|latency average|tps"
  cat results/fr027_log* | awk '{print $3/1000}' | sort -n | awk '{a[NR]=$1} END {
    printf "  транзакций: %d; p50 %.2f мс; p95 %.2f мс; p99 %.2f мс; максимум %.2f мс\n", NR, a[int(NR*0.5)], a[int(NR*0.95)], a[int(NR*0.99)], a[NR]}' \
    | tee results/nfr001.txt
}

stop() { "$PGBIN/pg_ctl" -D pgdata stop >/dev/null && echo "Сервер остановлен"; }
clean() { stop 2>/dev/null || true; rm -rf pgdata results; echo "Стенд удалён"; }

case "${1:-all}" in
  all) init; load; bench1; migrate; bench2; rollback; reapply; nfr001; stop ;;
  init) init ;; start) start ;; load) load ;; bench1) bench1 ;; migrate) migrate ;; bench2) bench2 ;;
  nfr001) nfr001 ;; rollback) rollback ;; rollback-track) rollback_track ;; reapply) reapply ;; stop) stop ;; clean) clean ;;
  *) echo "Неизвестная команда: $1"; exit 1 ;;
esac
