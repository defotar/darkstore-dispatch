\set ON_ERROR_STOP 1
\timing on
-- Трек: ключ (смена, время точки на устройстве) вместо суррогатного; повторная отправка точки отклоняется,
-- пакет точек одной транзакцией вставляется без конфликта. Разделы — по времени устройства.
BEGIN;
CREATE TABLE d03.TrackPoint_v2 (
  shift_id BIGINT NOT NULL, device_dttm TIMESTAMPTZ NOT NULL,
  point_lat NUMERIC(9,6) NOT NULL, point_lon NUMERIC(9,6) NOT NULL, receive_dttm TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (shift_id, device_dttm),
  CONSTRAINT trackpoint_delay_ck CHECK (receive_dttm - device_dttm BETWEEN interval '-5 min' AND interval '1 day')
) PARTITION BY RANGE (device_dttm);
DO $$ DECLARE d date; BEGIN
  FOR d IN SELECT generate_series('2026-09-26'::date, '2026-10-25'::date, '1 day')::date LOOP
    EXECUTE format('CREATE TABLE d03.TrackPoint_v2_%s PARTITION OF d03.TrackPoint_v2 FOR VALUES FROM (%L) TO (%L)',
                   to_char(d,'YYYYMMDD'), d, d + 1);
  END LOOP; END $$;
-- у старых точек времени устройства нет: берётся время приёма; повторы с тем же временем отбрасываются
INSERT INTO d03.TrackPoint_v2
  SELECT DISTINCT ON (shift_id, receive_dttm) shift_id, receive_dttm, point_lat, point_lon, receive_dttm
  FROM d03.TrackPoint ORDER BY shift_id, receive_dttm, track_point_id;
DROP TABLE d03.TrackPoint;
ALTER TABLE d03.TrackPoint_v2 RENAME TO TrackPoint;
COMMIT;
ANALYZE d03.TrackPoint;
