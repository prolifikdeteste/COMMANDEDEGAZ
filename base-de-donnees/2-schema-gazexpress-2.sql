-- =====================================================================
-- GazExpress – complément n°2 (à lancer APRÈS schema-gazexpress.sql)
-- Supabase > SQL Editor > Run.  NON TESTÉ : copie-moi toute erreur.
-- Fournit my_orders() : les commandes de l'utilisateur connecté, avec les
-- noms et téléphones qu'il a le droit de voir :
--   client  -> ses commandes, le nom/tel de la moto, son code de remise
--   moto    -> ses courses ; nom/tel du client seulement une fois la course acceptée
--   dépôt   -> les commandes de son dépôt ; nom de la moto
--   admin   -> tout
-- =====================================================================

create or replace function my_orders()
returns table(
  id uuid, statut text, qty int, type text, marque text, taille_kg numeric,
  prix_gaz int, consigne int, livraison int, total int,
  depot_nom text, depot_quartier text, quartier text, repere text,
  client_nom text, client_tel text, driver_nom text, driver_tel text,
  devis_expire_at timestamptz, created_at timestamptz, code text, hist jsonb)
language sql stable security definer set search_path = public as $$
  select o.id, o.statut, o.qty, o.type, b.marque, b.taille_kg,
         o.prix_gaz, o.consigne, o.livraison, o.total,
         d.nom, qd.nom, qc.nom, o.repere,
         pc.nom,
         case when o.client_id = auth.uid() or is_admin()
                or (o.driver_id = auth.uid() and o.statut in ('acceptee','en_route','livree'))
              then pc.tel end,
         pd.nom,
         case when o.driver_id is not null
                and (o.client_id = auth.uid() or o.depot_id = auth.uid() or o.driver_id = auth.uid() or is_admin())
              then pd.tel end,
         o.devis_expire_at, o.created_at,
         case when o.client_id = auth.uid()
              then (select c.code from order_codes c where c.order_id = o.id) end,
         (select jsonb_agg(jsonb_build_object('s', e.statut, 't', e.at) order by e.at)
            from order_events e where e.order_id = o.id)
  from orders o
  join bouteilles b on b.id = o.bouteille_id
  join depots d on d.id = o.depot_id
  join profiles pc on pc.id = o.client_id
  left join profiles pd on pd.id = o.driver_id
  left join quartiers qd on qd.id = d.quartier_id
  left join quartiers qc on qc.id = o.quartier_id
  where o.client_id = auth.uid() or o.driver_id = auth.uid() or o.depot_id = auth.uid() or is_admin()
  order by o.created_at desc
  limit 100 $$;
