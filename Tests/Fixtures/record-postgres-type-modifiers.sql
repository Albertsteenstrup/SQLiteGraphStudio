-- Owned disposable database only: deliberately unvalidated legacy FK rows.
CREATE TABLE alpha.modifier_parent (v varchar(2) PRIMARY KEY, n numeric(4,1) UNIQUE, c char(2) UNIQUE, t timestamp(3) UNIQUE);
INSERT INTO alpha.modifier_parent VALUES ('ab',1.2,'xy','2024-01-01 00:00:00.123');
CREATE TABLE alpha.modifier_child (key integer PRIMARY KEY, v varchar(8), n numeric(6,2), c varchar(8), t timestamp(6));
INSERT INTO alpha.modifier_child VALUES (1,'abcd',1.24,'xyz','2024-01-01 00:00:00.1234'),(2,'ab',1.20,'xy','2024-01-01 00:00:00.123');
ALTER TABLE alpha.modifier_child ADD CONSTRAINT modifier_v FOREIGN KEY(v) REFERENCES alpha.modifier_parent(v) NOT VALID;
ALTER TABLE alpha.modifier_child ADD CONSTRAINT modifier_n FOREIGN KEY(n) REFERENCES alpha.modifier_parent(n) NOT VALID;
ALTER TABLE alpha.modifier_child ADD CONSTRAINT modifier_c FOREIGN KEY(c) REFERENCES alpha.modifier_parent(c) NOT VALID;
ALTER TABLE alpha.modifier_child ADD CONSTRAINT modifier_t FOREIGN KEY(t) REFERENCES alpha.modifier_parent(t) NOT VALID;
GRANT SELECT ON alpha.modifier_parent,alpha.modifier_child TO record_reader;
