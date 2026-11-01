-- Сценарий FR027 на целевой схеме: у каждой из 100 открытых смен последняя связка «в доставке», последний заказ не вручён
\set ON_ERROR_STOP 1
CREATE TEMP TABLE b AS SELECT max(bundle_id) bundle_id FROM d04.Bundle WHERE shift_id BETWEEN 8901 AND 9000 GROUP BY shift_id;
UPDATE d04.Bundle SET bundle_status_id = 2 WHERE bundle_id IN (SELECT bundle_id FROM b);
UPDATE d01.DeliveryOrder o SET order_status_id = 2 FROM d04.BundleItem bi
  WHERE bi.order_id = o.order_id AND bi.bundle_id IN (SELECT bundle_id FROM b) AND bi.item_ord = 2;
UPDATE d04.BundleItem SET deliver_fact_dttm = NULL WHERE bundle_id IN (SELECT bundle_id FROM b) AND item_ord = 2;
CREATE SEQUENCE IF NOT EXISTS d04.bench_seq START 10000000;
-- Обращения к БД при отметке вручения последнего заказа и выдаче направления.
-- Время в пути берётся из кэша, прогноз опозданий по дарксторам посчитан заранее (FR023).
CREATE OR REPLACE FUNCTION d04.fr027(s BIGINT) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE bid BIGINT; oid BIGINT; base BIGINT; par BIGINT; tgt BIGINT; did BIGINT; n INT;
BEGIN
  SELECT bundle_id INTO bid FROM d04.Bundle WHERE shift_id = s AND bundle_status_id IN (1, 2);
  UPDATE d04.BundleItem SET deliver_fact_dttm = now()
   WHERE bundle_id = bid AND remove_fact_dttm IS NULL AND deliver_fact_dttm IS NULL RETURNING order_id INTO oid;
  UPDATE d01.DeliveryOrder SET order_status_id = 5, modify_dttm = now() WHERE order_id = oid;   -- Д-3
  UPDATE d04.Bundle SET bundle_status_id = 3 WHERE bundle_id = bid;
  SELECT base_darkstore_id INTO base FROM d02.Shift WHERE shift_id = s AND close_fact_dttm IS NULL;
  PERFORM point_lat, point_lon FROM d03.CourierLocation WHERE shift_id = s;                     -- Д-1
  SELECT parameter_id INTO par FROM d04.DistributionParameter WHERE valid_from_dttm <= now() ORDER BY valid_from_dttm DESC LIMIT 1;
  SELECT darkstore_id INTO tgt FROM d04.DarkstoreLoad ORDER BY late_qnt, darkstore_id <> base LIMIT 1;
  SELECT count(*) INTO n FROM d01.DeliveryOrder o JOIN d01.Subzone z USING (subzone_id)
   WHERE z.darkstore_id = tgt AND o.order_status_id IN (1, 2, 4);                                -- Q1
  did := nextval('d04.bench_seq');
  INSERT INTO d04.Direction (direction_id, shift_id, initial_darkstore_id, target_darkstore_id, trigger_dttm, issue_dttm)
  VALUES (did, s, tgt, tgt, now(), now());
  INSERT INTO d05.DecisionLog VALUES (did, did, par, now(), 'Наименьший прогноз опозданий');
  INSERT INTO d05.DecisionOption (decision_option_id, decision_log_id, darkstore_id, late_qnt, supply_sec, choose_bool)
  SELECT did * 3 + l.darkstore_id, did, l.darkstore_id, l.late_qnt, 600, l.darkstore_id = tgt FROM d04.DarkstoreLoad l;
  RETURN did;
END $$;
ANALYZE;
