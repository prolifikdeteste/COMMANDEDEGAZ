-- =====================================================================
-- GazExpress – schéma Supabase (PostgreSQL)
-- À coller dans Supabase > SQL Editor > Run (une seule fois).
-- NON TESTÉ : si une erreur s'affiche, copie-la moi et je la corrige.
-- Toute la logique sensible (prix, stock, attribution des courses) est
-- calculée côté base de données, jamais côté navigateur.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Référentiels ----------
create table quartiers(
  id serial primary key, nom text unique not null,
  lat double precision not null, lng double precision not null);

create table bouteilles(
  id serial primary key, marque text not null, taille_kg numeric not null,
  consigne_fcfa int not null default 0, unique(marque, taille_kg));

create table settings(
  id int primary key default 1 check (id = 1),
  base_fcfa int not null default 500,          -- frais de base de livraison
  km_fcfa int not null default 150,            -- prix par km
  service_fcfa int not null default 0,         -- frais de service GazExpress
  devis_minutes int not null default 5,        -- durée de validité du devis
  attente_moto_minutes int not null default 3);-- attente max avant "sans moto"
insert into settings default values;

-- ---------- Utilisateurs ----------
create table profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('client','chauffeur','depot','admin')),
  nom text not null, tel text not null,
  quartier_id int references quartiers(id),
  status text not null default 'pending' check (status in ('pending','ok','refuse')),
  created_at timestamptz default now());

create table drivers(
  id uuid primary key references profiles(id) on delete cascade,
  moto_plaque text, en_ligne boolean not null default false,
  lat double precision, lng double precision, position_at timestamptz,
  ok boolean not null default false);

create table depots(
  id uuid primary key references profiles(id) on delete cascade,
  nom text not null, quartier_id int references quartiers(id),
  lat double precision, lng double precision,
  ouvert boolean not null default false, ok boolean not null default false);

-- La contrainte qte_reservee <= qte_pleines empêche la vente de la même
-- bouteille deux fois, même si deux clients commandent en même temps.
create table stocks(
  depot_id uuid references depots(id) on delete cascade,
  bouteille_id int references bouteilles(id),
  qte_pleines int not null default 0 check (qte_pleines >= 0),
  qte_reservee int not null default 0 check (qte_reservee >= 0),
  prix_fcfa int not null,
  updated_at timestamptz default now(),
  primary key (depot_id, bouteille_id),
  check (qte_reservee <= qte_pleines));

-- ---------- Commandes ----------
create table orders(
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references profiles(id),
  depot_id uuid not null references depots(id),
  bouteille_id int not null references bouteilles(id),
  qty int not null check (qty between 1 and 3),
  type text not null check (type in ('echange','premiere')),
  quartier_id int references quartiers(id), repere text,
  prix_gaz int not null, consigne int not null default 0,
  livraison int not null, total int not null,
  statut text not null default 'devis' check (statut in
    ('devis','recherche','acceptee','en_route','livree','annulee','expire','sans_moto')),
  devis_expire_at timestamptz not null,
  recherche_debut timestamptz,
  driver_id uuid references drivers(id),
  created_at timestamptz default now());

create table order_codes(            -- code de remise, visible du client seul
  order_id uuid primary key references orders(id) on delete cascade, code text not null);

create table order_events(           -- historique horodaté des statuts
  id bigserial primary key, order_id uuid references orders(id) on delete cascade,
  statut text not null, user_id uuid, at timestamptz default now());

create table payments(               -- prête pour le Mobile Money
  id bigserial primary key, order_id uuid references orders(id),
  montant int not null, mode text check (mode in ('especes','mtn_momo','orange_money')),
  reference text, statut text default 'en_attente', created_at timestamptz default now());

create index on orders(statut);  create index on orders(client_id);
create index on orders(depot_id); create index on orders(driver_id);

-- ---------- Fonctions utilitaires ----------
-- distance routière estimée (km) = vol d'oiseau x 1,3
create function km(a1 double precision, o1 double precision, a2 double precision, o2 double precision)
returns double precision language sql immutable as $$
  select 12742 * asin(sqrt(sin(radians(a2-a1)/2)^2
         + cos(radians(a1)) * cos(radians(a2)) * sin(radians(o2-o1)/2)^2)) * 1.3 $$;

create function is_admin() returns boolean language sql stable security definer
set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin') $$;

create function log_event(o uuid, s text) returns void language sql security definer
set search_path = public as $$
  insert into order_events(order_id, statut, user_id) values (o, s, auth.uid()) $$;

create function release_stock(o orders) returns void language sql security definer
set search_path = public as $$
  update stocks set qte_reservee = greatest(0, qte_reservee - o.qty), updated_at = now()
  where depot_id = o.depot_id and bouteille_id = o.bouteille_id $$;

