"""Замер типовых запросов: медиана Execution Time из EXPLAIN ANALYZE по 7 прогонам после прогрева."""
import json, os, subprocess, sys

PGBIN = os.environ.get("PGBIN", "/Applications/Postgres.app/Contents/Versions/17/bin")
PSQL = [PGBIN + "/psql", "-h", "127.0.0.1", "-p", os.environ.get("PGPORT", "55432"),
        "-U", "postgres", "-tAq", "-v", "ON_ERROR_STOP=1"]
NOW = "'2026-10-25 18:00+03'::timestamptz"

FUNC = """
CREATE OR REPLACE FUNCTION pg_temp.bench(q text, n int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE j json; t float8[] := '{}'; plan json;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q INTO j;
  FOR i IN 1..n LOOP
    EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q INTO j;
    t := t || (j->0->>'Execution Time')::float8;
  END LOOP;
  SELECT array_agg(x ORDER BY x) INTO t FROM unnest(t) x;
  RETURN json_build_object('ms', t[(n+1)/2], 'plan', j->0->'Plan')::text;
END $$;
"""

# Q: (база, текст для v1, текст для v2); None — запрос в этой версии не меняется
Q = {
 "Q1": ("cluster",
  f"""SELECT o.order_id, o.deadline_dttm, o.ready_fcst_dttm FROM d01.DeliveryOrder o JOIN d01.Subzone s USING (subzone_id)
      WHERE s.darkstore_id = 2 AND o.order_status_id IN (1, 2, 4)
        AND NOT EXISTS (SELECT 1 FROM d04.BundleItem bi WHERE bi.order_id = o.order_id
                        AND bi.remove_fact_dttm IS NULL AND bi.deliver_fact_dttm IS NOT NULL)""",
  f"""SELECT o.order_id, o.deadline_dttm, o.ready_fcst_dttm FROM d01.DeliveryOrder o JOIN d01.Subzone s USING (subzone_id)
      WHERE s.darkstore_id = 2 AND o.order_status_id IN (1, 2, 4)"""),
 "Q2": ("cluster",
  f"""SELECT o.order_id, o.deadline_dttm FROM d01.DeliveryOrder o JOIN d01.Subzone s USING (subzone_id)
      WHERE s.darkstore_id = 2 AND o.overdue_bool AND o.order_status_id IN (1, 2, 4)""",
  f"""SELECT o.order_id, o.deadline_dttm FROM d01.DeliveryOrder o JOIN d01.Subzone s USING (subzone_id)
      WHERE s.darkstore_id = 2 AND o.order_status_id IN (1, 2, 4) AND o.deadline_dttm < {NOW}"""),
 "Q3": ("cluster",
  """SELECT bundle_item_id, order_id, item_ord, scan_fact_dttm FROM d04.BundleItem
     WHERE bundle_id = 150001 AND remove_fact_dttm IS NULL ORDER BY item_ord""", None),
 "Q4": ("cluster",
  f"""SELECT shift_id, arrive_dttm FROM d03.Arrival WHERE darkstore_id = 1
      AND arrive_dttm > {NOW} - interval '1 hour' ORDER BY arrive_dttm""", None),
 "Q5": ("cluster",
  """SELECT s.shift_id, s.end_dttm, cl.point_lat, cl.point_lon, cl.release_fcst_dttm
     FROM d02.Shift s JOIN d03.CourierLocation cl USING (shift_id)
     WHERE s.base_darkstore_id = 1 AND s.close_fact_dttm IS NULL""", None),
 "Q5T": ("track",
  f"""SELECT p.* FROM generate_series(8901, 9000) sh,
      LATERAL (SELECT point_lat, point_lon, receive_dttm FROM d03.TrackPoint t
               WHERE t.shift_id = sh AND t.receive_dttm > {NOW} - interval '1 day'
               ORDER BY receive_dttm DESC LIMIT 1) p""",
  f"""SELECT p.* FROM generate_series(8901, 9000) sh,
      LATERAL (SELECT point_lat, point_lon, device_dttm FROM d03.TrackPoint t
               WHERE t.shift_id = sh AND t.device_dttm > {NOW} - interval '1 day'
               ORDER BY device_dttm DESC LIMIT 1) p"""),
 "Q6": ("cluster",
  f"""SELECT d.direction_id, l.log_dttm, l.decision_reason_desc, o.darkstore_id, o.late_qnt, o.choose_bool
      FROM d04.Direction d JOIN d05.DecisionLog l USING (direction_id)
      JOIN d05.DecisionOption o ON o.decision_log_id = l.decision_log_id
      WHERE d.target_darkstore_id = 1 AND d.issue_dttm >= {NOW} - interval '1 day'""", None),
 "Q7": ("cluster",
  f"""SELECT c.lateness_cause_code, count(*), avg(l.late_sec) FROM d05.Lateness l
      JOIN d05.LatenessCauseDict c USING (lateness_cause_id)
      WHERE l.deliver_dttm >= {NOW} - interval '7 days' GROUP BY c.lateness_cause_code""", None),
 "Q7J": ("cluster",
  f"""SELECT l.lateness_cause_id, count(*), avg(EXTRACT(EPOCH FROM bi.deliver_fact_dttm - o.deadline_dttm))
      FROM d05.Lateness l JOIN d04.BundleItem bi ON bi.order_id = l.order_id AND bi.deliver_fact_dttm IS NOT NULL
      JOIN d01.DeliveryOrder o ON o.order_id = l.order_id
      WHERE bi.deliver_fact_dttm >= {NOW} - interval '7 days' GROUP BY l.lateness_cause_id""", None),
 "Q8": ("track",
  f"""SELECT shift_id, receive_dttm, point_lat, point_lon FROM d03.TrackPoint
      WHERE shift_id IN (8930, 8830, 8730, 8630, 8530, 8430, 8330, 8230, 8130, 8030, 7930, 7830, 7730, 7630)
        AND receive_dttm >= {NOW} - interval '14 days' ORDER BY shift_id, receive_dttm""",
  f"""SELECT shift_id, device_dttm, point_lat, point_lon FROM d03.TrackPoint
      WHERE shift_id IN (8930, 8830, 8730, 8630, 8530, 8430, 8330, 8230, 8130, 8030, 7930, 7830, 7730, 7630)
        AND device_dttm >= {NOW} - interval '14 days' ORDER BY shift_id, device_dttm"""),
 "Q9": ("cluster",
  """SELECT 1 FROM of1.ProcessedEvent WHERE source_code = 'WMS' AND event_code = 'E-1999996'""", None),
}

