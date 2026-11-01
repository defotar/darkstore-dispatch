-- Откат v2 -> v1: обратный порядок шагов; удалённые столбцы восстанавливаются расчётом
\set ON_ERROR_STOP 1
\timing on
\set now '''2026-10-25 18:00+03'''

-- Шаг 7 назад: выводимые столбцы и прежние таблицы
BEGIN;
ALTER TABLE d01.DeliveryOrder ADD COLUMN promise_sec INTEGER, ADD COLUMN overdue_bool BOOLEAN NOT NULL DEFAULT FALSE;
UPDATE d01.DeliveryOrder SET promise_sec = EXTRACT(EPOCH FROM deadline_dttm - place_dttm),
  overdue_bool = (order_status_id IN (1, 2, 4) AND deadline_dttm < :now);
ALTER TABLE d01.DeliveryOrder ALTER COLUMN promise_sec SET NOT NULL, DROP CONSTRAINT deliveryorder_deadline_ck,
  ADD CONSTRAINT deliveryorder_check CHECK (deadline_dttm > place_dttm AND promise_sec = EXTRACT(EPOCH FROM deadline_dttm - place_dttm));

ALTER TABLE d05.DecisionLog RENAME TO DecisionLog_v2;
CREATE TABLE d05.DecisionLog (
  decision_log_id BIGINT NOT NULL, direction_id BIGINT NOT NULL REFERENCES d04.Direction,
  parameter_id BIGINT NOT NULL REFERENCES d04.DistributionParameter,
  log_dttm TIMESTAMPTZ NOT NULL, decision_reason_desc TEXT,
  PRIMARY KEY (decision_log_id, log_dttm)) PARTITION BY RANGE (log_dttm);
CREATE TABLE d05.DecisionLog_2026_07 PARTITION OF d05.DecisionLog FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE d05.DecisionLog_2026_08 PARTITION OF d05.DecisionLog FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE d05.DecisionLog_2026_09 PARTITION OF d05.DecisionLog FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE d05.DecisionLog_2026_10 PARTITION OF d05.DecisionLog FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
INSERT INTO d05.DecisionLog SELECT * FROM d05.DecisionLog_v2;
ALTER TABLE d05.DecisionOption ADD COLUMN log_dttm TIMESTAMPTZ;
UPDATE d05.DecisionOption o SET log_dttm = l.log_dttm FROM d05.DecisionLog_v2 l WHERE l.decision_log_id = o.decision_log_id;
ALTER TABLE d05.DecisionOption ALTER COLUMN log_dttm SET NOT NULL, DROP CONSTRAINT decisionoption_decision_log_fk,
  ADD CONSTRAINT decisionoption_decision_log_id_log_dttm_fkey FOREIGN KEY (decision_log_id, log_dttm) REFERENCES d05.DecisionLog;
DROP TABLE d05.DecisionLog_v2;

ALTER TABLE d05.ForecastAccuracy RENAME TO ForecastAccuracy_v2;
CREATE TABLE d05.ForecastAccuracy (
  accuracy_id BIGINT PRIMARY KEY, darkstore_id BIGINT NOT NULL REFERENCES d01.Darkstore,
  calc_dt DATE NOT NULL, ready_error_sec INTEGER NOT NULL, release_error_sec INTEGER NOT NULL,
  supply_error_sec INTEGER NOT NULL, UNIQUE (darkstore_id, calc_dt));
INSERT INTO d05.ForecastAccuracy
  SELECT row_number() OVER (ORDER BY calc_dt, darkstore_id), darkstore_id, calc_dt,
         max(error_sec) FILTER (WHERE forecast_type_id = 1), max(error_sec) FILTER (WHERE forecast_type_id = 2),
         max(error_sec) FILTER (WHERE forecast_type_id = 3)
  FROM d05.ForecastAccuracy_v2 GROUP BY darkstore_id, calc_dt;
DROP TABLE d05.ForecastAccuracy_v2;
DROP TABLE d05.ForecastTypeDict;
COMMIT;

-- Шаг 6 назад
ALTER TABLE d04.Bundle DROP CONSTRAINT bundle_depart_ck;
ALTER TABLE d04.Direction DROP CONSTRAINT direction_target_ck;

-- Шаг 3 назад: пара снова хранится в обе стороны
BEGIN;
ALTER TABLE d01.SubzoneNeighborLink DROP CONSTRAINT subzoneneighborlink_order_ck,
  ADD CONSTRAINT subzoneneighborlink_check CHECK (subzone_id <> neighbor_subzone_id);
INSERT INTO d01.SubzoneNeighborLink SELECT neighbor_subzone_id, subzone_id FROM d01.SubzoneNeighborLink;
COMMIT;

-- Шаг 2 назад
DROP INDEX CONCURRENTLY d01.deliveryorder_active_ix;
DROP INDEX CONCURRENTLY d04.bundleitem_bundle_ix;
DROP INDEX CONCURRENTLY d04.bundleitem_order_ix;
DROP INDEX CONCURRENTLY d03.arrival_darkstore_ix;
DROP INDEX CONCURRENTLY d04.direction_target_ix;
-- Шаг 1 назад
BEGIN;
ALTER TABLE d01.DeliveryOrder DROP CONSTRAINT deliveryorder_ready_ck;
UPDATE d01.DeliveryOrder SET order_status_id = 2 WHERE order_status_id = 5;
DELETE FROM d01.OrderStatusDict WHERE order_status_id = 5;
COMMIT;

ANALYZE;
