-- ════════════════════════════════════════════════════════════════════
-- HALIEL PAPELERÍA · Nuevas funciones (octubre 2026)
-- Control de gastos · Abonos y saldos de clientes · Inventario · Respaldos
--
-- CÓMO EJECUTARLO
--   1. Entra a https://supabase.com → tu proyecto → SQL Editor → New query.
--   2. Pega TODO este archivo y pulsa "Run".
--   3. Recarga la app. Los módulos nuevos se activan solos.
--
-- Es seguro ejecutarlo más de una vez: no borra ni modifica datos existentes.
-- ════════════════════════════════════════════════════════════════════

-- ¿El usuario actual es administrador? (se usa en las políticas de seguridad)
create or replace function public.haliel_es_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.usuarios
    where id = auth.uid() and rol = 'administrador' and coalesce(estado, 'activo') = 'activo'
  );
$$;

-- ─────────────────────────────────────────────
-- 1. CONTROL DE GASTOS
-- ─────────────────────────────────────────────
create table if not exists public.gastos (
  id               uuid primary key default gen_random_uuid(),
  fecha            date not null default current_date,
  categoria        text not null,
  descripcion      text not null,
  monto            numeric(14,2) not null check (monto > 0),
  metodo_pago      text not null default 'efectivo',
  sucursal         text,
  operador_id      uuid references auth.users(id) on delete set null,
  operador_nombre  text,
  created_at       timestamptz not null default now()
);
create index if not exists gastos_fecha_idx on public.gastos (fecha desc);

-- ─────────────────────────────────────────────
-- 2. ABONOS Y SALDOS DE CLIENTES
--    tipo = 'cargo'  → el cliente queda debiendo (aumenta el saldo)
--    tipo = 'abono'  → el cliente paga (disminuye el saldo)
-- ─────────────────────────────────────────────
-- El tipo de cliente_id se toma del id real de streaming_clientes (uuid, bigint, etc.)
do $$
declare v_tipo text;
begin
  select format_type(a.atttypid, a.atttypmod) into v_tipo
    from pg_attribute a
   where a.attrelid = 'public.streaming_clientes'::regclass and a.attname = 'id';
  execute format($f$
    create table if not exists public.cliente_movimientos (
      id               uuid primary key default gen_random_uuid(),
      cliente_id       %s not null references public.streaming_clientes(id) on delete cascade,
      tipo             text not null check (tipo in ('cargo', 'abono')),
      monto            numeric(14,2) not null check (monto > 0),
      fecha            date not null default current_date,
      id_venta         text,
      metodo_pago      text,
      notas            text,
      operador_id      uuid references auth.users(id) on delete set null,
      operador_nombre  text,
      created_at       timestamptz not null default now()
    )$f$, v_tipo);
end $$;
create index if not exists cliente_mov_cliente_idx on public.cliente_movimientos (cliente_id, fecha desc);

-- ─────────────────────────────────────────────
-- 3. INVENTARIO DE PRODUCTOS
-- ─────────────────────────────────────────────
create table if not exists public.productos (
  id            uuid primary key default gen_random_uuid(),
  codigo        text unique,
  nombre        text not null,
  categoria     text,
  unidad        text not null default 'unidad',
  costo         numeric(14,2) not null default 0 check (costo >= 0),
  precio        numeric(14,2) not null default 0 check (precio >= 0),
  stock         numeric(14,2) not null default 0,
  stock_minimo  numeric(14,2) not null default 0 check (stock_minimo >= 0),
  activo        boolean not null default true,
  created_at    timestamptz not null default now()
);
create index if not exists productos_nombre_idx on public.productos (lower(nombre));

-- tipo: 'entrada' (compra / reposición), 'salida' (venta / consumo), 'ajuste' (conteo físico: cantidad = stock real)
create table if not exists public.inventario_movimientos (
  id               uuid primary key default gen_random_uuid(),
  producto_id      uuid not null references public.productos(id) on delete cascade,
  tipo             text not null check (tipo in ('entrada', 'salida', 'ajuste')),
  cantidad         numeric(14,2) not null check (cantidad >= 0),
  costo_unitario   numeric(14,2),
  stock_anterior   numeric(14,2),
  stock_nuevo      numeric(14,2),
  motivo           text,
  fecha            date not null default current_date,
  operador_id      uuid references auth.users(id) on delete set null,
  operador_nombre  text,
  created_at       timestamptz not null default now()
);
create index if not exists inv_mov_producto_idx on public.inventario_movimientos (producto_id, created_at desc);

