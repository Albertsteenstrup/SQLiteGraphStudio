-- Owned disposable database only: FK base types may differ without a typmod.
CREATE TABLE alpha.mixed_numeric_parent (key numeric PRIMARY KEY);
CREATE TABLE alpha.mixed_numeric_child (key integer PRIMARY KEY REFERENCES alpha.mixed_numeric_parent(key));
INSERT INTO alpha.mixed_numeric_parent VALUES (1), (1.3);
INSERT INTO alpha.mixed_numeric_child VALUES (1);
CREATE TABLE alpha.mixed_integer_parent (key bigint PRIMARY KEY);
CREATE TABLE alpha.mixed_integer_child (key smallint PRIMARY KEY REFERENCES alpha.mixed_integer_parent(key));
INSERT INTO alpha.mixed_integer_parent VALUES (7), (70000);
INSERT INTO alpha.mixed_integer_child VALUES (7);
GRANT SELECT ON alpha.mixed_numeric_parent, alpha.mixed_numeric_child, alpha.mixed_integer_parent, alpha.mixed_integer_child TO record_reader;