-- ---------- Choix du meilleur dépôt + prix ----------
create function pick_depot(p_bouteille int, p_qty int, p_type text, p_quartier int)
returns table(depot_id uuid, depot_nom text, prix_gaz int, consigne int, livraison int, total int)
language plpgsql stable security definer set search_path = public as $$
declare q quartiers; s settings; b bouteilles;
begin
  select * into q from quartiers where id = p_quartier;
  select * into s from settings;
  select * into b from bouteilles where id = p_bouteille;
  return query
  select d.id, d.nom,
         (st.prix_fcfa * p_qty),
         (case when p_type = 'premiere' then b.consigne_fcfa * p_qty else 0 end),
         fr.v,
         (st.prix_fcfa * p_qty) + (case when p_type = 'premiere' then b.consigne_fcfa * p_qty else 0 end) + fr.v
  from depots d
  join stocks st on st.depot_id = d.id and st.bouteille_id = p_bouteille
  cross join lateral (
    select (round((s.base_fcfa + s.km_fcfa * (
      coalesce((select min(km(dr.lat, dr.lng, d.lat, d.lng)) from drivers dr
                where dr.ok and dr.en_ligne and dr.lat is not null), 2)
      + km(d.lat, d.lng, q.lat, q.lng))) / 50) * 50 + s.service_fcfa)::int as v) fr
  where d.ok and d.ouvert and st.qte_pleines - st.qte_reservee >= p_qty
  order by 6 limit 1;
end $$;

create function estimate(p_bouteille int, p_qty int, p_type text, p_quartier int)
returns table(depot_id uuid, depot_nom text, prix_gaz int, consigne int, livraison int, total int)
language sql stable security definer set search_path = public as $$
  select * from pick_depot(p_bouteille, p_qty, p_type, p_quartier) $$;

create function motos_en_ligne() returns int language sql stable security definer
set search_path = public as $$
  select count(*)::int from drivers where ok and en_ligne $$;

-- ---------- Inscription et validation ----------
create function register(p_role text, p_nom text, p_tel text, p_quartier int,
                         p_moto text default null, p_depot_nom text default null)
returns void language plpgsql security definer set search_path = public as $$
declare q quartiers;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if p_role not in ('client','chauffeur','depot') then raise exception 'Rôle invalide'; end if;
  select * into q from quartiers where id = p_quartier;
  insert into profiles(id, role, nom, tel, quartier_id, status)
  values (auth.uid(), p_role, p_nom, p_tel, p_quartier, case when p_role = 'client' then 'ok' else 'pending' end);
  if p_role = 'chauffeur' then
    insert into drivers(id, moto_plaque, lat, lng) values (auth.uid(), p_moto, q.lat, q.lng);
  elsif p_role = 'depot' then
    insert into depots(id, nom, quartier_id, lat, lng) values (auth.uid(), coalesce(p_depot_nom, p_nom), p_quartier, q.lat, q.lng);
  end if;
end $$;

