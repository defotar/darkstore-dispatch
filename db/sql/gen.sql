-- Тестовые данные за 90 дней: 3 даркстора, 120 курьеров, 100 смен и 4500 заказов в сутки
SELECT setseed(0.42);
\set now '''2026-10-25 18:00+03'''
INSERT INTO d01.Darkstore SELECT i, 'DS-'||i, 'Даркстор '||i, 'POLYGON((37.5 55.7,37.6 55.7,37.6 55.8,37.5 55.7))' FROM generate_series(1,3) i;
INSERT INTO d01.Subzone SELECT (d-1)*10+z, d, 'SZ-'||z, 'Подзона '||z FROM generate_series(1,3) d, generate_series(1,10) z;
INSERT INTO d01.SubzoneNeighborLink SELECT s, s+1 FROM generate_series(1,30) s WHERE s % 10 <> 0;
INSERT INTO d01.SubzoneNeighborLink SELECT s+1, s FROM generate_series(1,30) s WHERE s % 10 <> 0;
INSERT INTO d01.OrderStatusDict VALUES (1,'ASSEMBLING','В сборке'),(2,'READY','Готов'),(3,'CANCELLED','Отменён'),(4,'REASSEMBLY','На пересборке');
INSERT INTO d02.TransportTypeDict VALUES (1,'FOOT','Пеший'),(2,'BIKE','Велосипед'),(3,'CAR','Автомобиль');
INSERT INTO d04.BundleStatusDict VALUES (1,'FORMED','Составлена'),(2,'DEPARTED','В доставке'),(3,'DONE','Завершена'),(4,'DISBANDED','Расформирована');
INSERT INTO d05.LatenessCauseDict VALUES (1,'ON_TIME','В срок'),(2,'BEFORE_DISTRIBUTION','До распределения'),(3,'COURIER_SHORTAGE','Нехватка курьеров'),(4,'DISTRIBUTION_DECISION','Решение распределения'),(5,'IN_DELIVERY','В доставке');
INSERT INTO d04.DistributionParameter VALUES (1,40,25,10,10,'2026-07-01',NULL),(2,40,25,12,10,'2026-09-01','ops.lead');
INSERT INTO d02.Courier SELECT c, 'C-'||c, 4, NULL FROM generate_series(1,120) c;
INSERT INTO d03.CourierSpeed SELECT c, 0.8 + random()*0.4, :now FROM generate_series(1,120) c;

-- смены: день 0..89, 100 курьеров в день; последние сутки — открытые смены
INSERT INTO d02.Shift (shift_id, courier_id, base_darkstore_id, transport_type_id, start_dttm, end_dttm, close_fact_dttm)
SELECT d*100+k+1, ((d*37+k) % 120)+1, (k % 3)+1, (k % 3)+1,
       date_trunc('day', :now::timestamptz) - (89-d) * interval '1 day' + interval '8 hours',
       date_trunc('day', :now::timestamptz) - (89-d) * interval '1 day' + interval '22 hours',
       CASE WHEN d < 89 THEN date_trunc('day', :now::timestamptz) - (89-d) * interval '1 day' + interval '22 hours' END
FROM generate_series(0,89) d, generate_series(0,99) k;

-- заказы: равномерно в 8:00–22:00, последние ~600 активны
INSERT INTO d01.DeliveryOrder (order_id, order_code, subzone_id, order_status_id, weight_kg, place_dttm, deadline_dttm,
  promise_sec, ready_fcst_dttm, ready_fact_dttm)
SELECT n, 'O-'||n, 1 + (n::bigint*7919 % 30), 2, round((random()*12)::numeric, 2), p, p + interval '30 min', 1800,
       p + interval '10 min', p + interval '10 min'
FROM (SELECT n, date_trunc('day', :now::timestamptz) - (89 - (n-1)/4500) * interval '1 day' + interval '8 hours'
             + ((n-1) % 4500) * interval '11.2 sec' AS p FROM generate_series(1, 405000) n) s;
-- отмены 3 %, активные: оформлены за последние 20 минут до «сейчас»
UPDATE d01.DeliveryOrder SET order_status_id = 3 WHERE order_id % 33 = 0;
UPDATE d01.DeliveryOrder SET order_status_id = CASE WHEN place_dttm > :now::timestamptz - interval '10 min' THEN 1 ELSE 2 END,
       ready_fact_dttm = CASE WHEN place_dttm > :now::timestamptz - interval '10 min' THEN NULL ELSE ready_fact_dttm END
 WHERE place_dttm > :now::timestamptz - interval '40 min' AND order_status_id <> 3;
UPDATE d01.DeliveryOrder SET at_risk_bool = TRUE WHERE order_id % 17 = 0;
UPDATE d01.DeliveryOrder SET overdue_bool = TRUE WHERE order_id % 23 = 0;
INSERT INTO d04.OrderForecast SELECT order_id, deadline_dttm - interval '3 min', deadline_dttm - interval '3 min', place_dttm FROM d01.DeliveryOrder;

-- связки по 2 заказа, вручённые заказы (оформлены раньше чем за 40 минут, не отменены)
CREATE TEMP TABLE od AS SELECT order_id, subzone_id, place_dttm, deadline_dttm,
  row_number() OVER (ORDER BY order_id) rn FROM d01.DeliveryOrder
  WHERE order_status_id = 2 AND place_dttm <= :now::timestamptz - interval '40 min';
