-- ════════════════════════════════════════════════════════════════════
-- HALIEL · RECONSTRUCCIÓN DEL MÓDULO DE ENTRETENIMIENTO
--
-- QUÉ HACE (en este orden, todo o nada: si algo falla no cambia nada)
--   0. Respaldo completo de ventas, clientes, pagos, abonos y auditoría.
--   1. Crea la tabla de VENTAS: cada venta tiene un número único que da la
--      base de datos (nunca se repite ni se reutiliza) y pertenece a un solo
--      cliente.
--   2. Corrige los números compartidos: el cliente que compró primero
--      conserva el número; los demás reciben uno nuevo. Queda registrado en
--      streaming_ids_reasignados y en la auditoría. No se borra nada.
--   3. Quita los borrados en cascada (borrar un cliente o una venta ya no
--      arrastra pagos ni historial) y bloquea los borrados físicos.
--   4. Eliminar = papelera (se puede restaurar). Clientes se archivan.
--   5. Historial automático de todo cambio (quién, cuándo, antes y después).
--   6. Funciones seguras para crear, renovar, eliminar y restaurar ventas.
--
-- CÓMO EJECUTARLO
--   Supabase → SQL Editor → New query → pega TODO → Run.
--   Si Supabase avisa "destructive operations", es por el cambio de las
--   relaciones (se quitan las cascadas). Pulsa "Run without RLS" o "Run and
--   enable RLS": ambas sirven. Se puede ejecutar más de una vez sin riesgo.
--   Al final verás la lista de números corregidos.
-- ════════════════════════════════════════════════════════════════════
begin;

create or replace function public.haliel_es_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.usuarios
                  where id = auth.uid() and rol = 'administrador' and coalesce(estado, 'activo') = 'activo');
$$;

-- ─────────────────────────────────────────────
-- 0. RESPALDO (solo la primera vez; quedan cerradas a la app)
-- ─────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['streaming_suscripciones','streaming_clientes','streaming_pagos','cliente_movimientos','auditoria'] loop
    if to_regclass('public.' || t) is not null and to_regclass('public.respaldo_20261108_' || t) is null then
      execute format('create table public.%I as table public.%I', 'respaldo_20261108_' || t, t);
      execute format('alter table public.%I enable row level security', 'respaldo_20261108_' || t);
      execute format('revoke all on public.%I from anon, authenticated', 'respaldo_20261108_' || t);
    end if;
  end loop;
end $$;

-- ─────────────────────────────────────────────
-- 1. ESTRUCTURA NUEVA
-- ─────────────────────────────────────────────
alter table public.streaming_clientes
  add column if not exists archivado_en     timestamptz,
  add column if not exists archivado_por    uuid,
  add column if not exists archivado_motivo text;

alter table public.streaming_suscripciones
  add column if not exists venta_id          uuid,
  add column if not exists eliminado_en      timestamptz,
  add column if not exists eliminado_por     uuid,
  add column if not exists eliminado_motivo  text,
  add column if not exists actualizado_en    timestamptz;

create sequence if not exists public.streaming_ventas_numero_seq;

create table if not exists public.streaming_ventas (
  id                uuid primary key default gen_random_uuid(),
  numero            bigint not null unique,
  codigo            text   not null unique,
  cliente_id        uuid   not null references public.streaming_clientes(id) on delete restrict,
  estado            text   not null default 'activa' check (estado in ('activa','eliminada')),
  creada_en         timestamptz not null default now(),
  creada_por        uuid default auth.uid(),
  eliminada_en      timestamptz,
  eliminada_por     uuid,
  eliminada_motivo  text,
  unique (id, cliente_id)
);
create index if not exists streaming_ventas_cliente_idx on public.streaming_ventas (cliente_id);

create table if not exists public.streaming_ids_reasignados (
  id               bigserial primary key,
  codigo_anterior  text,
  codigo_nuevo     text not null,
  venta_id         uuid,
  cliente_id       uuid,
  cliente_nombre   text,
  filas            int,
  motivo           text,
  en               timestamptz not null default now()
);

create table if not exists public.streaming_historial (
  id           bigserial primary key,
  tabla        text not null,
  registro_id  text,
  accion       text not null,
  antes        jsonb,
  despues      jsonb,
  usuario_id   uuid default auth.uid(),
  en           timestamptz not null default now()
);
create index if not exists streaming_historial_registro_idx on public.streaming_historial (tabla, registro_id);

