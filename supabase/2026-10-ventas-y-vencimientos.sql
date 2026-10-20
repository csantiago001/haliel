-- ════════════════════════════════════════════════════════════════════
-- HALIEL PAPELERÍA · Módulo de ventas + vencimientos de 30 días
--
-- ORDEN DE EJECUCIÓN
--   1. supabase/2026-10-nuevas-funciones.sql   (si aún no lo ejecutaste)
--   2. ESTE archivo
--
-- CÓMO EJECUTARLO
--   Supabase → tu proyecto → SQL Editor → New query → pegar TODO → Run.
--   Es seguro ejecutarlo más de una vez.
-- ════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────
-- 1. VENCIMIENTOS DE STREAMING: 30 DÍAS POR MES
--    1 mes = 30 días, 3 meses = 90 días, sin excepción.
--    Se recalculan TODAS las ventas existentes. Antes se guarda una copia
--    de las fechas originales en streaming_vencimientos_respaldo.
-- ─────────────────────────────────────────────
do $$
declare
  v_tipo_fecha text;
  v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  if to_regclass('public.streaming_suscripciones') is null then
    raise notice 'No existe streaming_suscripciones: se omite el recálculo.';
    return;
  end if;

  create table if not exists public.streaming_vencimientos_respaldo (
    suscripcion_id     text primary key,
    fecha_inicio       text,
    fecha_vencimiento  text,
    estado             text,
    guardado_en        timestamptz not null default now()
  );
  alter table public.streaming_vencimientos_respaldo enable row level security;

  -- Copia de seguridad (solo la primera vez para cada suscripción)
  insert into public.streaming_vencimientos_respaldo (suscripcion_id, fecha_inicio, fecha_vencimiento, estado)
  select id::text, fecha_inicio::text, fecha_vencimiento::text, estado
    from public.streaming_suscripciones
  on conflict (suscripcion_id) do nothing;

  select data_type into v_tipo_fecha
    from information_schema.columns
   where table_schema = 'public' and table_name = 'streaming_suscripciones' and column_name = 'fecha_vencimiento';

  -- Nuevo vencimiento = inicio + 30 × meses
  execute format($f$
    update public.streaming_suscripciones s
       set fecha_vencimiento = (%s)
     where s.fecha_inicio is not null
       and nullif(s.fecha_inicio::text, '') is not null
  $f$,
    case when v_tipo_fecha = 'date'
      then $e$(s.fecha_inicio::date + (30 * greatest(coalesce(nullif(s.duracion_meses::text, '')::numeric, 1), 1))::int)$e$
      else $e$to_char(s.fecha_inicio::date + (30 * greatest(coalesce(nullif(s.duracion_meses::text, '')::numeric, 1), 1))::int, 'YYYY-MM-DD')$e$
    end);

  -- Estado según la nueva fecha (igual que la app: ≤ 5 días = por vencer)
  update public.streaming_suscripciones s
     set estado = case
                    when s.fecha_vencimiento::date < v_hoy then 'vencido'
                    when s.fecha_vencimiento::date - v_hoy <= 5 then 'por_vencer'
                    else 'activo'
                  end
   where coalesce(s.estado, '') <> 'cancelado'
     and s.fecha_vencimiento is not null;
end $$;

-- ─────────────────────────────────────────────
-- 2. PRODUCTOS: CÓDIGO AUTOMÁTICO Y CÓDIGO DE BARRAS
--    codigo        → lo asigna el sistema (HAL000001, HAL000002, …)
--    codigo_barras → el código impreso por el fabricante (opcional)
-- ─────────────────────────────────────────────
alter table public.productos add column if not exists codigo_barras text;
create unique index if not exists productos_codigo_barras_uq on public.productos (codigo_barras) where codigo_barras is not null and codigo_barras <> '';

create sequence if not exists public.productos_codigo_seq;

create or replace function public.haliel_codigo_producto()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.codigo is null or btrim(new.codigo) = '' then
    loop
      new.codigo := 'HAL' || lpad(nextval('public.productos_codigo_seq')::text, 6, '0');
      exit when not exists (select 1 from public.productos where codigo = new.codigo);
    end loop;
  end if;
  if new.codigo_barras is not null and btrim(new.codigo_barras) = '' then
    new.codigo_barras := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_codigo_producto on public.productos;
create trigger trg_codigo_producto
  before insert or update of codigo, codigo_barras on public.productos
  for each row execute function public.haliel_codigo_producto();

