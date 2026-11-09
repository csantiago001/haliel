-- Haliel — Verificación (solo lectura): ¿se guardaron los pagos de las renovaciones?
-- No modifica nada.
select 1 as orden, '¿La ganancia la calcula Supabase sola?' as pregunta,
       case when is_generated = 'ALWAYS' then 'Sí (por eso fallaba al escribirla)' else 'No' end as respuesta
  from information_schema.columns
 where table_schema = 'public' and table_name = 'streaming_pagos' and column_name = 'ganancia'
union all
select 2, 'Renovaciones registradas en la auditoría', count(*)::text
  from auditoria where descripcion ilike 'Renovación venta%'
union all
select 3, 'Primera y última renovación', coalesce(min(created_at)::date::text, '-') || ' a ' || coalesce(max(created_at)::date::text, '-')
  from auditoria where descripcion ilike 'Renovación venta%'
union all
select 4, 'Pagos de renovación guardados (todos)', count(*)::text
  from streaming_pagos where notas ilike 'Renovación combo%'
union all
select 5, 'Pagos de renovación guardados antes de hoy', count(*)::text
  from streaming_pagos where notas ilike 'Renovación combo%' and fecha_pago < date '2026-11-08'
union all
select 6, 'Pagos en la tabla (cualquier tipo)', count(*)::text
  from streaming_pagos
order by orden;
