-- ════════════════════════════════════════════════════════════════════
-- HALIEL · AJUSTES EN LA NUBE
-- Preferencias de cada usuario y configuración del sistema en Supabase
-- (antes quedaban guardadas solo en el navegador de cada equipo).
--
-- CÓMO EJECUTARLO
--   1. Entra a https://supabase.com → tu proyecto → SQL Editor → New query.
--   2. Pega TODO este archivo y pulsa "Run".
--   3. Recarga la app. Lo que tenías guardado en el equipo se sube solo.
--
-- Es seguro ejecutarlo más de una vez: no borra ni modifica datos existentes.
-- ════════════════════════════════════════════════════════════════════

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
-- 1. CONFIGURACIÓN DEL SISTEMA (igual para todos los equipos)
--    metas-global, metas-<sucursal>: umbrales y metas de movimientos
--    inactividad: minutos antes de cerrar la sesión por inactividad
--    Todos la leen; solo los administradores la cambian.
-- ─────────────────────────────────────────────
create table if not exists public.haliel_configuracion (
  clave       text primary key check (length(clave) between 1 and 120),
  valor       jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null
);

-- ─────────────────────────────────────────────
-- 2. PREFERENCIAS DE CADA USUARIO (lo siguen en cualquier equipo)
--    modo oscuro, menú, pestaña del dashboard, etc.
-- ─────────────────────────────────────────────
create table if not exists public.usuario_preferencias (
  usuario_id  uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  prefs       jsonb not null default '{}'::jsonb check (jsonb_typeof(prefs) = 'object'),
  updated_at  timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 3. SEGURIDAD
-- ─────────────────────────────────────────────
alter table public.haliel_configuracion enable row level security;
alter table public.usuario_preferencias enable row level security;

drop policy if exists "haliel_configuracion_leer"  on public.haliel_configuracion;
drop policy if exists "haliel_configuracion_admin" on public.haliel_configuracion;
create policy "haliel_configuracion_leer" on public.haliel_configuracion
  for select to authenticated using (true);
create policy "haliel_configuracion_admin" on public.haliel_configuracion
  for all to authenticated using (public.haliel_es_admin()) with check (public.haliel_es_admin());

drop policy if exists "usuario_preferencias_propias" on public.usuario_preferencias;
create policy "usuario_preferencias_propias" on public.usuario_preferencias
  for all to authenticated using (usuario_id = auth.uid()) with check (usuario_id = auth.uid());

revoke all on public.haliel_configuracion, public.usuario_preferencias from anon;
grant select, insert, update, delete on public.haliel_configuracion, public.usuario_preferencias to authenticated;
