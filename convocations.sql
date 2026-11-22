-- =====================================================================
-- US Lamanon : convocations + rôle « coach »
-- À coller en entier dans Supabase → SQL Editor → Run
-- =====================================================================

-- 1) Ajouter le rôle « coach » (fonctionne que la colonne role soit du texte ou un type énuméré)
do $$
declare t text; c text;
begin
  select udt_name into t from information_schema.columns
   where table_schema = 'public' and table_name = 'membres' and column_name = 'role';
  if t in ('text', 'varchar', 'bpchar') then
    for c in select conname from pg_constraint
              where conrelid = 'public.membres'::regclass and contype = 'c'
                and pg_get_constraintdef(oid) ilike '%role%' loop
      execute format('alter table public.membres drop constraint %I', c);
    end loop;
    alter table public.membres add constraint membres_role_check
      check (role in ('membre', 'coach', 'bureau'));
  else
    execute format('alter type public.%I add value if not exists %L', t, 'coach');
  end if;
end $$;

-- 2) Tables
create table if not exists public.convocations (
  match_id   uuid not null references public.matchs(id)  on delete cascade,
  membre_id  uuid not null references public.membres(id) on delete cascade,
  created_by uuid references public.membres(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (match_id, membre_id)
);

create table if not exists public.convocation_matchs (
  match_id   uuid primary key references public.matchs(id) on delete cascade,
  rdv        text,
  envoyee_le timestamptz not null default now(),
  par        uuid references public.membres(id) on delete set null
);

-- 3) Sécurité : lecture pour les membres connectés, écriture uniquement via les fonctions ci-dessous
alter table public.convocations       enable row level security;
alter table public.convocation_matchs enable row level security;

drop policy if exists "lecture convocations" on public.convocations;
create policy "lecture convocations" on public.convocations
  for select to authenticated using (true);

drop policy if exists "lecture convocation_matchs" on public.convocation_matchs;
create policy "lecture convocation_matchs" on public.convocation_matchs
  for select to authenticated using (true);

grant select on public.convocations, public.convocation_matchs to authenticated;

-- 4) Fonction : enregistrer / remplacer la convocation d'un match
create or replace function public.envoyer_convocation(p_match uuid, p_membres uuid[], p_rdv text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_role text; v_equipe text; v_equipe_match text;
begin
  select role::text, equipe::text into v_role, v_equipe from membres where id = auth.uid() and actif;
  if v_role is null or v_role not in ('bureau', 'coach') then
    raise exception 'Accès refusé';
  end if;
  select equipe::text into v_equipe_match from matchs where id = p_match;
  if not found then raise exception 'Match introuvable'; end if;
  if v_role = 'coach' and v_equipe is distinct from v_equipe_match then
    raise exception 'Ce match ne concerne pas ton équipe';
  end if;

  delete from convocations where match_id = p_match;
  insert into convocations (match_id, membre_id, created_by)
    select p_match, x, auth.uid() from unnest(p_membres) as x;
  insert into convocation_matchs (match_id, rdv, envoyee_le, par)
    values (p_match, nullif(trim(p_rdv), ''), now(), auth.uid())
    on conflict (match_id) do update
      set rdv = excluded.rdv, envoyee_le = excluded.envoyee_le, par = excluded.par;
end $$;

-- 5) Fonction : annuler la convocation d'un match
create or replace function public.annuler_convocation(p_match uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_role text; v_equipe text; v_equipe_match text;
begin
  select role::text, equipe::text into v_role, v_equipe from membres where id = auth.uid() and actif;
  if v_role is null or v_role not in ('bureau', 'coach') then
    raise exception 'Accès refusé';
  end if;
  select equipe::text into v_equipe_match from matchs where id = p_match;
  if v_role = 'coach' and v_equipe is distinct from v_equipe_match then
    raise exception 'Ce match ne concerne pas ton équipe';
  end if;
  delete from convocations       where match_id = p_match;
  delete from convocation_matchs where match_id = p_match;
end $$;

revoke execute on function public.envoyer_convocation(uuid, uuid[], text) from public, anon;
revoke execute on function public.annuler_convocation(uuid)               from public, anon;
grant  execute on function public.envoyer_convocation(uuid, uuid[], text) to authenticated;
grant  execute on function public.annuler_convocation(uuid)               to authenticated;

-- 6) Composition d'équipe (formation + joueurs placés sur le terrain)
alter table public.convocation_matchs add column if not exists formation text;
alter table public.convocation_matchs add column if not exists compo jsonb;

create or replace function public.enregistrer_compo(p_match uuid, p_formation text, p_compo jsonb)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_role text; v_equipe text; v_equipe_match text;
begin
  select role::text, equipe::text into v_role, v_equipe from membres where id = auth.uid() and actif;
  if v_role is null or v_role not in ('bureau', 'coach') then
    raise exception 'Accès refusé';
  end if;
  select equipe::text into v_equipe_match from matchs where id = p_match;
  if v_role = 'coach' and v_equipe is distinct from v_equipe_match then
    raise exception 'Ce match ne concerne pas ton équipe';
  end if;
  update convocation_matchs set formation = p_formation, compo = p_compo where match_id = p_match;
  if not found then raise exception 'Enregistre d''abord la convocation'; end if;
end $$;

revoke execute on function public.enregistrer_compo(uuid, text, jsonb) from public, anon;
grant  execute on function public.enregistrer_compo(uuid, text, jsonb) to authenticated;
