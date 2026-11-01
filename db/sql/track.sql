CREATE SCHEMA d03;
-- в v1 ключ track_point_id; у раздельной таблицы ключ обязан включать ключ раздела
CREATE TABLE d03.TrackPoint (
  track_point_id BIGINT NOT NULL, shift_id BIGINT NOT NULL,
  point_lat NUMERIC(9,6) NOT NULL, point_lon NUMERIC(9,6) NOT NULL, receive_dttm TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (track_point_id, receive_dttm)) PARTITION BY RANGE (receive_dttm);
DO $$ DECLARE d date; BEGIN
  FOR d IN SELECT generate_series('2026-09-26'::date, '2026-10-25'::date, '1 day')::date LOOP
    EXECUTE format('CREATE TABLE d03.TrackPoint_%s PARTITION OF d03.TrackPoint FOR VALUES FROM (%L) TO (%L)',
                   to_char(d,'YYYYMMDD'), d, d + 1);
  END LOOP; END $$;
INSERT INTO d03.TrackPoint
SELECT row_number() OVER (), d*100+k+1, 55.7 + random()*0.1, 37.5 + random()*0.1,
       date_trunc('day', '2026-10-25 18:00+03'::timestamptz) - (89-d) * interval '1 day' + interval '8 hours' + t * interval '10 sec'
FROM generate_series(60,89) d, generate_series(0,99) k, generate_series(0,4319) t
WHERE date_trunc('day', '2026-10-25 18:00+03'::timestamptz) - (89-d) * interval '1 day' + interval '8 hours' + t * interval '10 sec' <= '2026-10-25 18:00+03';
VACUUM ANALYZE;
