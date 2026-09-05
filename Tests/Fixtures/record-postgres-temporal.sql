CREATE TABLE alpha.temporal_keys (key timestamp(6) PRIMARY KEY);
CREATE TABLE alpha.temporal_refs (key integer PRIMARY KEY, ref timestamp(6) REFERENCES alpha.temporal_keys(key));
INSERT INTO alpha.temporal_keys VALUES ('2026-09-05 12:34:56.000042'), ('2026-09-05 12:34:56.000043');
INSERT INTO alpha.temporal_refs SELECT row_number() OVER (),key FROM alpha.temporal_keys;
GRANT SELECT ON alpha.temporal_keys,alpha.temporal_refs TO record_reader;
