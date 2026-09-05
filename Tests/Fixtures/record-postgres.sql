-- Owned disposable database only. No production names or business rules.
CREATE SCHEMA alpha;
CREATE SCHEMA beta;
CREATE TABLE alpha.people (tenant integer, code integer, name text, note text, payload jsonb, tags text[], PRIMARY KEY(tenant,code));
CREATE TABLE beta.people (tenant integer, code integer, name text, PRIMARY KEY(tenant,code));
CREATE TABLE alpha.links (key integer PRIMARY KEY, tenant integer, source integer, target integer,
 FOREIGN KEY(tenant,source) REFERENCES alpha.people(tenant,code),
 FOREIGN KEY(tenant,target) REFERENCES alpha.people(tenant,code));
CREATE TABLE alpha.tree (key integer PRIMARY KEY, parent integer REFERENCES alpha.tree(key), label text);
CREATE TABLE alpha.no_key (value text);
CREATE TABLE alpha.typed_keys (key uuid PRIMARY KEY, amount numeric(40,8), bytes bytea);
INSERT INTO alpha.people VALUES (1,1,'Ada','', '{"large":123456789012345678901234567890}', ARRAY['a','b']), (1,2,'Ben',NULL,'{}',ARRAY[]::text[]), (2,1,'Cleo',repeat('Long value ',10000),'{"hello":"world"}',NULL);
INSERT INTO beta.people VALUES (1,1,'Other schema');
INSERT INTO alpha.links SELECT n,1,1,2 FROM generate_series(1,180) AS n;
INSERT INTO alpha.links VALUES (181,1,NULL,NULL);
INSERT INTO alpha.tree VALUES (1,NULL,'Root'),(2,1,'Child');
UPDATE alpha.tree SET parent=2 WHERE key=1;
INSERT INTO alpha.tree VALUES (3,3,'Self');
INSERT INTO alpha.no_key VALUES ('duplicate'),('duplicate');
INSERT INTO alpha.typed_keys VALUES ('12345678-1234-1234-1234-123456789abc',123456789012345678901234567890.12345678,decode('00ff','hex'));
CREATE TABLE alpha.typed_refs (key integer PRIMARY KEY, ref uuid REFERENCES alpha.typed_keys(key));
INSERT INTO alpha.typed_refs VALUES (1,'12345678-1234-1234-1234-123456789abc');
CREATE ROLE record_reader LOGIN;
GRANT USAGE ON SCHEMA alpha,beta TO record_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA alpha,beta TO record_reader;
ALTER ROLE record_reader SET default_transaction_read_only=on;
