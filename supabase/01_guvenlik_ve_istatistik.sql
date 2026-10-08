-- Minilist: güvenlik düzeltmeleri + istatistik görüntüleyici rolü
-- Supabase > SQL Editor'da bir kez çalıştırın. Tekrar çalıştırmak güvenlidir.
-- Uygulamanın mevcut davranışını bozmaz; misafir fonksiyonlarının imzaları aynı kalır.

begin;

-- 1) İç tabloları doğrudan API erişimine kapat.
--    SECURITY DEFINER fonksiyonlar tablo sahibi olarak çalıştığı için etkilenmez.
do $$
declare t text;
begin
  foreach t in array array['page_transfers', 'rate_log', 'admins', 'product_totals'] loop
    if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
               where n.nspname = 'public' and c.relname = t and c.relkind = 'r') then
      execute format('alter table public.%I enable row level security', t);
    end if;
  end loop;
end $$;

-- 2) Sayfa sahibi plan, sahiplik, kimlik ve adres alanlarını API'den değiştiremesin.
--    (Eskiden: sb.from('pages').update({plan:'pro'}) ile ücretsiz Pro alınabiliyordu.)
--    Admin RPC'leri, devir fonksiyonları ve ödeme webhook'u (service_role) etkilenmez.
create or replace function public.protect_page_cols()
 returns trigger
 language plpgsql
 security invoker
 set search_path to 'public'
as $$
begin
  if current_user in ('anon', 'authenticated') and not is_admin() then
    if tg_op = 'INSERT' then
      new.plan := 'free';
      new.plan_source := null;
    elsif new.id is distinct from old.id
       or new.owner is distinct from old.owner
       or new.slug is distinct from old.slug
       or new.plan is distinct from old.plan
       or new.plan_source is distinct from old.plan_source
       or new.created_at is distinct from old.created_at then
      raise exception 'Bu alan değiştirilemez';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists protect_page_cols on public.pages;
create trigger protect_page_cols before insert or update on public.pages
  for each row execute function public.protect_page_cols();

-- 3) Misafir girdilerine sunucu tarafında sınır (tarayıcıdaki maxlength atlanabilir).
create or replace function public.guest_letter(p_slug text, p_name text, p_body text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 80
     or length(trim(coalesce(p_body, ''))) not between 1 and 1000 then
    raise exception 'invalid';
  end if;
  insert into letters(page_id, name, body) values (guest_page(p_slug), trim(p_name), trim(p_body));
end $$;

create or replace function public.guest_suggest(p_slug text, p_name text, p_from text, p_note text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare pid uuid;
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 60
     or length(trim(coalesce(p_from, ''))) not between 1 and 80
     or length(coalesce(p_note, '')) > 200 then
    raise exception 'invalid';
  end if;
  pid := guest_page(p_slug);
  if (select count(*) from name_suggestions where page_id = pid) >= 200 then raise exception 'Çok fazla öneri var'; end if;
  insert into name_suggestions(page_id, name, from_name, note) values (pid, trim(p_name), trim(p_from), nullif(trim(p_note), ''));
end $$;

create or replace function public.guest_product_suggest(p_slug text, p_name text, p_from text, p_link text, p_note text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare pid uuid;
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 120
     or length(trim(coalesce(p_from, ''))) not between 1 and 80 then
    raise exception 'invalid';
  end if;
  pid := guest_page(p_slug);
  if (select count(*) from product_suggestions where page_id = pid) >= 100 then raise exception 'Çok fazla öneri var'; end if;
  insert into product_suggestions(page_id, name, from_name, link, note)
  values (pid, trim(p_name), trim(p_from), case when p_link ~* '^https?://' then left(p_link, 500) end, left(p_note, 300));
end $$;

create or replace function public.guest_guess(p_slug text, p_name text, p_gender text, p_gname text, p_date date, p_weight integer)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 80
     or (p_gender is not null and p_gender not in ('kiz', 'erkek'))
     or length(coalesce(p_gname, '')) > 60
     or (p_date is not null and p_date not between current_date - 60 and current_date + 300)
     or (p_weight is not null and p_weight not between 300 and 7000) then
    raise exception 'invalid';
  end if;
  insert into guesses(page_id, name, gender, guess_name, guess_date, guess_weight)
  values (guest_page(p_slug), trim(p_name), p_gender, nullif(trim(p_gname), ''), p_date, p_weight);
end $$;

-- 4) Kalp: hız sınırına tabi (eskiden sınırsız artırılabiliyordu).
create or replace function public.heart(uid bigint)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare pid uuid;
begin
  select page_id into pid from updates where id = uid;
  if pid is null then raise exception 'not found'; end if;
  if not rate_ok(pid) then raise exception 'Çok fazla deneme, lütfen daha sonra tekrar deneyin'; end if;
  update updates set hearts = hearts + 1 where id = uid;
end $$;

-- 5) İstatistik görüntüleyici: sadece sayılar. admins tablosundan ayrı,
--    bu yüzden is_admin() bu hesaplar için asla true dönmez.
create table if not exists public.stats_viewers (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.stats_viewers enable row level security;

create or replace function public.is_stats_viewer()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $$ select exists (select 1 from stats_viewers where user_id = auth.uid()) $$;

drop function if exists public.stats_list_pages();
create function public.stats_list_pages()
 returns table(code text, created_on date, plan text, lang text, born boolean,
               products int, reservations int, contributions int, letters int,
               updates int, hearts int, name_suggestions int, product_suggestions int, guesses int)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $$
begin
  if not (is_admin() or is_stats_viewer()) then raise exception 'forbidden'; end if;
  return query
    select left(md5(g.id::text), 6), g.created_at::date, g.plan, g.lang, g.born,
      (select count(*)::int from products p where p.page_id = g.id),
      (select count(*)::int from reservations r join products p on p.id = r.product_id where p.page_id = g.id and r.amount = 0),
      (select count(*)::int from reservations r join products p on p.id = r.product_id where p.page_id = g.id and r.amount > 0),
      (select count(*)::int from letters l where l.page_id = g.id),
      (select count(*)::int from updates u where u.page_id = g.id),
      (select coalesce(sum(u.hearts), 0)::int from updates u where u.page_id = g.id),
      (select count(*)::int from name_suggestions s where s.page_id = g.id),
      (select count(*)::int from product_suggestions s where s.page_id = g.id),
      (select count(*)::int from guesses s where s.page_id = g.id)
    from pages g
    order by g.created_at desc;
end $$;

revoke execute on function public.stats_list_pages() from public, anon;
grant execute on function public.stats_list_pages() to authenticated;
revoke execute on function public.is_stats_viewer() from public, anon;
grant execute on function public.is_stats_viewer() to authenticated;

-- 6) İstatistik hesabını ekle. Hesap önce uygulamadan kayıt olmuş olmalı;
--    olmadıysa kayıt olduktan sonra sadece bu satırı tekrar çalıştırın.
insert into public.stats_viewers(user_id)
select id from auth.users where lower(email) = lower('elcumanhuseyin@gmail.com')
on conflict do nothing;

commit;

-- Kontrol: istatistik hesabı eklendi mi? (1 satır görmelisiniz)
select u.email from public.stats_viewers v join auth.users u on u.id = v.user_id;
