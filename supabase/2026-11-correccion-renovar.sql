-- Haliel — Corrección: renovar en Entretenimiento
-- La columna 'ganancia' de streaming_pagos la calcula Supabase sola; la función intentaba escribirla.
-- Solo reemplaza la función de renovar. No toca datos.

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

grant execute on function public.haliel_renovar_venta_streaming(uuid, jsonb, date, date, int, text) to authenticated;
