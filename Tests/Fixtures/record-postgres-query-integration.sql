-- Supplemental query-checkpoint fixture; seed only the task-owned disposable database.
CREATE TABLE public.items (tenant integer NOT NULL, id integer NOT NULL, label text, amount numeric(30,10), active boolean, PRIMARY KEY(tenant,id));
INSERT INTO public.items SELECT i%3,i,CASE WHEN i%5=0 THEN NULL ELSE 'group-'||(i%7)::text END,i+0.1234567890,i%2=0 FROM generate_series(1,1205) AS i;
CREATE TABLE public.keyless(label text,value integer);
INSERT INTO public.keyless VALUES ('same',1),('same',1),('other',2);
CREATE VIEW public.item_view AS SELECT label,amount FROM public.items;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO record_reader;
