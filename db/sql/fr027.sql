\set s random(8901, 9000)
BEGIN;
SELECT d04.fr027(:s);
ROLLBACK;