-- Productos que ya existían sin código
update public.productos set codigo = null where codigo is null or btrim(codigo) = '';

-- ─────────────────────────────────────────────
-- 3. VENTAS DE PRODUCTOS (PUNTO DE VENTA)
-- ─────────────────────────────────────────────
create table if not exists public.ventas (
  id                 uuid primary key default gen_random_uuid(),
  numero             bigint generated always as identity unique,
  fecha              date not null default ((now() at time zone 'America/Bogota')::date),
  cliente_nombre     text,
  cliente_documento  text,
  subtotal           numeric(14,2) not null default 0,
  descuento          numeric(14,2) not null default 0,
  total              numeric(14,2) not null default 0,
  costo_total        numeric(14,2) not null default 0,
  metodo_pago        text not null default 'efectivo',
  recibido           numeric(14,2),
  cambio             numeric(14,2),
  estado             text not null default 'completada' check (estado in ('completada', 'anulada')),
  notas              text,
  sucursal           text,
  operador_id        uuid references auth.users(id) on delete set null,
  operador_nombre    text,
  anulada_por        text,
  anulada_motivo     text,
  anulada_at         timestamptz,
  created_at         timestamptz not null default now()
);
create index if not exists ventas_fecha_idx on public.ventas (fecha desc, numero desc);

create table if not exists public.venta_items (
  id               uuid primary key default gen_random_uuid(),
  venta_id         uuid not null references public.ventas(id) on delete cascade,
  producto_id      uuid references public.productos(id) on delete set null,
  codigo           text,
  nombre           text not null,
  cantidad         numeric(14,2) not null check (cantidad > 0),
  precio_unitario  numeric(14,2) not null check (precio_unitario >= 0),
  costo_unitario   numeric(14,2) not null default 0,
  subtotal         numeric(14,2) not null
);
create index if not exists venta_items_venta_idx on public.venta_items (venta_id);
create index if not exists venta_items_producto_idx on public.venta_items (producto_id);

alter table public.ventas      enable row level security;
alter table public.venta_items enable row level security;
drop policy if exists "ventas_leer" on public.ventas;
drop policy if exists "venta_items_leer" on public.venta_items;
create policy "ventas_leer"      on public.ventas      for select to authenticated using (true);
create policy "venta_items_leer" on public.venta_items for select to authenticated using (true);
-- No hay políticas de insert/update/delete: las ventas solo se crean y anulan
-- con las funciones de abajo, que validan stock y permisos en una sola transacción.

