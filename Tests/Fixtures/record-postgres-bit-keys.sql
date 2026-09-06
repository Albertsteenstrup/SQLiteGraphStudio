-- Owned disposable database only: fixed-bit scalar and array keys retain all bits.
CREATE TABLE alpha.bit_record_parent (key bit(4) PRIMARY KEY, bits bit(4)[] UNIQUE);
INSERT INTO alpha.bit_record_parent VALUES (B'1010', ARRAY[B'1010']);
CREATE TABLE alpha.bit_record_refs (key bit(4), bits bit(4)[]);
INSERT INTO alpha.bit_record_refs VALUES (B'1010', ARRAY[B'1010']);
ALTER TABLE alpha.bit_record_refs ADD FOREIGN KEY (key) REFERENCES alpha.bit_record_parent(key) NOT VALID;
-- PostgreSQL 17's bit[] FK trigger itself rejects its anyarray comparison;
-- keep a catalog-declared legacy FK so the browser comparison is tested directly.
ALTER TABLE alpha.bit_record_refs ADD FOREIGN KEY (bits) REFERENCES alpha.bit_record_parent(bits) NOT VALID;
GRANT SELECT ON alpha.bit_record_parent, alpha.bit_record_refs TO record_reader;