create or replace function public.haliel_codigo_venta(p_numero bigint)
returns text language sql stable as $$
  select 'NPE-' || to_char(now() at time zone 'America/Bogota', 'YYYY') || '-' || lpad(p_numero::text, 6, '0');
$$;

-- El contador arranca después del mayor número usado ALGUNA VEZ (también los eliminados)
do $$
declare v_max bigint := 0; v_tmp bigint;
begin
  select coalesce(max(substring(id_venta from '(\d+)$')::bigint), 0) into v_tmp
    from public.streaming_suscripciones where id_venta ~ '^NPE-\d{4}-\d{1,9}$';
  v_max := greatest(v_max, v_tmp);
  if to_regclass('public.auditoria') is not null then
    execute $q$ select coalesce(max(m[1]::bigint), 0)
                  from public.auditoria, regexp_matches(coalesce(descripcion, ''), 'NPE-\d{4}-(\d{1,9})', 'g') m $q$ into v_tmp;
    v_max := greatest(v_max, v_tmp);
  end if;
  select coalesce(max(numero), 0) into v_tmp from public.streaming_ventas;
  v_max := greatest(v_max, v_tmp);
  if v_max >= (select last_value from public.streaming_ventas_numero_seq) then
    perform setval('public.streaming_ventas_numero_seq', v_max, true);
  end if;
end $$;

-- ─────────────────────────────────────────────
-- 2. MIGRACIÓN: una venta por (número + cliente); el primer comprador conserva el número
-- ─────────────────────────────────────────────
do $$
declare
  r record; v_id uuid; v_num bigint; v_cod text; v_nom text; n_reasig int := 0; n_ventas int := 0;
begin
  for r in
    select id_venta, cliente_id, min(created_at) as primera, count(*) as filas
      from public.streaming_suscripciones
     where venta_id is null
     group by id_venta, cliente_id
     order by id_venta nulls last, min(created_at) nulls last, cliente_id
  loop
    v_num := null;
    if r.id_venta ~ '^NPE-\d{4}-\d{1,9}$' then
      v_num := substring(r.id_venta from '(\d+)$')::bigint;
      if exists (select 1 from public.streaming_ventas where numero = v_num or codigo = r.id_venta) then
        v_num := null;                                   -- ya lo tiene otro cliente (compró antes)
      end if;
    end if;

    if v_num is not null then
      v_cod := r.id_venta;                               -- conserva su número de siempre
    else
      v_num := nextval('public.streaming_ventas_numero_seq');
      v_cod := public.haliel_codigo_venta(v_num);
    end if;

    insert into public.streaming_ventas (numero, codigo, cliente_id, creada_en, creada_por)
    values (v_num, v_cod, r.cliente_id, coalesce(r.primera, now()), null)
    returning id into v_id;
    n_ventas := n_ventas + 1;

    update public.streaming_suscripciones
       set venta_id = v_id, id_venta = v_cod
     where venta_id is null and cliente_id = r.cliente_id and id_venta is not distinct from r.id_venta;

    if v_cod is distinct from r.id_venta then
      n_reasig := n_reasig + 1;
      select nombre into v_nom from public.streaming_clientes where id = r.cliente_id;
      insert into public.streaming_ids_reasignados (codigo_anterior, codigo_nuevo, venta_id, cliente_id, cliente_nombre, filas, motivo)
      values (r.id_venta, v_cod, v_id, r.cliente_id, v_nom, r.filas,
              case when r.id_venta is null then 'Venta sin número' else 'Número compartido con otro cliente que compró antes' end);
      -- Los abonos y cargos de ESTE cliente que apuntaban al número viejo pasan al nuevo
      if to_regclass('public.cliente_movimientos') is not null and r.id_venta is not null then
        update public.cliente_movimientos set id_venta = v_cod where id_venta = r.id_venta and cliente_id = r.cliente_id;
      end if;
      if to_regclass('public.auditoria') is not null then
        insert into public.auditoria (accion, usuario, descripcion)
        values ('editar', 'Sistema (reconstrucción)',
                format('Número de venta corregido: %s → %s (%s, %s plataforma%s). Motivo: número compartido con otro cliente que compró antes.',
                       coalesce(r.id_venta, 'sin número'), v_cod, coalesce(v_nom, 'cliente'), r.filas, case when r.filas = 1 then '' else 's' end));
      end if;
    end if;
  end loop;
  raise notice 'Ventas creadas: %, números corregidos: %', n_ventas, n_reasig;
