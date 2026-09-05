-- Owned disposable record fixture. Numeric specials require unbounded numeric.
CREATE TABLE IF NOT EXISTS alpha.numeric_special_keys (key numeric PRIMARY KEY, label text);
CREATE TABLE IF NOT EXISTS alpha.numeric_special_refs (key integer PRIMARY KEY, ref numeric REFERENCES alpha.numeric_special_keys(key));
INSERT INTO alpha.numeric_special_keys VALUES (0,'zero'),('NaN','not a number'),('Infinity','positive infinity'),('-Infinity','negative infinity') ON CONFLICT DO NOTHING;
INSERT INTO alpha.numeric_special_refs VALUES (1,0),(2,'NaN'),(3,'Infinity'),(4,'-Infinity') ON CONFLICT DO NOTHING;
GRANT SELECT ON alpha.numeric_special_keys,alpha.numeric_special_refs TO record_reader;

CREATE TABLE IF NOT EXISTS alpha.money_keys (key money PRIMARY KEY, label text);
CREATE TABLE IF NOT EXISTS alpha.money_refs (key integer PRIMARY KEY, ref money REFERENCES alpha.money_keys(key));
INSERT INTO alpha.money_keys VALUES ((0::numeric)::money,'zero'),((-0.01::numeric)::money,'negative cent'),((123.45::numeric)::money,'positive amount') ON CONFLICT DO NOTHING;
INSERT INTO alpha.money_refs VALUES (1,(0::numeric)::money),(2,(-0.01::numeric)::money),(3,(123.45::numeric)::money) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS alpha.money_array_keys (key money[] PRIMARY KEY);
CREATE TABLE IF NOT EXISTS alpha.money_array_refs (key integer PRIMARY KEY, ref money[] REFERENCES alpha.money_array_keys(key));
INSERT INTO alpha.money_array_keys VALUES ((ARRAY[-0.01,123.45]::numeric[])::money[]) ON CONFLICT DO NOTHING;
INSERT INTO alpha.money_array_refs VALUES (1,(ARRAY[-0.01,123.45]::numeric[])::money[]) ON CONFLICT DO NOTHING;
GRANT SELECT ON alpha.money_keys,alpha.money_refs,alpha.money_array_keys,alpha.money_array_refs TO record_reader;
