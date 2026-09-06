-- Owned disposable database only: traditional inheritance does not inherit PK/FK constraints.
CREATE TABLE alpha.inherited_parent (key integer PRIMARY KEY, label text);
CREATE TABLE alpha.inherited_child () INHERITS (alpha.inherited_parent);
INSERT INTO alpha.inherited_parent VALUES (1, 'Parent');
INSERT INTO alpha.inherited_child VALUES (1, 'Duplicate descendant'), (2, 'Descendant only');
CREATE TABLE alpha.inherited_refs (key integer PRIMARY KEY, target integer REFERENCES alpha.inherited_parent(key));
CREATE TABLE alpha.inherited_refs_child () INHERITS (alpha.inherited_refs);
INSERT INTO alpha.inherited_refs VALUES (1, 1);
INSERT INTO alpha.inherited_refs_child VALUES (1, 1), (2, 2);
CREATE TABLE alpha.partitioned_record_parent (key integer PRIMARY KEY, label text) PARTITION BY RANGE(key);
CREATE TABLE alpha.partitioned_record_leaf PARTITION OF alpha.partitioned_record_parent FOR VALUES FROM (0) TO (10);
INSERT INTO alpha.partitioned_record_parent VALUES (3, 'Partition record');
CREATE TABLE alpha.partitioned_record_refs (key integer PRIMARY KEY REFERENCES alpha.partitioned_record_parent(key));
INSERT INTO alpha.partitioned_record_refs VALUES (3);
GRANT SELECT ON alpha.inherited_parent, alpha.inherited_child, alpha.inherited_refs, alpha.inherited_refs_child, alpha.partitioned_record_parent, alpha.partitioned_record_leaf, alpha.partitioned_record_refs TO record_reader;