end $$;

-- Toda fila queda unida a su venta, y la venta y la fila deben ser del MISMO cliente
alter table public.streaming_suscripciones alter column venta_id set not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'streaming_suscripciones_venta_cliente_fkey') then
    alter table public.streaming_suscripciones
      add constraint streaming_suscripciones_venta_cliente_fkey
      foreign key (venta_id, cliente_id) references public.streaming_ventas (id, cliente_id) on delete restrict;
  end if;
end $$;
create index if not exists streaming_suscripciones_venta_idx on public.streaming_suscripciones (venta_id);

-- ─────────────────────────────────────────────
-- 3. SIN BORRADOS EN CASCADA (borrar ya no arrastra ventas, pagos ni abonos)
-- ─────────────────────────────────────────────
do $$
declare r record;
begin
  for r in
    select con.conname, rel.relname as tabla, att.attname as col, frel.relname as ref, fatt.attname as refcol
      from pg_constraint con
      join pg_class rel  on rel.oid = con.conrelid
      join pg_namespace ns on ns.oid = rel.relnamespace
      join pg_class frel on frel.oid = con.confrelid
      join pg_attribute att  on att.attrelid = con.conrelid  and att.attnum = con.conkey[1]
      join pg_attribute fatt on fatt.attrelid = con.confrelid and fatt.attnum = con.confkey[1]
     where con.contype = 'f' and con.confdeltype = 'c' and ns.nspname = 'public'
       and array_length(con.conkey, 1) = 1
       and rel.relname in ('streaming_suscripciones','streaming_pagos','cliente_movimientos')
  loop
    execute format('alter table public.%I drop constraint %I', r.tabla, r.conname);
    execute format('alter table public.%I add constraint %I foreign key (%I) references public.%I (%I) on delete restrict',
                   r.tabla, r.conname, r.col, r.ref, r.refcol);
  end loop;
end $$;

-- ─────────────────────────────────────────────
-- 4. PROTECCIONES AUTOMÁTICAS (triggers)
-- ─────────────────────────────────────────────
-- 4a. Ninguna venta, plataforma vendida, cliente o pago se borra físicamente
create or replace function public.haliel_bloquear_borrado()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('haliel.borrado_fisico', true), '') = 'si' then return old; end if;
  raise exception 'No se permite borrar registros de Entretenimiento. Usa "Eliminar" (papelera) o "Archivar".'
    using errcode = 'P0001';
end $$;
do $$
declare t text;
begin
  foreach t in array array['streaming_ventas','streaming_suscripciones','streaming_clientes','streaming_pagos'] loop
    execute format('drop trigger if exists haliel_sin_borrado on public.%I', t);
    execute format('create trigger haliel_sin_borrado before delete on public.%I for each row execute function public.haliel_bloquear_borrado()', t);
  end loop;
end $$;

-- 4b. Una plataforma vendida nunca cambia de venta ni de cliente, y su número es el de su venta.
--     Si una versión vieja de la app inserta sin venta, se le crea su propia venta con número nuevo.
create or replace function public.haliel_proteger_suscripcion()
returns trigger language plpgsql security definer set search_path = public as $$
declare v record;
begin
  if tg_op = 'INSERT' then
    if new.venta_id is null then
      select * into v from streaming_ventas
       where codigo = new.id_venta and cliente_id = new.cliente_id and estado = 'activa' limit 1;
      if not found then
        insert into streaming_ventas (numero, codigo, cliente_id)
        values (nextval('streaming_ventas_numero_seq'), haliel_codigo_venta(currval('streaming_ventas_numero_seq')), new.cliente_id)
        returning * into v;
      end if;
      new.venta_id := v.id;
    end if;
    select codigo into new.id_venta from streaming_ventas where id = new.venta_id;
    return new;
  end if;
  -- UPDATE: la identidad no se toca
  new.venta_id   := old.venta_id;
  new.cliente_id := old.cliente_id;
  new.id_venta   := (select codigo from streaming_ventas where id = old.venta_id);
  new.actualizado_en := now();
  return new;
end $$;
drop trigger if exists haliel_proteger_suscripcion on public.streaming_suscripciones;
create trigger haliel_proteger_suscripcion before insert or update on public.streaming_suscripciones
  for each row execute function public.haliel_proteger_suscripcion();

