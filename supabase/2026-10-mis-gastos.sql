-- ════════════════════════════════════════════════════════════════════
-- HALIEL · MIS GASTOS (control personal y privado del administrador)
--
-- CÓMO EJECUTARLO
--   1. Entra a https://supabase.com → tu proyecto → SQL Editor → New query.
--   2. Pega TODO este archivo y pulsa "Run".
--   3. Recarga la app. El menú "Mis gastos" se activa solo.
--
-- Es seguro ejecutarlo más de una vez: no borra ni modifica datos existentes.
--
-- PRIVACIDAD
--   · Solo un administrador activo puede leer o escribir en estas tablas.
--   · Cada administrador ve ÚNICAMENTE sus propios gastos y su presupuesto.
--   · Los operadores no pueden verlos aunque lo intenten desde fuera de la app.
--   · Estos datos no entran en cajas, ventas, reportes, estadísticas ni en el
--     respaldo mensual del negocio.
-- ════════════════════════════════════════════════════════════════════

-- ¿El usuario actual es administrador activo? (misma función que usan los otros módulos)
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
-- 1. GASTOS PERSONALES
--    recibo: foto comprimida (JPEG en texto, ~100–300 KB) · máximo ~1,5 MB
-- ─────────────────────────────────────────────
create table if not exists public.mis_gastos (
  id            uuid primary key default gen_random_uuid(),
  usuario_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  fecha         date not null default current_date,
  categoria     text not null check (length(trim(categoria)) between 1 and 40),
  descripcion   text not null check (length(trim(descripcion)) between 1 and 160),
  monto         numeric(14,2) not null check (monto > 0),
  metodo_pago   text not null default 'efectivo',
  es_fijo       boolean not null default false,
  recibo        text check (recibo is null or (recibo like 'data:image/%' and length(recibo) <= 1500000)),
  tiene_recibo  boolean generated always as (recibo is not null) stored,
  created_at    timestamptz not null default now()
);
create index if not exists mis_gastos_usuario_fecha_idx on public.mis_gastos (usuario_id, fecha desc);

-- ─────────────────────────────────────────────
-- 2. PRESUPUESTO (opcional; solo genera avisos, nunca bloquea gastos)
--    total: tope del mes · por_categoria: {"Comida y mercado": 500000, ...}
-- ─────────────────────────────────────────────
create table if not exists public.mis_gastos_presupuesto (
  usuario_id     uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  total          numeric(14,2) check (total is null or total > 0),
  por_categoria  jsonb not null default '{}'::jsonb check (jsonb_typeof(por_categoria) = 'object'),
  updated_at     timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 3. SEGURIDAD: solo el administrador dueño de cada fila
-- ─────────────────────────────────────────────
alter table public.mis_gastos             enable row level security;
alter table public.mis_gastos_presupuesto enable row level security;

drop policy if exists "mis_gastos_dueno" on public.mis_gastos;
create policy "mis_gastos_dueno" on public.mis_gastos
  for all to authenticated
  using (usuario_id = auth.uid() and public.haliel_es_admin())
  with check (usuario_id = auth.uid() and public.haliel_es_admin());

drop policy if exists "mis_gastos_presupuesto_dueno" on public.mis_gastos_presupuesto;
create policy "mis_gastos_presupuesto_dueno" on public.mis_gastos_presupuesto
  for all to authenticated
  using (usuario_id = auth.uid() and public.haliel_es_admin())
  with check (usuario_id = auth.uid() and public.haliel_es_admin());

revoke all on public.mis_gastos, public.mis_gastos_presupuesto from anon;
grant select, insert, update, delete on public.mis_gastos, public.mis_gastos_presupuesto to authenticated;
