-- ════════════════════════════════════════════════════════════════════
-- HALIEL · DIAGNÓSTICO DEL MÓDULO DE ENTRETENIMIENTO  (SOLO LECTURA)
--
-- No modifica, no borra y no crea nada permanente: solo lee y arma un
-- informe en una tabla temporal que desaparece al terminar.
--
-- CÓMO EJECUTARLO
--   1. Supabase → SQL Editor → New query.
--   2. Pega TODO este archivo y pulsa "Run".
--   3. Abajo aparece una tabla con el informe. Pulsa "Export" → CSV (o copia
--      el resultado) y envíamelo para preparar la recuperación.
-- ════════════════════════════════════════════════════════════════════

create temp table if not exists diag (
  orden     int,
  seccion   text,
  detalle   text,
  cantidad  numeric,
  datos     jsonb
) on commit preserve rows;
truncate diag;

do $$
declare
  n numeric; j jsonb; existe boolean;
begin
  -- ── 0. Estructura: columnas y reglas de borrado en cascada ──
  select jsonb_agg(jsonb_build_object('tabla', table_name, 'columna', column_name, 'tipo', data_type, 'nulo', is_nullable) order by table_name, ordinal_position)
    into j from information_schema.columns
   where table_schema = 'public' and table_name in ('streaming_suscripciones','streaming_clientes','streaming_pagos','streaming_plataformas','cliente_movimientos');
  insert into diag values (0, 'Estructura', 'Columnas de las tablas de Entretenimiento', null, j);

  select jsonb_agg(jsonb_build_object('tabla', tc.table_name, 'columna', kcu.column_name, 'apunta_a', ccu.table_name, 'al_borrar', rc.delete_rule))
    into j
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu on kcu.constraint_name = tc.constraint_name and kcu.table_schema = tc.table_schema
    join information_schema.constraint_column_usage ccu on ccu.constraint_name = tc.constraint_name and ccu.table_schema = tc.table_schema
    join information_schema.referential_constraints rc on rc.constraint_name = tc.constraint_name and rc.constraint_schema = tc.table_schema
   where tc.table_schema = 'public' and tc.constraint_type = 'FOREIGN KEY'
     and tc.table_name in ('streaming_suscripciones','streaming_pagos','cliente_movimientos');
  insert into diag values (0, 'Estructura', 'Relaciones (al_borrar = CASCADE significa que borrar el cliente borra sus ventas/pagos)', null, j);

  select jsonb_agg(jsonb_build_object('indice', indexname, 'definicion', indexdef)) into j
    from pg_indexes where schemaname = 'public' and tablename = 'streaming_suscripciones';
  insert into diag values (0, 'Estructura', 'Índices de streaming_suscripciones (¿hay alguno UNIQUE sobre id_venta?)', null, j);

  -- ── 1. Resumen ──
  select count(*) into n from streaming_suscripciones;
  insert into diag values (1, 'Resumen', 'Filas en streaming_suscripciones (una por plataforma vendida)', n, null);
  if n >= 1000 then
    insert into diag values (1, 'Resumen', '⚠️ Más de 1000 filas: la app actual solo carga las primeras 1000 y oculta el resto', n, null);
  end if;
  select count(distinct id_venta) into n from streaming_suscripciones where id_venta is not null;
  insert into diag values (1, 'Resumen', 'IDs de venta distintos', n, null);
  select count(*) into n from (select distinct id_venta, cliente_id::text from streaming_suscripciones) x;
  insert into diag values (1, 'Resumen', 'Ventas reales (ID de venta + cliente)', n, null);
  select count(*) into n from streaming_clientes;
  insert into diag values (1, 'Resumen', 'Clientes registrados', n, null);

  -- ── 2. IDs de venta repetidos entre clientes distintos ──
  select count(*) into n from (
    select id_venta from streaming_suscripciones where id_venta is not null
     group by id_venta having count(distinct cliente_id::text) > 1) x;
  insert into diag values (2, 'IDs repetidos', 'IDs de venta compartidos por 2 o más clientes', n, null);

  select coalesce(jsonb_agg(v order by v->>'id_venta'), '[]'::jsonb) into j from (
    select jsonb_build_object(
      'id_venta', s.id_venta,
      'ventas', jsonb_agg(jsonb_build_object(
          'fila', s.id::text, 'cliente_id', s.cliente_id::text, 'cliente', c.nombre,
          'plataforma', p.nombre, 'precio', s.precio_venta, 'inicio', s.fecha_inicio::text,
          'vence', s.fecha_vencimiento::text, 'estado', s.estado, 'creada', s.created_at::text) order by s.created_at)) v
      from streaming_suscripciones s
      left join streaming_clientes c on c.id::text = s.cliente_id::text
      left join streaming_plataformas p on p.id::text = s.plataforma_id::text
     where s.id_venta in (select id_venta from streaming_suscripciones where id_venta is not null
                           group by id_venta having count(distinct cliente_id::text) > 1)
     group by s.id_venta) x;
  insert into diag values (2, 'IDs repetidos', 'Detalle de cada ID repetido (filas, cliente, plataforma y fecha de creación)', jsonb_array_length(j), j);

  select count(*) into n from (
    select s.id_venta, s.cliente_id from streaming_suscripciones s
     where s.id_venta in (select id_venta from streaming_suscripciones where id_venta is not null
                           group by id_venta having count(distinct cliente_id::text) > 1)
     group by s.id_venta, s.cliente_id) x;
  insert into diag values (2, 'IDs repetidos', 'Ventas afectadas (cada cliente que comparte un ID cuenta como una venta)', n, null);

  -- ── 3. Filas sin ID de venta o con formato distinto ──
  select count(*) into n from streaming_suscripciones where id_venta is null or id_venta = '';
  insert into diag values (3, 'Formato', 'Filas sin ID de venta', n, null);
  select count(*) into n from streaming_suscripciones where id_venta is not null and id_venta !~ '^NPE-\d{4}-\d{6}$';
  select coalesce(jsonb_agg(distinct id_venta), '[]'::jsonb) into j from streaming_suscripciones where id_venta is not null and id_venta !~ '^NPE-\d{4}-\d{6}$';
  insert into diag values (3, 'Formato', 'Filas con ID fuera del formato NPE-AAAA-000000 (ej. hechos con la hora por un error)', n, j);

  -- ── 4. Huérfanas (venta sin cliente o sin plataforma) ──
  select count(*) into n from streaming_suscripciones s where not exists (select 1 from streaming_clientes c where c.id::text = s.cliente_id::text);
  select coalesce(jsonb_agg(jsonb_build_object('fila', s.id::text, 'id_venta', s.id_venta, 'cliente_id', s.cliente_id::text)), '[]'::jsonb) into j
    from streaming_suscripciones s where not exists (select 1 from streaming_clientes c where c.id::text = s.cliente_id::text);
  insert into diag values (4, 'Huérfanas', 'Filas de venta cuyo cliente no existe', n, j);
  select count(*) into n from streaming_suscripciones s where not exists (select 1 from streaming_plataformas p where p.id::text = s.plataforma_id::text);
  insert into diag values (4, 'Huérfanas', 'Filas de venta cuya plataforma no existe', n, null);

  -- ── 5. Clientes ──
  select count(*) into n from streaming_clientes where whatsapp is null or whatsapp = '';
  select coalesce(jsonb_agg(jsonb_build_object('id', id::text, 'nombre', nombre)), '[]'::jsonb) into j from streaming_clientes where whatsapp is null or whatsapp = '';
  insert into diag values (5, 'Clientes', 'Clientes sin WhatsApp (rompen la búsqueda y la lista queda vacía)', n, j);
  select count(*) into n from streaming_clientes where coalesce(estado,'') <> 'activo';
  select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'estado', estado)), '[]'::jsonb) into j from streaming_clientes where coalesce(estado,'') <> 'activo';
  insert into diag values (5, 'Clientes', 'Clientes no activos (no aparecen al buscar cliente en "Nueva venta")', n, j);
  select count(*) into n from streaming_clientes c where not exists (select 1 from streaming_suscripciones s where s.cliente_id::text = c.id::text);
  insert into diag values (5, 'Clientes', 'Clientes sin ninguna venta', n, null);
  select count(*) into n from (select lower(trim(nombre)) from streaming_clientes group by lower(trim(nombre)) having count(*) > 1) x;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into j from (select lower(trim(nombre)) nombre, count(*) veces from streaming_clientes group by lower(trim(nombre)) having count(*) > 1) x;
  insert into diag values (5, 'Clientes', 'Nombres de cliente repetidos (posibles clientes duplicados)', n, j);

  -- ── 6. Huecos en la numeración (posibles ventas eliminadas) ──
  select coalesce(jsonb_agg(x order by x), '[]'::jsonb) into j from (
    select format('NPE-%s-%s', anio, lpad(g::text, 6, '0')) x
      from (select substring(id_venta from 5 for 4) anio, max(substring(id_venta from 10)::int) mx
              from streaming_suscripciones where id_venta ~ '^NPE-\d{4}-\d{6}$' and substring(id_venta from 10)::int < 100000 group by 1) m,
           generate_series(1, m.mx) g
     where not exists (select 1 from streaming_suscripciones s where s.id_venta = format('NPE-%s-%s', m.anio, lpad(g::text, 6, '0')))) y;
  insert into diag values (6, 'Ventas eliminadas', 'Números de venta que ya no existen (huecos en la numeración)', jsonb_array_length(j), j);
  select count(distinct id_venta) into n from streaming_suscripciones where id_venta ~ '^NPE-\d{4}-\d{6}$' and substring(id_venta from 10)::int >= 100000;
  select coalesce(jsonb_agg(distinct id_venta), '[]'::jsonb) into j from streaming_suscripciones where id_venta ~ '^NPE-\d{4}-\d{6}$' and substring(id_venta from 10)::int >= 100000;
  insert into diag values (3, 'Formato', 'IDs con número fuera de la secuencia (generados con la hora cuando falló la consulta)', n, j);

  -- ── 7. Evidencia para recuperar ventas eliminadas ──
  select to_regclass('public.streaming_pagos') is not null into existe;
  if existe then
    execute $q$ select count(*) from streaming_pagos pg
                where pg.suscripcion_id is not null
                  and not exists (select 1 from streaming_suscripciones s where s.id::text = pg.suscripcion_id::text) $q$ into n;
    execute $q$ select coalesce(jsonb_agg(jsonb_build_object('pago', pg.id::text, 'suscripcion_id', pg.suscripcion_id::text, 'cliente_id', pg.cliente_id::text,
                  'cliente', c.nombre, 'plataforma_id', pg.plataforma_id::text, 'monto', pg.monto, 'meses', pg.duracion_meses, 'fecha', pg.fecha_pago::text, 'notas', pg.notas)), '[]'::jsonb)
                from streaming_pagos pg left join streaming_clientes c on c.id::text = pg.cliente_id::text
               where pg.suscripcion_id is not null
                 and not exists (select 1 from streaming_suscripciones s where s.id::text = pg.suscripcion_id::text) $q$ into j;
    insert into diag values (7, 'Recuperación', 'Pagos cuya venta ya no existe (sirven para reconstruirla)', n, j);
    execute $q$ select count(*) from streaming_pagos where suscripcion_id is null $q$ into n;
    insert into diag values (7, 'Recuperación', 'Pagos sin venta asociada (suscripcion_id vacío)', n, null);
  end if;

  if to_regclass('public.streaming_vencimientos_respaldo') is not null then
    execute $q$ select count(*) from streaming_vencimientos_respaldo r
                where not exists (select 1 from streaming_suscripciones s where s.id::text = r.suscripcion_id) $q$ into n;
    execute $q$ select coalesce(jsonb_agg(jsonb_build_object('suscripcion_id', r.suscripcion_id, 'inicio', r.fecha_inicio, 'vence', r.fecha_vencimiento, 'estado', r.estado)), '[]'::jsonb)
                from streaming_vencimientos_respaldo r
               where not exists (select 1 from streaming_suscripciones s where s.id::text = r.suscripcion_id) $q$ into j;
    insert into diag values (7, 'Recuperación', 'Filas que existían en la copia de octubre (cambio a 30 días) y hoy ya no están', n, j);
  end if;

  if to_regclass('public.auditoria') is not null then
    execute $q$ select coalesce(jsonb_agg(jsonb_build_object('fecha', created_at::text, 'usuario', usuario, 'accion', accion, 'descripcion', descripcion) order by created_at), '[]'::jsonb)
                from auditoria
               where descripcion ilike '%streaming%' or descripcion ilike '%NPE-%' or descripcion ilike '%cliente%eliminad%' $q$ into j;
    insert into diag values (7, 'Recuperación', 'Auditoría: eliminaciones y renovaciones de ventas de Entretenimiento', jsonb_array_length(j), j);
  end if;

  if to_regclass('public.cliente_movimientos') is not null then
    execute $q$ select count(*) from cliente_movimientos m
                where m.id_venta is not null and not exists (select 1 from streaming_suscripciones s where s.id_venta = m.id_venta) $q$ into n;
    insert into diag values (7, 'Recuperación', 'Abonos/cargos que apuntan a un ID de venta que ya no existe', n, null);
    execute $q$ select count(*) from cliente_movimientos m
                where m.id_venta is not null and exists (select 1 from streaming_suscripciones s where s.id_venta = m.id_venta and s.cliente_id::text <> m.cliente_id::text) $q$ into n;
    insert into diag values (7, 'Recuperación', 'Abonos/cargos cuyo ID de venta pertenece (también) a otro cliente', n, null);
  end if;
end $$;

select orden, seccion, detalle, cantidad, datos from diag order by orden, seccion, detalle;
