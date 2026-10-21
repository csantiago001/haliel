-- ════════════════════════════════════════════════════════════════════
-- HALIEL · MIS CRÉDITOS (control personal y privado del administrador)
--
-- CÓMO EJECUTARLO
--   1. Entra a https://supabase.com → tu proyecto → SQL Editor → New query.
--   2. Pega TODO este archivo y pulsa "Run".
--   3. Recarga la app. El menú "Mis créditos" se activa solo.
--
-- Es seguro ejecutarlo más de una vez: no borra ni modifica datos existentes.
--
-- PRIVACIDAD
--   · Solo un administrador activo puede leer o escribir en estas tablas.
--   · Cada administrador ve ÚNICAMENTE sus propias personas, créditos y abonos.
--   · No se mezcla con cajas, ventas, reportes, ni con "Abonos y saldos" de
--     los clientes de streaming. El enlace con un cliente de Entretenimiento
--     es solo una referencia: borrar el cliente no borra sus créditos.
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
-- 1. PERSONAS A LAS QUE LES PRESTAS
--    cliente_id: id del cliente de Entretenimiento enlazado (opcional)
-- ─────────────────────────────────────────────
create table if not exists public.mc_personas (
  id          uuid primary key default gen_random_uuid(),
  usuario_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nombre      text not null check (length(trim(nombre)) between 1 and 80),
  telefono    text check (telefono is null or length(telefono) <= 20),
  nota        text check (nota is null or length(nota) <= 160),
  cliente_id  text,
  created_at  timestamptz not null default now()
);
create index if not exists mc_personas_usuario_idx on public.mc_personas (usuario_id);
create unique index if not exists mc_personas_cliente_uidx on public.mc_personas (usuario_id, cliente_id) where cliente_id is not null;

-- ─────────────────────────────────────────────
-- 2. MOVIMIENTOS (historial completo, nada se borra)
--    credito → le prestaste (suma a la deuda)
--    interes → interés cargado a un crédito (suma)
--    abono   → te pagó (resta)
--    perdon  → decidiste no cobrar ese valor (resta)
--    anulado = true → el movimiento se ignora en los saldos, pero sigue visible
-- ─────────────────────────────────────────────
create table if not exists public.mc_movimientos (
  id            uuid primary key default gen_random_uuid(),
  usuario_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  persona_id    uuid not null references public.mc_personas(id) on delete cascade,
  tipo          text not null check (tipo in ('credito','interes','abono','perdon')),
  monto         numeric(14,2) not null check (monto > 0),
  fecha         date not null default current_date,
  concepto      text check (concepto is null or length(concepto) <= 160),
  metodo_pago   text,
  fecha_limite  date,
  interes_pct   numeric(5,2) not null default 0 check (interes_pct >= 0 and interes_pct <= 100),
  credito_id    uuid references public.mc_movimientos(id) on delete set null,
  anulado       boolean not null default false,
  anulado_motivo text,
  created_at    timestamptz not null default now()
);
create index if not exists mc_movimientos_persona_idx on public.mc_movimientos (usuario_id, persona_id, fecha);

-- ─────────────────────────────────────────────
-- 3. CONFIGURACIÓN: datos de pago del mensaje, firma e intereses
-- ─────────────────────────────────────────────
create table if not exists public.mc_config (
  usuario_id   uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  datos_pago   text check (datos_pago is null or length(datos_pago) <= 1500),
  firma        text check (firma is null or length(firma) <= 60),
  intereses    boolean not null default false,
  updated_at   timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 4. SEGURIDAD: solo el administrador dueño de cada fila
-- ─────────────────────────────────────────────
alter table public.mc_personas    enable row level security;
alter table public.mc_movimientos enable row level security;
alter table public.mc_config      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['mc_personas','mc_movimientos','mc_config'] loop
    execute format('drop policy if exists "%1$s_dueno" on public.%1$I', t);
    execute format('create policy "%1$s_dueno" on public.%1$I for all to authenticated
                      using (usuario_id = auth.uid() and public.haliel_es_admin())
                      with check (usuario_id = auth.uid() and public.haliel_es_admin())', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- Un movimiento solo puede pertenecer a una persona del mismo administrador
create or replace function public.mc_validar_movimiento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.mc_personas p where p.id = new.persona_id and p.usuario_id = new.usuario_id) then
    raise exception 'La persona no existe';
  end if;
  return new;
end;
$$;
drop trigger if exists mc_validar_movimiento on public.mc_movimientos;
create trigger mc_validar_movimiento before insert or update on public.mc_movimientos
  for each row execute function public.mc_validar_movimiento();
