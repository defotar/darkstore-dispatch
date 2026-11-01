BEGIN;
DELETE FROM d05.DecisionOption WHERE decision_log_id IN (SELECT decision_log_id FROM d05.DecisionLog WHERE log_dttm < '2026-07-29 00:00+03');
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) DELETE FROM d05.DecisionLog WHERE log_dttm < '2026-07-29 00:00+03';
ROLLBACK;