def run(db, sql):
    r = subprocess.run(PSQL + ["-d", db], input=FUNC + sql, capture_output=True, text=True)
    if r.returncode: sys.exit(r.stderr)
    return r.stdout.strip()

def nodes(p, out):
    out.append(p["Node Type"] + (" " + p.get("Index Name", "") if "Index Name" in p else ""))
    for c in p.get("Plans", []): nodes(c, out)
    return out

def bench(db, q):
    out = json.loads(run(db, "SELECT pg_temp.bench($q$" + q + "$q$, 7);"))
    return round(out["ms"], 3), [n for n in nodes(out["plan"], []) if "Scan" in n]

ver = sys.argv[1]
if ver == "extra":
    # проверки «индекс не нужен»: внешние ключи на Shift и отчёт опозданий с индексом и без
    for q in ["SELECT 1 FROM d04.Bundle WHERE shift_id = 4550", "SELECT 1 FROM d04.Direction WHERE shift_id = 4550",
              "SELECT 1 FROM d03.Arrival WHERE shift_id = 4550"]:
        print(q, *bench("cluster", q))
    print("Q7 без индекса", *bench("cluster", Q["Q7"][1]))
    run("cluster", "CREATE INDEX lat_tmp ON d05.Lateness (deliver_dttm); ANALYZE d05.Lateness;")
    print("Q7 с индексом Lateness(deliver_dttm)", *bench("cluster", Q["Q7"][1]))
    run("cluster", "DROP INDEX d05.lat_tmp;")
    sys.exit()
res = {}
for k, (db, q1, q2) in Q.items():
    q = q2 if (ver == "v2" and q2) else q1
    out = json.loads(run(db, "SELECT pg_temp.bench($q$" + q + "$q$, 7);"))
    ns = [n for n in nodes(out["plan"], []) if "Scan" in n]
    res[k] = {"ms": round(out["ms"], 3), "scans": ns}
    print(k, res[k]["ms"], "ms", "; ".join(dict.fromkeys(ns)))
json.dump(res, open(f"results/bench_{sys.argv[2] if len(sys.argv) > 2 else ver}.json", "w"), ensure_ascii=False, indent=1)