-- 4c. El número y el cliente de una venta tampoco cambian nunca
create or replace function public.haliel_proteger_venta()
returns trigger language plpgsql as $$
begin
  new.numero := old.numero; new.codigo := old.codigo; new.cliente_id := old.cliente_id; new.creada_en := old.creada_en;
  return new;
end $$;
drop trigger if exists haliel_proteger_venta on public.streaming_ventas;
create trigger haliel_proteger_venta before update on public.streaming_ventas
  for each row execute function public.haliel_proteger_venta();

-- 4d. Historial automático de todos los cambios
create or replace function public.haliel_registrar_historial()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into streaming_historial (tabla, registro_id, accion, antes, despues, usuario_id)
  values (tg_table_name,
          coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id', ''),
          lower(tg_op),
          case when tg_op = 'INSERT' then null else to_jsonb(old) end,
          case when tg_op = 'DELETE' then null else to_jsonb(new) end,
          auth.uid());
  return null;
end $$;
do $$
declare t text;
begin
  foreach t in array array['streaming_ventas','streaming_suscripciones','streaming_clientes','streaming_pagos','cliente_movimientos'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists haliel_historial on public.%I', t);
      execute format('create trigger haliel_historial after insert or update or delete on public.%I for each row execute function public.haliel_registrar_historial()', t);
    end if;
  end loop;
end $$;

-- ─────────────────────────────────────────────
-- 5. FUNCIONES SEGURAS (todo o nada; solo administradores)
-- ─────────────────────────────────────────────
create or replace function public.haliel_estado_por_fecha(p_vence date)
returns text language sql stable as $$
  select case when p_vence < (now() at time zone 'America/Bogota')::date then 'vencido'
              when p_vence <= (now() at time zone 'America/Bogota')::date + 5 then 'por_vencer'
              else 'activo' end;
$$;

create or replace function public.haliel_usuario_nombre()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select nombre from usuarios where id = auth.uid()), 'Sistema');
$$;