create function approve_profile(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  update profiles set status = case when p_ok then 'ok' else 'refuse' end where id = p_id;
  update drivers set ok = p_ok where id = p_id;
  update depots set ok = p_ok where id = p_id;
end $$;

-- ---------- Actions du dépôt et du chauffeur ----------
create function set_depot_open(p_open boolean) returns void language sql security definer
set search_path = public as $$
  update depots set ouvert = p_open where id = auth.uid() and ok $$;

create function set_stock(p_bouteille int, p_qte int, p_prix int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from depots where id = auth.uid() and ok) then raise exception 'Dépôt non validé'; end if;
  insert into stocks(depot_id, bouteille_id, qte_pleines, prix_fcfa)
  values (auth.uid(), p_bouteille, p_qte, p_prix)
  on conflict (depot_id, bouteille_id)
  do update set qte_pleines = excluded.qte_pleines, prix_fcfa = excluded.prix_fcfa, updated_at = now();
end $$;

create function set_driver_status(p_online boolean, p_lat double precision default null, p_lng double precision default null)
returns void language sql security definer set search_path = public as $$
  update drivers set en_ligne = p_online, lat = coalesce(p_lat, lat), lng = coalesce(p_lng, lng), position_at = now()
  where id = auth.uid() and ok $$;

-- ---------- Cycle de vie d'une commande ----------
-- 1. devis : réserve la bouteille et fige le prix (le serveur choisit le dépôt)
create function create_quote(p_bouteille int, p_qty int, p_type text, p_quartier int, p_repere text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare pk record; s settings; oid uuid;
begin
  if not exists(select 1 from profiles where id = auth.uid() and status = 'ok') then raise exception 'Compte non validé'; end if;
  select * into s from settings;
  if motos_en_ligne() = 0 then raise exception 'Aucune moto en ligne pour le moment'; end if;
  select * into pk from pick_depot(p_bouteille, p_qty, p_type, p_quartier);
  if pk.depot_id is null then raise exception 'Aucun dépôt ne peut livrer cette commande'; end if;
  update stocks set qte_reservee = qte_reservee + p_qty, updated_at = now()
  where depot_id = pk.depot_id and bouteille_id = p_bouteille and qte_pleines - qte_reservee >= p_qty;
  if not found then raise exception 'Stock insuffisant'; end if;
  insert into orders(client_id, depot_id, bouteille_id, qty, type, quartier_id, repere,
                     prix_gaz, consigne, livraison, total, devis_expire_at)
  values (auth.uid(), pk.depot_id, p_bouteille, p_qty, p_type, p_quartier, p_repere,
          pk.prix_gaz, pk.consigne, pk.livraison, pk.total, now() + make_interval(mins => s.devis_minutes))
  returning id into oid;
  insert into order_codes(order_id, code) values (oid, lpad((floor(random() * 10000))::int::text, 4, '0'));
  perform log_event(oid, 'devis');
  return oid;
end $$;

-- 2. le client valide : la recherche de moto démarre
create function validate_quote(p_order uuid) returns void language plpgsql security definer
set search_path = public as $$
begin
  update orders set statut = 'recherche', recherche_debut = now()
  where id = p_order and client_id = auth.uid() and statut = 'devis' and devis_expire_at > now();
  if not found then raise exception 'Devis expiré ou introuvable'; end if;
  perform log_event(p_order, 'recherche');
end $$;

create function cancel_order(p_order uuid) returns void language plpgsql security definer
set search_path = public as $$
declare o orders;
begin
  update orders set statut = 'annulee'
  where id = p_order and client_id = auth.uid() and statut in ('devis','recherche') returning * into o;
  if not found then raise exception 'Annulation impossible'; end if;
  perform release_stock(o);
  perform log_event(p_order, 'annulee');
end $$;

-- 3. courses proposées aux motos : rayon 1 km, +1 km toutes les 20 s, max 5 km
create function offers_for_driver()
returns table(id uuid, qty int, marque text, taille_kg numeric, depot_nom text, depot_quartier text,
              quartier text, livraison int, distance_km numeric)
language sql stable security definer set search_path = public as $$
  select o.id, o.qty, b.marque, b.taille_kg, d.nom, qd.nom, qc.nom, o.livraison,
         round(km(dr.lat, dr.lng, d.lat, d.lng)::numeric, 1)
  from orders o
  join drivers dr on dr.id = auth.uid() and dr.ok and dr.en_ligne and dr.lat is not null
  join depots d on d.id = o.depot_id
  join bouteilles b on b.id = o.bouteille_id
  left join quartiers qd on qd.id = d.quartier_id
  left join quartiers qc on qc.id = o.quartier_id
  where o.statut = 'recherche'
    and km(dr.lat, dr.lng, d.lat, d.lng) <= least(5, 1 + floor(extract(epoch from now() - o.recherche_debut) / 20))
  order by o.recherche_debut $$;

-- 4. premier arrivé, premier servi (la base garantit un seul gagnant)
create function accept_order(p_order uuid) returns void language plpgsql security definer
set search_path = public as $$
begin
  if not exists(select 1 from drivers where id = auth.uid() and ok and en_ligne) then raise exception 'Mets-toi en ligne'; end if;
  if exists(select 1 from orders where driver_id = auth.uid() and statut in ('acceptee','en_route')) then
    raise exception 'Termine ta course en cours'; end if;
  update orders set statut = 'acceptee', driver_id = auth.uid()
  where id = p_order and statut = 'recherche' and driver_id is null;
  if not found then raise exception 'Course déjà prise'; end if;
  perform log_event(p_order, 'acceptee');
end $$;

-- 5. bouteille récupérée au dépôt : le stock baisse vraiment
create function pickup_order(p_order uuid) returns void language plpgsql security definer
set search_path = public as $$
declare o orders;
begin
  update orders set statut = 'en_route' where id = p_order and driver_id = auth.uid() and statut = 'acceptee' returning * into o;
  if not found then raise exception 'Course introuvable'; end if;
  update stocks set qte_pleines = qte_pleines - o.qty, qte_reservee = qte_reservee - o.qty, updated_at = now()
  where depot_id = o.depot_id and bouteille_id = o.bouteille_id;
  perform log_event(p_order, 'en_route');
end $$;

-- 6. livraison confirmée avec le code du client
create function deliver_order(p_order uuid, p_code text) returns void language plpgsql security definer
set search_path = public as $$
declare o orders;
begin
  if not exists(select 1 from order_codes where order_id = p_order and code = p_code) then raise exception 'Code incorrect'; end if;
  update orders set statut = 'livree' where id = p_order and driver_id = auth.uid() and statut = 'en_route' returning * into o;
  if not found then raise exception 'Course introuvable'; end if;
  insert into payments(order_id, montant, mode, statut) values (p_order, o.total, 'especes', 'encaisse');
  perform log_event(p_order, 'livree');
end $$;

-- 7. nettoyage automatique : devis expirés et recherches sans moto
create function expire_orders() returns int language plpgsql security definer
set search_path = public as $$
declare o orders; s settings; n int := 0; nv text;
begin
  select * into s from settings;
  for o in select * from orders
           where (statut = 'devis' and devis_expire_at < now())
              or (statut = 'recherche' and recherche_debut < now() - make_interval(mins => s.attente_moto_minutes))
           for update skip locked
  loop
    nv := case when o.statut = 'devis' then 'expire' else 'sans_moto' end;
    update orders set statut = nv where id = o.id;
    perform release_stock(o);
    perform log_event(o.id, nv);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function release_stock(orders), log_event(uuid, text), expire_orders() from public, anon, authenticated;

-- ---------- Sécurité (RLS) : lecture seule, toute écriture passe par les fonctions ----------
alter table quartiers enable row level security;  alter table bouteilles enable row level security;
alter table settings enable row level security;   alter table profiles enable row level security;
alter table drivers enable row level security;    alter table depots enable row level security;
alter table stocks enable row level security;     alter table orders enable row level security;
alter table order_codes enable row level security; alter table order_events enable row level security;
alter table payments enable row level security;

create policy ref_q on quartiers   for select to authenticated using (true);
create policy ref_b on bouteilles  for select to authenticated using (true);
create policy ref_s on settings    for select to authenticated using (true);
create policy set_w on settings    for update to authenticated using (is_admin()) with check (is_admin());
create policy p_r on profiles      for select to authenticated using (id = auth.uid() or is_admin());
create policy dr_r on drivers      for select to authenticated using (id = auth.uid() or is_admin());
create policy dp_r on depots       for select to authenticated using (id = auth.uid() or is_admin());
create policy st_r on stocks       for select to authenticated using (depot_id = auth.uid() or is_admin());
create policy o_r on orders        for select to authenticated
  using (client_id = auth.uid() or driver_id = auth.uid() or depot_id = auth.uid() or is_admin());
create policy oc_r on order_codes  for select to authenticated
  using (exists(select 1 from orders o where o.id = order_id and o.client_id = auth.uid()));
create policy oe_r on order_events for select to authenticated
  using (exists(select 1 from orders o where o.id = order_id
        and (o.client_id = auth.uid() or o.driver_id = auth.uid() or o.depot_id = auth.uid() or is_admin())));
create policy pay_r on payments    for select to authenticated
  using (is_admin() or exists(select 1 from orders o where o.id = order_id and o.client_id = auth.uid()));

-- Temps réel (écrans qui se mettent à jour seuls)
alter publication supabase_realtime add table orders, stocks, drivers;

-- ---------- Données de départ ----------
-- ATTENTION : coordonnées APPROXIMATIVES, à vérifier une par une sur Google Maps.
insert into quartiers(nom, lat, lng) values
 ('Akwa',4.0511,9.7043),('Bonanjo',4.0453,9.6916),('Bonapriso',4.0290,9.6987),
 ('Deido',4.0668,9.7109),('New Bell',4.0425,9.7225),('Bépanda',4.0661,9.7406),
 ('Makepe',4.0828,9.7490),('Bonamoussadi',4.0905,9.7370),('Kotto',4.0950,9.7550),
 ('Ndokoti',4.0560,9.7380),('Bonabéri',4.0750,9.6700),('Logpom',4.0900,9.7650);

insert into bouteilles(marque, taille_kg, consigne_fcfa)
select m, t, case when t = 6 then 15000 else 35000 end
from unnest(array['Camgaz','Total','Tradex']) m, unnest(array[6, 12.5, 75]) t;

-- ---------- À faire ensuite, à la main ----------
-- 1) Te nommer administrateur (après ta première connexion dans l'app) :
--    insert into profiles(id, role, nom, tel, status)
--    values ('TON-UUID-AUTH', 'admin', 'Ton nom', '6XXXXXXXX', 'ok');
--    (ton UUID se trouve dans Authentication > Users)
-- 2) Activer l'extension pg_cron (Database > Extensions), puis lancer :
--    select cron.schedule('gazexpress-expire', '* * * * *', 'select expire_orders()');
