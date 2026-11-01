\set ON_ERROR_STOP 1
\timing on
BEGIN;
CREATE TABLE d03.TrackPoint_v1 (
  track_point_id BIGINT NOT NULL, shift_id BIGINT NOT NULL,
  point_lat NUMERIC(9,6) NOT NULL, point_lon NUMERIC(9,6) NOT NULL, receive_dttm TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (track_point_id, receive_dttm)) PARTITION BY RANGE (receive_dttm);
DO $$ DECLARE d date; BEGIN
  FOR d IN SELECT generate_series('2026-09-26'::date, '2026-10-25'::date, '1 day')::date LOOP
    EXECUTE format('CREATE TABLE d03.TrackPoint_v1_%s PARTITION OF d03.TrackPoint_v1 FOR VALUES FROM (%L) TO (%L)',
                   to_char(d,'YYYYMMDD'), d, d + 1);
  END LOOP; END $$;
INSERT INTO d03.TrackPoint_v1
  SELECT row_number() OVER (ORDER BY receive_dttm, shift_id), shift_id, point_lat, point_lon, receive_dttm FROM d03.TrackPoint;
DROP TABLE d03.TrackPoint;
ALTER TABLE d03.TrackPoint_v1 RENAME TO TrackPoint;
COMMIT;
ANALYZE d03.TrackPoint;