-- Registrar una venta: guarda la venta, sus productos y descuenta el stock.
-- Si algún producto no tiene stock suficiente, NO se guarda nada.
create or replace function public.haliel_registrar_venta(p_venta jsonb, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user     uuid := auth.uid();
  v_admin    boolean := public.haliel_es_admin();
  v_nombre   text;
  v_sucursal text;
  v_id       uuid;
  v_num      bigint;
  v_fecha    date := (now() at time zone 'America/Bogota')::date;
  it         jsonb;
  v_prod     public.productos%rowtype;
  v_cant     numeric;
  v_precio   numeric;
  v_sub      numeric := 0;
  v_costo    numeric := 0;
  v_desc     numeric;
  v_total    numeric;
  v_metodo   text := coalesce(nullif(p_venta->>'metodo_pago', ''), 'efectivo');
  v_recibido numeric := nullif(p_venta->>'recibido', '')::numeric;
begin
  if v_user is null then
    raise exception 'Tu sesión expiró. Vuelve a iniciar sesión.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta no tiene productos.';
  end if;

  select nombre, sucursal into v_nombre, v_sucursal from public.usuarios where id = v_user;

  insert into public.ventas (fecha, cliente_nombre, cliente_documento, metodo_pago, recibido, notas, sucursal, operador_id, operador_nombre)
  values (v_fecha,
          nullif(btrim(p_venta->>'cliente_nombre'), ''),
          nullif(btrim(p_venta->>'cliente_documento'), ''),
          v_metodo, v_recibido,
          nullif(btrim(p_venta->>'notas'), ''),
          coalesce(nullif(p_venta->>'sucursal', ''), v_sucursal),
          v_user, coalesce(v_nombre, 'Usuario'))
  returning id, numero into v_id, v_num;

  for it in select value from jsonb_array_elements(p_items)
  loop
    v_cant := nullif(it->>'cantidad', '')::numeric;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Hay una cantidad inválida en la venta.';
    end if;

    select * into v_prod from public.productos where id = (it->>'producto_id')::uuid;
    if not found or v_prod.activo is false then
      raise exception 'Un producto de la venta ya no está disponible.';
    end if;

    -- Solo un administrador puede cambiar el precio de venta
    v_precio := case when v_admin then coalesce(nullif(it->>'precio_unitario', '')::numeric, v_prod.precio) else v_prod.precio end;
    if v_precio < 0 then
      raise exception 'Precio inválido para %.', v_prod.nombre;
    end if;

    insert into public.venta_items (venta_id, producto_id, codigo, nombre, cantidad, precio_unitario, costo_unitario, subtotal)
    values (v_id, v_prod.id, coalesce(v_prod.codigo_barras, v_prod.codigo), v_prod.nombre, v_cant, v_precio, v_prod.costo, v_cant * v_precio);

    -- Descuenta el stock (el trigger de inventario valida que alcance)
    begin
      insert into public.inventario_movimientos (producto_id, tipo, cantidad, motivo, fecha, operador_id, operador_nombre)
      values (v_prod.id, 'salida', v_cant, 'Venta #' || v_num, v_fecha, v_user, v_nombre);
    exception when others then
      raise exception 'No hay stock suficiente de "%" (disponibles: %).', v_prod.nombre, v_prod.stock;
    end;

    v_sub   := v_sub + v_cant * v_precio;
    v_costo := v_costo + v_cant * coalesce(v_prod.costo, 0);
  end loop;

  v_desc  := least(greatest(coalesce(nullif(p_venta->>'descuento', '')::numeric, 0), 0), v_sub);
  v_total := v_sub - v_desc;

  if v_metodo = 'efectivo' and v_recibido is not null and v_recibido < v_total then
    raise exception 'El dinero recibido es menor que el total.';
  end if;

  update public.ventas
     set subtotal = v_sub, descuento = v_desc, total = v_total, costo_total = v_costo,
         cambio = case when v_metodo = 'efectivo' and v_recibido is not null then v_recibido - v_total end
   where id = v_id;

  insert into public.auditoria (accion, usuario, descripcion)
  values ('crear', coalesce(v_nombre, 'Usuario'), 'Venta #' || v_num || ' por ' || to_char(v_total, 'FM999G999G999') || ' (' || v_metodo || ')');

  return jsonb_build_object('id', v_id, 'numero', v_num, 'total', v_total);
end;
$$;

-- Anular una venta (solo administradores): devuelve el stock y deja constancia.
create or replace function public.haliel_anular_venta(p_venta_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venta  public.ventas%rowtype;
  v_nombre text;
  it       record;
begin
  if not public.haliel_es_admin() then
    raise exception 'Solo un administrador puede anular ventas.';
  end if;
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'Escribe el motivo de la anulación.';
  end if;

  select * into v_venta from public.ventas where id = p_venta_id for update;
  if not found then raise exception 'La venta no existe.'; end if;
  if v_venta.estado = 'anulada' then raise exception 'La venta ya estaba anulada.'; end if;

  select nombre into v_nombre from public.usuarios where id = auth.uid();

  for it in select * from public.venta_items where venta_id = p_venta_id and producto_id is not null
  loop
    insert into public.inventario_movimientos (producto_id, tipo, cantidad, motivo, fecha, operador_id, operador_nombre)
    values (it.producto_id, 'entrada', it.cantidad, 'Anulación venta #' || v_venta.numero,
            (now() at time zone 'America/Bogota')::date, auth.uid(), v_nombre);
  end loop;

  update public.ventas
     set estado = 'anulada', anulada_por = coalesce(v_nombre, 'Administrador'), anulada_motivo = btrim(p_motivo), anulada_at = now()
   where id = p_venta_id;

  insert into public.auditoria (accion, usuario, descripcion)
  values ('eliminar', coalesce(v_nombre, 'Administrador'), 'Venta #' || v_venta.numero || ' anulada: ' || btrim(p_motivo));
end;
$$;

revoke all on function public.haliel_registrar_venta(jsonb, jsonb) from public;
revoke all on function public.haliel_anular_venta(uuid, text) from public;
grant execute on function public.haliel_registrar_venta(jsonb, jsonb) to authenticated;
grant execute on function public.haliel_anular_venta(uuid, text) to authenticated;