-- El stock se actualiza en la base de datos (no en el navegador) para que
-- dos personas registrando al mismo tiempo no se pisen.
create or replace function public.haliel_aplicar_movimiento_inventario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actual numeric(14,2);
  v_nuevo  numeric(14,2);
begin
  select stock into v_actual from public.productos where id = new.producto_id for update;
  if not found then
    raise exception 'Producto no encontrado';
  end if;

  if new.tipo = 'entrada' then
    v_nuevo := v_actual + new.cantidad;
  elsif new.tipo = 'salida' then
    if new.cantidad > v_actual then
      raise exception 'Stock insuficiente: hay % disponibles', v_actual;
    end if;
    v_nuevo := v_actual - new.cantidad;
  else
    v_nuevo := new.cantidad;  -- ajuste: la cantidad es el conteo real
  end if;

  update public.productos
     set stock = v_nuevo,
         costo = case when new.tipo = 'entrada' and coalesce(new.costo_unitario, 0) > 0 then new.costo_unitario else costo end
   where id = new.producto_id;

  new.stock_anterior := v_actual;
  new.stock_nuevo    := v_nuevo;
  return new;
end;
$$;

drop trigger if exists trg_inventario_movimiento on public.inventario_movimientos;
create trigger trg_inventario_movimiento
  before insert on public.inventario_movimientos
  for each row execute function public.haliel_aplicar_movimiento_inventario();

-- ─────────────────────────────────────────────
-- 4. RESPALDOS MENSUALES (registro de cuáles ya se generaron)
-- ─────────────────────────────────────────────
create table if not exists public.respaldos (
  id            uuid primary key default gen_random_uuid(),
  periodo       text not null unique,          -- 'AAAA-MM'
  generado_por  text,
  created_at    timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 5. SEGURIDAD (RLS)
--    Cualquier usuario con sesión puede consultar y registrar.
--    Editar y eliminar: solo administradores.
--    Productos: solo administradores los crean o modifican
--    (el stock lo cambia el trigger al registrar movimientos).
-- ─────────────────────────────────────────────
alter table public.gastos                 enable row level security;
alter table public.cliente_movimientos    enable row level security;
alter table public.productos              enable row level security;
alter table public.inventario_movimientos enable row level security;
alter table public.respaldos              enable row level security;

do $$
declare t text;
begin
  foreach t in array array['gastos','cliente_movimientos','inventario_movimientos'] loop
    execute format('drop policy if exists "%1$s_leer" on public.%1$I', t);
    execute format('drop policy if exists "%1$s_crear" on public.%1$I', t);
    execute format('drop policy if exists "%1$s_editar_admin" on public.%1$I', t);
    execute format('drop policy if exists "%1$s_eliminar_admin" on public.%1$I', t);
    execute format('create policy "%1$s_leer" on public.%1$I for select to authenticated using (true)', t);
    execute format('create policy "%1$s_crear" on public.%1$I for insert to authenticated with check (true)', t);
    execute format('create policy "%1$s_editar_admin" on public.%1$I for update to authenticated using (public.haliel_es_admin()) with check (public.haliel_es_admin())', t);
    execute format('create policy "%1$s_eliminar_admin" on public.%1$I for delete to authenticated using (public.haliel_es_admin())', t);
  end loop;
end $$;

drop policy if exists "productos_leer" on public.productos;
drop policy if exists "productos_admin" on public.productos;
create policy "productos_leer"  on public.productos for select to authenticated using (true);
create policy "productos_admin" on public.productos for all    to authenticated using (public.haliel_es_admin()) with check (public.haliel_es_admin());

drop policy if exists "respaldos_admin" on public.respaldos;
create policy "respaldos_admin" on public.respaldos for all to authenticated using (public.haliel_es_admin()) with check (public.haliel_es_admin());
