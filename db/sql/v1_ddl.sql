-- Исходная схема v1: только ключи и ограничения целостности
CREATE SCHEMA d01; CREATE SCHEMA d02; CREATE SCHEMA d03; CREATE SCHEMA d04; CREATE SCHEMA d05; CREATE SCHEMA of1;

CREATE TABLE d01.Darkstore (
  darkstore_id BIGINT PRIMARY KEY, darkstore_code VARCHAR(64) NOT NULL UNIQUE,
  darkstore_name VARCHAR(256) NOT NULL, geozone_wkt TEXT NOT NULL,
  create_dttm TIMESTAMPTZ NOT NULL DEFAULT now(), modify_dttm TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE d01.Subzone (
  subzone_id BIGINT PRIMARY KEY, darkstore_id BIGINT NOT NULL REFERENCES d01.Darkstore,
  subzone_code VARCHAR(64) NOT NULL, subzone_name VARCHAR(256) NOT NULL,
  UNIQUE (darkstore_id, subzone_code));
CREATE TABLE d01.SubzoneNeighborLink (
  subzone_id BIGINT NOT NULL REFERENCES d01.Subzone,
  neighbor_subzone_id BIGINT NOT NULL REFERENCES d01.Subzone (subzone_id),
  PRIMARY KEY (subzone_id, neighbor_subzone_id), CHECK (subzone_id <> neighbor_subzone_id));
CREATE TABLE d01.OrderStatusDict (
  order_status_id BIGINT PRIMARY KEY, order_status_code VARCHAR(64) NOT NULL UNIQUE,
  order_status_name VARCHAR(256) NOT NULL);
CREATE TABLE d01.DeliveryOrder (
  order_id BIGINT PRIMARY KEY, order_code VARCHAR(64) NOT NULL UNIQUE,
  subzone_id BIGINT NOT NULL REFERENCES d01.Subzone,
  order_status_id BIGINT NOT NULL REFERENCES d01.OrderStatusDict,
  weight_kg NUMERIC(6,2) NOT NULL CHECK (weight_kg >= 0),
  place_dttm TIMESTAMPTZ NOT NULL, deadline_dttm TIMESTAMPTZ NOT NULL,
  promise_sec INTEGER NOT NULL,
  ready_fcst_dttm TIMESTAMPTZ, ready_fact_dttm TIMESTAMPTZ,
  assembly_delay_bool BOOLEAN NOT NULL DEFAULT FALSE, at_risk_bool BOOLEAN NOT NULL DEFAULT FALSE,
  overdue_bool BOOLEAN NOT NULL DEFAULT FALSE,
  create_dttm TIMESTAMPTZ NOT NULL DEFAULT now(), modify_dttm TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (deadline_dttm > place_dttm AND promise_sec = EXTRACT(EPOCH FROM deadline_dttm - place_dttm)));

CREATE TABLE d02.Courier (
  courier_id BIGINT PRIMARY KEY, courier_code VARCHAR(64) NOT NULL UNIQUE,
  order_limit_qnt INTEGER NOT NULL CHECK (order_limit_qnt > 0), limit_change_user VARCHAR(255),
  create_dttm TIMESTAMPTZ NOT NULL DEFAULT now(), modify_dttm TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE d02.TransportTypeDict (
  transport_type_id BIGINT PRIMARY KEY, transport_type_code VARCHAR(64) NOT NULL UNIQUE,
  transport_type_name VARCHAR(256) NOT NULL);
CREATE TABLE d02.Shift (
  shift_id BIGINT PRIMARY KEY, courier_id BIGINT NOT NULL REFERENCES d02.Courier,
  base_darkstore_id BIGINT NOT NULL REFERENCES d01.Darkstore (darkstore_id),
  transport_type_id BIGINT NOT NULL REFERENCES d02.TransportTypeDict,
  start_dttm TIMESTAMPTZ NOT NULL, end_dttm TIMESTAMPTZ NOT NULL, close_fact_dttm TIMESTAMPTZ,
  heavy_priority_bool BOOLEAN NOT NULL DEFAULT FALSE,
  pause_request_fact_dttm TIMESTAMPTZ, pause_sec INTEGER NOT NULL DEFAULT 0 CHECK (pause_sec >= 0),
  pause_start_fact_dttm TIMESTAMPTZ, pause_end_fact_dttm TIMESTAMPTZ,
  CHECK (end_dttm > start_dttm));
CREATE UNIQUE INDEX shift_open_uq ON d02.Shift (courier_id) WHERE close_fact_dttm IS NULL;

CREATE TABLE d03.CourierLocation (
  shift_id BIGINT PRIMARY KEY REFERENCES d02.Shift,
  point_lat NUMERIC(9,6) NOT NULL, point_lon NUMERIC(9,6) NOT NULL,
  receive_dttm TIMESTAMPTZ NOT NULL, release_fcst_dttm TIMESTAMPTZ);
CREATE TABLE d03.CourierSpeed (
  courier_id BIGINT PRIMARY KEY REFERENCES d02.Courier,
  speed_ratio NUMERIC(4,2) NOT NULL CHECK (speed_ratio > 0), calc_dttm TIMESTAMPTZ NOT NULL);
CREATE TABLE d03.Arrival (
  arrival_id BIGINT PRIMARY KEY, shift_id BIGINT NOT NULL REFERENCES d02.Shift,
  darkstore_id BIGINT NOT NULL REFERENCES d01.Darkstore, arrive_dttm TIMESTAMPTZ NOT NULL);

CREATE TABLE d04.DistributionParameter (
  parameter_id BIGINT PRIMARY KEY, supply_max_pct NUMERIC(5,2) NOT NULL, overdue_pct NUMERIC(5,2) NOT NULL,
  hold_max_pct NUMERIC(5,2) NOT NULL, fcst_shift_pct NUMERIC(5,2) NOT NULL,
  valid_from_dttm TIMESTAMPTZ NOT NULL UNIQUE, change_user VARCHAR(255));
CREATE TABLE d04.DarkstoreLoad (
  darkstore_id BIGINT PRIMARY KEY REFERENCES d01.Darkstore, calc_dttm TIMESTAMPTZ NOT NULL,
  late_qnt INTEGER NOT NULL, tense_bool BOOLEAN NOT NULL DEFAULT FALSE, reason_desc TEXT);
CREATE TABLE d04.OrderForecast (
  order_id BIGINT PRIMARY KEY REFERENCES d01.DeliveryOrder,
  deliver_fcst_dttm TIMESTAMPTZ, sent_fcst_dttm TIMESTAMPTZ, calc_dttm TIMESTAMPTZ NOT NULL);
CREATE TABLE d04.Direction (
  direction_id BIGINT PRIMARY KEY, shift_id BIGINT NOT NULL REFERENCES d02.Shift,
  initial_darkstore_id BIGINT NOT NULL REFERENCES d01.Darkstore (darkstore_id),
  target_darkstore_id BIGINT NOT NULL REFERENCES d01.Darkstore (darkstore_id),
  trigger_dttm TIMESTAMPTZ NOT NULL, issue_dttm TIMESTAMPTZ NOT NULL,
  change_fact_dttm TIMESTAMPTZ, close_fact_dttm TIMESTAMPTZ,
  base_fallback_bool BOOLEAN NOT NULL DEFAULT FALSE);
CREATE UNIQUE INDEX direction_open_uq ON d04.Direction (shift_id) WHERE close_fact_dttm IS NULL;
CREATE TABLE d04.BundleStatusDict (
  bundle_status_id BIGINT PRIMARY KEY, bundle_status_code VARCHAR(64) NOT NULL UNIQUE,
  bundle_status_name VARCHAR(256) NOT NULL);
CREATE TABLE d04.Bundle (
  bundle_id BIGINT PRIMARY KEY, shift_id BIGINT NOT NULL REFERENCES d02.Shift,
  subzone_id BIGINT NOT NULL REFERENCES d01.Subzone,
  bundle_status_id BIGINT NOT NULL REFERENCES d04.BundleStatusDict,
  form_dttm TIMESTAMPTZ NOT NULL, hold_sec INTEGER NOT NULL DEFAULT 0, depart_fact_dttm TIMESTAMPTZ);
CREATE UNIQUE INDEX bundle_active_uq ON d04.Bundle (shift_id) WHERE bundle_status_id IN (1, 2);
CREATE TABLE d04.BundleItem (
  bundle_item_id BIGINT PRIMARY KEY, bundle_id BIGINT NOT NULL REFERENCES d04.Bundle,
  order_id BIGINT NOT NULL REFERENCES d01.DeliveryOrder, item_ord SMALLINT NOT NULL,
  scan_fact_dttm TIMESTAMPTZ, deliver_fact_dttm TIMESTAMPTZ, remove_fact_dttm TIMESTAMPTZ,
  remove_user VARCHAR(255), remove_reason_desc TEXT);
CREATE UNIQUE INDEX bundle_item_active_uq ON d04.BundleItem (order_id) WHERE remove_fact_dttm IS NULL;

CREATE TABLE d05.LatenessCauseDict (
  lateness_cause_id BIGINT PRIMARY KEY, lateness_cause_code VARCHAR(64) NOT NULL UNIQUE,
  lateness_cause_name VARCHAR(256) NOT NULL);
CREATE TABLE d05.Lateness (
  lateness_id BIGINT PRIMARY KEY, order_id BIGINT NOT NULL UNIQUE REFERENCES d01.DeliveryOrder,
  lateness_cause_id BIGINT NOT NULL REFERENCES d05.LatenessCauseDict,
  deliver_dttm TIMESTAMPTZ NOT NULL, late_sec INTEGER NOT NULL,
  CHECK ((late_sec <= 0) = (lateness_cause_id = 1)));
CREATE TABLE d05.DecisionLog (
  decision_log_id BIGINT NOT NULL, direction_id BIGINT NOT NULL REFERENCES d04.Direction,
  parameter_id BIGINT NOT NULL REFERENCES d04.DistributionParameter,
  log_dttm TIMESTAMPTZ NOT NULL, decision_reason_desc TEXT,
  PRIMARY KEY (decision_log_id, log_dttm)) PARTITION BY RANGE (log_dttm);
CREATE TABLE d05.DecisionLog_2026_07 PARTITION OF d05.DecisionLog FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE d05.DecisionLog_2026_08 PARTITION OF d05.DecisionLog FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE d05.DecisionLog_2026_09 PARTITION OF d05.DecisionLog FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE d05.DecisionLog_2026_10 PARTITION OF d05.DecisionLog FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
-- ссылка на раздельную таблицу идёт по составному ключу
CREATE TABLE d05.DecisionOption (
  decision_option_id BIGINT PRIMARY KEY, decision_log_id BIGINT NOT NULL, log_dttm TIMESTAMPTZ NOT NULL,
  darkstore_id BIGINT NOT NULL REFERENCES d01.Darkstore,
  late_qnt INTEGER NOT NULL, supply_sec INTEGER NOT NULL, choose_bool BOOLEAN NOT NULL DEFAULT FALSE,
  FOREIGN KEY (decision_log_id, log_dttm) REFERENCES d05.DecisionLog,
  UNIQUE (decision_log_id, darkstore_id));
CREATE UNIQUE INDEX decision_option_choose_uq ON d05.DecisionOption (decision_log_id) WHERE choose_bool;
CREATE TABLE d05.ForecastAccuracy (
  accuracy_id BIGINT PRIMARY KEY, darkstore_id BIGINT NOT NULL REFERENCES d01.Darkstore,
  calc_dt DATE NOT NULL, ready_error_sec INTEGER NOT NULL, release_error_sec INTEGER NOT NULL,
  supply_error_sec INTEGER NOT NULL, UNIQUE (darkstore_id, calc_dt));

CREATE TABLE of1.ProcessedEvent (
  processed_event_id BIGINT PRIMARY KEY, source_code VARCHAR(64) NOT NULL, event_code VARCHAR(64) NOT NULL,
  receive_dttm TIMESTAMPTZ NOT NULL, UNIQUE (source_code, event_code));
CREATE TABLE of1.RejectedEvent (
  rejected_event_id BIGINT PRIMARY KEY, source_code VARCHAR(64) NOT NULL, event_code VARCHAR(64) NOT NULL,
  receive_dttm TIMESTAMPTZ NOT NULL, reject_reason_desc TEXT);