INSERT INTO d04.Bundle (bundle_id, shift_id, subzone_id, bundle_status_id, form_dttm, hold_sec, depart_fact_dttm)
SELECT (rn+1)/2, s.shift_id, od.subzone_id, 3, od.place_dttm + interval '11 min', 0, od.place_dttm + interval '12 min'
FROM od, LATERAL (SELECT shift_id FROM d02.Shift WHERE start_dttm = date_trunc('day', od.place_dttm) + interval '8 hours'
                  ORDER BY shift_id OFFSET (od.rn % 100) LIMIT 1) s
WHERE rn % 2 = 1;
INSERT INTO d04.BundleItem (bundle_item_id, bundle_id, order_id, item_ord, scan_fact_dttm, deliver_fact_dttm)
SELECT rn, (rn+1)/2, order_id, 2 - rn % 2, place_dttm + interval '11 min', place_dttm + interval '25 min' + (rn % 13) * interval '1 min'
FROM od WHERE (rn+1)/2 IN (SELECT bundle_id FROM d04.Bundle);
-- 10 % заказов ранее были сняты с другой связки
INSERT INTO d04.BundleItem (bundle_item_id, bundle_id, order_id, item_ord, scan_fact_dttm, remove_fact_dttm, remove_reason_desc)
SELECT 1000000 + bi.bundle_item_id, bi.bundle_id, bi.order_id, 3, NULL, bi.scan_fact_dttm - interval '1 min', 'Таймаут'
FROM d04.BundleItem bi WHERE bi.bundle_item_id % 10 = 0;

-- направления, прибытия, журнал: одно на связку
INSERT INTO d04.Direction SELECT b.bundle_id, b.shift_id, 1 + b.bundle_id % 3, 1 + (b.bundle_id + (b.bundle_id % 20 = 0)::int) % 3,
  b.form_dttm - interval '6 min', b.form_dttm - interval '6 min' + interval '0.4 sec',
  CASE WHEN b.bundle_id % 20 = 0 THEN b.form_dttm - interval '3 min' END, b.form_dttm - interval '1 min', FALSE FROM d04.Bundle b;
INSERT INTO d03.Arrival SELECT direction_id, shift_id, target_darkstore_id, close_fact_dttm FROM d04.Direction;
INSERT INTO d05.DecisionLog SELECT direction_id, direction_id, CASE WHEN issue_dttm < '2026-09-01' THEN 1 ELSE 2 END, issue_dttm, 'Наименьший прогноз опозданий' FROM d04.Direction;
INSERT INTO d05.DecisionOption SELECT (l.decision_log_id-1)*3 + ds, l.decision_log_id, l.log_dttm, ds, (random()*5)::int, 300 + (random()*900)::int, ds = d.initial_darkstore_id
FROM d05.DecisionLog l JOIN d04.Direction d ON d.direction_id = l.direction_id, generate_series(1,3) ds;
INSERT INTO d05.Lateness SELECT bi.bundle_item_id, bi.order_id,
  CASE WHEN bi.deliver_fact_dttm <= o.deadline_dttm THEN 1 ELSE 2 + bi.order_id % 4 END,
  bi.deliver_fact_dttm, EXTRACT(EPOCH FROM bi.deliver_fact_dttm - o.deadline_dttm)
FROM d04.BundleItem bi JOIN d01.DeliveryOrder o USING (order_id) WHERE bi.deliver_fact_dttm IS NOT NULL;

INSERT INTO d03.CourierLocation SELECT shift_id, 55.75, 37.6, :now, NULL FROM d02.Shift WHERE close_fact_dttm IS NULL;
INSERT INTO d03.CourierLocation SELECT shift_id, 55.75, 37.6, end_dttm, NULL FROM d02.Shift WHERE close_fact_dttm IS NOT NULL;
INSERT INTO d04.DarkstoreLoad SELECT i, :now, 0, FALSE, NULL FROM generate_series(1,3) i;
INSERT INTO d05.ForecastAccuracy SELECT d*3+ds, ds, date_trunc('day', :now::timestamptz)::date - 89 + d, 60, 90, 45 FROM generate_series(0,88) d, generate_series(1,3) ds;
INSERT INTO of1.ProcessedEvent SELECT n, CASE n % 4 WHEN 0 THEN 'WMS' WHEN 1 THEN 'OMS' WHEN 2 THEN 'HR' ELSE 'APP' END, 'E-'||n,
  :now::timestamptz - (2000000-n) * interval '3.8 sec' FROM generate_series(1,2000000) n;
INSERT INTO of1.RejectedEvent SELECT n, 'OMS', 'R-'||n, :now::timestamptz - n * interval '2 hours', 'Даркстор вне кластера' FROM generate_series(1,1000) n;
-- признак «просрочен» согласован с данными: срок прошёл, заказ действующий и не вручён
UPDATE d01.DeliveryOrder o SET overdue_bool = (order_status_id IN (1, 2, 4) AND deadline_dttm < :now
  AND NOT EXISTS (SELECT 1 FROM d04.BundleItem bi WHERE bi.order_id = o.order_id AND bi.deliver_fact_dttm IS NOT NULL));
VACUUM ANALYZE;