-- Crear una venta (combo): número atómico, todas las plataformas o ninguna
create or replace function public.haliel_crear_venta_streaming(
  p_cliente_id uuid, p_items jsonb, p_fecha_inicio date, p_fecha_vencimiento date,
  p_duracion int, p_notas text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_venta streaming_ventas; it jsonb; v_estado text; v_nombre text; v_plats text;
begin
  if not haliel_es_admin() then raise exception 'Solo un administrador puede registrar ventas de Entretenimiento'; end if;
  select nombre into v_nombre from streaming_clientes where id = p_cliente_id and archivado_en is null;
  if not found then raise exception 'El cliente no existe o está archivado'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Agrega al menos una plataforma'; end if;
  if (select count(distinct x->>'plataforma_id') from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then
    raise exception 'Una plataforma está repetida en la venta';
  end if;
  if p_fecha_inicio is null or p_fecha_vencimiento is null or p_fecha_vencimiento < p_fecha_inicio then raise exception 'Fechas inválidas'; end if;
  v_estado := haliel_estado_por_fecha(p_fecha_vencimiento);

  insert into streaming_ventas (numero, codigo, cliente_id)
  values (nextval('streaming_ventas_numero_seq'), haliel_codigo_venta(currval('streaming_ventas_numero_seq')), p_cliente_id)
  returning * into v_venta;

  for it in select * from jsonb_array_elements(p_items) loop
    if coalesce((it->>'precio')::numeric, -1) < 0 then raise exception 'Precio inválido'; end if;
    insert into streaming_suscripciones (venta_id, id_venta, cliente_id, plataforma_id, perfil, precio_venta, duracion_meses,
                                         fecha_inicio, fecha_vencimiento, estado, notas)
    values (v_venta.id, v_venta.codigo, p_cliente_id, (it->>'plataforma_id')::uuid, coalesce(nullif(it->>'perfil', ''), 'Perfil 1'),
            (it->>'precio')::numeric, greatest(coalesce(p_duracion, 1), 1), p_fecha_inicio, p_fecha_vencimiento, v_estado, nullif(p_notas, ''));
  end loop;

  select string_agg(p.nombre, ', ') into v_plats from jsonb_array_elements(p_items) x join streaming_plataformas p on p.id = (x->>'plataforma_id')::uuid;
  insert into auditoria (accion, usuario, descripcion)
  values ('crear', haliel_usuario_nombre(), format('Venta de streaming %s creada (%s: %s)', v_venta.codigo, v_nombre, v_plats));
  return jsonb_build_object('venta_id', v_venta.id, 'codigo', v_venta.codigo);
end $$;

-- Renovar: conserva el número; actualiza o agrega plataformas; las quitadas van a la papelera
create or replace function public.haliel_renovar_venta_streaming(
  p_venta_id uuid, p_items jsonb, p_fecha_inicio date, p_fecha_vencimiento date,
  p_duracion int, p_notas text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_venta streaming_ventas; it jsonb; f streaming_suscripciones; v_estado text; v_costo numeric; v_meses int; v_id uuid;
        v_plats text; v_nombre text; v_sel uuid[];
begin
  if not haliel_es_admin() then raise exception 'Solo un administrador puede renovar ventas'; end if;
  select * into v_venta from streaming_ventas where id = p_venta_id for update;   -- bloquea la venta mientras se renueva
  if not found or v_venta.estado <> 'activa' then raise exception 'La venta no existe o está en la papelera'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'El combo debe tener al menos una plataforma'; end if;
  if p_fecha_inicio is null or p_fecha_vencimiento is null or p_fecha_vencimiento < p_fecha_inicio then raise exception 'Fechas inválidas'; end if;
  v_estado := haliel_estado_por_fecha(p_fecha_vencimiento);
  v_meses := greatest(coalesce(p_duracion, 1), 1);
  select array_agg((x->>'plataforma_id')::uuid) into v_sel from jsonb_array_elements(p_items) x;

  for it in select * from jsonb_array_elements(p_items) loop
    select coalesce(costo_real, 0) into v_costo from streaming_plataformas where id = (it->>'plataforma_id')::uuid;
    select * into f from streaming_suscripciones
     where venta_id = p_venta_id and plataforma_id = (it->>'plataforma_id')::uuid and eliminado_en is null
     order by created_at desc limit 1;
    if found then
      update streaming_suscripciones
         set fecha_inicio = p_fecha_inicio, fecha_vencimiento = p_fecha_vencimiento, duracion_meses = v_meses,
             precio_venta = (it->>'precio')::numeric, perfil = coalesce(nullif(it->>'perfil', ''), perfil),
             estado = v_estado, notas = nullif(p_notas, '')
       where id = f.id;
      v_id := f.id;
    else
      insert into streaming_suscripciones (venta_id, id_venta, cliente_id, plataforma_id, perfil, precio_venta, duracion_meses,
                                           fecha_inicio, fecha_vencimiento, estado, notas)
      values (p_venta_id, v_venta.codigo, v_venta.cliente_id, (it->>'plataforma_id')::uuid, coalesce(nullif(it->>'perfil', ''), 'Perfil 1'),
              (it->>'precio')::numeric, v_meses, p_fecha_inicio, p_fecha_vencimiento, v_estado, nullif(p_notas, ''))
      returning id into v_id;
    end if;
    insert into streaming_pagos (suscripcion_id, cliente_id, plataforma_id, monto, costo_real, duracion_meses, fecha_pago, notas)
    values (v_id, v_venta.cliente_id, (it->>'plataforma_id')::uuid, (it->>'precio')::numeric, v_costo, v_meses,
            (now() at time zone 'America/Bogota')::date, 'Renovación combo ' || v_venta.codigo);
  end loop;

  -- Plataformas que salen del combo: a la papelera (nunca las que siguen activas)
  update streaming_suscripciones
     set eliminado_en = now(), eliminado_por = auth.uid(), eliminado_motivo = 'Quitada del combo al renovar'
   where venta_id = p_venta_id and eliminado_en is null and not (plataforma_id = any (v_sel))
     and haliel_estado_por_fecha(fecha_vencimiento) <> 'activo';

  select nombre into v_nombre from streaming_clientes where id = v_venta.cliente_id;
  select string_agg(p.nombre, ', ') into v_plats from streaming_plataformas p where p.id = any (v_sel);
  insert into auditoria (accion, usuario, descripcion)
  values ('editar', haliel_usuario_nombre(), format('Renovación venta %s (%s) — inicio %s, vence %s, plataformas: %s',
          v_venta.codigo, v_nombre, p_fecha_inicio, p_fecha_vencimiento, v_plats));
  return jsonb_build_object('venta_id', v_venta.id, 'codigo', v_venta.codigo);
end $$;

-- Eliminar una venta = enviarla a la papelera (se puede restaurar)
create or replace function public.haliel_eliminar_venta_streaming(p_venta_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_venta streaming_ventas; v_nombre text; n int;
begin
  if not haliel_es_admin() then raise exception 'Solo un administrador puede eliminar ventas'; end if;
  select * into v_venta from streaming_ventas where id = p_venta_id for update;
  if not found or v_venta.estado <> 'activa' then raise exception 'La venta no existe o ya está en la papelera'; end if;
  update streaming_ventas set estado = 'eliminada', eliminada_en = now(), eliminada_por = auth.uid(), eliminada_motivo = nullif(p_motivo, '')
   where id = p_venta_id;
  update streaming_suscripciones set eliminado_en = now(), eliminado_por = auth.uid(), eliminado_motivo = '[venta] ' || coalesce(nullif(p_motivo, ''), 'Venta eliminada')
   where venta_id = p_venta_id and eliminado_en is null;
  get diagnostics n = row_count;
  select nombre into v_nombre from streaming_clientes where id = v_venta.cliente_id;
  insert into auditoria (accion, usuario, descripcion)
  values ('eliminar', haliel_usuario_nombre(), format('Venta de streaming %s enviada a la papelera (%s, %s plataforma%s)%s',
          v_venta.codigo, v_nombre, n, case when n = 1 then '' else 's' end, coalesce('. Motivo: ' || nullif(p_motivo, ''), '')));
end $$;

create or replace function public.haliel_restaurar_venta_streaming(p_venta_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_venta streaming_ventas; v_nombre text;
begin
  if not haliel_es_admin() then raise exception 'Solo un administrador puede restaurar ventas'; end if;
  select * into v_venta from streaming_ventas where id = p_venta_id for update;
  if not found or v_venta.estado <> 'eliminada' then raise exception 'La venta no está en la papelera'; end if;
  if exists (select 1 from streaming_clientes where id = v_venta.cliente_id and archivado_en is not null) then
    update streaming_clientes set archivado_en = null, archivado_por = null, archivado_motivo = null where id = v_venta.cliente_id;
  end if;
  update streaming_ventas set estado = 'activa', eliminada_en = null, eliminada_por = null, eliminada_motivo = null where id = p_venta_id;
  update streaming_suscripciones
     set eliminado_en = null, eliminado_por = null, eliminado_motivo = null,
         estado = haliel_estado_por_fecha(fecha_vencimiento)
   where venta_id = p_venta_id and eliminado_motivo like '[venta]%';
  select nombre into v_nombre from streaming_clientes where id = v_venta.cliente_id;
  insert into auditoria (accion, usuario, descripcion)
  values ('editar', haliel_usuario_nombre(), format('Venta de streaming %s restaurada desde la papelera (%s)', v_venta.codigo, v_nombre));
end $$;

-- Quitar una sola plataforma de una venta (a la papelera)
create or replace function public.haliel_eliminar_suscripcion_streaming(p_suscripcion_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare f streaming_suscripciones; v_cod text; v_plat text;
begin
  if not haliel_es_admin() then raise exception 'Solo un administrador puede eliminar'; end if;
  select * into f from streaming_suscripciones where id = p_suscripcion_id and eliminado_en is null for update;
  if not found then raise exception 'La plataforma no existe o ya está en la papelera'; end if;
  if not exists (select 1 from streaming_suscripciones where venta_id = f.venta_id and eliminado_en is null and id <> f.id) then
    perform haliel_eliminar_venta_streaming(f.venta_id, p_motivo);   -- era la única: se va la venta completa
    return;
  end if;
  update streaming_suscripciones set eliminado_en = now(), eliminado_por = auth.uid(), eliminado_motivo = coalesce(nullif(p_motivo, ''), 'Plataforma eliminada')
   where id = f.id;
  select codigo into v_cod from streaming_ventas where id = f.venta_id;
  select nombre into v_plat from streaming_plataformas where id = f.plataforma_id;
  insert into auditoria (accion, usuario, descripcion)
  values ('eliminar', haliel_usuario_nombre(), format('Plataforma %s quitada de la venta %s (papelera)', coalesce(v_plat, ''), v_cod));
end $$;

-- Clientes: archivar en lugar de borrar
create or replace function public.haliel_archivar_cliente_streaming(p_cliente_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_nombre text;
begin
  if not haliel_es_admin() then raise exception 'Solo un administrador puede archivar clientes'; end if;
  update streaming_clientes set archivado_en = now(), archivado_por = auth.uid(), archivado_motivo = nullif(p_motivo, '')
   where id = p_cliente_id and archivado_en is null
  returning nombre into v_nombre;
  if not found then raise exception 'El cliente no existe o ya está archivado'; end if;
  insert into auditoria (accion, usuario, descripcion)
  values ('editar', haliel_usuario_nombre(), format('Cliente %s archivado%s', v_nombre, coalesce('. Motivo: ' || nullif(p_motivo, ''), '')));
end $$;

create or replace function public.haliel_restaurar_cliente_streaming(p_cliente_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_nombre text;
begin
  if not haliel_es_admin() then raise exception 'Solo un administrador puede restaurar clientes'; end if;
  update streaming_clientes set archivado_en = null, archivado_por = null, archivado_motivo = null
   where id = p_cliente_id and archivado_en is not null
  returning nombre into v_nombre;
  if not found then raise exception 'El cliente no está archivado'; end if;
  insert into auditoria (accion, usuario, descripcion) values ('editar', haliel_usuario_nombre(), format('Cliente %s restaurado', v_nombre));
end $$;

-- ─────────────────────────────────────────────
-- 6. PERMISOS
-- ─────────────────────────────────────────────
alter table public.streaming_ventas          enable row level security;
alter table public.streaming_ids_reasignados enable row level security;
alter table public.streaming_historial       enable row level security;
drop policy if exists "streaming_ventas_leer" on public.streaming_ventas;
create policy "streaming_ventas_leer" on public.streaming_ventas for select to authenticated using (true);
drop policy if exists "streaming_ids_reasignados_leer" on public.streaming_ids_reasignados;
create policy "streaming_ids_reasignados_leer" on public.streaming_ids_reasignados for select to authenticated using (true);
drop policy if exists "streaming_historial_admin" on public.streaming_historial;
create policy "streaming_historial_admin" on public.streaming_historial for select to authenticated using (public.haliel_es_admin());
revoke all on public.streaming_ventas, public.streaming_ids_reasignados, public.streaming_historial from anon;
grant select on public.streaming_ventas, public.streaming_ids_reasignados, public.streaming_historial to authenticated;
grant usage on sequence public.streaming_ventas_numero_seq to authenticated;

revoke all on function public.haliel_crear_venta_streaming(uuid, jsonb, date, date, int, text) from public, anon;
revoke all on function public.haliel_renovar_venta_streaming(uuid, jsonb, date, date, int, text) from public, anon;
revoke all on function public.haliel_eliminar_venta_streaming(uuid, text) from public, anon;
revoke all on function public.haliel_restaurar_venta_streaming(uuid) from public, anon;
revoke all on function public.haliel_eliminar_suscripcion_streaming(uuid, text) from public, anon;
revoke all on function public.haliel_archivar_cliente_streaming(uuid, text) from public, anon;
revoke all on function public.haliel_restaurar_cliente_streaming(uuid) from public, anon;
grant execute on function public.haliel_crear_venta_streaming(uuid, jsonb, date, date, int, text) to authenticated;
grant execute on function public.haliel_renovar_venta_streaming(uuid, jsonb, date, date, int, text) to authenticated;
grant execute on function public.haliel_eliminar_venta_streaming(uuid, text) to authenticated;
grant execute on function public.haliel_restaurar_venta_streaming(uuid) to authenticated;
grant execute on function public.haliel_eliminar_suscripcion_streaming(uuid, text) to authenticated;
grant execute on function public.haliel_archivar_cliente_streaming(uuid, text) to authenticated;
grant execute on function public.haliel_restaurar_cliente_streaming(uuid) to authenticated;

commit;

-- ─────────────────────────────────────────────
-- RESULTADO: números de venta corregidos y comprobación final
-- ─────────────────────────────────────────────
select 'Corregido' as resultado, codigo_anterior, codigo_nuevo, cliente_nombre, filas, motivo
  from public.streaming_ids_reasignados
union all
select 'Comprobación', 'IDs compartidos que quedan', (select count(*)::text from (
         select id_venta from public.streaming_suscripciones group by id_venta having count(distinct cliente_id) > 1) x),
       'Debe ser 0', null, null
union all
select 'Comprobación', 'Próximo número de venta', public.haliel_codigo_venta((select last_value + 1 from public.streaming_ventas_numero_seq)),
       null, null, null;
