-- Контрольные суммы данных в форме v1 (до миграции и после отката) и проверки v2
\set ON_ERROR_STOP 1
\set now '''2026-10-25 18:00+03'''
\if :{?v2}
SELECT 'DeliveryOrder' t, count(*) n, md5(string_agg(concat_ws(',', order_id, CASE order_status_id WHEN 5 THEN 2 ELSE order_status_id END,
         EXTRACT(EPOCH FROM deadline_dttm - place_dttm)::int, (order_status_id IN (1, 2, 4) AND deadline_dttm < :now)), ';' ORDER BY order_id)) h
  FROM d01.DeliveryOrder
UNION ALL SELECT 'SubzoneNeighborLink', count(*), md5(string_agg(p, ';' ORDER BY p)) FROM (
  SELECT subzone_id || '-' || neighbor_subzone_id p FROM d01.SubzoneNeighborLink
  UNION ALL SELECT neighbor_subzone_id || '-' || subzone_id FROM d01.SubzoneNeighborLink) x
UNION ALL SELECT 'ForecastAccuracy', count(*), md5(string_agg(r, ';' ORDER BY r)) FROM (
  SELECT concat_ws(',', darkstore_id, calc_dt, max(error_sec) FILTER (WHERE forecast_type_id = 1),
         max(error_sec) FILTER (WHERE forecast_type_id = 2), max(error_sec) FILTER (WHERE forecast_type_id = 3)) r
  FROM d05.ForecastAccuracy GROUP BY darkstore_id, calc_dt) x
UNION ALL SELECT 'DecisionLog', count(*), md5(string_agg(concat_ws(',', decision_log_id, direction_id, parameter_id, log_dttm, decision_reason_desc), ';' ORDER BY decision_log_id)) FROM d05.DecisionLog
UNION ALL SELECT 'DecisionOption', count(*), md5(string_agg(concat_ws(',', o.decision_option_id, o.decision_log_id, l.log_dttm, o.darkstore_id, o.late_qnt, o.supply_sec, o.choose_bool), ';' ORDER BY o.decision_option_id))
  FROM d05.DecisionOption o JOIN d05.DecisionLog l USING (decision_log_id)
UNION ALL SELECT 'Неподтверждённые ограничения', count(*), '' FROM pg_constraint WHERE NOT convalidated
UNION ALL SELECT 'Вручено, но не DELIVERED', count(*), '' FROM d04.BundleItem bi JOIN d01.DeliveryOrder o USING (order_id)
  WHERE bi.deliver_fact_dttm IS NOT NULL AND o.order_status_id <> 5
ORDER BY 1;
\else
SELECT 'DeliveryOrder' t, count(*) n, md5(string_agg(concat_ws(',', order_id, order_status_id, promise_sec, overdue_bool), ';' ORDER BY order_id)) h
  FROM d01.DeliveryOrder
UNION ALL SELECT 'SubzoneNeighborLink', count(*), md5(string_agg(subzone_id || '-' || neighbor_subzone_id, ';' ORDER BY subzone_id || '-' || neighbor_subzone_id)) FROM d01.SubzoneNeighborLink
UNION ALL SELECT 'ForecastAccuracy', count(*), md5(string_agg(r, ';' ORDER BY r)) FROM (
  SELECT concat_ws(',', darkstore_id, calc_dt, ready_error_sec, release_error_sec, supply_error_sec) r FROM d05.ForecastAccuracy) x
UNION ALL SELECT 'DecisionLog', count(*), md5(string_agg(concat_ws(',', decision_log_id, direction_id, parameter_id, log_dttm, decision_reason_desc), ';' ORDER BY decision_log_id)) FROM d05.DecisionLog
UNION ALL SELECT 'DecisionOption', count(*), md5(string_agg(concat_ws(',', decision_option_id, decision_log_id, log_dttm, darkstore_id, late_qnt, supply_sec, choose_bool), ';' ORDER BY decision_option_id)) FROM d05.DecisionOption
UNION ALL SELECT 'Неподтверждённые ограничения', count(*), '' FROM pg_constraint WHERE NOT convalidated
ORDER BY 1;
\endif
